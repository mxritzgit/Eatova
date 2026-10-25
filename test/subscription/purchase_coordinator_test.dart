// The app-level purchase pipeline (docs/PREMIUM.md 4.2): a store transaction
// is finished only after the server's active, inactive or owned-by-other
// answer, purchases wait for an account, one account's answer never reaches
// another, a purchase always ends in an event, a restore ends only once
// everything it found was answered (silently, when it runs on its own), and a
// silent answer never decides the account's own purchase.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/billing_client.dart';
import 'package:eatova/src/services/billing/purchase_coordinator.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/subscription_sync.dart';

import '../support/subscription_fakes.dart';

PurchaseCoordinator _coordinator(FakeBillingClient store) {
  final coordinator = PurchaseCoordinator(store, observeLifecycle: false);
  addTearDown(coordinator.dispose);
  return coordinator;
}

/// A server side that answers each proof with its own [answers] entry, held
/// while its [gates] entry is open; the account token waits for [tokenGate].
class _GatedLog extends FakeSubscriptionLog {
  _GatedLog() : super(plan: planOf(PlanTier.free));

  final Map<PurchaseProof, VerifyResult> answers = {};
  final Map<PurchaseProof, Completer<void>> gates = {};
  Completer<void>? tokenGate;

  @override
  Future<String> accountToken() async {
    await tokenGate?.future;
    return token;
  }

  @override
  Future<VerifyResult> verify(PurchaseProof proof) async {
    verified.add(proof);
    await gates[proof]?.future;
    return answers[proof]!;
  }
}

RecordingPurchaseAccount _account(
  String userId, {
  VerifyOutcome outcome = VerifyOutcome.active,
}) => RecordingPurchaseAccount(
  userId,
  FakeSubscriptionLog()..verifyOutcome = outcome,
);

void main() {
  test(
    'der Store-Vorgang endet nur nach active, inactive oder ownedByOther',
    () async {
      final rows = <(VerifyOutcome, Type, bool, bool)>[
        // outcome, event, finished at once, verified again on resume
        (VerifyOutcome.active, PurchaseVerified, true, false),
        (VerifyOutcome.inactive, PurchaseVerified, true, false),
        (VerifyOutcome.ownedByOther, PurchaseOwnedByOther, true, false),
        (VerifyOutcome.pending, PurchasePending, false, true),
        (VerifyOutcome.invalid, PurchaseInvalid, false, false),
        (VerifyOutcome.unavailable, PurchaseVerifyDeferred, false, true),
        (VerifyOutcome.unauthorized, PurchaseVerifyDeferred, false, true),
      ];
      for (final (outcome, event, finished, retried) in rows) {
        final store = FakeBillingClient();
        final coordinator = _coordinator(store);
        final account = _account('user-a', outcome: outcome);
        coordinator.bindAccount(account);
        final purchase = googlePurchase('token-${outcome.name}');

        store.emit([purchase]);
        await pumpEventQueue();

        expect(account.events.map((e) => e.runtimeType), [
          event,
        ], reason: '$outcome');
        expect(
          store.completed,
          finished ? [purchase] : isEmpty,
          reason: '$outcome',
        );

        account.log.verifyOutcome = VerifyOutcome.active;
        coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(
          account.log.verified,
          hasLength(retried ? 2 : 1),
          reason: '$outcome',
        );
        expect(
          store.completed,
          finished || retried ? [purchase] : isEmpty,
          reason: '$outcome',
        );
      }
    },
  );

  test(
    'ein Kauf ohne Konto wartet und wird fuer das gebundene Konto geprueft',
    () async {
      final store = FakeBillingClient();
      final coordinator = _coordinator(store);
      final purchase = googlePurchase('token-at-launch');

      store.emit([purchase]);
      await pumpEventQueue();
      expect(store.completed, isEmpty);

      final account = _account('user-a');
      coordinator.bindAccount(account);
      await pumpEventQueue();

      expect(account.log.verified, [purchase.proof]);
      expect(account.events, [
        isA<PurchaseVerified>().having((e) => e.active, 'active', isTrue),
      ]);
      expect(store.completed, [purchase]);
      expect(store.restores, 1, reason: 'one silent restore per bind');
    },
  );

  test(
    'ein Ergebnis fuer Konto A erreicht nach dem Wechsel nie Konto B',
    () async {
      final store = FakeBillingClient();
      final coordinator = _coordinator(store);
      final a = _account('user-a');
      final b = _account('user-b', outcome: VerifyOutcome.ownedByOther);
      a.log.verifyGate = Completer<void>();
      coordinator.bindAccount(a);
      final purchase = googlePurchase('token-of-a');
      store.emit([purchase]);
      await pumpEventQueue();
      expect(a.log.verified, [purchase.proof]);

      // The next shell binds, then the old one disposes; A's answer lands last.
      coordinator.bindAccount(b);
      coordinator.unbindAccount(a);
      await pumpEventQueue();
      a.log.verifyGate!.complete();
      await pumpEventQueue();

      expect(a.events, isEmpty);
      expect(b.events.map((e) => e.runtimeType), [PurchaseOwnedByOther]);
      expect(b.log.verified, [purchase.proof]);
      expect(store.completed, [
        purchase,
      ], reason: 'once, after B\'s own answer');
    },
  );

  test(
    'das spaete Abmelden der alten Shell laesst das neue Konto gebunden',
    () async {
      final store = FakeBillingClient();
      final coordinator = _coordinator(store);
      final a = _account('user-a');
      final b = _account('user-b');

      coordinator.bindAccount(a);
      coordinator.bindAccount(b);
      coordinator.unbindAccount(a);
      store.emit([googlePurchase('token-after-switch')]);
      await pumpEventQueue();

      expect(b.events.map((e) => e.runtimeType), [PurchaseVerified]);
      expect(a.log.verified, isEmpty);
    },
  );

  test(
    'jeder Kauf endet in einem Ereignis, auch ein geschlossenes Sheet',
    () async {
      final rows = <(StorePurchase, Type)>[
        (googleFlowEnd(StorePurchaseStatus.canceled), PurchaseCanceled),
        (googleFlowEnd(StorePurchaseStatus.error), PurchaseFailed),
        (googleFlowEnd(StorePurchaseStatus.pending), PurchasePending),
        (googlePurchase('token-bought'), PurchaseVerified),
      ];
      for (final (answer, event) in rows) {
        final store = FakeBillingClient()..onBuy = [answer];
        final coordinator = _coordinator(store);
        final account = _account('user-a');
        coordinator.bindAccount(account);
        await pumpEventQueue();

        await coordinator.buy(
          kFakeOffers.first,
          accountToken: kFakeAccountToken,
        );
        await pumpEventQueue();

        expect(account.events.map((e) => e.runtimeType), [
          event,
        ], reason: '${answer.status}');
        expect(store.buys.single.token, kFakeAccountToken);
      }
    },
  );

  test(
    'Wiederherstellen antwortet vor dem Ende, still nur mit Erfolgen',
    () async {
      final rows = <(bool, List<StorePurchase>, VerifyOutcome, List<Type>)>[
        (false, [], VerifyOutcome.active, [PurchaseRestoredNothing]),
        (true, [], VerifyOutcome.active, []),
        (
          false,
          [googlePurchase('t', status: StorePurchaseStatus.restored)],
          VerifyOutcome.ownedByOther,
          [PurchaseOwnedByOther],
        ),
        (
          true,
          [googlePurchase('t', status: StorePurchaseStatus.restored)],
          VerifyOutcome.ownedByOther,
          [],
        ),
        (
          true,
          [googlePurchase('t', status: StorePurchaseStatus.restored)],
          VerifyOutcome.active,
          [PurchaseVerified],
        ),
      ];
      for (final (silent, owned, outcome, events) in rows) {
        final store = FakeBillingClient();
        final coordinator = _coordinator(store);
        final account = _account('user-a', outcome: outcome);
        coordinator.bindAccount(account);
        await pumpEventQueue();
        store.owned = owned;

        // No pump after the restore: its end is the answer.
        await coordinator.restore(silent: silent);

        final row = 'silent: $silent, ${owned.length} owned, $outcome';
        expect(account.events.map((e) => e.runtimeType), events, reason: row);
        expect(store.completed, owned, reason: row);
      }
    },
  );

  test('eine stille Antwort beendet den eigenen Kauf nicht und dreht ihn '
      'nicht zurueck', () {
    return withClock(Clock.fixed(kPlanDay), () async {
      // The bind's restore finds a lapsed purchase; its answer, computed
      // before the new purchase, lands while the user is buying (during the
      // token request, or withheld while the sheet is open) or after the
      // purchase ended. `own` is the server's answer to the bought proof;
      // null: the store ends the sheet with a pending payment.
      final rows = <(String, VerifyOutcome?, PurchaseState)>[
        ('token', VerifyOutcome.active, PurchaseState.success),
        ('sheet', VerifyOutcome.active, PurchaseState.success),
        ('sheet', null, PurchaseState.pending),
        ('after', VerifyOutcome.unavailable, PurchaseState.verifyDeferred),
      ];
      for (final (stage, own, end) in rows) {
        final when = '$stage, $own';
        final stale = googlePurchase(
          'stale',
          status: StorePurchaseStatus.restored,
        );
        final bought = googlePurchase('bought');
        final store = FakeBillingClient()..owned = [stale];
        final coordinator = _coordinator(store);
        final staleGate = Completer<void>();
        final tokenGate = Completer<void>();
        final log = _GatedLog()
          ..tokenGate = tokenGate
          ..gates[stale.proof!] = staleGate
          ..answers[stale.proof!] = VerifyResult(
            VerifyOutcome.inactive,
            plan: planOf(PlanTier.free),
          )
          ..answers[bought.proof!] = VerifyResult(
            own ?? VerifyOutcome.pending,
            plan: own == VerifyOutcome.active ? planOf(PlanTier.premium) : null,
          );
        final controller = SubscriptionController(
          userId: 'user-a',
          cache: MemoryPlanCache(),
          log: log,
          flow: coordinator,
        );
        addTearDown(controller.dispose);
        coordinator.bindAccount(controller);
        await pumpEventQueue();
        expect(log.verified, [stale.proof], reason: when);

        final buying = controller.buy(PremiumPeriod.yearly);
        await pumpEventQueue();
        if (stage == 'token') staleGate.complete();
        await pumpEventQueue();
        tokenGate.complete();
        await buying;
        if (stage == 'sheet') staleGate.complete();
        await pumpEventQueue();
        expect(
          controller.purchaseState,
          PurchaseState.purchasing,
          reason: when,
        );
        expect(store.buys, hasLength(1), reason: 'the sheet opened ($when)');

        store.emit([
          own == null ? googleFlowEnd(StorePurchaseStatus.pending) : bought,
        ]);
        await pumpEventQueue();
        if (stage == 'after') staleGate.complete();
        await pumpEventQueue();
        expect(controller.purchaseState, end, reason: when);
        expect(
          controller.isPremium,
          end == PurchaseState.success,
          reason: when,
        );
      }
    });
  });
}
