// One price estimate per shopping list: each line is read locally against
// the dictionary, the session cache answers what it can, and the rest comes
// from Open Prices in a few batched requests under per-run and per-session
// budgets. Contract: docs/SHOPPING-PRICES.md.
//
// Nothing here is written to disk: the cache lives as long as the signed-in
// session's home page, and only category tags and barcodes leave the device.

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:clock/clock.dart';

import '../models/shopping_price.dart';
import '../models/shopping_price_dictionary.dart';
import 'crash_reporter.dart';
import 'eatova_http.dart' show ChainDeadline;
import 'local_day.dart';
import 'open_prices_api.dart';
import 'shopping_price_aggregation.dart';

abstract interface class ShoppingPriceService {
  /// Starts estimating [lines]; never blocks, never throws.
  ShoppingPriceRun estimate(
    List<PriceRequestLine> lines, {
    required PriceRegion region,
  });

  /// Cancels every run and drops the cache.
  void dispose();
}

/// One estimate in flight.
class ShoppingPriceRun {
  ShoppingPriceRun({
    required this.initial,
    required this.result,
    required void Function() onCancel,
  }) : _onCancel = onCancel;

  /// Lines settled without a request: local outcomes and cache hits.
  final Map<String, LinePrice> initial;

  /// Every line's outcome; completes with [ShoppingPriceCancelled] once
  /// [cancel] ran first.
  final Future<Map<String, LinePrice>> result;
  final void Function() _onCancel;

  /// Closes the connection; requests in flight fail and are not retried.
  void cancel() => _onCancel();
}

class ShoppingPriceCancelled implements Exception {
  const ShoppingPriceCancelled();

  @override
  String toString() => 'ShoppingPriceCancelled';
}

/// A cached aggregate; null means the lookup found too few prices.
class PriceCacheHit {
  const PriceCacheHit(this.aggregate);
  final PriceAggregate? aggregate;
}

/// Aggregates for the session, in memory only. An entry is valid on the
/// local day it was written and for under [ttl]; failures are never stored.
class ShoppingPriceCache {
  ShoppingPriceCache({
    this.maxEntries = 500,
    this.ttl = const Duration(hours: 12),
  });

  final int maxEntries;
  final Duration ttl;
  final LinkedHashMap<String, ({DateTime at, PriceAggregate? value})> _entries =
      LinkedHashMap();

  int get length => _entries.length;

  PriceCacheHit? read(String key, DateTime now) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (localDayKey(entry.at) != localDayKey(now) ||
        now.isBefore(entry.at) ||
        now.difference(entry.at) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return PriceCacheHit(entry.value);
  }

  void write(String key, PriceAggregate? value, DateTime now) {
    _entries
      ..remove(key)
      ..[key] = (at: now, value: value);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}

class OpenPricesShoppingPriceService implements ShoppingPriceService {
  OpenPricesShoppingPriceService(
    this.source, {
    ShoppingPriceCache? cache,
    this.maxRequestsPerRun = 16,
    this.maxConcurrent = 2,
    this.runBudget = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
    this.sessionLimit = 48,
    this.sessionWindow = const Duration(minutes: 10),
    this.maxProductLookups = 6,
    this.maxTagPages = 8,
    this.maxCategoryPages = 2,
  }) : cache = cache ?? ShoppingPriceCache();

  final OpenPricesSource source;
  final ShoppingPriceCache cache;
  final int maxRequestsPerRun, maxConcurrent;
  final Duration runBudget, retryDelay;

  /// Rolling ceiling over all runs of the session.
  final int sessionLimit;
  final Duration sessionWindow;
  final int maxProductLookups, maxTagPages, maxCategoryPages;

  final Queue<DateTime> _recentRequests = Queue();

  /// Barcode -> categories (null: unknown product), for the session.
  final LinkedHashMap<String, List<String>?> _categories = LinkedHashMap();
  final Set<_PriceRun> _runs = {};
  bool _schemaReported = false;
  bool _disposed = false;

  @override
  ShoppingPriceRun estimate(
    List<PriceRequestLine> lines, {
    required PriceRegion region,
  }) {
    final run = _PriceRun(this, lines, region);
    if (_disposed) {
      run.cancel();
    } else {
      _runs.add(run);
      run.start();
    }
    return run.handle;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final run in _runs.toList()) {
      run.cancel();
    }
    _runs.clear();
    cache.clear();
    _categories.clear();
  }

  bool _sessionAllows(DateTime now) {
    while (_recentRequests.isNotEmpty &&
        now.difference(_recentRequests.first) >= sessionWindow) {
      _recentRequests.removeFirst();
    }
    return _recentRequests.length < sessionLimit;
  }

  void _rememberCategories(String code, List<String>? tags) {
    _categories
      ..remove(code)
      ..[code] = tags;
    while (_categories.length > cache.maxEntries) {
      _categories.remove(_categories.keys.first);
    }
  }

  /// A changed answer shape is reported once per session, without content.
  void _reportSchema() {
    if (_schemaReported) return;
    _schemaReported = true;
    unawaited(
      CrashReporter.capture(
        const OpenPricesFormatException(),
        StackTrace.current,
        context: 'open_prices',
      ),
    );
  }
}

/// A line with what can be read from it locally.
class _LinePlan {
  _LinePlan(this.line) : quantity = lineQuantity(line) {
    match = matchPriceEntry(line.label, quantity: quantity);
  }

  final PriceRequestLine line;
  final PriceQuantity? quantity;
  late final PriceMatch match;
}

/// What a line still needs, or its outcome.
sealed class _Step {
  const _Step();
}

final class _Done extends _Step {
  const _Done(this.price);
  final LinePrice price;
}

final class _NeedCode extends _Step {
  const _NeedCode(this.code);
  final String code;
}

final class _NeedCategories extends _Step {
  const _NeedCategories(this.code);
  final String code;
}

final class _NeedEntry extends _Step {
  const _NeedEntry(this.entry);
  final PriceEntry entry;
}

class _BudgetExceeded implements Exception {
  const _BudgetExceeded();
}

final RegExp _barcode = RegExp(r'^\d{4,20}$');

class _PriceRun {
  _PriceRun(this.service, List<PriceRequestLine> lines, this.region)
    : plans = [for (final line in lines) _LinePlan(line)] {
    final now = clock.now();
    today = DateTime(now.year, now.month, now.day);
    todayKey = localDayKey(today);
    since = priceWindowStart(today);
    _result.future.ignore();
  }

  final OpenPricesShoppingPriceService service;
  final PriceRegion region;
  final List<_LinePlan> plans;
  late final DateTime today;
  late final String todayKey, since;
  final Map<String, LinePrice> _initial = {};
  final Completer<Map<String, LinePrice>> _result = Completer();
  late final ShoppingPriceRun handle = ShoppingPriceRun(
    initial: _initial,
    result: _result.future,
    onCancel: cancel,
  );

  final Map<String, PriceAggregate?> _codes = {};
  final Set<String> _codesFailed = {};
  final Set<String> _categoriesFailed = {};

  /// Barcodes beyond the lookup cap: priced as unknown this run.
  final Set<String> _categoriesSkipped = {};
  final Map<String, PriceAggregate?> _entries = {};
  final Set<String> _entriesFailed = {};

  List<OpenPriceRow>? _categoryRows;
  bool _categorySnapshotTried = false;
  final List<OpenPriceRow> _tagRows = [];
  final Map<String, bool> _tagsFetched = {};

  OpenPricesConnection? _connection;
  ChainDeadline? _deadline;
  final List<Completer<void>> _sleeps = [];
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();
  bool _cancelled = false;
  int _requests = 0, _pages = 0;
  bool _partial = false;

  String _codeKey(String code) => '${region.countryCode}|$todayKey|code:$code';
  String _entryKey(PriceEntry entry) =>
      '${region.countryCode}|$todayKey|v$kPriceDictionaryVersion'
      '|entry:${entry.id}';

  void start() {
    final pending = <_LinePlan>[];
    for (final plan in plans) {
      if (_decide(plan) case _Done(:final price)) {
        _initial[plan.line.id] = price;
      } else {
        pending.add(plan);
      }
    }
    if (pending.isEmpty) {
      _finish(Map.of(_initial));
      return;
    }
    _execute().then(
      _finish,
      onError: (Object error, StackTrace stack) {
        if (_cancelled) return;
        dev.log(
          'estimate failed',
          error: error,
          stackTrace: stack,
          name: 'open_prices',
        );
        _finish(_outcomes());
      },
    );
  }

  void _finish(Map<String, LinePrice> prices) {
    service._runs.remove(this);
    if (!_result.isCompleted) _result.complete(prices);
  }

  void cancel() {
    if (_cancelled || _result.isCompleted) return;
    _cancelled = true;
    service._runs.remove(this);
    for (final sleep in _sleeps) {
      if (!sleep.isCompleted) {
        sleep.completeError(const ShoppingPriceCancelled());
      }
    }
    for (final waiter in _waiting) {
      if (!waiter.isCompleted) {
        waiter.completeError(const ShoppingPriceCancelled());
      }
    }
    _connection?.close();
    _deadline?.dispose();
    _result.completeError(const ShoppingPriceCancelled());
  }

  /// The line's outcome from what is known so far, or what it still needs.
  _Step _decide(_LinePlan plan) {
    final line = plan.line;
    final match = plan.match;
    if (match.skipped) return const _Done(LinePriceSkipped());
    // An amount that cannot be converted is never priced.
    if (line.grams == null && line.amount != null && plan.quantity == null) {
      return const _Done(LinePriceNoData());
    }
    // The exact barcode first; when it has no prices (or failed), the name
    // or the product's categories still price the line. Open Prices knows
    // numeric barcodes only.
    final code = switch (line.productCode) {
      final value? when _barcode.hasMatch(value) => value,
      _ => null,
    };
    if (code != null && !_codesFailed.contains(code)) {
      if (!_knowsCode(code)) return _NeedCode(code);
      if (_codes[code] case final exact?) {
        return _Done(priceLine(line, exact, entry: match.entry));
      }
    }
    var entry = match.entry;
    if (entry == null) {
      if (code == null || match.blocked || _categoriesSkipped.contains(code)) {
        return const _Done(LinePriceNoData());
      }
      if (_categoriesFailed.contains(code)) {
        return const _Done(LinePriceUnavailable());
      }
      if (!service._categories.containsKey(code)) return _NeedCategories(code);
      final tags = service._categories[code];
      entry = tags == null ? null : priceEntryForCategories(tags);
      if (entry == null) return const _Done(LinePriceNoData());
    }
    if (!linePriceable(line, entry, impliedUnit: match.impliedUnit)) {
      return const _Done(LinePriceNoData());
    }
    if (_entriesFailed.contains(entry.id)) {
      return const _Done(LinePriceUnavailable());
    }
    if (!_knowsEntry(entry)) return _NeedEntry(entry);
    return _Done(
      priceLine(
        line,
        _entries[entry.id],
        entry: entry,
        impliedUnit: match.impliedUnit,
      ),
    );
  }

  bool _knowsCode(String code) {
    if (_codes.containsKey(code)) return true;
    final hit = service.cache.read(_codeKey(code), clock.now());
    if (hit == null) return false;
    _codes[code] = hit.aggregate;
    return true;
  }

  bool _knowsEntry(PriceEntry entry) {
    if (_entries.containsKey(entry.id)) return true;
    final hit = service.cache.read(_entryKey(entry), clock.now());
    if (hit == null) return false;
    _entries[entry.id] = hit.aggregate;
    return true;
  }

  List<_Step> _steps() => [for (final plan in plans) _decide(plan)];

  Map<String, LinePrice> _outcomes() => {
    for (final plan in plans)
      plan.line.id: switch (_decide(plan)) {
        _Done(:final price) => price,
        _ => const LinePriceUnavailable(),
      },
  };

  Future<Map<String, LinePrice>> _execute() async {
    _connection = service.source.connect();
    _deadline = ChainDeadline(service.runBudget, operation: 'openPrices.run');
    try {
      // (a) Exact barcodes and the loose-goods snapshot, side by side.
      var steps = _steps();
      final codes = {
        for (final step in steps)
          if (step case _NeedCode(:final code)) code,
      }.toList();
      await Future.wait([
        if (codes.isNotEmpty) _fetchCodes(codes),
        if (_needsSnapshot(steps)) _fetchCategorySnapshot(),
      ]);

      // (b) Categories of barcodes without their own prices or a name.
      steps = _steps();
      final lookups = <String, double>{};
      for (var i = 0; i < plans.length; i++) {
        if (steps[i] case _NeedCategories(:final code)) {
          lookups[code] = (lookups[code] ?? 0) + (plans[i].line.grams ?? 0);
        }
      }
      final ordered = lookups.keys.toList()
        ..sort((a, b) => lookups[b]!.compareTo(lookups[a]!));
      _categoriesSkipped.addAll(ordered.skip(service.maxProductLookups));
      await Future.wait(
        ordered.take(service.maxProductLookups).map(_fetchCategories),
      );

      // (c) Product prices for every entry still missing, in one overlap.
      steps = _steps();
      final entries = {
        for (final step in steps)
          if (step case _NeedEntry(:final entry)) entry.id: entry,
      }.values.toList();
      if (entries.isNotEmpty) {
        await Future.wait([
          _fetchTags(entries),
          if (_needsSnapshot(steps)) _fetchCategorySnapshot(),
        ]);
        for (final entry in entries) {
          _aggregate(entry);
        }
      }
    } finally {
      _deadline?.dispose();
      _connection?.close();
    }
    if (_cancelled) throw const ShoppingPriceCancelled();
    final outcomes = _outcomes();
    dev.log(
      'requests=$_requests pages=$_pages '
      'priced=${outcomes.values.whereType<LinePriceEstimate>().length} '
      'partial=$_partial',
      name: 'open_prices',
    );
    return outcomes;
  }

  bool _needsSnapshot(List<_Step> steps) =>
      !_categorySnapshotTried &&
      steps.any((s) => s is _NeedEntry && s.entry.categoryPrices);

  void _aggregate(PriceEntry entry) {
    final tagsOk = entry.productTags.every((tag) => _tagsFetched[tag] == true);
    final categoriesOk = !entry.categoryPrices || _categoryRows != null;
    if (!tagsOk || !categoriesOk) {
      _entriesFailed.add(entry.id);
      return;
    }
    final aggregate = aggregatePriceObservations(
      priceObservations(
        entry,
        [..._tagRows, ...?_categoryRows],
        region: region,
        today: today,
      ),
      basis: entry.basis,
    );
    _entries[entry.id] = aggregate;
    service.cache.write(_entryKey(entry), aggregate, clock.now());
  }

  Future<void> _fetchCodes(List<String> codes) async {
    for (var i = 0; i < codes.length; i += OpenPricesQuery.maxCodes) {
      final chunk = codes.sublist(
        i,
        (i + OpenPricesQuery.maxCodes).clamp(0, codes.length),
      );
      try {
        final page = await _page(
          OpenPricesQuery.barcodes(region, since, chunk),
        );
        for (final code in chunk) {
          final aggregate = exactProductAggregate(
            code,
            page.items,
            region: region,
            today: today,
          );
          _codes[code] = aggregate;
          service.cache.write(_codeKey(code), aggregate, clock.now());
        }
      } on ShoppingPriceCancelled {
        rethrow;
      } catch (error) {
        _noteFailure(error);
        _codesFailed.addAll(chunk);
      }
    }
  }

  Future<void> _fetchCategorySnapshot() async {
    _categorySnapshotTried = true;
    final rows = <OpenPriceRow>[];
    try {
      for (var number = 1; number <= service.maxCategoryPages; number++) {
        final page = await _page(
          OpenPricesQuery.categoryPrices(region, since, page: number),
        );
        rows.addAll(page.items);
        if (number >= page.pages) break;
        if (number == service.maxCategoryPages) _partial = true;
      }
      _categoryRows = rows;
    } on ShoppingPriceCancelled {
      rethrow;
    } catch (error) {
      _noteFailure(error);
    }
  }

  Future<void> _fetchCategories(String code) async {
    try {
      final tags = await _request((c) => c.productCategories(code));
      service._rememberCategories(code, tags);
    } on ShoppingPriceCancelled {
      rethrow;
    } catch (error) {
      _noteFailure(error);
      _categoriesFailed.add(code);
    }
  }

  Future<void> _fetchTags(List<PriceEntry> entries) async {
    final tags = <String>{
      for (final entry in entries) ...entry.productTags,
    }.toList();
    var budget = service.maxTagPages;
    for (var i = 0; i < tags.length; i += OpenPricesQuery.maxTags) {
      final chunk = tags.sublist(
        i,
        (i + OpenPricesQuery.maxTags).clamp(0, tags.length),
      );
      var ok = true;
      try {
        for (var number = 1; ; number++) {
          if (budget <= 0) {
            _partial = true;
            ok = number > 1;
            break;
          }
          budget--;
          final page = await _page(
            OpenPricesQuery.tags(region, since, chunk, page: number),
          );
          _tagRows.addAll(page.items);
          if (number >= page.pages) break;
        }
      } on ShoppingPriceCancelled {
        rethrow;
      } catch (error) {
        _noteFailure(error);
        ok = false;
      }
      for (final tag in chunk) {
        _tagsFetched[tag] = ok;
      }
    }
  }

  Future<OpenPricesPage> _page(Map<String, String> query) async {
    final page = await _request((c) => c.prices(query));
    _pages++;
    return page;
  }

  void _noteFailure(Object error) {
    if (error is FormatException) service._reportSchema();
  }

  /// One request through the pool and both budgets; one retry after
  /// [OpenPricesShoppingPriceService.retryDelay] for a transient failure.
  Future<T> _request<T>(Future<T> Function(OpenPricesConnection c) call) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _once(call);
      } on ShoppingPriceCancelled {
        rethrow;
      } catch (error) {
        if (_cancelled) throw const ShoppingPriceCancelled();
        if (attempt > 0 || !_retryable(error)) rethrow;
        await _sleep(service.retryDelay);
      }
    }
  }

  Future<T> _once<T>(Future<T> Function(OpenPricesConnection c) call) async {
    await _acquire();
    try {
      if (_cancelled) throw const ShoppingPriceCancelled();
      final now = clock.now();
      if (_requests >= service.maxRequestsPerRun ||
          !service._sessionAllows(now)) {
        throw const _BudgetExceeded();
      }
      _requests++;
      service._recentRequests.add(now);
      return await _deadline!.guard(call(_connection!));
    } finally {
      _release();
    }
  }

  bool _retryable(Object error) => switch (error) {
    OpenPricesHttpException(:final retryable) => retryable,
    TimeoutException() || SocketException() || HttpException() => true,
    _ => false,
  };

  Future<void> _acquire() async {
    if (_active < service.maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    await waiter.future;
  }

  void _release() {
    while (_waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    _active--;
  }

  Future<void> _sleep(Duration delay) async {
    final done = Completer<void>();
    _sleeps.add(done);
    final timer = Timer(delay, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _deadline!.guard(done.future);
    } finally {
      timer.cancel();
      _sleeps.remove(done);
    }
  }
}
