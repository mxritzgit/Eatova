import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// B2 — die Plan-Karte im Settings-Sheet widersprach sich selbst: sie versprach
// das GEWAEHLTE Tempo (WeightGoal.paceLabel), obwohl die 1200er-Sicherheits-
// klemme das Tagesziel anhebt. Fuer das Standardprofil stand
// „Erhaltung 1997 · −1 kg/Woche" direkt ueber „1200" — 1997 − 1200 = 797, das
// sind −0,72 kg/Woche, nicht −1.
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

  testWidgets('Plan-Karte zeigt das effektive statt des versprochenen Tempos',
      (tester) async {
    await openSheet(tester, profile: autoProfil(WeightGoal.lose1kg));

    // Erhaltung 1997, Tagesziel 1200 (aus 900 hochgeklemmt) → −0,72 kg/Woche.
    expect(find.text('Erhaltung 1997 · −0,72 kg/Woche'), findsOneWidget);
    expect(find.text('Erhaltung 1997 · −1 kg/Woche'), findsNothing);
  });

  testWidgets('Plan-Karte erklaert die Sicherheitsklemme in einem Satz',
      (tester) async {
    await openSheet(tester, profile: autoProfil(WeightGoal.lose1kg));

    expect(find.byKey(const ValueKey('settings-pace-warning')), findsOneWidget);
    expect(
      find.text(
        'Aus Sicherheitsgründen liegt dein Tagesziel bei 1200 kcal statt '
        '900 kcal. Dein tatsächliches Tempo ist damit −0,72 kg/Woche statt '
        '−1 kg/Woche.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ohne Klemme bleibt die Plan-Karte ohne Hinweis', (tester) async {
    await openSheet(tester, profile: autoProfil(WeightGoal.maintain));

    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
    expect(find.text('Erhaltung 1997 · Gewicht stabil'), findsOneWidget);
  });

  testWidgets('manuelles Tagesziel bestimmt das angezeigte Tempo',
      (tester) async {
    // Standardprofil: 2200 kcal gespeichert, gerechnet waeren es 2000 → das
    // Sheet startet im Manuell-Modus. 2200 − 1997 = +203 kcal/Tag.
    await openSheet(tester, profile: const UserProfile());

    expect(find.text('Erhaltung 1997 · +0,18 kg/Woche'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pace-warning')), findsNothing);
  });
}
