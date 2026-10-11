// The receipt's price view state (docs/SHOPPING-PRICES.md): one run per
// change of lines, no synchronous notify from build, cancellation on pause
// and dispose, late results ignored, a cooldown for failed lines, a fresh
// start after midnight, and no endless loading when the service gives up.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/shopping_price.dart';
import 'package:eatova/src/services/open_prices_api.dart';
import 'package:eatova/src/services/shopping_price_controller.dart';
import 'package:eatova/src/services/shopping_price_service.dart';

import '../support/fake_shopping_prices.dart';

const _milk = PriceRequestLine(id: 'milk', label: 'Milch', amount: '500 ml');
const _salt = PriceRequestLine(id: 'salt', label: 'Salz', amount: '1 Prise');
const _bread = PriceRequestLine(id: 'bread', label: 'Brot', amount: '1');

var _now = DateTime(2026, 10, 11, 9);

/// Runs [body] with the clock at [_now], which a test may move.
Future<void> _at(Future<void> Function() body) =>
    withClock(Clock(() => _now), body);

Future<void> _settle() => pumpEventQueue();

/// A source a disposed service must never reach.
class _NoSource implements OpenPricesSource {
  @override
  OpenPricesConnection connect() => throw StateError('no request expected');
}

LinePrice _priced(PriceRequestLine line) => switch (line.id) {
  'salt' => const LinePriceSkipped(),
  _ => fakeEstimate(57),
};

void main() {
  late FakeShoppingPriceService service;
  late ShoppingPriceController controller;
  late int notifications;

  setUp(() {
    _now = DateTime(2026, 10, 11, 9);
    service = FakeShoppingPriceService(priceOf: _priced);
    controller = ShoppingPriceController(service);
    notifications = 0;
    controller.addListener(() => notifications++);
  });

  tearDown(() => controller.dispose());

  test(
    'the same lines start one run; changed lines cancel it and start '
    'the next',
    () => _at(() async {
      controller.show(const [_milk, _salt], PriceRegion.germany);
      controller.show(const [_milk, _salt], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(1));
      expect(service.lastRun.lines, const [_milk, _salt]);

      controller.show(const [_milk, _salt, _bread], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(2));
      expect(service.runs.first.cancelled, isTrue);
    }),
  );

  test(
    'show never notifies synchronously, results do',
    () => _at(() async {
      controller.show(const [_milk], PriceRegion.germany);
      expect(notifications, 0);
      expect(controller.priceFor('milk'), isA<LinePriceLoading>());
      await _settle();
      service.lastRun.complete();
      await _settle();
      expect(notifications, 1);
      expect(controller.priceFor('milk'), fakeEstimate(57));
      expect(controller.totalFor(const ['milk']).cents, 57);
    }),
  );

  test(
    'pause and dispose cancel the run in flight',
    () => _at(() async {
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      controller.pause();
      expect(service.lastRun.cancelled, isTrue);
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(2));
      controller.dispose();
      expect(service.lastRun.cancelled, isTrue);
      // tearDown disposes again; a second dispose must not run.
      controller = ShoppingPriceController(service);
    }),
  );

  test(
    'a late result of a replaced run is ignored',
    () => _at(() async {
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      final first = service.lastRun;
      controller.show(const [_bread], PriceRegion.germany);
      await _settle();
      first.complete((_) => fakeEstimate(999));
      await _settle();
      expect(controller.priceFor('milk'), isA<LinePriceLoading>());
      expect(notifications, 0);
    }),
  );

  test(
    'only lines without an outcome today are asked again',
    () => _at(() async {
      controller.show(const [_milk, _salt], PriceRegion.germany);
      await _settle();
      service.lastRun.complete();
      await _settle();
      controller.pause();
      controller.show(const [_milk, _salt, _bread], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(2));
      expect(service.lastRun.lines, const [_bread]);
    }),
  );

  test(
    'a failed line is asked again at most once a minute',
    () => _at(() async {
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      service.lastRun.fail();
      await _settle();
      expect(controller.priceFor('milk'), isA<LinePriceUnavailable>());
      expect(controller.totalFor(const ['milk']).failed, isTrue);

      // Back to the receipt within the minute: still "n/a", no request.
      _now = _now.add(const Duration(seconds: 30));
      controller.pause();
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(1));

      _now = _now.add(const Duration(seconds: 31));
      controller.pause();
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(2));
      expect(controller.priceFor('milk'), isA<LinePriceLoading>());
    }),
  );

  test(
    'after midnight yesterday\'s prices are gone and asked again',
    () => _at(() async {
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      service.lastRun.complete();
      await _settle();
      expect(controller.priceFor('milk'), isA<LinePriceEstimate>());

      _now = DateTime(2026, 10, 12, 0, 1);
      expect(controller.priceFor('milk'), isA<LinePriceLoading>());
      controller.show(const [_milk], PriceRegion.germany);
      await _settle();
      expect(service.runs, hasLength(2));
    }),
  );

  test(
    'a run the service refuses (a planner outliving its session) stops '
    'loading and reads as unavailable',
    () => _at(() async {
      final disposed = OpenPricesShoppingPriceService(_NoSource())..dispose();
      final refused = ShoppingPriceController(disposed);
      addTearDown(refused.dispose);
      var notified = 0;
      refused.addListener(() => notified++);
      refused.show(const [_milk], PriceRegion.germany);
      await _settle();
      expect(refused.priceFor('milk'), isA<LinePriceUnavailable>());
      expect(refused.totalFor(const ['milk']).failed, isTrue);
      expect(notified, 1);
    }),
  );

  test(
    'a run settled at once by the service shows without a loading step',
    () => _at(() async {
      service.autoComplete = true;
      controller.show(const [_milk, _salt], PriceRegion.germany);
      await _settle();
      expect(controller.priceFor('salt'), isA<LinePriceSkipped>());
      expect(controller.totalFor(const ['milk', 'salt']).complete, isTrue);
    }),
  );
}
