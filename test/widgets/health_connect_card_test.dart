import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  testWidgets('profile goals distinguish missing steps from measured zero', (tester) async {
    await pumpLocalized(tester, const GoalsCard(profile: UserProfile(), dailyKcal: 0, dailySteps: null));
    expect(find.text('–/8000'), findsOneWidget);
    expect(find.text('0/8000'), findsNothing);
    await pumpLocalized(tester, const GoalsCard(profile: UserProfile(), dailyKcal: 0, dailySteps: 0));
    expect(find.text('0/8000'), findsOneWidget);
  });
  for (final locale in [const Locale('de'), const Locale('en')]) {
    for (final state in [
      HealthAuthState.unknown,
      HealthAuthState.noData,
      HealthAuthState.denied,
      HealthAuthState.granted,
      HealthAuthState.updateRequired,
      HealthAuthState.unavailable,
      HealthAuthState.error,
    ]) {
      testWidgets(
        'Health Connect $state at 320px/2x in ${locale.languageCode}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final context = await pumpLocalizedContext(
            tester,
            HealthConnectionCard(
              state: state,
              lastFetch: null,
              healthConnect: true,
              onConnect: () {},
              onRefresh: () {},
              onSettings: () {},
            ),
            locale: locale,
            textScale: 2,
            scrollable: true,
            padding: const EdgeInsets.all(16),
          );
          expect(find.text(context.l10n.healthConnectTitle), findsOneWidget);
          expect(find.text('Apple Health'), findsNothing);
          expect(
            find.text(context.l10n.healthConnectStepsOnly),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (state == HealthAuthState.noData) {
            expect(find.text(context.l10n.healthConnectNoData), findsOneWidget);
            expect(
              find.text(context.l10n.profileHealthConnected),
              findsNothing,
            );
          }
        },
      );
    }
  }

  testWidgets('actions invoke the correct recovery, busy state disables them', (
    tester,
  ) async {
    var connects = 0;
    var refreshes = 0;
    var settings = 0;
    Widget card(HealthAuthState state, {bool syncing = false}) =>
        HealthConnectionCard(
          state: state,
          lastFetch: null,
          healthConnect: true,
          syncing: syncing,
          onConnect: () => connects++,
          onRefresh: () => refreshes++,
          onSettings: () => settings++,
        );
    await pumpLocalized(tester, card(HealthAuthState.updateRequired));
    await tester.tap(find.byKey(const ValueKey('profile-health-connect')));
    expect(connects, 1);
    await pumpLocalized(tester, card(HealthAuthState.noData));
    await tester.tap(find.byKey(const ValueKey('profile-health-refresh')));
    await tester.tap(find.byKey(const ValueKey('profile-health-settings')));
    expect(refreshes, 1);
    expect(settings, 1);
    await pumpLocalized(tester, card(HealthAuthState.noData, syncing: true));
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('profile-health-refresh')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('profile-health-settings')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('Today missing steps offers profile; measured zero shows steps', (
    tester,
  ) async {
    var opened = 0;
    Widget today(int? steps) => TodayScreen(
      userName: 'Test',
      profile: const UserProfile(),
      consumedKcal: 0,
      burnedKcal: 0,
      macroProgress: MacroProgress.empty,
      meals: const [],
      selectedDate: DateTime(2026, 9, 10),
      streak: 0,
      steps: steps,
      healthConnect: true,
      onOpenProfile: () => opened++,
    );
    final context = await pumpLocalizedContext(tester, today(null));
    expect(find.byKey(const ValueKey('today-steps-card')), findsNothing);
    await tester.ensureVisible(find.text(context.l10n.healthConnectReview));
    await tester.tap(find.text(context.l10n.healthConnectReview));
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpLocalized(tester, today(0));
    expect(
      find.byKey(const ValueKey('today-health-connect-missing')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('today-steps-card')), findsOneWidget);
  });
}
