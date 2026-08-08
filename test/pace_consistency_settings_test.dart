import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// B2, Reststelle 1 — derselbe Widerspruch wie in der Plan-Karte, nur zwei
// Karten weiter unten im SELBEN Scroll:
//
//   _PlanHero          „Erhaltung 1997 · −0,72 kg/Woche"   (settings_sheet:1144)
//   _WeightGoalField   „Abnehmen              −1 kg/Woche"  (settings_sheet:1738)
//
// Anders als im Picker gibt es hier zwangslaeufig ein vollstaendiges Profil:
// das Sheet rechnet aus genau diesen Feldern live das Tagesziel. Es sind also
// zwei verschiedene Tempo-Zeichenketten auf einem Bildschirm, ohne dass etwas
// den Unterschied erklaert.
//
// Regel, gegen die hier geprueft wird: **Steht auf einem Bildschirm mehr als
// eine Tempo-Zeichenkette, muss eine dritte sie verbinden.** Das gewaehlte
// Tempo bleibt am Bedienelement (es ist die Auswahl, nicht die Zusage) — was
// daraus wird, sagt eine Zeile direkt darunter bzw. der Untertitel jeder
// Option.
void main() {
  /// Profil, dessen gespeicherte Energie-Ziele exakt der Rechnung entsprechen.
  /// Nur dann startet das Sheet im Live-Modus (Manuell-Schalter aus).
  UserProfile autoProfil(WeightGoal goal) {
    const basis = UserProfile();
    final p = basis.copyWith(weightGoal: goal);
    final t = const KcalCalculator().calculate(p);
    return p.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  Future<void> openSheet(
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
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () => showSettingsSheet(context, profile: profile),
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

  /// Oeffnet das Auswahl-Sheet des Gewichtsziels. Das Feld liegt weit unten im
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
      'das Gewichtsziel-Feld sagt, was aus dem gewaehlten Tempo wird',
      (tester) async {
    await openSheet(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Die Plan-Karte im selben Scroll: 1997 − 1200 = 797 kcal ≙ −0,72 kg/Woche.
    expect(find.text('Erhaltung 1997 · −0,72 kg/Woche'), findsOneWidget);

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
      'Ergibt 1200 kcal/Tag · −0,72 kg/Woche',
    );
  });

  testWidgets(
      'ohne abweichendes Tempo bleibt das Feld ohne Zusatzzeile',
      (tester) async {
    // −0,5 kg/Woche: Erhaltung 1997, Ziel 1450, real −547 kcal ≙ −0,5 kg/Woche.
    // Versprechen und Plan tragen dieselbe Beschriftung — eine erklaerende
    // Zeile waere hier nur Laerm.
    await openSheet(tester, profile: autoProfil(WeightGoal.lose05kg));

    expect(find.text('Erhaltung 1997 · −0,5 kg/Woche'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-weight-goal-effective')),
      findsNothing,
    );
  });

  testWidgets(
      'jede Option im Ziel-Picker nennt den Plan, den sie ergibt',
      (tester) async {
    await openSheet(tester, profile: autoProfil(WeightGoal.lose1kg));
    await openGoalPicker(tester);

    // „Zuegig" und „Ambitioniert" landen fuer dieses Profil beide auf 1200 kcal
    // — der Untertitel sagt das VOR der Auswahl, wortgleich.
    expect(
      optionText('lose1kg', 'Ergibt 1200 kcal/Tag · −0,72 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('lose075kg', 'Ergibt 1200 kcal/Tag · −0,72 kg/Woche'),
      findsOneWidget,
    );

    // Wo die Klemme nicht greift, steht dieselbe Zeile mit anderer Zahl.
    expect(
      optionText('lose05kg', 'Ergibt 1450 kcal/Tag · −0,5 kg/Woche'),
      findsOneWidget,
    );
    expect(
      optionText('maintain', 'Ergibt 2000 kcal/Tag · Gewicht stabil'),
      findsOneWidget,
    );

    // Das ungedeckte kcal-Versprechen (WeightGoal.deltaLabel) ist weg.
    expect(find.text('−1100 kcal'), findsNothing);
    expect(find.text('−825 kcal'), findsNothing);
  });

  testWidgets(
      'im Manuell-Modus sagt der Picker, dass die Auswahl das Tagesziel nicht bewegt',
      (tester) async {
    // Standardprofil: 2200 kcal gespeichert, gerechnet waeren es 2000 → das
    // Sheet startet im Manuell-Modus. Dort haengt das Tagesziel nicht mehr am
    // Tempo; „Ergibt 1450 kcal/Tag" waere schlicht falsch.
    await openSheet(tester, profile: const UserProfile());

    // Ziel „halten", aber 2200 kcal ueber einer Erhaltung von 1997.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('settings-weight-goal-effective')),
          )
          .data,
      'Ergibt 2200 kcal/Tag · +0,18 kg/Woche',
    );

    await openGoalPicker(tester);
    expect(
      find.text('Ändert dein manuelles Tagesziel nicht'),
      findsNWidgets(WeightGoal.values.length),
    );
  });
}
