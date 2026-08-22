import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// DESIGN_REFACTOR §7.2 / §5: renders in BOTH brightnesses and at 200 % text
// without RenderFlex overflow. [GoalsScreen] is the densest page in the app,
// so it gets its own pump, and overflows are the subject, not swallowed.
void main() {
  /// Stored goals matching the calculation exactly -> live mode.
  UserProfile autoProfil() {
    const basis = UserProfile();
    final t = const KcalCalculator().calculate(basis);
    return basis.copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
    );
  }

  /// Pumps the page and reports every overflow collectively.
  /// FlutterError.onError is restored BEFORE the expect(), or the binding
  /// asserts on the first TestFailure.
  Future<void> pumpOhneOverflow(
    WidgetTester tester,
    String fall, {
    required Brightness brightness,
    double textScale = 1.0,
    UserProfile profile = const UserProfile(),
    ReminderState reminderState = ReminderState.off,
    VoidCallback? onOpenSystemSettings,
    ThemeModeController? themeController,
    Locale locale = const Locale('de'),
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    final app = MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: GoalsScreen(
        profile: profile,
        reminderState: reminderState,
        onOpenSystemSettings: onOpenSystemSettings,
      ),
    );

    try {
      await tester.pumpWidget(
        themeController == null
            ? app
            : ThemeModeScope(controller: themeController, child: app),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      overflows,
      isEmpty,
      reason: '$fall overflowt:\n${overflows.join('\n')}',
    );
  }

  testWidgets('rendert im Hellmodus', (tester) async {
    await pumpOhneOverflow(tester, 'hell', brightness: Brightness.light);
  });

  testWidgets('rendert im Dunkelmodus', (tester) async {
    await pumpOhneOverflow(tester, 'dunkel', brightness: Brightness.dark);
  });

  testWidgets(
      'rendert unter EN mit englischem Tempo-Label statt deutschem Leck '
      '(i18n-Paket-7-Regression)', (tester) async {
    // The pace labels used to stay hardcoded German; this pins that shut.
    await pumpOhneOverflow(
      tester,
      'en',
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
    await pumpOhneOverflow(
      tester,
      'en Dezimalrate',
      brightness: Brightness.light,
      locale: const Locale('en'),
      profile: const UserProfile(weightGoal: WeightGoal.lose05kg),
    );

    expect(find.text('−0.5 kg/week'), findsOneWidget);
    expect(find.text('−0,5 kg/Woche'), findsNothing);
  });

  testWidgets('rendert bei textScale 2.0 (hell)', (tester) async {
    await pumpOhneOverflow(
      tester,
      'hell @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );
  });

  testWidgets('rendert bei textScale 2.0 (dunkel)', (tester) async {
    await pumpOhneOverflow(
      tester,
      'dunkel @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
    );
  });

  testWidgets('Live-Modus blendet die Energie-Felder aus und bleibt heil',
      (tester) async {
    await pumpOhneOverflow(
      tester,
      'Live-Modus @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
      profile: autoProfil(),
    );
    expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
  });

  testWidgets('blockierte Erinnerungen blenden eine Extra-Zeile ein',
      (tester) async {
    await pumpOhneOverflow(
      tester,
      'blockiert @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
      reminderState: ReminderState.blocked,
      onOpenSystemSettings: () {},
    );
    expect(
      find.byKey(const ValueKey('settings-open-system-settings')),
      findsOneWidget,
    );
  });

  testWidgets('die Fehler-Sammelmeldung sprengt die Seite nicht',
      (tester) async {
    await pumpOhneOverflow(
      tester,
      'Fehlerfall @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
      profile: const UserProfile(weightKg: 30, heightCm: 100),
    );

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };
    try {
      await tester.enterText(
        find.byKey(const ValueKey('settings-weight')),
        '755',
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(
      find.byKey(const ValueKey('settings-validation-note')),
      findsOneWidget,
    );
    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('der Anzeige-Modus steht NICHT mehr auf dieser Seite',
      (tester) async {
    // Counter-check that the pill does not live in TWO places.
    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    await pumpOhneOverflow(
      tester,
      'ohne ANZEIGE @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
      themeController: controller,
    );

    expect(find.text('ANZEIGE'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('die drei Auswahl-Sheets rendern im Dunkelmodus bei 2.0',
      (tester) async {
    // The pickers sit on their own route, and their title + subtitle rows
    // are what breaks at 2.0.
    await pumpOhneOverflow(
      tester,
      'Picker-Grundzustand',
      brightness: Brightness.dark,
      textScale: 2.0,
    );

    final overflows = <String>[];
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) {
        overflows.add(details.summary.toString());
        return;
      }
      prior?.call(details);
    };

    try {
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
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  // --- A11y: the cost of custom surfaces over Material widgets --------------
  //
  // Rows and InkWells must set name and enabled state explicitly, and both
  // drop silently in a refactor.

  testWidgets('jedes Zahlenfeld traegt seine Beschriftung als Semantik-Name',
      (tester) async {
    await pumpOhneOverflow(tester, 'a11y-Felder', brightness: Brightness.light);

    const felder = <String, String>{
      'settings-weight': 'Gewicht',
      'settings-height': 'Größe',
      'settings-age': 'Alter',
      'settings-target-weight': 'Wunschgewicht',
      'settings-steps-goal': 'Schritte',
      'settings-water': 'Wasser',
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
    await pumpOhneOverflow(tester, 'a11y-Knoepfe', brightness: Brightness.light);

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

  testWidgets('der Seitenfuss steht ohne vorheriges Scrollen im Baum',
      (tester) async {
    // Guards against ListView: a lazy list never builds the save button or
    // legal links, which several tests read unscrolled.
    await pumpOhneOverflow(tester, 'Fuss', brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-save')), findsOneWidget);
    // `settings-reset-day` was removed; pinned so it cannot return.
    expect(find.byKey(const ValueKey('settings-reset-day')), findsNothing);
    expect(find.text('Tagesdaten zurücksetzen'), findsNothing);
    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
  });
}
