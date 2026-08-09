import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// HELL-MODUS-AUDIT (Verifikations-Welle 2026-08-09)
//
// Der Hell-Modus ist der Grund fuer den ganzen Umbau. app_tokens_test.dart
// prueft die Paletten fuer sich; dieser Test prueft, ob die APP sie wirklich
// benutzt. Drei Ebenen:
//
//   1. LAUFZEIT — jeder Kern-Screen und die beiden meistgenutzten Sheets
//      werden unter Geraete-Helligkeit HELL *und* DUNKEL gepumpt. Exceptions
//      und RenderFlex-Overflows sind Testfehler (sie werden gesammelt, nicht
//      geschluckt). Zusaetzlich wird an jedem Screen nachgemessen, dass die
//      Tokens im Baum wirklich die erwartete Palette sind — sonst wuerde ein
//      Test, der zweimal dieselbe Palette pumpt, folgenlos gruen bleiben.
//   2. QUELLTEXT — die drei harten Regeln aus DESIGN_REFACTOR §3 als Scan
//      ueber `lib/`: kein `app_colors.dart`, kein `Color(0x…)`, kein
//      Brightness-Abzweig fuer Farben.
//   3. KONTRAST — die Paarungen, die im Hell-Modus erfahrungsgemaess kippen,
//      inklusive der HALBTRANSPARENTEN Flaechen. Ein 12-%-Weiss auf hellem
//      Grund ist unsichtbar, deshalb wird hier zuerst komponiert und dann
//      gemessen, statt nur die deckenden Tokens gegeneinander zu halten.
// ---------------------------------------------------------------------------

const Size _viewport = Size(393, 852); // iPhone 14

// --- 3. KONTRAST: Rechenwerkzeug --------------------------------------------

/// WCAG-2.1-Kontrastverhaeltnis zweier DECKENDER Farben (1.0 … 21.0).
/// Gleiche Formel wie in app_tokens_test.dart.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hell = math.max(la, lb);
  final dunkel = math.min(la, lb);
  return (hell + 0.05) / (dunkel + 0.05);
}

/// Legt [vorn] mit seiner eigenen Deckung ueber [hinten] und liefert die
/// tatsaechlich sichtbare, deckende Farbe.
///
/// Ohne diesen Schritt misst man an halbtransparenten Flaechen Unsinn:
/// `computeLuminance()` ignoriert den Alpha-Kanal komplett, ein 12-%-Weiss
/// haette damit die Leuchtkraft von reinem Weiss.
Color _ueber(Color vorn, Color hinten) {
  final a = vorn.a;
  double kanal(double v, double h) => v * a + h * (1 - a);
  return Color.from(
    alpha: 1.0,
    red: kanal(vorn.r, hinten.r),
    green: kanal(vorn.g, hinten.g),
    blue: kanal(vorn.b, hinten.b),
  );
}

Map<String, AppTokens> get _paletten => <String, AppTokens>{
      'hell': AppTokens.light,
      'dunkel': AppTokens.dark,
    };

// --- 1. LAUFZEIT: Huelle ----------------------------------------------------

/// Pinnt Viewport und GERAETE-Helligkeit. Die App laeuft im Auslieferungs-
/// zustand auf `ThemeMode.system`, also entscheidet genau dieser Wert, welche
/// Palette gebaut wird — derselbe Weg wie auf dem Geraet.
void _pin(WidgetTester tester, Brightness brightness) {
  tester.view.physicalSize = _viewport * 3.0;
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

/// Sammelt Exceptions und Overflows waehrend [body] und meldet sie gesammelt.
///
/// WICHTIG: `FlutterError.onError` wird VOR dem `expect()` wiederhergestellt —
/// sonst asserted das Test-Binding beim ersten TestFailure, solange der
/// Handler noch ueberschrieben ist (dieselbe Falle wie in
/// text_scale_stress_test.dart).
Future<void> _ohneFehler(
  String was,
  Brightness brightness,
  Future<void> Function() body,
) async {
  final fehler = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    fehler.add(details.exception.toString());
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(
    fehler,
    isEmpty,
    reason: '$was bricht in $brightness:\n${fehler.join('\n')}',
  );
}

/// Bootet die App und landet auf „Heute" (Index 0 seit dem Design-Refactor).
Future<void> _boot(WidgetTester tester) async {
  await tester.pumpWidget(const EatovaApp());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey<String>('nav-$label')));
  await tester.pumpAndSettle();
}

/// Der CoachOrb dreht endlos — `pumpAndSettle` settlet dort nie.
Future<void> _frames(WidgetTester tester, {int anzahl = 20}) async {
  for (var i = 0; i < anzahl; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _scroll(
  WidgetTester tester,
  Finder flaeche, {
  int schritte = 5,
}) async {
  for (var i = 0; i < schritte; i++) {
    await tester.drag(flaeche, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

/// Liest die Tokens, die an [schluessel] wirklich im Baum haengen.
///
/// Das ist der Kern des Audits: ohne diese Messung wuerde ein Durchlauf, der
/// zweimal dieselbe (dunkle) Palette pumpt, folgenlos gruen bleiben und der
/// Hell-Modus waere ungeprueft.
void _erwartePalette(
  WidgetTester tester,
  String schluessel,
  Brightness brightness,
) {
  final erwartet =
      brightness == Brightness.light ? AppTokens.light : AppTokens.dark;
  final gelesen = AppTokens.of(
    tester.element(find.byKey(ValueKey<String>(schluessel))),
  );
  expect(
    gelesen.bg,
    erwartet.bg,
    reason: '$schluessel haengt in $brightness an der falschen Palette — '
        'der Screen sitzt vermutlich unter einem eigenen Theme',
  );
  expect(gelesen.ink, erwartet.ink);
}

// --- 2. QUELLTEXT: Scanner --------------------------------------------------

/// Die beiden Auth-Screens sind bewusst zurueckgestellt (DESIGN_REFACTOR §3:
/// „die Datei lebt nur noch, bis der letzte Import weg ist"). Sie sind die
/// EINZIGE erlaubte Ausnahme; kommt eine dritte dazu, ist das ein Fund.
const Set<String> _authAusnahmen = <String>{
  'lib/src/screens/auth_screen.dart',
  'lib/src/screens/auth_code_screen.dart',
};

/// Alle Dart-Quellen unter `lib/` als (Pfad mit `/`, Inhalt).
List<MapEntry<String, String>> _libQuellen() {
  final wurzel = Directory('lib');
  if (!wurzel.existsSync()) {
    fail('lib/ fehlt (aufgeloest von ${Directory.current.path})');
  }
  final quellen = <MapEntry<String, String>>[];
  for (final e in wurzel.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    quellen.add(
      MapEntry<String, String>(
        e.path.replaceAll(r'\', '/'),
        e.readAsStringSync(),
      ),
    );
  }
  expect(quellen, isNotEmpty);
  return quellen;
}

/// Quelltext ohne Kommentare — sonst schlaegt ein erklaerender Kommentar
/// („`Color(0x…)` ist hier verboten") die Pruefung los.
String _ohneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

void main() {
  // =========================================================================
  // 1. LAUFZEIT
  // =========================================================================
  for (final brightness in Brightness.values) {
    final modus = brightness == Brightness.light ? 'HELL' : 'DUNKEL';

    testWidgets('$modus: Heute-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Heute-Tab', brightness, () async {
        await _boot(tester);
        _erwartePalette(tester, 'screen-today', brightness);
        expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);

        // Der Archivtag ist ein eigener Farbzweig (andere Kachelwerte,
        // andere Coach-Zeile).
        await tester.tap(find.byKey(const ValueKey('today-date-prev')));
        await tester.pumpAndSettle();

        // Makro-Balken, Slot-Zeilen und Coach-Banner liegen unter dem Falz —
        // ohne Scrollen werden sie nie gelayoutet und nie gefaerbt.
        await _scroll(tester, find.byKey(const ValueKey('screen-today')));
        expect(
          find.byKey(const ValueKey('today-coach-banner')),
          findsOneWidget,
        );
      });
    });

    testWidgets('$modus: Food-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Food-Tab', brightness, () async {
        await _boot(tester);
        await _tab(tester, 'Food');
        _erwartePalette(tester, 'screen-kcal-tracker', brightness);
        await _scroll(
          tester,
          find.byKey(const ValueKey('kcal-page-fill')),
          schritte: 4,
        );
      });
    });

    testWidgets('$modus: Rezepte-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Rezepte-Tab', brightness, () async {
        await _boot(tester);
        await _tab(tester, 'Rezepte');
        _erwartePalette(tester, 'screen-recipes', brightness);
        // Die Kacheln tragen Text auf halbtransparenten Overlays ueber dem
        // Bild — genau die Stelle, an der ein Hell-Modus gern unlesbar wird.
        await _scroll(tester, find.byKey(const ValueKey('screen-recipes')));
      });
    });

    testWidgets('$modus: Coach-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Coach-Tab', brightness, () async {
        await _boot(tester);
        // Kein pumpAndSettle: der CoachOrb dreht endlos.
        await tester.tap(find.byKey(const ValueKey('nav-Coach')));
        await _frames(tester);
        _erwartePalette(tester, 'screen-coach', brightness);
        await tester.enterText(
          find.byKey(const ValueKey('coach-input')),
          'Was soll ich heute Abend essen?',
        );
        await _frames(tester, anzahl: 6);
      });
    });

    testWidgets('$modus: Profil rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Profil', brightness, () async {
        await _boot(tester);
        await tester.tap(find.byKey(const ValueKey('today-profile')));
        await tester.pumpAndSettle();
        _erwartePalette(tester, 'screen-profile', brightness);
        await _scroll(
          tester,
          find.byKey(const ValueKey('screen-profile')),
          schritte: 8,
        );
      });
    });

    testWidgets('$modus: Einstellungen rendern sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Einstellungen', brightness, () async {
        await _boot(tester);
        await _tab(tester, 'Food');
        await tester.tap(find.byKey(const ValueKey('topbar-settings')));
        await tester.pumpAndSettle();
        _erwartePalette(tester, 'screen-settings', brightness);
        await _scroll(
          tester,
          find.byKey(const ValueKey('screen-settings')),
          schritte: 8,
        );
      });
    });

    testWidgets('$modus: das Add-Sheet rendert ueber dem Tagebuch sauber',
        (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Add-Sheet', brightness, () async {
        await _boot(tester);
        await _tab(tester, 'Food');
        // Aus der App heraus geoeffnet, nicht isoliert gepumpt: nur so
        // liegen Barrier, Sheet und Seitengrund gleichzeitig im Baum.
        final knopf = find.byKey(const ValueKey('food-slot-add-breakfast'));
        await tester.ensureVisible(knopf);
        await tester.pumpAndSettle();
        await tester.tap(knopf, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('add-meal-slot-select')),
          findsOneWidget,
        );
        _erwartePalette(tester, 'add-meal-slot-select', brightness);
      });
    });
  }

  testWidgets('der Anzeige-Modus folgt wirklich dem Geraet', (tester) async {
    // Gegenprobe zu allen Tests oben: waeren die beiden Durchlaeufe in
    // Wahrheit dieselbe Palette, waere das komplette Audit wertlos.
    _pin(tester, Brightness.light);
    await _boot(tester);
    final hell = AppTokens.of(
      tester.element(find.byKey(const ValueKey('screen-today'))),
    );

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    final dunkel = AppTokens.of(
      tester.element(find.byKey(const ValueKey('screen-today'))),
    );

    expect(hell.bg, AppTokens.light.bg);
    expect(dunkel.bg, AppTokens.dark.bg);
    expect(hell.bg.computeLuminance(), greaterThan(dunkel.bg.computeLuminance()),
        reason: 'der helle Grund muss heller sein als der dunkle');
  });

  // =========================================================================
  // 2. QUELLTEXT — die drei harten Regeln aus DESIGN_REFACTOR §3
  // =========================================================================
  group('Token-Disziplin in lib/', () {
    test('nur die zurueckgestellten Auth-Screens importieren app_colors.dart',
        () {
      final treffer = <String>[];
      for (final quelle in _libQuellen()) {
        if (quelle.key.endsWith('theme/app_colors.dart')) continue;
        if (_authAusnahmen.contains(quelle.key)) continue;
        if (_ohneKommentare(quelle.value).contains('app_colors.dart')) {
          treffer.add(quelle.key);
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Diese Dateien haengen noch an der festen Dunkel-Palette und '
            'wuerden im Hell-Modus dunkle Flaechen zeichnen:\n'
            '${treffer.join('\n')}',
      );
    });

    test('kein Color(0x…) ausserhalb von lib/src/theme/', () {
      final treffer = <String>[];
      for (final quelle in _libQuellen()) {
        if (quelle.key.startsWith('lib/src/theme/')) continue;
        if (_authAusnahmen.contains(quelle.key)) continue;
        for (final zeile in _ohneKommentare(quelle.value).split('\n')) {
          if (zeile.contains('Color(0x')) {
            treffer.add('${quelle.key}: ${zeile.trim()}');
          }
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Eine Konstante kann nicht hell UND dunkel sein — diese '
            'Farben gehoeren als Token nach app_tokens.dart:\n'
            '${treffer.join('\n')}',
      );
    });

    test('kein Brightness-Abzweig fuer Farben ausserhalb von lib/src/theme/',
        () {
      // Ein `if (isDark)` im Widget-Code baut die Palette ein zweites Mal —
      // genau das, was die ThemeExtension abschaffen soll. Erlaubt bleibt der
      // Abzweig in lib/src/theme/ (dort wird die Palette ja gewaehlt) und die
      // BEWUSSTE feste Palette der Kamera-Overlays, die auf einem immer
      // dunklen Live-Bild liegen — die nennen `AppTokens.dark` direkt und
      // fragen nicht die Geraete-Helligkeit ab.
      final treffer = <String>[];
      for (final quelle in _libQuellen()) {
        if (quelle.key.startsWith('lib/src/theme/')) continue;
        if (_authAusnahmen.contains(quelle.key)) continue;
        for (final zeile in _ohneKommentare(quelle.value).split('\n')) {
          if (zeile.contains('Theme.of(context).brightness') ||
              zeile.contains('platformBrightnessOf') ||
              zeile.contains('MediaQuery.of(context).platformBrightness')) {
            treffer.add('${quelle.key}: ${zeile.trim()}');
          }
        }
      }
      expect(
        treffer,
        isEmpty,
        reason: 'Farbwahl ueber die Helligkeit gehoert als Token nach '
            'AppTokens:\n${treffer.join('\n')}',
      );
    });
  });

  // =========================================================================
  // 3. KONTRAST — inklusive der halbtransparenten Flaechen
  // =========================================================================
  group('Kontrast an den kritischen Flaechen', () {
    test('Text auf forest erreicht AA (4.5:1)', () {
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.onForest, t.forest), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Haupttext auf der Marken-Flaeche');
        // Die grosse Kalorienzahl im Hero setzt Einheit und Nebenzeilen
        // gedaempft ab — 0.6 ist die schwaechste im Code vorkommende Deckung.
        for (final alpha in <double>[0.60, 0.65, 0.70]) {
          expect(
            _contrast(_ueber(t.onForest.withValues(alpha: alpha), t.forest),
                t.forest),
            greaterThanOrEqualTo(4.5),
            reason: '${p.key}: onForest@$alpha auf forest',
          );
        }
      }
    });

    test('Text auf lime erreicht AA (4.5:1)', () {
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.onLime, t.lime), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Text auf dem Marken-Akzent');
        // Gegenprobe: `ink` ist hier NICHT der richtige Token. Im Dunkelmodus
        // ist `ink` fast weiss und auf Lime unlesbar (~1.1:1) — deshalb gibt
        // es `onLime` ueberhaupt.
        if (p.key == 'dunkel') {
          expect(_contrast(t.ink, t.lime), lessThan(3.0));
        }
      }
    });

    test('gedaempfter Text auf surf2 erreicht AA-Large (3:1)', () {
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.ink2, t.surf2), greaterThanOrEqualTo(3.0),
            reason: '${p.key}: ink2 auf der zweiten Flaeche');
        expect(_contrast(t.ink, t.surf2), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Haupttext auf der zweiten Flaeche');
      }
    });

    test('Icons auf tile erreichen AA-Large (3:1) — tile ist TRANSPARENT', () {
      // `tile` ist in beiden Paletten halbtransparent (hell 5 % Tinte, dunkel
      // 7 % Weiss). Ohne Komposition misst man die volle Tinte und uebersieht,
      // dass die Kachel im Hell-Modus fast unsichtbar ist.
      for (final p in _paletten.entries) {
        final t = p.value;
        for (final grund in <MapEntry<String, Color>>[
          MapEntry<String, Color>('surf', t.surf),
          MapEntry<String, Color>('bg', t.bg),
        ]) {
          final kachel = _ueber(t.tile, grund.value);
          expect(_contrast(t.ink2, kachel), greaterThanOrEqualTo(3.0),
              reason: '${p.key}: Icon (ink2) auf tile ueber ${grund.key}');
          expect(_contrast(t.ink, kachel), greaterThanOrEqualTo(4.5),
              reason: '${p.key}: Text (ink) auf tile ueber ${grund.key}');
        }
      }
    });

    test('die Kalorien-Anzeige bleibt in beiden Modi ablesbar', () {
      // TickGauge: gefuellte Striche in `lime` auf einer Spur aus
      // onForest@20 % ueber `forest`. Der Fuellstand ist die Aussage der
      // Anzeige, also gilt hier die 3:1-Grenze fuer grafische Objekte
      // (WCAG 1.4.11) zwischen Fuellung und Spur.
      for (final p in _paletten.entries) {
        final t = p.value;
        final spur = _ueber(t.onForest.withValues(alpha: 0.20), t.forest);
        expect(_contrast(t.lime, spur), greaterThanOrEqualTo(3.0),
            reason: '${p.key}: gefuellter Strich gegen die Spur');
      }
    });

    test('Signalbanner bleiben lesbar — Fuellung UND Glyphe aus einer Farbe',
        () {
      // Das Muster im Code (coach_message_list.dart:235, onboarding_screen
      // .dart:1321, diary_meal_card.dart:296): die Flaeche ist die Signal-
      // farbe mit 10-16 % Deckung, das ICON steht in der vollen Signalfarbe
      // darauf, der TEXT in `ink`. Im Hell-Modus wird die Fuellung fast
      // weiss — beide muessen trotzdem tragen.
      //
      // Geprueft werden nur die Deckungen, die wirklich vorkommen. Als
      // Leitplanke fuer neuen Code: `warning@0.16` waere mit 4.34:1 fuer
      // TEXT in Warnfarbe bereits unter AA — Text gehoert hier in `ink`.
      for (final p in _paletten.entries) {
        final t = p.value;
        for (final fall in <(String, Color, double)>[
          ('warning', t.warning, 0.10),
          ('warning', t.warning, 0.12),
          ('danger', t.danger, 0.16),
        ]) {
          final flaeche = _ueber(fall.$2.withValues(alpha: fall.$3), t.surf);
          expect(_contrast(t.ink, flaeche), greaterThanOrEqualTo(4.5),
              reason: '${p.key}: Text (ink) auf ${fall.$1}@${fall.$3}');
          // Glyphe = grafisches Objekt (WCAG 1.4.11): 3:1.
          expect(_contrast(fall.$2, flaeche), greaterThanOrEqualTo(3.0),
              reason: '${p.key}: Icon (${fall.$1}) auf ${fall.$1}@${fall.$3}');
        }
      }
    });

    test('das Coach-Banner bleibt unter seinem Lime-Kreis lesbar', () {
      // today_sections.dart:170 legt einen Kreis aus lime@30 % auf `surf2`,
      // der Teaser-Text steht darueber. Im Hell-Modus hat der Kreis fast
      // dieselbe Leuchtkraft wie surf2 (er verschwindet dort optisch) — das
      // ist Dekoration und erlaubt; entscheidend ist der Text darauf.
      for (final p in _paletten.entries) {
        final t = p.value;
        final kreis = _ueber(t.lime.withValues(alpha: 0.30), t.surf2);
        expect(_contrast(t.ink, kreis), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Teaser-Text ueber dem Lime-Kreis');
      }
    });

    test('gefuellte Kapseln nutzen ihren eigenen Auf-Token', () {
      // Die Nav-Kapsel (AppNavBar) und der Primaerknopf fuellen sich mit
      // `lime` bzw. `forest`. Wer dort `ink` statt `onLime`/`onForest`
      // einsetzt, bekommt im Dunkelmodus weisse Schrift auf Lime.
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.onLime, t.lime), greaterThanOrEqualTo(4.5));
        expect(_contrast(t.onForest, t.forest), greaterThanOrEqualTo(4.5));
        // `accent` ist der Token fuer Striche/Text AUF einer Karte und muss
        // deshalb gegen `surf` tragen — im Dunkelmodus ist er Lime, im
        // Hell-Modus Forest.
        expect(_contrast(t.accent, t.surf), greaterThanOrEqualTo(3.0),
            reason: '${p.key}: accent auf der Karte');
      }
    });

    // OFFENER FUND, hier bewusst NICHT als Erwartung festgeschrieben, weil er
    // im Hell-Modus real fehlschlaegt und die Korrektur eine Palette-
    // Entscheidung ist (siehe Bericht der Verifikations-Welle):
    //
    //   MealAvatar (widgets/design/meters.dart:198/209) setzt den Buchstaben
    //   in der VOLLEN Slot-Farbe auf dieselbe Farbe mit 16 % Deckung.
    //   Gemessen ueber `surf`, Hell-Palette:
    //     carbs (Fruehstueck) 2.15:1 · fat (Abend) 3.10:1 · snack 3.89:1
    //     protein (Mittag)    4.57:1  — als einziger ueber AA.
    //   Im Dunkelmodus tragen alle vier (4.8 … 6.9:1).
    //
    //   Dasselbe gilt fuer MacroBar: der Balken in `carbs` gegen seine Spur
    //   (`tile` ueber `surf`) misst hell 2.24:1, unter der 3:1-Grenze fuer
    //   grafische Objekte. `protein` traegt mit 5.21:1.
  });
}
