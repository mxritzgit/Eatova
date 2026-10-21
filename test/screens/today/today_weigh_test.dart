// Today's weight chip and the weekly check's progress line
// (docs/WEIGHT-TREND.md, stage 2).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_energy_check.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/today/today_weigh.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/energy_check.dart';

import '../../support/design_capture.dart' show loadDesignFonts;
import '../../support/harness.dart';
import '../../support/today_summary.dart';

final DateTime _now = DateTime(2026, 10, 3, 12);
final DateTime _day = DateTime(2026, 10, 3);

/// A progress as `EnergyCheck.progress` reports it; [ready] means a full
/// window, otherwise 10 logged days and 2 weigh-ins.
EnergyCheckProgress _progress({
  bool ready = false,
  int daysUntil = 1,
  int loggedToGo = 0,
  int weighInsToGo = 0,
  DateTime? pausedUntil,
}) => EnergyCheckProgress(
  today: _day,
  loggedDays: ready ? 21 : 10,
  weighInDays: ready ? 21 : 2,
  weighInSpanDays: ready ? 20 : 5,
  pausedUntil: pausedUntil,
  earliestDay: addDays(_day, ready ? 0 : daysUntil),
  loggedDaysToGo: loggedToGo,
  weighInsToGo: weighInsToGo,
);

const EnergyCheckProposal _proposal = EnergyCheckProposal(
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

TodayScreen _today({
  DateTime? selectedDate,
  bool dayLoading = false,
  double? latestKg = 82.4,
  EnergyCheckProgress? progress,
  EnergyCheckProposal? proposal,
  Future<void> Function(double kg)? onLogWeight,
  bool withChip = true,
}) => TodayScreen(
  userName: 'Moritz',
  profile: const UserProfile(weightKg: 84),
  summary: todaySummary(),
  meals: const [],
  selectedDate: selectedDate ?? _day,
  streak: 0,
  dayLoading: dayLoading,
  energyCheck: proposal,
  onAcceptEnergyCheck: () async {},
  onDismissEnergyCheck: () async {},
  energyCheckProgress: progress,
  latestWeightKg: latestKg,
  onLogWeight: withChip ? (onLogWeight ?? (_) async {}) : null,
);

Future<void> _pumpToday(
  WidgetTester tester,
  TodayScreen screen, {
  Locale locale = const Locale('de'),
}) => withClock(Clock.fixed(_now), () async {
  await pumpLocalized(
    tester,
    screen,
    locale: locale,
    surfaceSize: const Size(390, 2400),
    scaffold: false,
    safeArea: false,
  );
  await tester.pump(const Duration(seconds: 2));
});

String _line(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('today-weigh-progress')))
    .data!;

String _chip(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('today-weigh-value'))).data!;

void main() {
  // The app's fonts: whether the line fits beside the chip depends on real
  // glyph widths, not on the test font's squares.
  setUpAll(loadDesignFonts);

  group('progress line', () {
    test('German: earliest day and what is missing, singular and plural', () {
      final l = deL10n;
      expect(
        todayWeighProgressText(_progress(daysUntil: 5, weighInsToGo: 2), l),
        'Wochen-Check frühestens in 5 Tagen · noch 2 Wiegungen',
      );
      expect(
        todayWeighProgressText(_progress(weighInsToGo: 1), l),
        'Wochen-Check frühestens morgen · noch 1 Wiegung',
      );
      expect(
        todayWeighProgressText(
          _progress(daysUntil: 15, loggedToGo: 14, weighInsToGo: 4),
          l,
        ),
        'Wochen-Check frühestens in 15 Tagen · noch 14 vollständige Tage · '
        'noch 4 Wiegungen',
      );
      expect(
        todayWeighProgressText(_progress(loggedToGo: 1), l),
        'Wochen-Check frühestens morgen · noch 1 vollständiger Tag',
      );
      // Only the pause after an answer is left.
      expect(
        todayWeighProgressText(
          _progress(daysUntil: 7, pausedUntil: DateTime(2026, 10, 10)),
          l,
        ),
        'Wochen-Check frühestens in 7 Tagen',
      );
      expect(
        todayWeighProgressText(_progress(ready: true), l),
        'Wochen-Check aktiv · deine Daten reichen',
      );
    });

  });

  group('on the Today screen', () {
    testWidgets('chip with the latest weight and the line', (tester) async {
      await _pumpToday(
        tester,
        _today(progress: _progress(daysUntil: 5, weighInsToGo: 2)),
      );
      expect(_chip(tester), '82,4 kg');
      expect(
        _line(tester),
        'Wochen-Check frühestens in 5 Tagen · noch 2 Wiegungen',
      );
    });

    testWidgets('English decimal point; without a weigh-in "Log weight"', (
      tester,
    ) async {
      await _pumpToday(tester, _today(), locale: const Locale('en'));
      expect(_chip(tester), '82.4 kg');
      await _pumpToday(
        tester,
        _today(latestKg: null),
        locale: const Locale('en'),
      );
      expect(_chip(tester), 'Log weight');
      await _pumpToday(tester, _today(latestKg: null));
      expect(_chip(tester), 'Gewicht eintragen');
    });

    testWidgets('the chip is a labelled button', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpToday(tester, _today());
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-weigh-chip'))),
        isSemantics(
          label: 'Letztes Gewicht 82,4 kg. Neues Gewicht eintragen',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await _pumpToday(tester, _today(latestKg: null));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('today-weigh-chip'))),
        isSemantics(label: 'Gewicht eintragen', isButton: true),
      );
      handle.dispose();
    });

    testWidgets('a proposal card replaces the line, the chip stays', (
      tester,
    ) async {
      await _pumpToday(
        tester,
        _today(progress: _progress(ready: true), proposal: _proposal),
      );
      expect(find.byType(TodayEnergyCheckCard), findsOneWidget);
      expect(find.byKey(const ValueKey('today-weigh-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-weigh-progress')), findsNothing);

      await _pumpToday(tester, _today(progress: _progress(ready: true)));
      expect(_line(tester), 'Wochen-Check aktiv · deine Daten reichen');
    });

    testWidgets('today only: not on an archive day, not while loading, '
        'not without a save path', (tester) async {
      await _pumpToday(
        tester,
        _today(
          selectedDate: DateTime(2026, 10, 2),
          progress: _progress(weighInsToGo: 1),
        ),
      );
      expect(find.byKey(const ValueKey('today-weigh')), findsNothing);
      await _pumpToday(
        tester,
        _today(dayLoading: true, progress: _progress(weighInsToGo: 1)),
      );
      expect(find.byKey(const ValueKey('today-weigh')), findsNothing);
      await _pumpToday(tester, _today(withChip: false));
      expect(find.byKey(const ValueKey('today-weigh')), findsNothing);
    });

    testWidgets('without a progress the chip stands alone', (tester) async {
      await _pumpToday(tester, _today());
      expect(find.byKey(const ValueKey('today-weigh-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-weigh-progress')), findsNothing);
    });

    testWidgets('the chip opens the profile weigh-in sheet and saves', (
      tester,
    ) async {
      final saved = <double>[];
      await _pumpToday(
        tester,
        _today(onLogWeight: (kg) async => saved.add(kg)),
      );
      await tester.tap(find.byKey(const ValueKey('today-weigh-chip')));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('profile-weight-input'));
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, '82,4');
      await tester.enterText(field, '81,9');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('profile-weight-save')));
      await tester.pumpAndSettle();

      expect(saved, [81.9]);
      expect(field, findsNothing, reason: 'closed after the save');
    });

    testWidgets('without a weigh-in the sheet starts at the profile weight', (
      tester,
    ) async {
      await _pumpToday(tester, _today(latestKg: null));
      await tester.tap(find.byKey(const ValueKey('today-weigh-chip')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('profile-weight-input')),
            )
            .controller!
            .text,
        '84',
      );
    });
  });

  renderMatrix(
    'chip and the longest line fit at 320 px',
    (tester, c) async {
      for (final kg in <double?>[82.4, null]) {
        await c.pump(
          tester,
          SizedBox(
            width: 320,
            child: TodayWeighRow(
              latestKg: kg,
              onTap: () {},
              progress: _progress(
                daysUntil: 15,
                loggedToGo: 14,
                weighInsToGo: 4,
              ),
            ),
          ),
          scrollable: true,
        );
        expect(find.byKey(const ValueKey('today-weigh-chip')), findsOneWidget);
        // The 44 px touch floor holds at every text size.
        expect(
          tester.getSize(find.byKey(const ValueKey('today-weigh-chip'))).height,
          greaterThanOrEqualTo(44),
        );
      }
    },
    locales: const [Locale('de'), Locale('en')],
    // Layout does not depend on the brightness.
    brightnesses: const [Brightness.dark],
    textScales: const [1.0, 2.0],
  );

  renderMatrix('side by side at phone width', (tester, c) async {
    await c.pump(
      tester,
      SizedBox(
        width: 350,
        child: TodayWeighRow(
          latestKg: 82.4,
          onTap: () {},
          progress: _progress(daysUntil: 5, weighInsToGo: 2),
        ),
      ),
    );
    final chip = tester.getRect(find.byKey(const ValueKey('today-weigh-chip')));
    final line = tester.getRect(
      find.byKey(const ValueKey('today-weigh-progress')),
    );
    expect(line.left, greaterThan(chip.right));
  }, brightnesses: const [Brightness.dark]);

  renderMatrix(
    'a line that would need three lines beside the chip goes under it',
    (tester, c) async {
      for (final textScale in [1.0, 2.0]) {
        await pumpLocalized(
          tester,
          SizedBox(
            width: 350,
            child: TodayWeighRow(
              latestKg: null,
              onTap: () {},
              progress: _progress(
                daysUntil: 15,
                loggedToGo: 14,
                weighInsToGo: 4,
              ),
            ),
          ),
          locale: c.locale,
          textScale: textScale,
        );
        final chip = tester.getRect(
          find.byKey(const ValueKey('today-weigh-chip')),
        );
        final line = tester.getRect(
          find.byKey(const ValueKey('today-weigh-progress')),
        );
        expect(line.top, greaterThanOrEqualTo(chip.bottom));
        expect(line.left, lessThan(chip.right));
      }
    },
    locales: const [Locale('de'), Locale('en')],
    brightnesses: const [Brightness.dark],
  );
}
