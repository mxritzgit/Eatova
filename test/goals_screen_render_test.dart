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

// DESIGN_REFACTOR §7.2 / §5: jeder Screen rendert in BEIDEN Helligkeiten und
// bei Systemschrift 200 % ohne RenderFlex-Overflow.
//
// „Profil & Ziele" ist die dichteste Seite der App: jede Zeile traegt
// Beschriftung links und Zahlenfeld plus Einheit rechts, der Plan-Hero drei
// Makro-Kacheln nebeneinander. Feste Breiten sind hier die wahrscheinlichste
// Bruchstelle, deshalb wird sie eigens gepumpt statt nur im Sammel-Stresstest.
//
// Diese Datei hiess bis 2026-08-10 `settings_screen_render_test.dart`. Sie
// pruefte immer schon DIESEN Screen; erst seit der Trennung von Zielen und
// Einstellungen heisst er [GoalsScreen] und traegt `screen-goals`. Der Name
// wanderte mit, die Zusicherungen sind unveraendert (Ausnahme: der
// Anzeige-Modus, siehe unten).
//
// Anders als in den Verhaltens-Tests werden Overflows hier NICHT geschluckt —
// sie sind der Pruefgegenstand.
void main() {
  /// Profil, dessen gespeicherte Energie-Ziele exakt der Rechnung entsprechen
  /// → Live-Modus, die vier Energie-Felder sind ausgeblendet.
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

  /// Pumpt die Seite und meldet gesammelt jeden Overflow.
  ///
  /// FlutterError.onError wird VOR dem expect() wiederhergestellt — das
  /// Test-Binding asserted sonst beim ersten TestFailure, solange der Handler
  /// noch ueberschrieben ist.
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
    // Paket-6-Review-Fund: `WeightGoal.paceLabel`/`KcalTargets.effectivePaceLabel`
    // blieben hartkodiertes Deutsch, obwohl der Rest der Seite laengst
    // uebersetzt war — unter EN stand „Gewicht stabil" mitten im englischen
    // Screen. Paket 7 schliesst genau diese Luecke; diese Zusicherung haelt
    // sie zu, damit ein kuenftiger Rueckfall wieder auffaellt.
    await pumpOhneOverflow(
      tester,
      'en',
      brightness: Brightness.light,
      locale: const Locale('en'),
    );

    // Default-Profil hat WeightGoal.maintain — die Gewichtsziel-Zeile zeigt
    // dessen Tempo-Label als eigenstaendigen Text (goals_screen.dart:
    // `value: _goal.paceLabel(l10n)`).
    expect(find.text('Weight stable'), findsOneWidget);
    expect(find.text('Gewicht stabil'), findsNothing);
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
    // Eigener Zweig: statt der vier Zahlenzeilen steht hier die Notiz.
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
    // Zweiter eigener Zweig: Hinweis in Warnfarbe plus Knopf in die
    // Systemeinstellungen.
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
    // Ungueltige Werte blenden zehn Fehlerzeilen UND die Sammelmeldung ein.
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
    // Umgeschrieben statt geloescht (Nutzer-Entscheid 2026-08-10): die
    // Drei-Segment-Pille ist in die Einstellungen umgezogen. Ihr
    // Overflow-Verhalten bei textScale 2.0 prueft jetzt
    // `settings_screen_render_test.dart`; hier bleibt die Gegenprobe, dass
    // dieselbe Einstellung nicht an ZWEI Orten steht.
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
    // Die Picker sind neuer Code (settings_pickers.dart) und liegen als
    // eigene Route ueber der Seite — die Render-Faelle oben erreichen sie
    // nicht. Ihre Zeilen tragen Titel UND Untertitel („Ergibt 1200 kcal/Tag ·
    // −0,72 kg/Woche"), also genau die Sorte langer Text, die bei 2.0 bricht.
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

        // Die Options-Schluessel sind seit dem Sheet unveraendert.
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

  // --- A11y: was der Umbau von Material-Widgets auf eigene Flaechen kostet ---
  //
  // Das alte Sheet baute auf `TextField(decoration: labelText:)`,
  // `OutlinedButton.icon` und `FilledButton.icon`. Die trugen ihren Namen und
  // ihren Enabled-Zustand von selbst im Semantik-Baum. Die neuen Flaechen sind
  // Rows und InkWells — beides muss ausdruecklich gesetzt werden, und beides
  // faellt bei einem Umbau lautlos weg, weil kein Pixel sich aendert. Deshalb
  // stehen die drei Zusicherungen hier fest.

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
    // Der Fall lief bis 2026-08-10 ueber ZWEI Knoepfe: „Speichern" und
    // „Tagesdaten zurücksetzen" (`settings-reset-day`). Der zweite ist auf
    // Nutzer-Entscheid ersatzlos entfallen — die Aussage selbst (gesperrt wird
    // als gesperrt ANGESAGT, nicht als wirkungsloser Knopf) gilt unveraendert
    // fuer den verbliebenen und bleibt deshalb stehen.
    await pumpOhneOverflow(tester, 'a11y-Knoepfe', brightness: Brightness.light);

    expect(
      tester.getSemantics(find.byKey(const ValueKey('settings-save'))),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
    );

    // 755 kg — dieselbe Eingabe wie in settings_validation_test.
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
    // Zusicherung gegen ein spaeteres Zurueckrutschen auf ListView: eine
    // Lazy-Liste baut „Speichern" und die Rechts-Links gar nicht erst, und
    // mehrere Tests lesen sie, bevor irgendwer scrollt.
    await pumpOhneOverflow(tester, 'Fuss', brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-save')), findsOneWidget);
    // Der Knopf `settings-reset-day` stand bis 2026-08-10 direkt darueber und
    // ist ersatzlos entfallen (Nutzer-Entscheid) — hier bleibt er als
    // Negativ-Zusicherung stehen, damit er nicht unbemerkt zurueckkehrt.
    expect(find.byKey(const ValueKey('settings-reset-day')), findsNothing);
    expect(find.text('Tagesdaten zurücksetzen'), findsNothing);
    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
  });
}
