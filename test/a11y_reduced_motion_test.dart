// A11y "reduce motion" OUTSIDE the design library. A sweep, not per-widget
// assertions: under `disableAnimations: true` no implicitly animated widget
// below the checked root may carry a duration > 0. Out of scope: debounces,
// dwell times, timeouts and backoffs (timing, not motion), and
// `MealLoadingCard`'s progress (see the last test).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_suggestion_item.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

// ---------------------------------------------------------------------------
// The sweep
// ---------------------------------------------------------------------------

/// Our implicit animation widgets. Material's own building blocks are
/// deliberately absent: their durations belong to the framework and are no
/// finding about our screens.
const Set<String> _unsereTypen = <String>{
  'AnimatedContainer',
  'AnimatedOpacity',
  'AnimatedAlign',
  'AnimatedScale',
  'AnimatedRotation',
  'AnimatedSlide',
  'AnimatedPadding',
  'AnimatedPositioned',
  'AnimatedSize',
  'AnimatedSwitcher',
};

Duration? _dauerVon(Widget widget) {
  if (widget is ImplicitlyAnimatedWidget) return widget.duration;
  if (widget is AnimatedSize) return widget.duration;
  if (widget is AnimatedSwitcher) return widget.duration;
  return null;
}

bool _gehoertUns(Widget widget) {
  final name = widget.runtimeType.toString();
  // TweenAnimationBuilder is generic -> `TweenAnimationBuilder<double>`.
  return _unsereTypen.contains(name) || name.startsWith('TweenAnimationBuilder');
}

/// All implicitly animated widgets below [wurzel] whose duration did not
/// collapse to 0; an empty list means the surface respects the toggle.
///
/// `TextField`/`InputDecorator` subtrees are skipped: Material's input
/// decoration fades hint and error text with its own hardcoded 200 ms.
List<String> _offeneAnimationen(WidgetTester tester, Finder wurzel) {
  final funde = <String>[];
  void lauf(Element element) {
    element.visitChildren((Element kind) {
      final widget = kind.widget;
      if (widget is TextField || widget is InputDecorator) return;
      final dauer = _dauerVon(widget);
      if (dauer != null && _gehoertUns(widget) && dauer != Duration.zero) {
        funde.add('${widget.runtimeType} · $dauer');
      }
      lauf(kind);
    });
  }

  lauf(tester.element(wurzel.first));
  return funde;
}

Matcher get _keineBewegung => isEmpty;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Runs the app with "reduce motion" on. The `MediaQueryData` is derived from
/// the real view and only gets the flag added — a bare `MediaQueryData()`
/// would have size 0 and break every layout measurement.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reduceMotion = true,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // Several of the pumped screens read context.l10n.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const MealAnalysisResult _haferbrei = MealAnalysisResult(
  mealName: 'Haferbrei',
  caloriesKcal: 320,
  estimatedGrams: 250,
  kcalPer100G: 128,
  protein: '12 g',
  carbs: '48 g',
  fat: '6 g',
  confidence: 'Hoch',
  portionNotes: 'Standardportion.',
  sourceLabel: 'Foto-KI',
);

LoggedMeal _mahlzeit(String id, MealSlot slot) => LoggedMeal(
      id: id,
      result: _haferbrei,
      loggedAt: DateTime.now(),
      forcedSlot: slot,
    );

void main() {
  group('MealSuggestionItem', () {
    // Four sites in one file: card border, expand height, chevron and the
    // focus highlight of the gram field.
    testWidgets('aufgeklappt steht sofort im Endzustand', (tester) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: MealSuggestionItem(
            result: _haferbrei,
            expanded: true,
            onTap: () {},
            onAdd: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(MealSuggestionItem)),
        _keineBewegung,
      );
    });

    testWidgets('zugeklappt ebenso', (tester) async {
      await _pump(
        tester,
        MealSuggestionItem(
          result: _haferbrei,
          expanded: false,
          onTap: () {},
          onAdd: (_) {},
        ),
      );
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(MealSuggestionItem)),
        _keineBewegung,
      );
    });

    // Counter-check: without the toggle the card still animates. Otherwise the
    // test would stay green if someone deleted the animations outright.
    testWidgets('ohne den Schalter bleiben die Animationen erhalten',
        (tester) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: MealSuggestionItem(
            result: _haferbrei,
            expanded: true,
            onTap: () {},
            onAdd: (_) {},
          ),
        ),
        reduceMotion: false,
      );
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(MealSuggestionItem)),
        isNotEmpty,
      );
    });
  });

  group('MealAnalysisScreen (Food-Tab)', () {
    testWidgets('Datums-Chips und Tagebuch stehen sofort im Endzustand',
        (tester) async {
      await _pump(
        tester,
        MealAnalysisScreen(
          dailyConsumedKcal: 320,
          loggedMeals: <LoggedMeal>[
            _mahlzeit('m1', MealSlot.breakfast),
            _mahlzeit('m2', MealSlot.lunch),
          ],
        ),
      );
      // The chip strip scrolls into view in the post-frame callback. Under
      // reduced motion that must be a jump: `animateTo` with `Duration.zero`
      // trips `assert(duration > Duration.zero)` in DrivenScrollActivity.
      await tester.pump();
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(MealAnalysisScreen)),
        _keineBewegung,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('die Chip-Leiste SPRINGT zur Auswahl statt zu gleiten',
        (tester) async {
      // A day far back in the strip, so it must scroll for the chosen chip to
      // become visible — the trap: `motionDuration` alone would have made this
      // `animateTo(..., Duration.zero)` and thrown.
      await _pump(
        tester,
        MealAnalysisScreen(
          dailyConsumedKcal: 0,
          selectedDate: DateTime.now().subtract(const Duration(days: 20)),
        ),
      );
      // The jump happens in the first frame's post-frame callback.
      await tester.pump();
      expect(tester.takeException(), isNull);

      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('food-date-strip')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final sofort = position.pixels;
      expect(
        sofort,
        greaterThan(0),
        reason: 'ohne Zeitvorschub muss die Leiste bereits am Ziel stehen',
      );

      // And it does not glide on: a running scroll animation would have moved
      // further in the next frame.
      await tester.pump(const Duration(milliseconds: 130));
      expect(position.pixels, sofort);
    });
  });

  group('OnboardingScreen', () {
    testWidgets('Schrittwechsel und Auswahlkarten ohne Bewegung',
        (tester) async {
      await _pump(
        tester,
        OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: const UserProfile(weightGoal: WeightGoal.lose1kg),
          onComplete: (_) {},
        ),
      );
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(OnboardingScreen)),
        _keineBewegung,
      );
    });
  });

  group('DiaryMealCard', () {
    testWidgets('der Stagger-Auftritt entfaellt — die Zeile ist sofort da',
        (tester) async {
      await _pump(
        tester,
        DiaryMealCard(
          slot: MealSlot.breakfast,
          entries: <DiaryEntry>[
            DiaryEntry(_mahlzeit('m1', MealSlot.breakfast), 0),
            DiaryEntry(_mahlzeit('m2', MealSlot.breakfast), 1),
            DiaryEntry(_mahlzeit('m3', MealSlot.breakfast), 2),
          ],
        ),
      );
      // ONE frame without advancing time. There used to be a 40 ms stagger per
      // row plus a 280 ms fade, so row three appeared only after 400 ms.
      await tester.pump();

      final fades = tester
          .widgetList<FadeTransition>(
            find.descendant(
              of: find.byType(DiaryMealCard),
              matching: find.byType(FadeTransition),
            ),
          )
          .toList(growable: false);
      expect(fades, isNotEmpty, reason: 'Auftritts-Fade der Zeilen erwartet');
      expect(
        fades.map((f) => f.opacity.value).toSet(),
        <double>{1.0},
        reason: 'jede Zeile muss sofort voll sichtbar sein',
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('EditMealSheet — Tages-Picker', () {
    testWidgets('die 35 Tages-Chips faerben sich ohne Uebergang',
        (tester) async {
      await _pump(
        tester,
        EditMealSheet(
          meal: _mahlzeit('m1', MealSlot.breakfast),
          onUpdateMeal: (String id, {result, slot, day}) => null,
        ),
      );
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(EditMealSheet)),
        _keineBewegung,
      );
    });
  });

  group('showAppSnack', () {
    testWidgets('das Icon poppt nicht mehr auf', (tester) async {
      late BuildContext ctx;
      await _pump(
        tester,
        Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        }),
      );
      showAppSnack(ctx, 'Gespeichert', icon: Icons.check_rounded);
      await tester.pump();

      expect(
        _offeneAnimationen(tester, find.byType(SnackBar)),
        _keineBewegung,
      );

      // Cleanup: the custom dismiss timer hangs off the snackbar content.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('MealLoadingCard — bewusste Ausnahme', () {
    // This card IS the feedback during photo analysis, so its 7-second
    // progress must NOT collapse to 0 — the bar would sit at 95 % from the
    // first second while the request is still running. Pinned so nobody
    // "cleans it up".
    testWidgets('der Fortschritt laeuft auch unter reduzierter Bewegung',
        (tester) async {
      await _pump(tester, const MealLoadingCard());
      await tester.pump();

      double wert() => tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value!;

      final start = wert();
      await tester.pump(const Duration(seconds: 2));
      expect(
        wert(),
        greaterThan(start),
        reason: 'ohne laufenden Balken haette der Nutzer keine Rueckmeldung',
      );

      // The stage text cross-fade is pure decoration and has to go.
      expect(
        _offeneAnimationen(tester, find.byType(MealLoadingCard)),
        _keineBewegung,
      );
      await tester.pump(const Duration(seconds: 8));
    });
  });
}
