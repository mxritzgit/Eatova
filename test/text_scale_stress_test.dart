import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Stress-Test fuer den textScaler-Cap (EatovaApp deckelt bei 2.0, WCAG
// 1.4.4): die Kern-Screens muessen bei Systemschrift 200 % ohne
// RenderFlex-Overflow rendern. Anders als testWidgetsRobust (widget_test.dart)
// werden Overflows hier NICHT geschluckt, sondern gesammelt und als
// Testfehler gemeldet — genau sie sind der Pruefgegenstand.

const double _stressScale = 2.0;

/// iPhone-14-Viewport (393x852 logical) + Systemschrift auf [_stressScale].
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = _stressScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Faengt waehrend [body] alle Overflow-Fehler ab und meldet sie gesammelt.
///
/// WICHTIG: FlutterError.onError wird VOR dem expect() wiederhergestellt —
/// das Test-Binding asserted sonst beim ersten TestFailure, solange der
/// Handler noch ueberschrieben ist. Nicht-Overflow-Fehler laufen unveraendert
/// in den Framework-Handler (normaler Testfehler).
Future<void> _expectNoOverflow(
  String screen,
  Future<void> Function() body,
) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      // Zusammenfassung + Verursacher-Widget fuer eine brauchbare Diagnose.
      final full = details.toString();
      final culprit = RegExp(r'\S+:file:///\S+').firstMatch(full)?.group(0);
      overflows.add(
        '${details.summary} (${culprit ?? 'Verursacher unbekannt'})',
      );
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(
    overflows,
    isEmpty,
    reason:
        '$screen overflowt bei textScale $_stressScale:\n'
        '${overflows.join('\n')}',
  );
}

DateTime _daysAgo(int n) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - n);
}

/// Bootet die App und landet auf „Heute" (Index 0 seit dem Design-Refactor).
///
/// `EatovaApp` ohne Locale-Override loest in `flutter test` NICHT auf `de`
/// auf (Test-PlatformDispatcher-Default ist `en`, s. Paket-2-Bericht) —
/// die Profil-Seite prueft weiter unten den migrierten Text „Verbindungen"
/// (ARB-Wert unter `de`), deshalb hier fest auf `de` gepinnt.
Future<void> _bootApp(WidgetTester tester) async {
  tester.platformDispatcher.localesTestValue = <Locale>[
    const Locale('de', 'DE'),
  ];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(const EatovaApp());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
}

/// Wechselt auf einen Tab der unteren Leiste.
Future<void> _goToTab(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey<String>('nav-$label')));
  await tester.pumpAndSettle();
}

/// Der Coach-Hero dreht endlos (CoachOrb) — `pumpAndSettle` settlet dort nie.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Scrollt eine Liste bis ans Ende, damit auch die unteren Karten wirklich
/// gelayoutet werden. Ohne das misst ein `ListView`-Screen bei 2.0 nur seine
/// obersten zwei Karten — und genau die unteren tragen die dichten Zeilen.
Future<void> _scrollDurch(
  WidgetTester tester,
  Finder scrollable, {
  int schritte = 6,
  bool settle = true,
}) async {
  for (var i = 0; i < schritte; i++) {
    await tester.drag(scrollable, const Offset(0, -400));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await _pumpFrames(tester, frames: 6);
    }
  }
}

void main() {
  testWidgets('Auth-Screen rendert bei textScale 2.0 ohne Overflow', (
    tester,
  ) async {
    _pinViewport(tester);
    await _expectNoOverflow('Auth-Screen', () async {
      final authRepository = InMemoryAuthRepository();
      addTearDown(authRepository.dispose);
      await tester.pumpWidget(EatovaApp(authRepository: authRepository));
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

      // Auch die Registrieren-Variante (zusaetzliches Namensfeld) pumpen.
      await tester.ensureVisible(
        find.byKey(const ValueKey('auth-toggle-register')),
      );
      await tester.tap(
        find.byKey(const ValueKey('auth-toggle-register')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Heute-Tab (Landepunkt) rendert bei textScale 2.0 ohne Overflow',
      (tester) async {
    // Neu seit dem Design-Refactor 2026-08-09 und zugleich der Kaltstart-
    // Landepunkt: Forest-Hero mit drei Kennzahl-Kacheln nebeneinander, drei
    // Makro-Balken (Label/Balken/Wert in EINER Zeile) und vier Slot-Zeilen.
    // Jede dieser Zeilen ist eine klassische Bruchstelle bei 200 %
    // Systemschrift. (Der frueher hier erwaehnte schwebende Knopf ist am
    // 2026-08-10 auf Nutzer-Wunsch entfallen.)
    _pinViewport(tester);
    await _expectNoOverflow('Heute-Tab', () async {
      await _bootApp(tester);
      expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);

      // Der Archivtag ist ein eigener Zweig: „Vor 1 Tag" statt „Heute" in der
      // Pille, „—" statt einer Zahl in VERBRANNT, andere Coach-Zeile.
      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-date-selected-label')),
          findsOneWidget);

      // Die Karten unterhalb des Falzes (Makros, Mahlzeiten, Coach-Banner)
      // werden erst beim Scrollen gelayoutet.
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-today')),
        schritte: 4,
      );
      expect(find.byKey(const ValueKey('today-coach-banner')), findsOneWidget);
    });
  });

  testWidgets('Food-Tab (EatovaHomePage) rendert bei textScale 2.0 '
      'ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Food-Tab', () async {
      // Seit dem Design-Refactor startet die App auf „Heute" (Index 0) —
      // der Food-Tab wird im lazy IndexedStack erst beim ersten Besuch
      // gebaut, `screen-kcal-tracker` existiert vorher gar nicht.
      await _bootApp(tester);
      await _goToTab(tester, 'Food');
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

      // Datums-Chip-Wechsel rendert die Auswahl-Zustaende beider Chip-Formen.
      await tester.tap(
        find.byKey(const ValueKey('food-date-chip-3')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      // Die vier neuen Slot-Karten des Verlaufs liegen unter dem Falz.
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('kcal-page-fill')),
        schritte: 4,
      );
    });
  });

  testWidgets('Rezepte-Tab rendert bei textScale 2.0 ohne Overflow',
      (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Rezepte-Tab', () async {
      await _bootApp(tester);
      await _goToTab(tester, 'Rezepte');
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);

      // Suche mit Treffer-Zeile („N Treffer") — eigener Zweig ueber der Liste.
      // Zuerst, solange das Feld noch oben steht.
      await tester.enterText(
        find.byKey(const ValueKey('recipes-search-input')),
        'Reis',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipes-search-clear')));
      await tester.pumpAndSettle();

      // Die Filter-Chip-Leiste und die Kachel-Liste; die Karten tragen Text
      // auf halbtransparenten Overlays ueber dem Bild.
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-recipes')),
        schritte: 5,
      );
    });
  });

  testWidgets('Coach-Tab rendert bei textScale 2.0 ohne Overflow',
      (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Coach-Tab', () async {
      await _bootApp(tester);
      // Kein pumpAndSettle: der CoachOrb dreht endlos.
      await tester.tap(find.byKey(const ValueKey('nav-Coach')));
      await _pumpFrames(tester);
      expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);

      // Der Composer traegt vier Icon-Knoepfe plus Eingabefeld in EINER Zeile.
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Was soll ich heute Abend essen?',
      );
      await _pumpFrames(tester, frames: 6);
    });
  });

  testWidgets('Profil-Seite rendert bei textScale 2.0 ohne Overflow',
      (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Profil', () async {
      await _bootApp(tester);
      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);

      // Die dichteste Seite: Kennzahl-Kacheln zu zweit, Plan-Karte mit drei
      // Makro-Spalten, Gewichts-Sparkline und die Health-Karte ganz unten.
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-profile')),
        schritte: 8,
      );
      // Anker am Seitenende. Bis 2026-08-10 stand hier
      // `profile-action-about` — die Zeile ist mit dem Block „Daten & Konto"
      // in die Einstellungen gezogen (`settings-about`, unten mitgeprueft).
      expect(find.text('Verbindungen'), findsOneWidget);
    });
  });

  testWidgets('Einstellungen (aus der Schale) rendern bei textScale 2.0 '
      'ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Einstellungen', () async {
      await _bootApp(tester);
      await _goToTab(tester, 'Food');
      await tester.tap(find.byKey(const ValueKey('topbar-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);

      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-settings')),
        schritte: 8,
      );

      // („Über Eatova" ist am 2026-08-10 aus dem Profil hierher gezogen. Sein
      // Sheet ist eine eigene Route und wird von diesem Durchlauf nicht
      // geoeffnet — der 2.0-Fall dafuer steht in
      // `test/settings_screen_render_test.dart`.)

      // Seit der Trennung 2026-08-10 tragen die Einstellungen nur noch Konto,
      // Anzeige, Daten und Gefahrenzone; Koerperdaten und Ziele (und damit
      // „Speichern") leben eine Ebene tiefer. Der Stresstest laeuft deshalb
      // weiter bis dorthin — die dichte Formularseite ist genau der Fall, den
      // er finden soll.
      final zuDenZielen = find.byKey(const ValueKey('settings-open-goals'));
      await tester.ensureVisible(zuDenZielen);
      await tester.pumpAndSettle();
      await tester.tap(zuDenZielen);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-goals')),
        schritte: 8,
      );
      expect(find.byKey(const ValueKey('settings-save')), findsOneWidget);
    });
  });

  testWidgets('Trend-Ansicht rendert bei textScale 2.0 ohne Overflow', (
    tester,
  ) async {
    _pinViewport(tester);
    await _expectNoOverflow('Trend-Ansicht', () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          // TrendsScreen liest seit der i18n-Migration context.l10n.
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: TrendsScreen(
            kcalGoal: 2200,
            loadTotals: () => Future.value([
              for (var i = 0; i < 7; i++)
                TrendDayTotals(
                  day: _daysAgo(i),
                  kcal: 1800 + i * 60,
                  proteinG: 120,
                  carbsG: 200,
                  fatG: 70,
                ),
            ]),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });
  });
}
