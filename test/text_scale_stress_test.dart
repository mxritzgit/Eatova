import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Stress test for the textScaler cap (EatovaApp caps at 2.0, WCAG 1.4.4): the
// core screens must render at 200 % system font without RenderFlex overflows.
// Unlike testWidgetsRobust, overflows are collected and reported as test
// failures here — they are the subject.

const double _stressScale = 2.0;

/// iPhone 14 viewport (393x852 logical) with system font at [_stressScale].
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = _stressScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Collects all overflow errors during [body] and reports them together.
///
/// FlutterError.onError is restored BEFORE the expect(): the test binding
/// otherwise asserts on the first TestFailure while the handler is still
/// overridden. Non-overflow errors go to the framework handler unchanged.
Future<void> _expectNoOverflow(
  String screen,
  Future<void> Function() body,
) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      // Summary plus offending widget, for a usable diagnosis.
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
    await _expectNoOverflow('Heute-Tab', () async {
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
    await _expectNoOverflow('Food-Tab', () async {
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
    await _expectNoOverflow('Rezepte-Tab', () async {
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
    await _expectNoOverflow('Coach-Tab', () async {
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
    await _expectNoOverflow('Profil', () async {
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
    await _expectNoOverflow('Trend-Ansicht', () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          // TrendsScreen reads context.l10n.
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
