// View state of the receipt's price estimate: which line shows what, and the
// one run in flight. Never synced, never persisted; lives as long as the
// meal plan screen. Contract: docs/SHOPPING-PRICES.md.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../models/shopping_price.dart';
import 'local_day.dart';
import 'shopping_price_service.dart';

class ShoppingPriceController extends ChangeNotifier {
  ShoppingPriceController(
    this.service, {
    this.retryCooldown = const Duration(seconds: 60),
  });

  final ShoppingPriceService service;

  /// A failed line is asked again at most this often.
  final Duration retryCooldown;

  /// Outcome per line id, with the local day it is valid for.
  final Map<String, ({String day, LinePrice price})> _results = {};
  String? _fingerprint;
  ShoppingPriceRun? _run;
  int _generation = 0;
  DateTime? _lastFailure;
  bool _disposed = false;

  String get _today => localDayKey(clock.now());

  /// The line's outcome today; a line not settled yet is loading.
  LinePrice priceFor(String lineId) {
    final hit = _results[lineId];
    if (hit == null || hit.day != _today) return const LinePriceLoading();
    return hit.price;
  }

  ShoppingPriceTotal totalFor(Iterable<String> lineIds) =>
      shoppingPriceTotal(lineIds.map(priceFor));

  /// Asks for the prices of [lines]. Safe to call from build: it never
  /// notifies synchronously. The same lines on the same day are a no-op; a
  /// change cancels the run in flight and starts the next in a microtask,
  /// for the lines without an outcome today.
  void show(List<PriceRequestLine> lines, PriceRegion region) {
    if (_disposed) return;
    final day = _today;
    final fingerprint = [
      region.name,
      day,
      for (final line in lines) line.fingerprint,
    ].join('\n');
    if (fingerprint == _fingerprint) return;
    _fingerprint = fingerprint;
    _cancelRun();
    _results.removeWhere((_, r) => r.day != day);
    final generation = ++_generation;
    final pending = [
      for (final line in lines)
        if (_results[line.id]?.day != day) line,
    ];
    if (pending.isEmpty) return;
    scheduleMicrotask(() {
      if (_disposed || generation != _generation) return;
      final run = service.estimate(pending, region: region);
      _run = run;
      _apply(run.initial, day);
      run.result.then(
        (prices) {
          if (_disposed || generation != _generation) return;
          _run = null;
          _apply(prices, day);
        },
        onError: (Object _) {
          if (_disposed || generation != _generation) return;
          _run = null;
          // Not our cancel (that bumps the generation): the service gave
          // up on the run, e.g. after a logout. The lines stop loading.
          _apply({
            for (final line in pending)
              if (_results[line.id]?.day != day)
                line.id: const LinePriceUnavailable(),
          }, day);
        },
      );
    });
  }

  /// Cancels the run in flight (the receipt is hidden). Failed lines are
  /// dropped so the next [show] asks again, unless they failed within
  /// [retryCooldown].
  void pause() {
    _fingerprint = null;
    _generation++;
    _cancelRun();
    final last = _lastFailure;
    if (last == null || clock.now().difference(last) >= retryCooldown) {
      _results.removeWhere((_, r) => r.price is LinePriceUnavailable);
    }
  }

  void _apply(Map<String, LinePrice> prices, String day) {
    if (prices.isEmpty) return;
    for (final MapEntry(key: id, value: price) in prices.entries) {
      _results[id] = (day: day, price: price);
    }
    if (prices.values.any((p) => p is LinePriceUnavailable)) {
      _lastFailure = clock.now();
    }
    notifyListeners();
  }

  void _cancelRun() {
    _run?.cancel();
    _run = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancelRun();
    super.dispose();
  }
}
