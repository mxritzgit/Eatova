import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/app_theme.dart';

// B2 — die Plan-Karte widersprach sich selbst: sie versprach das GEWAEHLTE
// Tempo (WeightGoal.paceLabel), obwohl die Sicherheitsklemme das Tagesziel
// anhebt. Fuer das damalige Standardprofil stand „Erhaltung 1997 ·
// −1 kg/Woche" direkt ueber „1200" — 1997 − 1200 = 797, das sind
// −0,72 kg/Woche, nicht −1.
//
// Seit dem Design-Refactor 2026-08-09 ist die Karte ein Forest-Hero auf einer
// Route statt einer Glaskarte im Sheet; die zeichengenauen Erwartungen sind
// geblieben.
//
// Zahlen seit dem Kalorien-Review 2026-08-21 und „jeder Schritt zaehlt"
// (PAL-Leiter OHNE Gehen 1,3 / 1,45 / 1,6 / 1,75 / 1,9, keine Schritt-Basis
// mehr; 1-%-Defizitdeckel kg × 11 kcal/Tag — auf 0,05 kg/Woche abgerundet,
// also 55-kcal-Schritte —, geschlechtsabhaengige Untergrenze, Tempo-Labels
// auf dem 0,05-Raster): Standardprofil 78 kg / 178 cm / 30 J. / neutral /
// sitzend → BMR 1665, Erhaltung 1664,5 × 1,3 = 2164, Deckel 858 → 825
// kcal/Tag, Untergrenze 1350. Fuer dieses Profil greift bei „−1 kg/Woche"
// nicht die Untergrenze, sondern der Deckel: 2163,85 − 825 = 1338,85 → 1350
// landet GENAU auf der Untergrenze, nicht darunter — die Klemme selbst
// braucht ein leichteres Profil (s. [klemmProfil]).
void main() {
  /// Profil, dessen gespeicherte Energie-Ziele exakt der Rechnung entsprechen.
  /// Nur dann startet der Screen im Live-Modus (Manuell-Schalter aus).
  UserProfile autoProfil(
    WeightGoal goal, {
    UserProfile basis = const UserProfile(),
  }) {
    final p = basis.copyWith(weightGoal: goal);
    final t = const KcalCalculator().calculate(p);
    return p.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  /// Profil, bei dem Deckel UND Untergrenze greifen: 55 kg / 160 cm / 35 J. /
  /// weiblich / sitzend → BMR 1214, Erhaltung 1214 × 1,3 = 1578, Deckel
  /// 605 kcal/Tag, Untergrenze 1200. „Ambitioniert" (−1100) wird auf −605
  /// gedeckelt, landet bei 973 → 950 und wird auf 1200 hochgeklemmt —
  /// effektiv −378 kcal/Tag ≙ −0,35 kg/Woche.
  const klemmProfil = UserProfile(
    weightKg: 55,
    heightCm: 160,
    ageYears: 35,
    sex: BiologicalSex.female,
    targetWeightKg: 55,
  );

  Future<void> openSettings(
    WidgetTester tester, {
    required UserProfile profile,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => GoalsScreen(profile: profile),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
  }

  testWidgets('Plan-Karte zeigt das effektive statt des versprochenen Tempos',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Erhaltung 2164, Tagesziel 1350 (Defizit auf 825 gedeckelt) →
    // −814 kcal/Tag ≙ −0,74 → im Raster −0,75 kg/Woche.
    expect(find.text('Erhaltung 2164 · −0,75 kg/Woche'), findsOneWidget);
    expect(find.text('Erhaltung 2164 · −1 kg/Woche'), findsNothing);
  });

  testWidgets('Plan-Karte erklaert die Sicherheitsklemme in einem Satz',
      (tester) async {
    await openSettings(
      tester,
      profile: autoProfil(WeightGoal.lose1kg, basis: klemmProfil),
    );

    // Erhaltung 1578, Tagesziel 1200 (aus 950 hochgeklemmt; Deckel 605 →
    // 973 → 950) → −378 kcal/Tag ≙ −0,35 kg/Woche.
    // Die Untergrenze bindet staerker als der Deckel: der Satz nennt die
    // Klemme, nicht das 1 %.
    expect(find.text('Erhaltung 1578 · −0,35 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '950 kcal. Dein tatsächliches Tempo ist damit −0,35 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Plan-Karte erklaert den 1-%-Defizitdeckel in einem Satz',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Die Untergrenze (1350) greift hier nicht — das Ziel landet mit 1350
    // genau AUF ihr, `floorApplied` verlangt echtes Unterschreiten. Der Deckel
    // (78 kg × 11 = 858, auf 0,05 kg/Woche = 825 abgerundet) bremst das
    // Versprechen von −1100 auf −825, und der Satz nennt die runde Stufe statt
    // „858 … −0,78".
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 825 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,75 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ohne Klemme bleibt die Plan-Karte ohne Hinweis', (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.maintain));

    // 2163,85 → 2150 kcal; 2150 − 2164 = −14 kcal/Tag liegt im 0,05-Rauschen.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(find.text('Erhaltung 2164 · Gewicht stabil'), findsOneWidget);
  });

  testWidgets('manuelles Tagesziel bestimmt das angezeigte Tempo',
      (tester) async {
    // Standardprofil mit 2500 kcal gespeichert, gerechnet waeren es 2150 → der
    // Screen startet im Manuell-Modus. 2500 − 2164 = +336 kcal/Tag ≙ +0,305
    // kg/Woche, im 0,05-Raster „+0,3 kg/Woche".
    //
    // Bewusst NICHT der Default 2200: seit der PAL-Leiter ohne Gehen liegt
    // die Erhaltung bei 2164, und +36 kcal/Tag bleiben unter dem 0,05-Rauschen
    // → „Gewicht stabil" — dieselbe Zeichenkette wie fuer das gerechnete Ziel,
    // der Test saehe nicht mehr, dass die MANUELLE Zahl das Tempo bestimmt.
    await openSettings(
      tester,
      profile: const UserProfile().copyWith(dailyKcalGoal: 2500),
    );

    expect(find.text('Erhaltung 2164 · +0,3 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
  });
}
