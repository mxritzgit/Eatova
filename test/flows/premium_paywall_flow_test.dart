// The onboarding paywall (docs/PREMIUM.md 1.2, 4.3) over a real sync: only
// a fresh onboarding opens it, it survives a kill until answered, "Weiter mit
// Free" leads to Today, and an answered or an already onboarded account
// never sees it again.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/local_cache.dart';

import '../support/fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

final DateTime _now = DateTime(2026, 10, 25, 12);

final Finder _paywall = find.byKey(const ValueKey('screen-paywall'));
final Finder _today = find.byKey(const ValueKey('screen-today'));

void main() {
  testWidgets('nach frischem Onboarding einmal Premium, Free fuehrt zu Heute '
      'und kein Neustart zeigt es wieder', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer();
      final kv = InMemoryKeyValueStore();
      final slot = LocalCache(kv, kFixlaufUser);
      final store = await pumpSignedIn(tester, server, store: kv);
      await pumpUntil(tester, () => store.needsOnboarding, 'the onboarding');

      await store.completeOnboarding(completedProfile);
      await settleFrames(tester);
      expect(_paywall, findsOneWidget);
      expect(_today, findsNothing);
      expect(await slot.readPaywallPrompt(), 'pending');

      // Killed on the paywall: the restart opens it again, not the tabs.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpSignedIn(tester, server, store: kv);
      expect(_paywall, findsOneWidget);
      expect(_today, findsNothing);

      await tester.tap(find.byKey(const ValueKey('paywall-continue-free')));
      await settleFrames(tester);
      expect(_paywall, findsNothing);
      expect(_today, findsOneWidget);
      expect(await slot.readPaywallPrompt(), 'answered');

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpSignedIn(tester, server, store: kv);
      expect(_today, findsOneWidget);
      expect(_paywall, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('ein schon onboardetes Konto sieht die Paywall nie', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(completedProfile);
      final kv = InMemoryKeyValueStore();
      // First start on this device, then a restart from its cache.
      for (var start = 0; start < 2; start++) {
        final store = await pumpSignedIn(tester, server, store: kv);
        await settleFrames(tester);
        expect(store.paywallPending, isFalse, reason: 'start $start');
        expect(_paywall, findsNothing, reason: 'start $start');
        expect(_today, findsOneWidget, reason: 'start $start');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(await LocalCache(kv, kFixlaufUser).readPaywallPrompt(), isNull);
    });
  });
}
