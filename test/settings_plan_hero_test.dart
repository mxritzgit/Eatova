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
// Zahlen seit dem Kalorien-Review 2026-08-21 (PAL-Leiter ab 1,4, 1-%-
// Defizitdeckel kg × 11 kcal/Tag, geschlechtsabhaengige Untergrenze):
// Standardprofil 78 kg / 178 cm / 30 J. / neutral / sitzend → BMR 1665,
// Erhaltung 2330, Deckel 858 kcal/Tag, Untergrenze 1350. Fuer dieses Profil
// greift bei „−1 kg/Woche" nicht mehr die Untergrenze, sondern der Deckel —
// die Klemme selbst braucht ein leichteres Profil (s. [klemmProfil]).
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
  /// weiblich / sitzend → Erhaltung 1700, Deckel 605 kcal/Tag, Untergrenze
  /// 1200. „Ambitioniert" (−1100) wird auf −605 gedeckelt, landet bei 1100
  /// und wird auf 1200 hochgeklemmt — effektiv −500 kcal/Tag ≙ −0,45 kg/Woche.
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

    // Erhaltung 2330, Tagesziel 1450 (Defizit auf 858 gedeckelt) → −0,8 kg/Woche.
    expect(find.text('Erhaltung 2330 · −0,8 kg/Woche'), findsOneWidget);
    expect(find.text('Erhaltung 2330 · −1 kg/Woche'), findsNothing);
  });

  testWidgets('Plan-Karte erklaert die Sicherheitsklemme in einem Satz',
      (tester) async {
    await openSettings(
      tester,
      profile: autoProfil(WeightGoal.lose1kg, basis: klemmProfil),
    );

    // Erhaltung 1700, Tagesziel 1200 (aus 1100 hochgeklemmt) → −0,45 kg/Woche.
    expect(find.text('Erhaltung 1700 · −0,45 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '1100 kcal. Dein tatsächliches Tempo ist damit −0,45 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Plan-Karte erklaert den 1-%-Defizitdeckel in einem Satz',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Die Untergrenze (1350) greift hier nicht — der Deckel (78 kg × 11 = 858
    // kcal/Tag) bremst das Versprechen von −1100 auf −858.
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Schneller als 1 % deines Körpergewichts pro Woche empfehlen wir '
        'nicht: Dein Defizit ist auf 858 kcal/Tag begrenzt. Dein tatsächliches '
        'Tempo ist damit −0,8 kg/Woche statt −1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ohne Klemme bleibt die Plan-Karte ohne Hinweis', (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.maintain));

    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(find.text('Erhaltung 2330 · Gewicht stabil'), findsOneWidget);
  });

  testWidgets('manuelles Tagesziel bestimmt das angezeigte Tempo',
      (tester) async {
    // Standardprofil: 2200 kcal gespeichert, gerechnet waeren es 2350 → der
    // Screen startet im Manuell-Modus. 2200 − 2330 = −130 kcal/Tag.
    await openSettings(tester, profile: const UserProfile());

    expect(find.text('Erhaltung 2330 · −0,12 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
  });
}
