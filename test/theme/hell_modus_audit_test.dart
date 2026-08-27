import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// LIGHT MODE AUDIT
//
// app_tokens_test.dart checks the palettes themselves; this checks whether the
// APP actually uses them. Two levels:
//
//   1. RUNTIME — every core screen and the two busiest sheets are pumped in
//      light AND dark. Exceptions and overflows are collected, not swallowed.
//      Each screen also verifies the tokens in the tree are the expected
//      palette, else pumping the same palette twice would pass silently.
//   2. CONTRAST — the pairings that tip over in light mode, including
//      semi-transparent surfaces: composited first, then measured.
//
// The SOURCE level (the three hard rules from DESIGN_REFACTOR §3 scanned over
// `lib/`: no `app_colors.dart`, no `Color(0x…)`, no brightness branch) lives
// in test/repo_rules_test.dart with the other source-text guards — including
// the `_festeFarbenErlaubt` allowlist and its reasons.
// ---------------------------------------------------------------------------

const Size _viewport = Size(393, 852); // iPhone 14

// --- 2. CONTRAST: math helpers ----------------------------------------------

/// WCAG 2.1 contrast ratio of two OPAQUE colors (1.0 … 21.0).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hell = math.max(la, lb);
  final dunkel = math.min(la, lb);
  return (hell + 0.05) / (dunkel + 0.05);
}

/// Composites [vorn] over [hinten] and returns the visible opaque color.
/// `computeLuminance()` ignores alpha, so without this a 12 % white would
/// measure as pure white.
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

// --- 1. RUNTIME: harness ----------------------------------------------------

/// Pins viewport and DEVICE brightness. The app ships on `ThemeMode.system`,
/// so this value decides which palette is built, just like on a device.
void _pin(WidgetTester tester, Brightness brightness) {
  tester.view.physicalSize = _viewport * 3.0;
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

/// Collects exceptions and overflows during [body] and reports them together.
///
/// `FlutterError.onError` is restored BEFORE the `expect()`, otherwise the
/// test binding asserts on the first failure while the handler is overridden.
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

/// Boots the app and lands on the first tab.
Future<void> _boot(WidgetTester tester) async {
  await tester.pumpWidget(const EatovaApp());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey<String>('nav-$label')));
  await tester.pumpAndSettle();
}

/// The CoachOrb spins forever, so `pumpAndSettle` never settles there.
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

/// Reads the tokens actually attached at [schluessel] in the tree. The core of
/// the audit: without it, pumping the dark palette twice would pass green.
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

void main() {
  // =========================================================================
  // 1. RUNTIME
  // =========================================================================
  for (final brightness in Brightness.values) {
    final modus = brightness == Brightness.light ? 'HELL' : 'DUNKEL';

    testWidgets('$modus: Heute-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Heute-Tab', brightness, () async {
        await _boot(tester);
        _erwartePalette(tester, 'screen-today', brightness);
        expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);

        // An archived day is its own color branch.
        await tester.tap(find.byKey(const ValueKey('today-date-prev')));
        await tester.pumpAndSettle();

        // Macro bars, slot rows and the coach banner sit below the fold and
        // are never laid out or colored without scrolling.
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
        // Tiles put text on semi-transparent overlays above the image, where
        // light mode tends to become unreadable.
        await _scroll(tester, find.byKey(const ValueKey('screen-recipes')));
      });
    });

    testWidgets('$modus: Coach-Tab rendert sauber', (tester) async {
      _pin(tester, brightness);
      await _ohneFehler('Coach-Tab', brightness, () async {
        await _boot(tester);
        // No pumpAndSettle: the CoachOrb spins forever.
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
        // Opened from within the app, not pumped in isolation: only then are
        // barrier, sheet and page background in the tree together.
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
    // Counter-check: if both runs were the same palette, the whole audit
    // would be worthless.
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
  // 2. CONTRAST — including the semi-transparent surfaces
  // =========================================================================
  group('Kontrast an den kritischen Flaechen', () {
    test('Text auf forest erreicht AA (4.5:1)', () {
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.onForest, t.forest), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Haupttext auf der Marken-Flaeche');
        // The hero mutes unit and side lines; 0.6 is the weakest opacity in
        // the code.
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
        // Counter-check: `ink` is the wrong token here. In dark mode it is
        // near-white and unreadable on lime (~1.1:1) — hence `onLime`.
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
      // `tile` is semi-transparent in both palettes (light 5 % ink, dark 7 %
      // white). Without compositing one measures the full ink and misses that
      // the tile is nearly invisible in light mode.
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
      // TickGauge: filled ticks in `lime` on a track of onForest@20 % over
      // `forest`. The fill level is the message, so WCAG 1.4.11's 3:1 for
      // graphical objects applies between fill and track.
      for (final p in _paletten.entries) {
        final t = p.value;
        final spur = _ueber(t.onForest.withValues(alpha: 0.20), t.forest);
        expect(_contrast(t.lime, spur), greaterThanOrEqualTo(3.0),
            reason: '${p.key}: gefuellter Strich gegen die Spur');
      }
    });

    test('Signalbanner bleiben lesbar — Fuellung UND Glyphe aus einer Farbe',
        () {
      // Pattern in the code: surface = signal color at 10-16 % opacity, icon
      // in the full signal color, text in `ink`. In light mode the fill turns
      // near-white and both must still carry.
      //
      // Only opacities that actually occur are checked. Guard rail: text in
      // warning color at 0.16 would be 4.34:1, already below AA — text goes
      // in `ink`.
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
          // Glyph = graphical object (WCAG 1.4.11): 3:1.
          expect(_contrast(fall.$2, flaeche), greaterThanOrEqualTo(3.0),
              reason: '${p.key}: Icon (${fall.$1}) auf ${fall.$1}@${fall.$3}');
        }
      }
    });

    test('das Coach-Banner bleibt unter seinem Lime-Kreis lesbar', () {
      // A lime@30 % circle sits on `surf2` with the teaser text above it. In
      // light mode the circle nearly matches surf2 and visually disappears;
      // that is decoration and fine — only the text on it matters.
      for (final p in _paletten.entries) {
        final t = p.value;
        final kreis = _ueber(t.lime.withValues(alpha: 0.30), t.surf2);
        expect(_contrast(t.ink, kreis), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Teaser-Text ueber dem Lime-Kreis');
      }
    });

    test('gefuellte Kapseln nutzen ihren eigenen Auf-Token', () {
      // Nav capsule and primary button fill with `lime` / `forest`. Using
      // `ink` instead of `onLime`/`onForest` gives white on lime in dark mode.
      for (final p in _paletten.entries) {
        final t = p.value;
        expect(_contrast(t.onLime, t.lime), greaterThanOrEqualTo(4.5));
        expect(_contrast(t.onForest, t.forest), greaterThanOrEqualTo(4.5));
        // `accent` is the token for strokes/text ON a card, so it must carry
        // against `surf` (lime in dark mode, forest in light).
        expect(_contrast(t.accent, t.surf), greaterThanOrEqualTo(3.0),
            reason: '${p.key}: accent auf der Karte');
      }
    });

    // OPEN FINDING, deliberately not asserted: it really fails in light mode
    // and the fix is a palette decision.
    //
    //   MealAvatar (widgets/design/meters.dart:198/209) puts the letter in the
    //   full slot color on that same color at 16 % opacity. Over `surf`, light
    //   palette: carbs 2.15:1 · fat 3.10:1 · snack 3.89:1 · protein 4.57:1
    //   (the only one above AA). All four carry in dark mode (4.8 … 6.9:1).
    //
    //   Same for MacroBar: `carbs` against its track (`tile` over `surf`) is
    //   2.24:1 in light mode, below the 3:1 for graphical objects; `protein`
    //   carries at 5.21:1.
  });
}
