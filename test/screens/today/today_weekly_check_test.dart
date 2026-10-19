// The weekly check explained and its weekly result on Today (2026-10-19):
// the progress line opens a short explainer, and once a week without a
// proposal a quiet card shows the check's own numbers.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/energy_check.dart';

import '../../support/design_capture.dart' show loadDesignFonts;
import '../../support/harness.dart';
import '../../support/today_summary.dart';

final DateTime _now = DateTime(2026, 10, 5, 12);
final DateTime _day = DateTime(2026, 10, 5);

final EnergyCheckProgress _ready = EnergyCheckProgress(
  today: _day,
  loggedDays: 21,
  weighInDays: 21,
  weighInSpanDays: 20,
  pausedUntil: null,
  earliestDay: _day,
  loggedDaysToGo: 0,
  weighInsToGo: 0,
);

const EnergyCheckEstimate _fits = EnergyCheckEstimate(
  observedKcal: 2347,
  modelledKcal: 2300,
  weeklyRateKg: -0.42,
  planWeeklyRateKg: -0.5,
  currentGoalKcal: 2100,
  loggedDays: 19,
  weighInDays: 8,
  withinNoise: true,
);

TodayScreen _today({
  EnergyCheckEstimate? result,
  VoidCallback? onOpenFoodLog,
  Future<void> Function(double kg)? onLogWeight,
}) => TodayScreen(
  userName: 'Moritz',
  profile: const UserProfile(weightKg: 84),
  summary: todaySummary(),
  meals: const [],
  selectedDate: _day,
  streak: 0,
  energyCheckProgress: _ready,
  energyCheckResult: result,
  latestWeightKg: 82.4,
  onLogWeight: onLogWeight ?? (_) async {},
  onOpenFoodLog: onOpenFoodLog,
);

Future<void> _pump(
  WidgetTester tester,
  TodayScreen screen, {
  Locale locale = const Locale('de'),
}) => withClock(Clock.fixed(_now), () async {
  await pumpLocalized(
    tester,
    screen,
    locale: locale,
    surfaceSize: const Size(390, 2400),
    safeArea: false,
  );
  await tester.pump(const Duration(seconds: 2));
});

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('die Zeile ist ein Knopf und oeffnet die Erklaerung', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _today());
    final tap = find.byKey(const ValueKey('today-weigh-progress-tap'));
    expect(tap, findsOneWidget);
    expect(tester.getSize(tap).height, greaterThanOrEqualTo(44));
    expect(
      tester.getSemantics(tap),
      isSemantics(
        label: 'Wochen-Check aktiv · deine Daten reichen',
        hint: 'Erklärt den Wochen-Check',
        isButton: true,
        hasTapAction: true,
      ),
    );

    await _tap(tester, 'today-weigh-progress-tap');
    expect(find.byKey(const ValueKey('weekly-check-explainer')), findsOneWidget);
    expect(find.text('So funktioniert der Wochen-Check'), findsOneWidget);
    // The rules' own numbers, from EnergyCheck's constants.
    expect(
      find.textContaining(
        'Dafür braucht es ${EnergyCheck.minLoggedDays} vollständige Tage',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('mindestens ${EnergyCheck.minWeighInSpanDays} Tage'),
      findsOneWidget,
    );
    expect(
      find.textContaining('höchstens ${EnergyCheck.maxStepKcal} kcal'),
      findsOneWidget,
    );
    expect(
      find.textContaining('in den letzten ${EnergyCheck.windowDays} Tagen'),
      findsOneWidget,
    );

    await _tap(tester, 'weekly-check-explainer-close');
    expect(find.byKey(const ValueKey('weekly-check-explainer')), findsNothing);
    handle.dispose();
  });

  testWidgets('die Erklaerung fuehrt zum Wiegen und zum Tagebuch', (
    tester,
  ) async {
    var logs = 0;
    await _pump(tester, _today(onOpenFoodLog: () => logs++));

    await _tap(tester, 'today-weigh-progress-tap');
    await _tap(tester, 'weekly-check-explainer-log');
    expect(logs, 1);
    expect(find.byKey(const ValueKey('weekly-check-explainer')), findsNothing);

    await _tap(tester, 'today-weigh-progress-tap');
    await _tap(tester, 'weekly-check-explainer-weigh');
    expect(find.byKey(const ValueKey('weekly-check-explainer')), findsNothing);
    // The profile's weigh-in sheet, as from the chip.
    final field = find.byKey(const ValueKey('profile-weight-input'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '82,4');
  });

  testWidgets('das Wochen-Ergebnis zeigt die Zahlen des Checks, ohne Zeile', (
    tester,
  ) async {
    await _pump(tester, _today(result: _fits));

    final card = find.byKey(const ValueKey('today-weekly-result'));
    expect(card, findsOneWidget);
    String text(String key) =>
        tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;
    expect(text('today-weekly-result-burn'), 'Verbrauch ≈ 2.350 kcal am Tag');
    expect(
      text('today-weekly-result-goal'),
      'Dein Tagesziel von 2.100 kcal passt dazu.',
    );
    expect(
      text('today-weekly-result-rate'),
      'Gemessen: −0,4 kg/Woche · Plan: −0,5 kg/Woche',
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('Grundlage: 19 vollständige Tage, 8 Wiegungen'),
      ),
      findsOneWidget,
    );
    // The card speaks for the check: no progress line beside it.
    expect(find.byKey(const ValueKey('today-weigh-progress')), findsNothing);
    expect(find.byKey(const ValueKey('today-weigh-chip')), findsOneWidget);

    await _tap(tester, 'today-weekly-result-more');
    expect(find.byKey(const ValueKey('weekly-check-explainer')), findsOneWidget);
  });

  testWidgets('an einer Grenze sagt die Karte das, Englisch mit Punkt', (
    tester,
  ) async {
    const held = EnergyCheckEstimate(
      observedKcal: 1954,
      modelledKcal: 2350,
      weeklyRateKg: 0.02,
      planWeeklyRateKg: -0.5,
      currentGoalKcal: 1200,
      loggedDays: 21,
      weighInDays: 21,
      withinNoise: false,
    );
    await _pump(tester, _today(result: held), locale: const Locale('en'));
    String text(String key) =>
        tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;
    expect(text('today-weekly-result-burn'), 'You burn ≈ 1,950 kcal a day');
    expect(
      text('today-weekly-result-goal'),
      'Your daily goal stays at 1,200 kcal: it is already at a limit.',
    );
    expect(
      text('today-weekly-result-rate'),
      'Measured: Weight stable · plan: −0.5 kg/week',
    );
  });

  testWidgets('kein Ergebnis auf einem Archivtag', (tester) async {
    await _pump(
      tester,
      TodayScreen(
        userName: 'Moritz',
        profile: const UserProfile(weightKg: 84),
        summary: todaySummary(),
        meals: const [],
        selectedDate: addDays(_day, -1),
        streak: 0,
        energyCheckResult: _fits,
      ),
    );
    expect(find.byKey(const ValueKey('today-weekly-result')), findsNothing);
  });
}
