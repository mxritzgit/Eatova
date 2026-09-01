import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';

import 'support/harness.dart';

// Stress test for the textScaler cap (EatovaApp caps at 2.0, WCAG 1.4.4): the
// core screens must render at 200 % system font without RenderFlex overflows
// AND without a text box that is too SHORT for the text inside it.
//
// The second half is not decoration. A RenderFlex overflow is loud (yellow
// bars, a FlutterError); a fixed height around a Text is silent — the glyphs
// are simply clipped away and every "does it render" assertion stays green.
// That is the regression this suite let through until 2026-09-01: giving the
// macro label a `SizedBox(height: 16)` truncated "Kohlenhydrate" to "K…" at
// 200 % and the whole file still passed.
//
// This suite is parameterised over SCREENS, not over locale/brightness/scale,
// so it stays one test per screen instead of a `renderMatrix`: each case boots
// the whole app and walks its own path. Only the overflow plumbing comes from
// the harness now.

const double _stressScale = 2.0;

/// iPhone 14 viewport (393x852 logical) with SYSTEM font at [_stressScale].
///
/// The scale has to come from the platform dispatcher here, not from a
/// MediaQuery: these cases boot `EatovaApp`, which builds its own MaterialApp,
/// so there is no place above it to inject one.
void _pinViewport(WidgetTester tester) {
  pinPhoneViewport(tester);
  tester.platformDispatcher.textScaleFactorTestValue = _stressScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

// --- silent truncation ------------------------------------------------------

/// The ONE box in the app that is knowingly too tight, kept out of the sweep.
///
/// `_ProfileBadge` (screens/meal_analysis_screen.dart) is a hard 34x34 capsule
/// with the first letter of the name in it; at 200 % the letter needs 38 px and
/// loses ~4 px of ascender and descender. Not fixed here — this suite pins
/// existing behaviour, it does not change layout. The exception cannot go stale:
/// the last case in this file asserts the clip is still there and tells you to
/// delete both halves once it is gone.
const String _bekannteEngeKey = 'topbar-profile';

/// Paragraphs under [_bekannteEngeKey] in the CURRENT tree.
///
/// `skipOffstage: false` throughout: with the settings route pushed the food
/// tab below it is still laid out (and still in `allRenderObjects`), but the
/// default finder no longer sees it — the exception would silently stop
/// applying on exactly that screen.
Finder _engeFinder() => find.descendant(
      of: find.byKey(
        const ValueKey<String>(_bekannteEngeKey),
        skipOffstage: false,
      ),
      matching: find.byType(Text, skipOffstage: false),
      skipOffstage: false,
    );

Set<RenderObject> _ausgenommen() => _engeFinder()
    .evaluate()
    .map((Element e) => e.renderObject)
    .whereType<RenderObject>()
    .toSet();

/// Everything the sweep found while one screen was walked.
final Set<String> _abschnitte = <String>{};

/// Text boxes that are SHORTER than the text they hold.
///
/// `RenderParagraph.size` is `constraints.constrain(textSize)`, so a fixed
/// height simply clamps the box and the surplus lines are clipped at paint
/// time — no exception, no yellow bar, nothing a "renders without overflow"
/// test can see. `getMaxIntrinsicHeight(width)` is what the text needs at the
/// width it actually got; anything under that is cut off.
///
/// Deliberately NOT about ellipsis: `overflow: ellipsis` on a name or an
/// e-mail is a design decision and appears all over these screens. A height
/// clamp never is.
void _sammleAbschnitte(WidgetTester tester, String wo) {
  final ausgenommen = _ausgenommen();
  for (final absatz in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (absatz.debugNeedsLayout || ausgenommen.contains(absatz)) continue;
    final breite = absatz.size.width;
    if (breite <= 0) continue;
    final gebraucht = absatz.getMaxIntrinsicHeight(breite);
    // Half a logical pixel of slack for the rounding in the shaper.
    if (absatz.size.height + 0.5 < gebraucht) {
      final text = absatz.text.toPlainText().replaceAll('\n', ' ');
      _abschnitte.add(
        '$wo: "${text.length > 40 ? '${text.substring(0, 40)}…' : text}" '
        'hat ${absatz.size.height.toStringAsFixed(1)} px, '
        'braucht ${gebraucht.toStringAsFixed(1)} px',
      );
    }
  }
}

/// Collects all overflow errors and every clipped text box during [body] and
/// reports them together.
Future<void> _expectNoOverflow(
  WidgetTester tester,
  String screen,
  Future<void> Function() body,
) async {
  _abschnitte.clear();
  final overflows = await collectOverflows(body);
  // Last state of the walk as well, so a screen without a scroll step is
  // covered too.
  _sammleAbschnitte(tester, screen);
  expect(
    overflows,
    isEmpty,
    reason: '$screen overflowt bei textScale $_stressScale: '
        '${describeOverflows(overflows)}',
  );
  expect(
    _abschnitte,
    isEmpty,
    reason: '$screen schneidet bei textScale $_stressScale Text ab '
        '(feste Hoehe ueber einem Text — lautlos, kein Overflow):\n'
        '${_abschnitte.join('\n')}',
  );
}

DateTime _daysAgo(int n) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - n);
}

/// Boots the app and lands on the "Heute" tab (index 0).
///
/// `EatovaApp` without a locale override does NOT resolve to `de` in
/// `flutter test` (the test PlatformDispatcher defaults to `en`), and the
/// profile assertions below expect German ARB values, so `de` is pinned here.
Future<void> _bootApp(WidgetTester tester) async {
  tester.platformDispatcher.localesTestValue = <Locale>[
    const Locale('de', 'DE'),
  ];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(const EatovaApp());
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
}

/// Switches to a tab of the bottom bar.
Future<void> _goToTab(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(ValueKey<String>('nav-$label')));
  await tester.pumpAndSettle();
}

/// The coach hero spins forever (CoachOrb), so `pumpAndSettle` never settles.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Scrolls a list to the end so the lower cards actually get laid out;
/// otherwise a `ListView` screen only measures its top two cards at 2.0.
Future<void> _scrollDurch(
  WidgetTester tester,
  Finder scrollable, {
  int schritte = 6,
  bool settle = true,
}) async {
  // Before the first drag as well: the top of the page is laid out too and is
  // where the densest headers sit.
  _sammleAbschnitte(tester, 'Scrollstand 0');
  for (var i = 0; i < schritte; i++) {
    await tester.drag(scrollable, const Offset(0, -400));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await _pumpFrames(tester, frames: 6);
    }
    // Cards below the fold only exist between two drags; without a sweep per
    // step the check would only ever see the bottom of the page.
    _sammleAbschnitte(tester, 'Scrollstand ${i + 1}');
  }
}

void main() {
  testWidgets('Auth-Screen rendert bei textScale 2.0 ohne Overflow', (
    tester,
  ) async {
    _pinViewport(tester);
    await _expectNoOverflow(tester, 'Auth-Screen', () async {
      final authRepository = InMemoryAuthRepository();
      addTearDown(authRepository.dispose);
      await tester.pumpWidget(EatovaApp(authRepository: authRepository));
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

      // Also pump the signup variant (extra name field).
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
    // The cold-start landing point: forest hero with three metric tiles side
    // by side, three macro bars (label/bar/value in ONE row) and four slot
    // rows — all classic breaking points at 200 % system font.
    _pinViewport(tester);
    await _expectNoOverflow(tester, 'Heute-Tab', () async {
      await _bootApp(tester);
      expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);

      // An archive day is its own branch: relative date in the pill, a dash
      // instead of a number in the burned tile, a different coach line.
      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-date-selected-label')),
          findsOneWidget);

      // The cards below the fold are only laid out once scrolled to.
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
    await _expectNoOverflow(tester, 'Food-Tab', () async {
      // The app starts on tab 0; the food tab is built lazily on first visit,
      // so `screen-kcal-tracker` does not exist before that.
      await _bootApp(tester);
      await _goToTab(tester, 'Food');
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

      // Switching the date chip renders both chip shapes' selected states.
      await tester.tap(
        find.byKey(const ValueKey('food-date-chip-3')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      // The four slot cards of the history sit below the fold.
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
    await _expectNoOverflow(tester, 'Rezepte-Tab', () async {
      await _bootApp(tester);
      await _goToTab(tester, 'Rezepte');
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);

      // Search with its result line, a separate branch above the list. Done
      // first, while the field is still at the top.
      await tester.enterText(
        find.byKey(const ValueKey('recipes-search-input')),
        'Reis',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipes-search-clear')));
      await tester.pumpAndSettle();

      // Filter chip bar and tile list; the cards put text on semi-transparent
      // overlays above the image.
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
    await _expectNoOverflow(tester, 'Coach-Tab', () async {
      await _bootApp(tester);
      // No pumpAndSettle: the CoachOrb spins forever.
      await tester.tap(find.byKey(const ValueKey('nav-Coach')));
      await _pumpFrames(tester);
      expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);

      // The composer holds four icon buttons plus the field in ONE row.
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
    await _expectNoOverflow(tester, 'Profil', () async {
      await _bootApp(tester);
      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);

      // The densest page: paired metric tiles, plan card with three macro
      // columns, weight sparkline and the health card at the bottom.
      await _scrollDurch(
        tester,
        find.byKey(const ValueKey('screen-profile')),
        schritte: 8,
      );
      // Anchor at the page end; the about row moved to the settings screen
      // (`settings-about`, checked below).
      expect(find.text('Verbindungen'), findsOneWidget);
    });
  });

  testWidgets('Einstellungen (aus der Schale) rendern bei textScale 2.0 '
      'ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow(tester, 'Einstellungen', () async {
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

      // The about sheet is its own route and is not opened here; its 2.0 case
      // lives in `test/settings_screen_render_test.dart`.

      // Settings only carries account, display, data and danger zone; body
      // data and goals (and thus save) live one level deeper, so the stress
      // test walks on to that dense form page.
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
    await _expectNoOverflow(tester, 'Trend-Ansicht', () async {
      await pumpLocalized(
        tester,
        TrendsScreen(
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
        // Not read from the platform dispatcher here: this case mounts the
        // screen directly, so the MediaQuery above it carries the scale.
        textScale: _stressScale,
        // TrendsScreen brings its own Scaffold and SafeArea.
        scaffold: false,
        safeArea: false,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });
  });

  // Everything above renders at EXACTLY 2.0, so the clamp in `EatovaApp` is a
  // no-op there: lowering the cap to 1.3 (or deleting it) left all eight
  // screens green while every user at 200 % silently got 130 %. The cap is a
  // claim of its own and needs its own case.
  group('Der Deckel selbst', () {
    /// Effective scale inside the app for a system scale of [system].
    Future<double> effektiv(WidgetTester tester, double system) async {
      pinPhoneViewport(tester);
      tester.platformDispatcher.textScaleFactorTestValue = system;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _bootApp(tester);
      return MediaQuery.textScalerOf(
        tester.element(find.byKey(const ValueKey('screen-today'))),
      ).scale(10);
    }

    testWidgets('bei 300 % Systemschrift kommen in der App 200 % an',
        (tester) async {
      expect(
        await effektiv(tester, 3.0),
        20.0,
        reason: 'ohne Deckel zerreisst die feste Geometrie (Kalorienring, '
            'Navigationsleiste) — WCAG 1.4.4 verlangt nur 200 %',
      );
    });

    testWidgets('unterhalb des Deckels bleibt die Systemschrift unangetastet',
        (tester) async {
      // Gegenprobe: ein zu NIEDRIGER Deckel faellt sonst nicht auf. Genau so
      // war es bis 2026-09-01 — eine Senkung auf 1.3 liess diese Datei gruen.
      expect(
        await effektiv(tester, 1.5),
        15.0,
        reason: 'der Deckel darf nur kappen, nicht skalieren',
      );
    });
  });

  testWidgets('BEKANNTE LUECKE: die Profil-Initiale im Food-Kopf wird bei 2.0 '
      'beschnitten', (tester) async {
    // The single exception [_bekannteEngeKey] takes out of the sweep, pinned
    // so it cannot go stale. `_ProfileBadge` is a hard 34x34 capsule; at 200 %
    // the letter needs 38 px, so ~2 px of ascender and descender are clipped.
    // Cosmetic, but real — reported 2026-09-01, not fixed here.
    //
    // WHEN THIS TURNS RED the badge grew with the font: delete this case AND
    // the `_bekannteEngeKey` exception above, and the sweep covers the badge
    // like everything else.
    _pinViewport(tester);
    await _bootApp(tester);
    await _goToTab(tester, 'Food');

    final absatz = tester.renderObject<RenderParagraph>(_engeFinder());
    expect(
      absatz.size.height,
      lessThan(absatz.getMaxIntrinsicHeight(absatz.size.width)),
      reason: 'die Initiale passt wieder in ihre Kapsel — Ausnahme entfernen',
    );
  });
}
