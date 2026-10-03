// The weekly energy check card on Today (docs/WEIGHT-TREND.md, stage 2).

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_energy_check.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/energy_check.dart';

import '../../support/harness.dart';
import '../../support/today_summary.dart';

const EnergyCheckProposal _lower = EnergyCheckProposal(
  stepKcal: -150,
  newAdjustmentKcal: -150,
  currentGoalKcal: 2100,
  newGoalKcal: 1950,
  observedKcal: 2454,
  modelledKcal: 2850,
  weeklyRateKg: -0.14,
  loggedDays: 19,
  weighInDays: 8,
);

const EnergyCheckProposal _higher = EnergyCheckProposal(
  stepKcal: 150,
  newAdjustmentKcal: 150,
  currentGoalKcal: 2100,
  newGoalKcal: 2250,
  observedKcal: 3024,
  modelledKcal: 2650,
  weeklyRateKg: -0.84,
  loggedDays: 21,
  weighInDays: 8,
);

final DateTime _now = DateTime(2026, 10, 3, 12);

Future<void> _pumpCard(
  WidgetTester tester, {
  EnergyCheckProposal proposal = _lower,
  Future<void> Function()? onAccept,
  Future<void> Function()? onDismiss,
  Locale locale = const Locale('de'),
}) => pumpLocalized(
  tester,
  SingleChildScrollView(
    child: TodayEnergyCheckCard(
      proposal: proposal,
      onAccept: onAccept ?? () async {},
      onDismiss: onDismiss ?? () async {},
    ),
  ),
  locale: locale,
  settle: true,
);

TodayScreen _today({
  required DateTime selectedDate,
  EnergyCheckProposal? check = _lower,
  bool dayLoading = false,
}) => TodayScreen(
  userName: 'Moritz',
  profile: const UserProfile(),
  summary: todaySummary(profile: const UserProfile()),
  meals: const [],
  selectedDate: selectedDate,
  streak: 0,
  dayLoading: dayLoading,
  energyCheck: check,
  onAcceptEnergyCheck: () async {},
  onDismissEnergyCheck: () async {},
);

void main() {
  group('card', () {
    testWidgets('names expenditure, difference and the new goal', (tester) async {
      await _pumpCard(tester);
      expect(find.text('Wochen-Check'), findsOneWidget);
      // 2454 -> 2450, |2454 - 2850| = 396 -> 400: rounded to tens.
      expect(
        find.text(
          'Laut deinen letzten drei Wochen verbrauchst du rund 2450 kcal am '
          'Tag – etwa 400 kcal weniger als berechnet.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Tagesziel von 2100 auf 1950 kcal anpassen?'),
        findsOneWidget,
      );
      expect(
        find.text('Grundlage: 19 Tage mit Einträgen, 8 Wiegungen'),
        findsOneWidget,
      );
    });

    testWidgets('says "more" when the user burns more than modelled', (
      tester,
    ) async {
      await _pumpCard(tester, proposal: _higher, locale: const Locale('en'));
      expect(
        find.text(
          'Your last three weeks suggest you burn about 3020 kcal a day – '
          'roughly 370 kcal more than calculated.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Change your daily goal from 2100 to 2250 kcal?'),
        findsOneWidget,
      );
    });

    testWidgets('one answer at a time: a second tap while busy is ignored', (
      tester,
    ) async {
      final pending = Completer<void>();
      var accepted = 0;
      var dismissed = 0;
      await _pumpCard(
        tester,
        onAccept: () {
          accepted++;
          return pending.future;
        },
        onDismiss: () async => dismissed++,
      );
      await tester.tap(find.byKey(const ValueKey('today-energy-check-accept')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('today-energy-check-accept')));
      await tester.tap(find.byKey(const ValueKey('today-energy-check-dismiss')));
      await tester.pump();
      expect(accepted, 1);
      expect(dismissed, 0);

      pending.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('today-energy-check-dismiss')));
      await tester.pumpAndSettle();
      expect(dismissed, 1);
    });

    testWidgets('a failed save keeps the card and names the error', (
      tester,
    ) async {
      await _pumpCard(tester, onAccept: () async => throw StateError('disk'));
      await tester.tap(find.byKey(const ValueKey('today-energy-check-accept')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-energy-check')), findsOneWidget);
      expect(find.text(deL10n.commonLocalSaveFailed), findsOneWidget);
    });

    renderMatrix(
      'fits at 320 px and 2x text',
      (tester, c) async {
        await c.pump(
          tester,
          SizedBox(
            width: 320,
            child: TodayEnergyCheckCard(
              proposal: _lower,
              onAccept: () async {},
              onDismiss: () async {},
            ),
          ),
          scrollable: true,
        );
        expect(tester.takeException(), isNull);
      },
      locales: const [Locale('de'), Locale('en')],
      textScales: const [1.0, 2.0],
    );
  });

  group('on the Today screen', () {
    Future<void> pumpToday(WidgetTester tester, TodayScreen screen) =>
        withClock(Clock.fixed(_now), () async {
          await pumpLocalized(
            tester,
            screen,
            surfaceSize: const Size(390, 2400),
            scaffold: false,
            safeArea: false,
          );
          await tester.pump(const Duration(seconds: 2));
        });

    testWidgets('today shows the card', (tester) async {
      await pumpToday(tester, _today(selectedDate: startOfDay(_now)));
      expect(find.byType(TodayEnergyCheckCard), findsOneWidget);
    });

    testWidgets('an archive day and a loading day do not', (tester) async {
      await pumpToday(
        tester,
        _today(selectedDate: startOfDay(_now).subtract(const Duration(days: 1))),
      );
      expect(find.byType(TodayEnergyCheckCard), findsNothing);
      await pumpToday(
        tester,
        _today(selectedDate: startOfDay(_now), dayLoading: true),
      );
      expect(find.byType(TodayEnergyCheckCard), findsNothing);
    });

    testWidgets('no proposal, no card', (tester) async {
      await pumpToday(
        tester,
        _today(selectedDate: startOfDay(_now), check: null),
      );
      expect(find.byType(TodayEnergyCheckCard), findsNothing);
    });
  });
}
