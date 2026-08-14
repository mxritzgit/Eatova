import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

// DESIGN_REFACTOR §7.2 / §5: jeder Screen rendert in BEIDEN Helligkeiten und
// bei Systemschrift 200 % ohne RenderFlex-Overflow.
//
// Diese Datei trug bis 2026-08-10 die Render-Faelle von „Profil & Ziele"; die
// sind mit dem Screen nach `goals_screen_render_test.dart` umgezogen. Hier
// steht jetzt der neue Einstellungs-Screen. Seine Bruchstellen sind andere:
// die Drei-Segment-Pille neben der Erscheinungsbild-Zeile, die
// Icon-Kachel-Zeile mit langer Mailadresse und der Loesch-Block mit seinem
// Erklaerkasten.
//
// Anders als in den Verhaltens-Tests werden Overflows hier NICHT geschluckt —
// sie sind der Pruefgegenstand.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> pumpOhneOverflow(
    WidgetTester tester,
    String fall, {
    required Brightness brightness,
    double textScale = 1.0,
    String? email = 'jonas.schmidt.mit.langer.adresse@beispiel-mail.de',
    bool mitScope = true,
    bool mitAuth = true,
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

    final controller = ThemeModeController();
    addTearDown(controller.dispose);

    // Seit dem Sicherheits-Audit 2026-08-14 haengen an der Auth-Schicht drei
    // Zeilen (Passwort, Adresse, Loeschen) — ohne sie ist das hier nicht mehr
    // der dichteste Fall, sondern eine halbe Seite. Die Gegenstelle ist
    // dieselbe wie in den Verhaltens-Tests.
    final repo = mitAuth
        ? InMemoryAuthRepository(
            initialUser: EatovaUser(id: 'u1', email: email),
          )
        : null;
    if (repo != null) addTearDown(repo.dispose);

    // Alle Callbacks gesetzt: das ist der VOLLE Screen, also der dichteste
    // Fall. Die ausgeduennten Varianten koennen konstruktiv nicht mehr
    // ueberlaufen als dieser.
    final app = MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: SettingsScreen(
        email: email,
        authRepository: repo,
        onOpenGoals: () {},
        onSignOut: () async {},
        onDeleteAccount: () async {},
        onExportData: () async => '{}',
      ),
    );

    try {
      await tester.pumpWidget(
        mitScope ? ThemeModeScope(controller: controller, child: app) : app,
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
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

  testWidgets('die Erscheinungsbild-Zeile traegt die Pille auch bei 2.0',
      (tester) async {
    // Die dichteste Zeile der Seite: Titel und Untertitel links,
    // Drei-Segment-Pille rechts. Bei 2.0 muss die Pille in eine zweite Zeile
    // umbrechen statt die Zeile zu sprengen. (Zusicherung uebernommen aus dem
    // frueheren `settings_screen_render_test`, als die Pille noch auf „Profil
    // & Ziele" stand.)
    await pumpOhneOverflow(
      tester,
      'Erscheinungsbild @2.0',
      brightness: Brightness.light,
      textScale: 2.0,
    );

    // Die Zeile liegt seit dem Audit 2026-08-14 unterhalb des Viewports: die
    // KONTO-Gruppe traegt jetzt drei statt einer Zeile (Adresse, Passwort,
    // Adresswechsel). Die Seite ist eine lazy ListView — ohne Scrollen
    // existiert die Pille gar nicht erst im Baum. Der Overflow-Waechter laeuft
    // dabei mit, denn genau beim Bau der Zeile faellt er an.
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
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-theme-mode')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-theme-mode-dark')),
      findsOneWidget,
    );
  });

  testWidgets('die ausgeduennte Seite rendert ebenfalls sauber',
      (tester) async {
    // Ohne Mailadresse, ohne Auth-Schicht und ohne ThemeModeScope faellt die
    // halbe Seite weg — eine leere [SettingsGroup] waere hier die Bruchstelle.
    await pumpOhneOverflow(
      tester,
      'ohne Konto @2.0',
      brightness: Brightness.dark,
      textScale: 2.0,
      email: null,
      mitScope: false,
      mitAuth: false,
    );

    expect(find.text('KONTO'), findsNothing);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsNothing);
  });

  testWidgets('das Loesch-Sheet rendert bei 2.0 ohne Overflow', (tester) async {
    // Eigene Route ueber der Seite — die Faelle oben erreichen sie nicht. Der
    // Titel, drei Zeilen Erklaertext, ein Eingabefeld und ein 52-px-Knopf sind
    // bei doppelter Schrift der engste Platz der App.
    //
    // Seit dem Audit 2026-08-14 hat das Sheet ZWEI Schritte, und der zweite
    // ist der engere: sein Untertitel traegt die volle Mailadresse (hier
    // absichtlich lang), darunter ein beschriftetes Ziffernfeld und der Knopf.
    // Geprueft wird deshalb nicht nur Schritt 1, sondern der ganze Weg — und
    // am Ende, dass der Loesch-Knopf erreichbar bleibt statt unten
    // abgeschnitten zu werden.
    await pumpOhneOverflow(
      tester,
      'Loesch-Sheet Grundzustand',
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
      // Bei doppelter Schrift liegt der Loesch-Block weit unterhalb des
      // Viewports, und die Seite ist eine (lazy) ListView — ohne Scrollen
      // existiert er gar nicht erst im Baum.
      final oeffner = find.byKey(const ValueKey('settings-delete-account'));
      await tester.scrollUntilVisible(
        oeffner,
        400,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(oeffner);
      await tester.pumpAndSettle();

      // Schritt 1: das getippte Wort. Der Loesch-Knopf traegt hier noch nicht
      // seine Beschriftung — er fordert erst den Code an.
      expect(find.text('Code anfordern'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings-delete-confirm-field')),
        'LÖSCHEN',
      );
      await tester.pumpAndSettle();

      // Schritt 2: der Code. Untertitel mit voller Mailadresse, beschriftetes
      // Ziffernfeld, 52-px-Knopf.
      await tester.tap(find.text('Code anfordern'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-delete-code-field')),
        findsOneWidget,
      );
      expect(find.text('Konto endgültig löschen'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings-delete-code-field')),
        '123456',
      );
      await tester.pumpAndSettle();

      // Der Kern der Zusage: der Knopf, der die Loeschung ausloest, ist bei
      // doppelter Schrift noch zu erreichen und liegt vollstaendig im Bild.
      // Ein Overflow-Zaehler allein wuerde das nicht bemerken — ein Sheet, aus
      // dem der Knopf unten herausragt, meldet keinen RenderFlex-Fehler.
      final knopf = find.text('Konto endgültig löschen');
      await tester.ensureVisible(knopf);
      await tester.pumpAndSettle();
      final rect = tester.getRect(knopf);
      final bild = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.left, greaterThanOrEqualTo(0.0), reason: 'links beschnitten');
      expect(rect.right, lessThanOrEqualTo(bild.width),
          reason: 'rechts beschnitten');
      expect(rect.top, greaterThanOrEqualTo(0.0), reason: 'oben beschnitten');
      expect(rect.bottom, lessThanOrEqualTo(bild.height),
          reason: 'unten beschnitten');
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('das „Über Eatova"-Sheet rendert bei 2.0 ohne Overflow',
      (tester) async {
    // Umgezogen am 2026-08-10 aus `test/widgets/profile_screen_design_test`,
    // zusammen mit dem Sheet selbst. Der Fall ist nicht kosmetisch: der Block
    // aus Beschreibung, Version, Build, Quellen und Datenschutz-Zeile war bei
    // doppelter Systemschrift schon einmal 251 px zu hoch — und ganz unten
    // steht die Zeile, die nie abgeschnitten werden darf.
    await pumpOhneOverflow(
      tester,
      'Über-Sheet Grundzustand',
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
      final oeffner = find.byKey(const ValueKey('settings-about'));
      await tester.scrollUntilVisible(
        oeffner,
        400,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(oeffner);
      await tester.pumpAndSettle();

      // Die beiden Pflichtzeilen des Sheets: die ODbL-Namensnennung fuer die
      // OpenFoodFacts-Daten und der Datenschutz-Link nach DSGVO Art. 13.
      expect(find.text('Quellen'), findsOneWidget);
      expect(
        find.textContaining('OpenFoodFacts'),
        findsOneWidget,
        reason: 'die Quellennennung ist lizenzrechtlich vorgeschrieben',
      );
      expect(
        find.byKey(const ValueKey('profile-privacy-link')),
        findsOneWidget,
        reason: 'Key bleibt Key — er ist mit dem Sheet mitgewandert',
      );
    } finally {
      FlutterError.onError = prior;
    }

    expect(overflows, isEmpty, reason: overflows.join('\n'));
  });

  testWidgets('der Seitenfuss steht ohne vorheriges Scrollen im Baum',
      (tester) async {
    // Die Seite ist eine ListView (Lazy). Diese Zusicherung haelt fest, dass
    // die Rechtsseiten und die Gefahrenzone trotzdem gefunden werden, solange
    // der Viewport sie traegt — sonst laufen die Verhaltens-Tests ins Leere,
    // bevor irgendwer scrollt.
    await pumpOhneOverflow(tester, 'Fuss', brightness: Brightness.light);

    expect(find.byKey(const ValueKey('settings-privacy-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-terms-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-imprint-link')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about')), findsOneWidget);

    // `settings-sign-out` stand hier bis 2026-08-10 mit in der Liste. Mit der
    // zugewanderten Zeile „Über Eatova" ist die GEFAHRENZONE eine Zeile
    // tiefer gerutscht und liegt bei voller Verdrahtung knapp unter dem Rand —
    // die Zusicherung wird deshalb zur Erreichbarkeit statt zur Sichtbarkeit.
    // (Die Verhaltens-Tests scrollen ohnehin per `ensureVisible` dorthin.)
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-sign-out')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('screen-settings')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sign-out')), findsOneWidget);
  });
}
