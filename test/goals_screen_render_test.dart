// DESIGN_REFACTOR §7.2 / §5: renders in BOTH brightnesses and at 200 % text
// without RenderFlex overflow. [GoalsScreen] is the densest page in the app,
// so it gets its own pump, and overflows are the subject, not swallowed.
//
// The four hand-written smokes (hell / dunkel / 2.0 hell / 2.0 dunkel) are one
// `renderMatrix` now; the two EN regressions keep their own cases because they
// pin a translated VALUE, not just "no exception".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'support/harness.dart';

/// Stored goals matching the calculation exactly -> live mode.
UserProfile _autoProfil() {
  const basis = UserProfile();
  final t = const KcalCalculator().calculate(basis);
  return basis.copyWith(
    dailyKcalGoal: t.kcal,
    proteinGoalG: t.proteinG,
    carbsGoalG: t.carbsG,
    fatGoalG: t.fatG,
  );
}

/// Pumps the page and pins what every case shares. Overflows are collected by
/// the caller ([renderMatrix] or [collectOverflows]).
Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  Locale locale = const Locale('de'),
  double textScale = 1.0,
  UserProfile profile = const UserProfile(),
  ReminderState reminderState = ReminderState.off,
  VoidCallback? onOpenSystemSettings,
  ThemeModeController? themeController,
}) async {
  pinPhoneViewport(tester);
  final Widget page = GoalsScreen(
    profile: profile,
    reminderState: reminderState,
    onOpenSystemSettings: onOpenSystemSettings,
  );
  await pumpLocalized(
    tester,
    themeController == null
        ? page
        : ThemeModeScope(controller: themeController, child: page),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    // GoalsScreen brings its own Scaffold and SafeArea.
    scaffold: false,
    safeArea: false,
    settle: true,
  );

  expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  renderMatrix(
    'Die Ziele-Seite rendert overflow-frei',
    (tester, c) async {
      await _pump(tester, brightness: c.brightness, locale: c.locale,
          textScale: c.textScale);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
    textScales: const <double>[1.0, 2.0],
  );

  testWidgets(
      'rendert unter EN mit englischem Tempo-Label statt deutschem Leck '
      '(i18n-Paket-7-Regression)', (tester) async {
    // The pace labels used to stay hardcoded German; this pins that shut.
    await _pump(
      tester,
      brightness: Brightness.light,
      locale: const Locale('en'),
    );

    expect(find.text('Weight stable'), findsOneWidget);
    expect(find.text('Gewicht stabil'), findsNothing);
  });

  testWidgets(
      'rendert unter EN mit Dezimalrate im Punkt- statt Komma-Format '
      '(i18n-Nachzieh-Regression)', (tester) async {
    // Same leak one level deeper: `_formatRateKg` stayed German-formatted.
    // `lose05kg` gives exactly 0.5 kg/week, so the separator is unambiguous.
    // Wunschgewicht 70: die Zeile zeigt seit P9-08d das WIRKSAME Tempo, und
    // ohne Rest-Weg (Wunsch == Gewicht) gaebe es gar keine Dezimalrate mehr.
    await _pump(
      tester,
      brightness: Brightness.light,
      locale: const Locale('en'),
      profile: const UserProfile(
        weightGoal: WeightGoal.lose05kg,
        targetWeightKg: 70,
      ),
    );

    expect(find.text('−0.5 kg/week'), findsOneWidget);
    expect(find.text('−0,5 kg/Woche'), findsNothing);
  });

  renderMatrix(
    'Der Live-Modus blendet die Energie-Felder aus und bleibt heil',
    (tester, c) async {
      await _pump(tester, brightness: c.brightness, textScale: c.textScale,
          profile: _autoProfil());
      expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
    },
    textScales: const <double>[2.0],
  );

  renderMatrix(
    'Blockierte Erinnerungen blenden eine Extra-Zeile ein',
    (tester, c) async {
      await _pump(
        tester,
        brightness: c.brightness,
        textScale: c.textScale,
        reminderState: ReminderState.blocked,
        onOpenSystemSettings: () {},
      );
      expect(
        find.byKey(const ValueKey('settings-open-system-settings')),
        findsOneWidget,
      );
    },
    textScales: const <double>[2.0],
  );

  testWidgets('die Fehler-Sammelmeldung sprengt die Seite nicht',
      (tester) async {
    final overflows = await collectOverflows(() async {
      await _pump(
        tester,
        brightness: Brightness.light,
        textScale: 2.0,
        profile: const UserProfile(weightKg: 30, heightCm: 100),
      );
      await tester.enterText(
        find.byKey(const ValueKey('settings-weight')),
        '755',
      );
      await tester.pumpAndSettle();
    });

    expect(
      find.byKey(const ValueKey('settings-validation-note')),
      findsOneWidget,
    );
    expect(overflows, isEmpty, reason: describeOverflows(overflows));
  });

  testWidgets('der Anzeige-Modus steht NICHT mehr auf dieser Seite',
      (tester) async {
    // Counter-check that the pill does not live in TWO places.
    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    final overflows = await collectOverflows(() async {
      await _pump(
        tester,
        brightness: Brightness.light,
        textScale: 2.0,
        themeController: controller,
      );
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
    expect(find.text('ANZEIGE'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('die drei Auswahl-Sheets rendern im Dunkelmodus bei 2.0',
      (tester) async {
    // The pickers sit on their own route, and their title + subtitle rows
    // are what breaks at 2.0.
    final overflows = await collectOverflows(() async {
      await _pump(tester, brightness: Brightness.dark, textScale: 2.0);

      for (final fall in const <(String, String)>[
        ('settings-sex', 'settings-sex-female'),
        ('settings-activity', 'settings-activity-moderate'),
        ('settings-weight-goal', 'settings-weight-goal-lose1kg'),
      ]) {
        await tester.ensureVisible(find.byKey(ValueKey(fall.$1)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(fall.$1)));
        await tester.pumpAndSettle();

        expect(find.byKey(ValueKey(fall.$2)), findsOneWidget,
            reason: '${fall.$1}: Picker ist nicht aufgegangen');

        Navigator.of(tester.element(find.byKey(ValueKey(fall.$2)))).pop();
        await tester.pumpAndSettle();
      }
    });

    expect(overflows, isEmpty, reason: describeOverflows(overflows));
  });

  // --- A11y: the cost of custom surfaces over Material widgets --------------
  //
  // Rows and InkWells must set name and enabled state explicitly, and both
  // drop silently in a refactor.

  testWidgets('jedes Zahlenfeld traegt seine Beschriftung als Semantik-Name',
      (tester) async {
    // Manual mode is a persisted flag (F7-01); only then are the kcal/macro
    // fields on the page at all. The water row is gone (F7-06).
    await _pump(
      tester,
      brightness: Brightness.light,
      profile: const UserProfile(manualEnergy: true),
    );

    const felder = <String, String>{
      'settings-weight': 'Gewicht',
      'settings-height': 'Größe',
      'settings-age': 'Alter',
      'settings-target-weight': 'Wunschgewicht',
      'settings-steps-goal': 'Schritte',
      'settings-kcal': 'Kcal Ziel',
      'settings-protein': 'Protein',
      'settings-carbs': 'Carbs',
      'settings-fat': 'Fett',
    };
    for (final eintrag in felder.entries) {
      final knoten = tester.getSemantics(find.byKey(ValueKey(eintrag.key)));
      expect(
        knoten,
        isSemantics(isTextField: true, isEnabled: true),
        reason: eintrag.key,
      );
      expect(
        knoten.getSemanticsData().label,
        contains(eintrag.value),
        reason: '${eintrag.key} waere ohne Namen nur „ein Zahlenfeld"',
      );
    }
  });

  testWidgets('gesperrte Aktionen sagen dem Screenreader, dass sie gesperrt '
      'sind', (tester) async {
    // A disabled action must be ANNOUNCED as disabled, not silently inert.
    await _pump(tester, brightness: Brightness.light);

    expect(
      tester.getSemantics(find.byKey(const ValueKey('settings-save'))),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
    );

    // 755 kg — the same input as in settings_validation_test.
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '755');
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const ValueKey('settings-save'))),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      reason: 'muss als GESPERRT angesagt werden, nicht als wirkungslos',
    );
  });

  testWidgets('der Seitenfuss der Ziele-Seite steht ohne vorheriges Scrollen '
      'im Baum', (tester) async {
    // Guards against ListView: a lazy list never builds the save button or
    // legal links, which several tests read unscrolled.
    await _pump(tester, brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-save')), findsOneWidget);
    // `settings-reset-day` was removed; pinned so it cannot return.
    expect(find.byKey(const ValueKey('settings-reset-day')), findsNothing);
    expect(find.text('Tagesdaten zurücksetzen'), findsNothing);
    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
  });
}
