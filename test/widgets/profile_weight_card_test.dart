// Die Gewichts-Karte ersetzt seit dem Design-Refactor die alte
// BodyStatsCard + WeightHistoryCard. Vier Aussagen, die sie halten muss:
//
//   * die Delta-Pille sagt deutsch und mit echtem Vorzeichen, was passiert
//     ist (vorher stand dort '-2.6 kg' neben einem '78,4 kg'),
//   * unter zwei Messungen gibt es keine Verlaufslinie, sondern einen Satz,
//   * ein Wunschgewicht GLEICH dem Startgewicht erzeugt keine
//     100-%-Erfolgsmeldung (und keine Division durch Null),
//   * das Gewichts-Sheet bleibt BEWUSST ohne Verwerfen-Rueckfrage (D5) —
//     dieser Test verhindert, dass sie jemand gutgemeint nachruestet.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

WeightLog _log(List<double> kg) => WeightLog(
      entries: <WeightLogEntry>[
        for (var i = 0; i < kg.length; i++)
          WeightLogEntry(
            timestamp: DateTime(2026, 7, 1 + i),
            weightKg: kg[i],
          ),
      ],
    );

Future<void> _pumpCard(
  WidgetTester tester, {
  required WeightLog log,
  UserProfile profile = const UserProfile(),
  ValueChanged<double>? onLogWeight,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // WeightCard liest seit der i18n-Migration context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: WeightCard(
            profile: profile,
            log: log,
            onLogWeight: onLogWeight ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Delta-Pille', () {
    testWidgets('nennt eine Abnahme mit echtem Minuszeichen und Komma', (
      tester,
    ) async {
      await _pumpCard(tester, log: _log([80.0, 78.8]));

      expect(find.text('−1,2 kg'), findsOneWidget);
      expect(find.text('-1.2 kg'), findsNothing);
    });

    testWidgets('nennt eine Zunahme mit Pluszeichen', (tester) async {
      await _pumpCard(tester, log: _log([78.8, 80.0]));

      expect(find.text('+1,2 kg'), findsOneWidget);
    });

    testWidgets('nennt Rauschen „stabil" statt einer Scheingenauigkeit', (
      tester,
    ) async {
      await _pumpCard(tester, log: _log([78.0, 78.02]));

      expect(find.text('stabil'), findsOneWidget);
      expect(find.textContaining('0,0 kg'), findsNothing);
    });

    testWidgets('ohne zweite Messung gibt es gar keine Pille', (tester) async {
      await _pumpCard(tester, log: _log([78.0]));

      expect(find.text('stabil'), findsNothing);
      expect(find.textContaining(' kg'), findsNothing);
    });
  });

  group('Verlaufslinie', () {
    testWidgets('erscheint erst ab zwei Messungen', (tester) async {
      await _pumpCard(tester, log: _log([80.0, 79.0]));

      expect(find.byType(Sparkline), findsOneWidget);
      expect(find.text('2 Messungen'), findsOneWidget);
      expect(
        find.textContaining('Logge dein Gewicht regelmäßig'),
        findsNothing,
      );
    });

    testWidgets(
      'bei einer einzigen Messung steht dort ein Satz statt einer '
      'leeren Flaeche',
      (tester) async {
        await _pumpCard(tester, log: _log([80.0]));

        expect(find.byType(Sparkline), findsNothing);
        expect(
          find.text('Logge dein Gewicht regelmäßig für eine Verlaufslinie.'),
          findsOneWidget,
          reason: 'der Satz war doppelt kodiert im Painter versteckt',
        );
        expect(find.text('–'), findsOneWidget);
      },
    );
  });

  group('Ziel-Fortschritt', () {
    testWidgets('rechnet vom ersten Eintrag zum Wunschgewicht', (tester) async {
      // Start 80, Ziel 70, aktuell 75 -> genau die Haelfte.
      await _pumpCard(
        tester,
        log: _log([80.0, 75.0]),
        profile: const UserProfile(weightKg: 80, targetWeightKg: 70),
      );

      expect(find.text('Ziel 70 kg'), findsOneWidget);
      expect(find.text('50 %'), findsOneWidget);
    });

    testWidgets('klemmt bei falscher Richtung auf 0 statt negativ zu werden', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        log: _log([80.0, 83.0]),
        profile: const UserProfile(weightKg: 80, targetWeightKg: 70),
      );

      expect(find.text('0 %'), findsOneWidget);
    });

    testWidgets(
      'ein Wunschgewicht gleich dem Startgewicht blendet die Zeile aus',
      (tester) async {
        await _pumpCard(
          tester,
          log: _log([78.0, 78.4]),
          profile: const UserProfile(weightKg: 78, targetWeightKg: 78),
        );

        expect(tester.takeException(), isNull);
        expect(find.textContaining('Ziel 78 kg'), findsNothing);
        expect(find.text('100 %'), findsNothing);
        expect(find.text('0 %'), findsNothing);
      },
    );
  });

  group('Gewichts-Sheet', () {
    testWidgets('speichert den eingetippten Wert', (tester) async {
      double? gespeichert;
      await _pumpCard(
        tester,
        log: _log([78.0]),
        onLogWeight: (kg) => gespeichert = kg,
      );

      await tester.tap(find.byKey(const ValueKey('profile-log-weight')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('profile-weight-input')),
        '76,5',
      );
      await tester.tap(find.byKey(const ValueKey('profile-weight-save')));
      await tester.pumpAndSettle();

      expect(gespeichert, 76.5);
    });

    testWidgets(
      'D5: Schliessen ohne Speichern fragt BEWUSST nicht nach — ein Feld mit '
      'sichtbarem Ausgangswert braucht keinen Verwerfen-Schutz',
      (tester) async {
        await _pumpCard(tester, log: _log([78.0]));

        await tester.tap(find.byKey(const ValueKey('profile-log-weight')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('profile-weight-input')),
          '99',
        );
        await tester.pumpAndSettle();

        // Ueber die Barriere schliessen.
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('discard-changes-dialog')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('profile-weight-input')),
          findsNothing,
          reason: 'das Sheet muss beim ersten Tap wirklich zu sein',
        );
      },
    );
  });

  testWidgets('rendert in Hell und Dunkel ohne Exception', (tester) async {
    for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
      await _pumpCard(
        tester,
        log: _log([80.0, 79.1, 78.4]),
        profile: const UserProfile(weightKg: 78, targetWeightKg: 72),
        brightness: brightness,
      );
      expect(tester.takeException(), isNull, reason: brightness.name);
    }
  });
}
