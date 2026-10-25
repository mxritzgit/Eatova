// Visual evidence for the Premium screen and the Profile "Abo" card
// (design polish 2026-10-25).
//
// The real PaywallScreen over the subscription fakes (yearly 49,99 € with a
// 7-day trial, monthly 7,99 €) and the real SubscriptionCard, German, at the
// design's 390 px reference, on the fakes' frozen day. Shots, each with the
// run's palette as suffix (-dark, or -light with DESIGN_CAPTURE_BRIGHTNESS):
//   paywall-top              onboarding mode, offers loaded, at the top
//   paywall-mid              the table's end and the two reassurances
//   paywall-plans            scrolled to the plan choice, yearly selected
//   paywall-monthly          the same, monthly selected
//   paywall-bottom           scrolled to the end (renewal, legal, restore)
//   paywall-busy             the purchase sheet open (button busy)
//   paywall-pending          a pending payment under the plans
//   paywall-loading          the store has not answered yet
//   paywall-store-unavailable  no store on this device
//   paywall-premium-status   already Premium (status card, manage)
//   paywall-success          "Willkommen bei Premium"
//   paywall-upsell-top       the pushed route (no Free choice)
//   abo-card-free            Profile card, Free with some use today
//   abo-card-premium         Profile card, yearly Google Premium
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/, with --dart-define=DESIGN_CAPTURE_BRIGHTNESS=light
// in build/light-redesign/. Without either it only checks that every scene
// renders without an exception.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/screens/premium/paywall_screen.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';
import 'package:eatova/src/widgets/profile/subscription_card.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/subscription_fakes.dart';

/// A store that never answers: the loading state stays.
class _SilentStore extends FakePurchaseFlow {
  @override
  Future<BillingAvailability> availability() =>
      Completer<BillingAvailability>().future;
}

String get _palette =>
    designCaptureBrightness == Brightness.light ? '-light' : '-dark';

Future<void> _shot(WidgetTester tester, String scene) =>
    captureDesignShot(tester, '$scene$_palette');

Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// Frames instead of settling, for scenes with a running spinner.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _mountPaywall(
  WidgetTester tester, {
  PlanStatus? plan,
  FakePurchaseFlow? flow,
  PaywallMode mode = PaywallMode.onboarding,
  bool settle = true,
}) async {
  pinDesignViewport(tester);
  final controller = await subscriptionController(
    log: FakeSubscriptionLog(plan: plan ?? planOf(PlanTier.free)),
    flow: flow ?? FakePurchaseFlow(),
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        PaywallScreen(
          mode: mode,
          controller: controller,
          onAnswered: mode == PaywallMode.onboarding ? () async {} : null,
        ),
        safeArea: false,
        scaffold: false,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _frames(tester);
  }
}

/// The paywall's scroll view.
Finder _scrollable() => find
    .descendant(of: _key('paywall-scroll'), matching: find.byType(Scrollable))
    .first;

/// The paywall's scroll position.
ScrollPosition _scroll(WidgetTester tester) =>
    tester.state<ScrollableState>(_scrollable()).position;

/// Scrolls so [key]'s top sits just below the top edge fade.
Future<void> _scrollToTopOf(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final position = _scroll(tester);
  final viewport = tester.getRect(_key('paywall-scroll'));
  final target = tester.getRect(_key(key));
  position.jumpTo(
    (position.pixels + target.top - viewport.top - 28).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _frames(tester);
  }
}

Future<void> _tap(WidgetTester tester, String key, {bool settle = true}) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _frames(tester);
  }
}

Future<void> _mountCard(WidgetTester tester, PlanStatus plan) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Builder(
                builder: (context) =>
                    ProfileSectionLabel(context.l10n.profileSectionSubscription),
              ),
              SubscriptionCard(
                plan: plan,
                onUpgrade: () {},
                onManage: () {},
                onRestore: () async => PurchaseState.idle,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  Future<void> frozen(Future<void> Function() body) =>
      withClock(Clock.fixed(kPlanDay), body);

  testWidgets('Paywall mit Angeboten: oben, Plaene, Monat, Ende', (
    tester,
  ) async {
    await frozen(() async {
      await _mountPaywall(tester);
      expect(_key('paywall-plans'), findsOneWidget);
      await _shot(tester, 'paywall-top');

      await _scrollToTopOf(tester, 'paywall-compare');
      await scrollDesignTabBy(tester, 260, scrollable: _scrollable());
      await _shot(tester, 'paywall-mid');

      await _scrollToTopOf(tester, 'paywall-plans');
      expect(_key('paywall-trial-timeline'), findsOneWidget);
      await _shot(tester, 'paywall-plans');

      await _tap(tester, 'paywall-plan-monthly');
      await _scrollToTopOf(tester, 'paywall-plans');
      expect(_key('paywall-trial-timeline'), findsNothing);
      await _shot(tester, 'paywall-monthly');

      await _tap(tester, 'paywall-plan-yearly');
      final position = _scroll(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(_key('paywall-restore'), findsOneWidget);
      await _shot(tester, 'paywall-bottom');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Paywall: Kauf laeuft und Zahlung ausstehend', (tester) async {
    await frozen(() async {
      await _mountPaywall(tester);
      // The fake opens no sheet and sends nothing: the purchase stays busy.
      await _tap(tester, 'paywall-buy', settle: false);
      await _scrollToTopOf(tester, 'paywall-plans', settle: false);
      await _shot(tester, 'paywall-busy');
      expect(tester.takeException(), isNull);
    });
    await frozen(() async {
      await _mountPaywall(
        tester,
        flow: FakePurchaseFlow()..onBuy = const [PurchasePending()],
      );
      await _tap(tester, 'paywall-buy');
      expect(_key('paywall-pending'), findsOneWidget);
      await _scrollToTopOf(tester, 'paywall-plans');
      await _shot(tester, 'paywall-pending');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Paywall ohne Preise: laedt, Store nicht erreichbar', (
    tester,
  ) async {
    await frozen(() async {
      await _mountPaywall(tester, flow: _SilentStore(), settle: false);
      expect(_key('paywall-loading'), findsOneWidget);
      await _scrollToTopOf(tester, 'paywall-loading', settle: false);
      await _shot(tester, 'paywall-loading');
      expect(tester.takeException(), isNull);
    });
    await frozen(() async {
      await _mountPaywall(
        tester,
        flow: FakePurchaseFlow()
          ..availabilityAnswer = BillingAvailability.unavailable,
      );
      expect(_key('paywall-store-unavailable'), findsOneWidget);
      await _scrollToTopOf(tester, 'paywall-store-unavailable');
      await _shot(tester, 'paywall-store-unavailable');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Paywall: schon Premium, Kauf geglueckt, als Route', (
    tester,
  ) async {
    await frozen(() async {
      await _mountPaywall(tester, plan: planOf(PlanTier.premium));
      expect(_key('paywall-premium-status'), findsOneWidget);
      await _scrollToTopOf(tester, 'paywall-premium-status');
      await _shot(tester, 'paywall-premium-status');
      expect(tester.takeException(), isNull);
    });
    await frozen(() async {
      await _mountPaywall(
        tester,
        flow: FakePurchaseFlow()
          ..onBuy = [
            PurchaseVerified(active: true, plan: planOf(PlanTier.premium)),
          ],
      );
      await _tap(tester, 'paywall-buy');
      expect(_key('paywall-success'), findsOneWidget);
      await _shot(tester, 'paywall-success');
      expect(tester.takeException(), isNull);
    });
    await frozen(() async {
      await _mountPaywall(tester, mode: PaywallMode.upsell);
      expect(_key('paywall-continue-free'), findsNothing);
      await _shot(tester, 'paywall-upsell-top');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Abo-Karte: Free und Premium', (tester) async {
    await frozen(() async {
      await _mountCard(
        tester,
        planOf(PlanTier.free, coachUsed: 1, analysesUsed: 2),
      );
      expect(_key('profile-subscription-upgrade'), findsOneWidget);
      await _shot(tester, 'abo-card-free');
      expect(tester.takeException(), isNull);
    });
    await frozen(() async {
      await _mountCard(tester, planOf(PlanTier.premium, coachUsed: 4));
      expect(_key('profile-subscription-manage'), findsOneWidget);
      await _shot(tester, 'abo-card-premium');
      expect(tester.takeException(), isNull);
    });
  });
}
