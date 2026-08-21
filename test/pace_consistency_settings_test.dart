import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/app_theme.dart';

// B2, Reststelle 1 — derselbe Widerspruch wie in der Plan-Karte, nur eine
// Gruppe weiter unten im SELBEN Scroll:
//
//   Plan-Hero          „Erhaltung 2330 · −0,8 kg/Woche"
//   Gewichtsziel-Zeile „Abnehmen              −1 kg/Woche"
//
// Anders als im Picker gibt es hier zwangslaeufig ein vollstaendiges Profil:
// der Screen rechnet aus genau diesen Feldern live das Tagesziel. Es sind also
// zwei verschiedene Tempo-Zeichenketten auf einem Bildschirm, ohne dass etwas
// den Unterschied erklaert.
//
// Regel, gegen die hier geprueft wird: **Steht auf einem Bildschirm mehr als
// eine Tempo-Zeichenkette, muss eine dritte sie verbinden.** Das gewaehlte
// Tempo bleibt am Bedienelement (es ist die Auswahl, nicht die Zusage) — was
// daraus wird, sagt eine Zeile direkt darunter bzw. der Untertitel jeder
// Option.
//
// Zahlen seit dem Kalorien-Review 2026-08-21 (PAL-Leiter ab 1,4, 1-%-
// Defizitdeckel kg × 11 kcal/Tag, geschlechtsabhaengige Untergrenze):
// Standardprofil 78 kg / 178 cm / 30 J. / neutral / sitzend → BMR 1665,
// Erhaltung 2330, Deckel 858 kcal/Tag, Untergrenze 1350.
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
  /// 1200. „Zuegig" (−825) und „Ambitioniert" (−1100) werden beide auf −605
  /// gedeckelt, landen bei 1100 und werden auf 1200 hochgeklemmt —
  /// effektiv −500 kcal/Tag ≙ −0,45 kg/Woche.
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

  /// Oeffnet das Auswahl-Sheet des Gewichtsziels. Die Zeile liegt weit unten im
  /// Scroll — ohne [WidgetController.ensureVisible] geht der Tap ins Leere.
  Future<void> openGoalPicker(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-weight-goal')));
    await tester.pumpAndSettle();
  }

  /// Der Untertitel einer Option — nur innerhalb ihrer eigenen Zeile gesucht,
  /// damit die identische Zeile unter dem Feld nicht mitzaehlt.
  Finder optionText(String goalName, String text) => find.descendant(
        of: find.byKey(ValueKey('settings-weight-goal-$goalName')),
        matching: find.text(text),
      );

  testWidgets(
      'die Gewichtsziel-Zeile sagt, was aus dem gewaehlten Tempo wird',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Die Plan-Karte im selben Scroll: der 1-%-Deckel laesst statt −1100 nur
    // −858 kcal/Tag zu → 1450 kcal; 2330 − 1450 = 880 kcal ≙ −0,8 kg/Woche.
    expect(find.text('Erhaltung 2330 · −0,8 kg/Woche'), findsOneWidget);

    // Das Bedienelement zeigt weiter die Auswahl — sonst sieht der Nutzer nach
    // dem Tippen etwas anderes, als er getippt hat.
    expect(find.text('−1 kg/Woche'), findsOneWidget);

    // …und direkt darunter die Zeile, die beide Zahlen verbindet.
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-weight-goal-effective')),
          )
          .data,
      'Ergibt 1450 kcal/Tag · −0,8 kg/Woche',
    );
  });

  testWidgets(
      'ohne abweichendes Tempo bleibt die Zeile ohne Zusatzzeile',
      (tester) async {
    // −0,75 kg/Woche: Erhaltung 2330, Ziel 1500, real −830 kcal ≙ −0,75 kg/Woche.
    // Versprechen und Plan tragen dieselbe Beschriftung — eine erklaerende
    // Zeile waere hier nur Laerm.
    //
    // Frueher stand hier −0,5 kg/Woche; seit der PAL-Anhebung ergibt das 1800
    // kcal, also −530 kcal/Tag ≙ „−0,48 kg/Woche". Das liegt zwar innerhalb
    // des Rundungsrauschens (kein Warnsatz auf der Plan-Karte), ist aber eine
    // ANDERE Zeichenkette als „−0,5 kg/Woche" — und die Zusatzzeile vergleicht
    // bewusst Zeichenketten, nicht Zahlen.
    await openSettings(tester, profile: autoProfil(WeightGoal.lose075kg));

    expect(find.text('Erhaltung 2330 · −0,75 kg/Woche'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsNothing,
    );
  });

  testWidgets(
      'jede Option im Ziel-Picker nennt den Plan, den sie ergibt',
      (tester) async {
    await openSettings(tester, profile: autoProfil(WeightGoal.lose1kg));
    await openGoalPicker(tester);

    // „Ambitioniert" wird fuer dieses Profil vom 1-%-Deckel auf 1450 kcal
    // gebremst, „Zuegig" (−825) passt noch unter den Deckel (858) und ergibt
    // 1500 — der Untertitel sagt das VOR der Auswahl.
    expect(
      optionText('lose1kg', 'Ergibt 1450 kcal/Tag · −0,8 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose075kg', 'Ergibt 1500 kcal/Tag · −0,75 kg/Woche'),
      findsOneWidget,
    );

    // Wo weder Deckel noch Klemme greifen, steht dieselbe Zeile mit anderer
    // Zahl — auch wenn die 50er-Rundung das Tempo leicht verschiebt.
    expect(
      optionText('lose05kg', 'Ergibt 1800 kcal/Tag · −0,48 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('maintain', 'Ergibt 2350 kcal/Tag · Gewicht stabil'),
      findsOneWidget,
    );

    // Das ungedeckte kcal-Versprechen (WeightGoal.deltaLabel) ist weg.
    expect(find.text('−1100 kcal'), findsNothing);
    expect(find.text('−825 kcal'), findsNothing);
  });

  testWidgets(
      'in der Klemme nennen zwei Optionen wortgleich denselben Plan',
      (tester) async {
    await openSettings(
      tester,
      profile: autoProfil(WeightGoal.lose1kg, basis: klemmProfil),
    );
    await openGoalPicker(tester);

    // „Zuegig" und „Ambitioniert" landen fuer dieses Profil beide auf 1200 kcal
    // — der Untertitel sagt das VOR der Auswahl, wortgleich.
    expect(
      optionText('lose1kg', 'Ergibt 1200 kcal/Tag · −0,45 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose075kg', 'Ergibt 1200 kcal/Tag · −0,45 kg/Woche'),
      findsOneWidget,
    );
  });

  testWidgets(
      'im Manuell-Modus sagt der Picker, dass die Auswahl das Tagesziel nicht bewegt',
      (tester) async {
    // Standardprofil: 2200 kcal gespeichert, gerechnet waeren es 2350 → der
    // Screen startet im Manuell-Modus. Dort haengt das Tagesziel nicht mehr am
    // Tempo; „Ergibt 1800 kcal/Tag" waere schlicht falsch.
    await openSettings(tester, profile: const UserProfile());

    // Ziel „halten", aber 2200 kcal unter einer Erhaltung von 2330:
    // −130 kcal/Tag ≙ −0,12 kg/Woche.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-weight-goal-effective')),
          )
          .data,
      'Ergibt 2200 kcal/Tag · −0,12 kg/Woche',
    );

    await openGoalPicker(tester);
    expect(
      find.text('Ändert dein manuelles Tagesziel nicht'),
      findsNWidgets(WeightGoal.values.length),
    );
  });
}
