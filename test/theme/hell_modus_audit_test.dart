import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/theme/meal_slot_style.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import '../support/harness.dart';

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
//   3. USAGE — the macro tones are toned for GRAPHICS (3:1, WCAG 1.4.11) and
//      may not be painted into text. Level 2 alone missed that: it measures
//      colour pairs, not which widget picks which pair.
//   4. GEBOXTE NOTIZ — the signal-banner pattern read back OUT of the tree,
//      and against `bg` as well as `surf`. Same blind spot as 3, other
//      widget: level 2 measured the card only, the boxes sit on the page.
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

// --- 3. USAGE: helpers ------------------------------------------------------

/// The four graphical tones by TOKEN name — the same four [MealSlot] reaches
/// through `accentOn`. `accent` is NOT among them: it carries text at 13.6:1
/// (hell) / 14.0:1 (dunkel).
Map<Color, String> _makroToene(AppTokens t) => <Color, String>{
      t.protein: 'protein',
      t.carbs: 'carbs',
      t.fat: 'fat',
      t.snack: 'snack',
    };

/// Fails when any [Text] in the current tree is PAINTED in a macro tone.
///
/// Deliberately widget-level: the tones themselves are correct (3:1 for
/// graphics), only their use as text is wrong, and no colour-pair check can
/// see that.
void _erwarteKeineMakroTexte(WidgetTester tester, AppTokens t) {
  final toene = _makroToene(t);
  final treffer = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final farbe = widget.style?.color;
    if (farbe == null) continue;
    final name = toene[farbe];
    if (name == null) continue;
    final inhalt = widget.data ?? widget.textSpan?.toPlainText() ?? '';
    treffer.add('"$inhalt" in $name');
  }
  expect(
    treffer,
    isEmpty,
    reason: 'Makrofarben sind Grafik-Toene (3:1) und tragen keinen Text — '
        'im Hellmodus erreichen carbs 3,39:1 und fat 3,73:1 auf surf, '
        'noetig waeren 4,5:1. Farbiger Punkt + Text in ink:\n'
        '${treffer.join('\n')}',
  );
}

/// Tones a macro MARKER may legitimately carry: the raw tone, which holds the
/// 3:1 for graphical objects on `surf`, and its [AppTokens.readableOnTint]
/// correction, which a darker ground needs — on `surf2` the raw carb tone is
/// only 2.77:1, so the scan result's tiles (P9-01b) lift their dot.
Map<Color, String> _makroPunktToene(AppTokens t) => <Color, String>{
      for (final eintrag in _makroToene(t).entries) ...<Color, String>{
        eintrag.key: eintrag.value,
        t.readableOnTint(eintrag.key): '${eintrag.value} (readableOnTint)',
      },
    };

/// Circular markers painted in a macro tone — what replaces the coloured
/// number. Counts them so a fix that merely drops the colour fails too.
int _makroPunkte(WidgetTester tester, AppTokens t) {
  final toene = _makroPunktToene(t);
  var anzahl = 0;
  for (final element in find.byType(Container).evaluate()) {
    final deko = (element.widget as Container).decoration;
    if (deko is! BoxDecoration || deko.shape != BoxShape.circle) continue;
    final farbe = deko.color;
    if (farbe != null && toene.containsKey(farbe)) anzahl++;
  }
  return anzahl;
}

/// A user recipe with all four nutrition tiles filled.
final FitnessRecipe _rezept = FitnessRecipe(
  slug: FitnessRecipe.userRecipeSlug(),
  title: 'Kontrastteller',
  description: 'Vier Naehrwert-Kacheln',
  portion: '1 Portion',
  ingredients: 'Keine Angabe',
  preparation: 'Keine Zubereitung hinterlegt.',
  professionalHint: 'Selbst angelegt.',
  imageAsset: '',
  caloriesKcal: 520,
  proteinG: 40,
  carbsG: 50,
  fatG: 15,
  estimatedGrams: 300,
  categories: const <String>['Eigene'],
  userCreated: true,
);

/// A scan result with all three macros filled — the only way into
/// [MealResultCard], which is what kept its tiles out of this section.
const MealAnalysisResult _scanErgebnis = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '24 g',
  carbs: '48 g',
  fat: '9 g',
  confidence: 'Hoch',
  portionNotes: 'Ein tiefer Teller.',
  sourceLabel: 'Foto-KI',
);

/// Walks the onboarding to its summary — the only place the macro chips are
/// built. Defaults everywhere except the goal, which has to be a direction so
/// target and pace steps appear.
Future<void> _zurOnboardingZusammenfassung(WidgetTester tester) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    OnboardingScreen(
      firstName: 'Moritz',
      initialProfile: const UserProfile(),
      onComplete: (_) {},
    ),
    brightness: Brightness.light,
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
    settle: true,
  );

  Future<void> weiter() async {
    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pumpAndSettle();
  }

  // intro, sex, age, height, weight, activity
  for (var i = 0; i < 6; i++) {
    await weiter();
  }
  await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
  await tester.pumpAndSettle();
  // goal, target, pace, diet
  for (var i = 0; i < 4; i++) {
    await weiter();
  }
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
      // BOTH grounds, not just `surf`: this test used to measure the card
      // only, and the boxed settings note — which sits on the PAGE, `bg` —
      // slipped past it for that reason (P9-03). `bg` is the darker of the
      // two, so it is the one that decides.
      //
      // Only opacities that actually occur are checked. Guard rail, measured
      // on `bg` in the light palette: text in the signal color itself would
      // be warning 4.20:1 · danger 4.48:1 · ink2 4.48:1 — all under AA, which
      // is why the text goes in `ink` (12.9 - 13.1:1 there).
      for (final p in _paletten.entries) {
        final t = p.value;
        for (final grund in <(String, Color)>[
          ('bg', t.bg),
          ('surf', t.surf),
        ]) {
          for (final fall in <(String, Color, double)>[
            ('ink2', t.ink2, 0.10),
            ('warning', t.warning, 0.10),
            ('warning', t.warning, 0.12),
            ('danger', t.danger, 0.10),
            ('danger', t.danger, 0.16),
          ]) {
            final flaeche =
                _ueber(fall.$2.withValues(alpha: fall.$3), grund.$2);
            expect(_contrast(t.ink, flaeche), greaterThanOrEqualTo(4.5),
                reason: '${p.key}: Text (ink) auf ${fall.$1}@${fall.$3} '
                    'ueber ${grund.$1}');
            // Glyph = graphical object (WCAG 1.4.11): 3:1.
            expect(_contrast(fall.$2, flaeche), greaterThanOrEqualTo(3.0),
                reason: '${p.key}: Icon (${fall.$1}) auf '
                    '${fall.$1}@${fall.$3} ueber ${grund.$1}');
          }
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

    // The two findings that stood here as OPEN are closed; the block is the
    // assertion now, so a regression fails instead of being re-described.
    test('der MealAvatar-Buchstabe erreicht auf seinem eigenen Tint AA', () {
      // MealAvatar (widgets/design/meters.dart) puts the letter on that same
      // slot color at 16 %. In the full color it reached 2.15:1 in light mode;
      // `readableOnTint` blends towards `ink` and now holds 5.95 … 7.75 (hell)
      // and 7.35 … 8.35 (dunkel).
      for (final p in _paletten.entries) {
        final t = p.value;
        for (final slot in MealSlot.values) {
          final farbe = slot.accentOn(t);
          final tint = _ueber(farbe.withValues(alpha: 0.16), t.surf);
          expect(
            _contrast(t.readableOnTint(farbe), tint),
            greaterThanOrEqualTo(4.5),
            reason: '${p.key}: ${slot.name}-Buchstabe auf seinem 16-%-Tint',
          );
        }
      }
      // Counter-check: the raw slot color is what used to stand there, and
      // the carb tone still would not carry the letter (2.86:1).
      const hell = AppTokens.light;
      final tint = _ueber(hell.carbs.withValues(alpha: 0.16), hell.surf);
      expect(_contrast(hell.carbs, tint), lessThan(3.0));
    });

    test('die MacroBar-Fuellung erreicht 3:1 gegen ihre Spur', () {
      // Bar in the macro color on a track of `tile` over `surf` — the fill
      // level is the message, so WCAG 1.4.11 applies. `carbs` was 2.24:1
      // before the tone was darkened; it now holds 3.07:1, the tightest of
      // the three and the reason the tone may not move.
      for (final p in _paletten.entries) {
        final t = p.value;
        final spur = _ueber(t.tile, t.surf);
        for (final farbe in <MapEntry<String, Color>>[
          MapEntry<String, Color>('protein', t.protein),
          MapEntry<String, Color>('carbs', t.carbs),
          MapEntry<String, Color>('fat', t.fat),
        ]) {
          expect(_contrast(farbe.value, spur), greaterThanOrEqualTo(3.0),
              reason: '${p.key}: ${farbe.key}-Balken gegen die Spur');
        }
      }
    });

    test('Makrofarben tragen Grafik, aber keinen Text', () {
      // The pairing this file never measured — and exactly the one three
      // metric tiles got wrong. The tones are toned for graphical objects
      // (3:1): dot, bar, avatar tint. As TEXT on a card they are short in
      // light mode, so tiles carry a colored DOT and put the number in `ink`
      // — the rule `trends_screen` already writes out.
      for (final p in _paletten.entries) {
        final t = p.value;
        for (final slot in MealSlot.values) {
          expect(
            _contrast(slot.accentOn(t), t.surf),
            greaterThanOrEqualTo(3.0),
            reason: '${p.key}: ${slot.name}-Punkt auf der Karte',
          );
        }
        // What the tiles use instead.
        expect(_contrast(t.ink, t.surf), greaterThanOrEqualTo(4.5),
            reason: '${p.key}: Kachelzahl in ink auf der Karte');
      }
      // Counter-check and the whole reason for the rule: in light mode carbs
      // (3.39:1) and fat (3.73:1) miss the 4.5:1 for normal text. 16 px w700
      // is NOT large text — AA-Large starts at 14 pt bold = 14 x 96/72 =
      // 18.67 px.
      const hell = AppTokens.light;
      expect(_contrast(hell.carbs, hell.surf), lessThan(4.5));
      expect(_contrast(hell.fat, hell.surf), lessThan(4.5));
    });
  });

  // =========================================================================
  // 3. USAGE — no macro tone may be painted into a Text
  // =========================================================================
  group('Makrofarben faerben keinen Text', () {
    // The three metric-tile screens the RUNTIME section never reaches: the
    // audit boots into the tab shell, while these sit behind onboarding, a
    // recipe push and the goals route. That gap is why the violation lived
    // here for three releases.

    testWidgets('Naehrwert-Kacheln im Rezept', (tester) async {
      await pumpLocalized(
        tester,
        RecipeDetailScreen(
          recipe: _rezept,
          onAddMeal: (_, __) {},
        ),
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      expect(find.text('520'), findsOneWidget);
      _erwarteKeineMakroTexte(tester, AppTokens.light);
      // kcal, protein, carbs, fat — one marker each.
      expect(_makroPunkte(tester, AppTokens.light), greaterThanOrEqualTo(3));
    });

    testWidgets('Plan-Kacheln in den Zielen', (tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        const GoalsScreen(profile: UserProfile()),
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
      _erwarteKeineMakroTexte(tester, AppTokens.light);
      expect(_makroPunkte(tester, AppTokens.light), greaterThanOrEqualTo(3));
    });

    testWidgets('Makro-Kacheln der Onboarding-Zusammenfassung', (tester) async {
      await _zurOnboardingZusammenfassung(tester);
      expect(
        find.byKey(const ValueKey('onboarding-summary-kcal')),
        findsOneWidget,
      );
      _erwarteKeineMakroTexte(tester, AppTokens.light);
      expect(_makroPunkte(tester, AppTokens.light), greaterThanOrEqualTo(3));
    });

    // The FOURTH tile, and the one this section could not see: it needs a scan
    // RESULT, so neither the runtime walk (which boots into the tab shell) nor
    // the three cases above ever build it. Its ground is `surf2`, half a point
    // darker than the `surf` the others sit on — the reason it was the worst
    // of the four (carbs 2.77:1) while looking like the same code.
    testWidgets('Makro-Kacheln des KI-Scan-Ergebnisses', (tester) async {
      await pumpLocalized(
        tester,
        MealResultCard(
          result: _scanErgebnis,
          addedToDailyTotal: false,
          onAdjustRequested: () {},
          onAddToDailyRequested: () {},
        ),
        brightness: Brightness.light,
        settle: true,
      );
      expect(
        find.byKey(const ValueKey('analyse-result-card')),
        findsOneWidget,
      );
      _erwarteKeineMakroTexte(tester, AppTokens.light);
      expect(_makroPunkte(tester, AppTokens.light), greaterThanOrEqualTo(3));
    });
  });

  // =========================================================================
  // 4. DIE GEBOXTE NOTIZ — am GERENDERTEN Widget gemessen, auf bg UND surf
  //
  // Level 2 measures colour pairs; it never sees which pair the CODE picks.
  // That is the hole P9-03 fell through: [SettingsNote] painted its text in
  // the signal colour, and the banner rule above was held against `surf`
  // only — while every boxed note sits on `bg` (delete sheet, goals screen,
  // plan hero; `app_theme.dart` grounds sheets in `bg` as well), the darker
  // of the two, where the same fill costs another half point.
  // =========================================================================
  group('Die geboxte Notiz haelt den Signalbanner-Kontrakt', () {
    /// Renders one note on [grund] and hands back what it actually painted.
    Future<({Color text, Color glyphe, Color flaeche})> notiz(
      WidgetTester tester, {
      required Brightness brightness,
      required Color grund,
      required Color? ton,
      required bool boxed,
    }) async {
      await pumpLocalized(
        tester,
        ColoredBox(
          color: grund,
          child: SettingsNote(
            'Hinweis',
            tone: ton,
            icon: Icons.error_outline_rounded,
            boxed: boxed,
          ),
        ),
        brightness: brightness,
        scaffold: false,
        safeArea: false,
      );

      // Alpha 0 for the unboxed note: `_ueber` then returns the bare ground.
      var fuellung = const Color(0x00000000);
      if (boxed) {
        final kasten = tester.widget<Container>(
          find.descendant(
            of: find.byType(SettingsNote),
            matching: find.byType(Container),
          ),
        );
        fuellung = (kasten.decoration! as BoxDecoration).color!;
      }
      return (
        text: tester.widget<Text>(find.text('Hinweis')).style!.color!,
        glyphe: tester.widget<Icon>(find.byType(Icon)).color!,
        flaeche: _ueber(fuellung, grund),
      );
    }

    for (final brightness in Brightness.values) {
      final modus = brightness == Brightness.light ? 'HELL' : 'DUNKEL';
      final t =
          brightness == Brightness.light ? AppTokens.light : AppTokens.dark;

      for (final grund in <(String, Color)>[
        ('bg', t.bg),
        ('surf', t.surf),
      ]) {
        for (final ton in <(String, Color?)>[
          ('warning', t.warning),
          ('danger', t.danger),
          ('ohne Ton', null),
        ]) {
          testWidgets('$modus: geboxt, ${ton.$1}, auf ${grund.$1}',
              (tester) async {
            final n = await notiz(
              tester,
              brightness: brightness,
              grund: grund.$2,
              ton: ton.$2,
              boxed: true,
            );

            // The contract itself, not only its numbers.
            expect(n.text, t.ink,
                reason: 'Kontrakt: Glyphe im Signalton, Text in ink — auf '
                    'der eigenen Fuellung faellt der Ton unter AA');
            expect(n.glyphe, ton.$2 ?? t.ink2);

            expect(_contrast(n.text, n.flaeche), greaterThanOrEqualTo(4.5),
                reason: '$modus: 12-px-Text auf ${ton.$1}@10 % ueber '
                    '${grund.$1}');
            // Glyph = graphical object (WCAG 1.4.11): 3:1.
            expect(_contrast(n.glyphe, n.flaeche), greaterThanOrEqualTo(3.0),
                reason: '$modus: Glyphe auf ${ton.$1}@10 % ueber ${grund.$1}');
          });

          testWidgets('$modus: ungeboxt, ${ton.$1}, auf ${grund.$1}',
              (tester) async {
            // Without a fill the tone keeps its headroom (warning 4,76:1 on
            // the light `bg` is the weakest case), so THERE it stays the text
            // colour — otherwise the signal would disappear entirely.
            final n = await notiz(
              tester,
              brightness: brightness,
              grund: grund.$2,
              ton: ton.$2,
              boxed: false,
            );

            expect(n.text, ton.$2 ?? t.ink2);
            expect(n.glyphe, ton.$2 ?? t.ink2);
            expect(_contrast(n.text, n.flaeche), greaterThanOrEqualTo(4.5),
                reason: '$modus: 12-px-Text (${ton.$1}) auf ${grund.$1}');
          });
        }
      }
    }
  });
}
