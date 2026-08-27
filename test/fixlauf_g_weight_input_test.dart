import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/tracking_sync.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';

// F7-02: the weigh-in sheet accepted anything > 0, so "7.55" (slipped
// decimal) reached log, cache and HealthKit, the server rejected it with
// 23514 and the value vanished on the next boot. The sheet now checks
// isValidWeightLogKg (20..400), the store clamps as the last barrier.
//
// F7-03: loader fetched 365 points, WeightLog.add trimmed to 30 — the first
// weigh-in after boot moved the baseline and every derived number jumped.

WeightLog _log(int n, {double start = 90}) => WeightLog(
      entries: <WeightLogEntry>[
        for (var i = 0; i < n; i++)
          WeightLogEntry(
            timestamp: DateTime(2026, 1, 1).add(Duration(days: i)),
            weightKg: start - i * 0.1,
          ),
      ],
    );

Future<void> _pumpCard(
  WidgetTester tester, {
  required ValueChanged<double> onLogWeight,
}) async {
  pinPhoneViewport(tester);

  await pumpLocalized(
    tester,
    WeightCard(
      profile: const UserProfile(),
      log: _log(3),
      onLogWeight: onLogWeight,
    ),
    brightness: Brightness.light,
    // Motion as before the migration.
    reducedMotion: false,
    padding: const EdgeInsets.all(20),
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('profile-log-weight')));
  await tester.pumpAndSettle();
}

VoidCallback? _saveHandler(WidgetTester tester) => tester
    .widget<PrimaryActionButton>(
      find.byKey(const ValueKey('profile-weight-save')),
    )
    .onTap;

Future<void> _tippe(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('profile-weight-input')),
    text,
  );
  await tester.pump();
}

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

void main() {
  group('Gewichts-Sheet prueft den Bereich (F7-02)', () {
    testWidgets('7.55 (verrutschtes Komma) wird abgelehnt', (tester) async {
      double? empfangen;
      await _pumpCard(tester, onLogWeight: (kg) => empfangen = kg);
      expect(_saveHandler(tester), isNotNull, reason: 'Vorbelegung ist gueltig');

      await _tippe(tester, '7.55');

      expect(find.byKey(const ValueKey('profile-weight-error')), findsOneWidget);
      expect(find.text('20–400 kg'), findsOneWidget);
      expect(_saveHandler(tester), isNull);
      // Enter on the keyboard must not sneak past the button either.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-weight-input')), findsOneWidget,
          reason: 'das Sheet bleibt offen');
      expect(empfangen, isNull);
    });

    testWidgets('755 (verschlucktes Komma) wird abgelehnt', (tester) async {
      double? empfangen;
      await _pumpCard(tester, onLogWeight: (kg) => empfangen = kg);

      await _tippe(tester, '755');

      expect(find.text('20–400 kg'), findsOneWidget);
      expect(_saveHandler(tester), isNull);
      expect(empfangen, isNull);
    });

    testWidgets('75,5 geht durch (Komma erlaubt), Fehlzeile verschwindet',
        (tester) async {
      double? empfangen;
      await _pumpCard(tester, onLogWeight: (kg) => empfangen = kg);

      await _tippe(tester, '7.55');
      expect(_saveHandler(tester), isNull);
      await _tippe(tester, '75,5');

      expect(find.byKey(const ValueKey('profile-weight-error')), findsNothing);
      expect(_saveHandler(tester), isNotNull);
      await tester.tap(find.byKey(const ValueKey('profile-weight-save')));
      await tester.pumpAndSettle();
      expect(empfangen, 75.5);
    });

    testWidgets('leeres Feld: gesperrt, aber ohne Fehlzeile', (tester) async {
      await _pumpCard(tester, onLogWeight: (_) {});
      await _tippe(tester, '');

      expect(_saveHandler(tester), isNull);
      expect(find.byKey(const ValueKey('profile-weight-error')), findsNothing);
    });
  });

  group('HomeStore klemmt als letzte Schranke (F7-02)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    HomeStore store() => HomeStore(
          sync: null,
          health: const NoopHealthService(),
          notificationService: const NoopNotificationService(),
          initialUserName: 'Test',
          emitSnack: _noopSnack,
        );

    test('7.55 -> 20 kg, 755 -> 400 kg, 0/NaN -> nichts', () {
      final s = store();
      addTearDown(s.dispose);

      s.logWeight(7.55);
      expect(s.weightLog.latest!.weightKg, 20.0);

      s.logWeight(755);
      expect(s.weightLog.latest!.weightKg, 400.0);

      final vorher = s.weightLog.entries.length;
      s.logWeight(0);
      s.logWeight(double.nan);
      expect(s.weightLog.entries.length, vorher);
    });

    test('gueltige Werte bleiben unveraendert (2 Nachkommastellen)', () {
      final s = store();
      addTearDown(s.dispose);
      s.logWeight(75.456);
      expect(s.weightLog.latest!.weightKg, 75.46);
    });
  });

  group('WeightLog — EINE Obergrenze, stabile Basis (F7-03)', () {
    test('lokaler Puffer und Server-Limit sind dieselbe Zahl', () {
      expect(WeightLog.maxEntries, 365);
      expect(TrackingSync.weightLogLimit, WeightLog.maxEntries);
    });

    test('45 Eintraege -> wiegen -> Basis, Delta und Fortschritt unveraendert',
        () {
      final vorher = _log(45);
      final basisVorher = vorher.baseline!;
      final nachher = vorher.add(85.0);

      expect(nachher.entries.length, 46);
      expect(identical(nachher.baseline, basisVorher), isTrue,
          reason: 'frueher fiel der Puffer auf 30 und die Basis sprang');
      expect(nachher.trendDelta, closeTo(85.0 - 90.0, 1e-9));
      expect(vorher.baseline!.timestamp, DateTime(2026, 1, 1));
    });

    test('ab 366 faellt der aelteste Eintrag — auf beiden Seiten gleich', () {
      var log = const WeightLog();
      for (var i = 1; i <= 366; i++) {
        log = log.add(i.toDouble());
      }
      expect(log.entries.length, 365);
      expect(log.baseline!.weightKg, 2);
      expect(log.latest!.weightKg, 366);
    });

    test('sanitizeKg: Tabellengrenzen und zwei Nachkommastellen', () {
      expect(WeightLog.sanitizeKg(7.55), 20.0);
      expect(WeightLog.sanitizeKg(755), 400.0);
      expect(WeightLog.sanitizeKg(75.456), 75.46);
      expect(WeightLog.sanitizeKg(0), isNull);
      expect(WeightLog.sanitizeKg(-1), isNull);
      expect(WeightLog.sanitizeKg(double.infinity), isNull);
    });
  });
}
