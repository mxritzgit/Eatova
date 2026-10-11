// A scripted [ShoppingPriceService] for widget and capture tests: every
// estimate is a run the test completes (or fails, or leaves loading) by
// hand, and cancellations are recorded. No network, no timers.

import 'dart:async';

import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/services/shopping_price_service.dart';

class FakeShoppingPriceService implements ShoppingPriceService {
  FakeShoppingPriceService({this.priceOf, this.autoComplete = false});

  /// The outcome a run completes with per line; Loading lines stay out of
  /// the result. Null prices every line as no data.
  LinePrice Function(PriceRequestLine line)? priceOf;

  /// Completes every run in the same microtask it starts.
  bool autoComplete;

  final List<FakePriceRun> runs = [];
  bool disposed = false;

  int get cancels => runs.where((r) => r.cancelled).length;

  FakePriceRun get lastRun => runs.last;

  @override
  ShoppingPriceRun estimate(
    List<PriceRequestLine> lines, {
    required PriceRegion region,
  }) {
    final run = FakePriceRun(this, lines, region);
    runs.add(run);
    if (autoComplete) run.complete();
    return run.handle;
  }

  @override
  void dispose() => disposed = true;
}

class FakePriceRun {
  FakePriceRun(this._service, this.lines, this.region) {
    _result.future.ignore();
  }

  final FakeShoppingPriceService _service;
  final List<PriceRequestLine> lines;
  final PriceRegion region;
  final Completer<Map<String, LinePrice>> _result = Completer();
  bool cancelled = false;

  late final ShoppingPriceRun handle = ShoppingPriceRun(
    initial: const {},
    result: _result.future,
    onCancel: () {
      if (_result.isCompleted) return;
      cancelled = true;
      _result.completeError(const ShoppingPriceCancelled());
    },
  );

  /// Completes with [priceOf] (or the service's), skipping loading lines.
  void complete([LinePrice Function(PriceRequestLine line)? priceOf]) {
    if (_result.isCompleted) return;
    final of = priceOf ?? _service.priceOf ?? (_) => const LinePriceNoData();
    _result.complete({
      for (final line in lines)
        if (of(line) case final price when price is! LinePriceLoading)
          line.id: price,
    });
  }

  /// Every line failed to load.
  void fail() => complete((_) => const LinePriceUnavailable());
}

/// An estimate of [cents] from a median per [basis].
LinePriceEstimate fakeEstimate(
  int cents, {
  double median = 4.76,
  PriceBasis basis = PriceBasis.mass,
  LinePriceKind kind = LinePriceKind.amount,
}) => LinePriceEstimate(
  cents: cents,
  kind: kind,
  aggregate: PriceAggregate(
    basis: basis,
    median: median,
    samples: 5,
    newestDate: '2026-09-28',
  ),
);
