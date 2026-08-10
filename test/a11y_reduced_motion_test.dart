// A11y „Bewegung reduzieren" (iOS/Android System-Toggle) AUSSERHALB der
// Design-Bibliothek.
//
// Die Bibliothek (lib/src/widgets/design/**) faehrt ihre Animationen laengst
// ueber `motionDuration(context, ...)`. Die Screens und die kcal-/meal-Widgets
// taten es nicht: dort standen rund zwei Dutzend fest verdrahtete `Duration`s,
// die den Systemschalter schlicht ignorierten. Genau das haelt diese Suite
// fest — und zwar nicht an einzelnen Zeilennummern, sondern als Eigenschaft
// der gerenderten Flaeche: unter `disableAnimations: true` darf unterhalb der
// gepruefte Wurzel KEIN implizit animiertes Widget mehr eine Dauer > 0 tragen.
//
// Warum als Sweep und nicht als Einzel-Assertions: eine neue `AnimatedContainer`
// in einem dieser Screens faellt damit beim naechsten Lauf auf, ohne dass
// jemand diesen Test erweitern muss.
//
// Nicht Gegenstand dieser Suite (bewusst):
//   * Debounces, Snackbar-Standzeiten, HTTP-Timeouts und Retry-Backoffs —
//     das ist Zeitsteuerung, keine Bewegung. Wuerden sie auf 0 kollabieren,
//     waere das ein Verhaltensfehler.
//   * Der 7-Sekunden-Fortschritt der `MealLoadingCard`. Er IST die
//     Rueckmeldung waehrend der Analyse; auf 0 gesetzt saesse der Balken
//     sofort bei 95 % fest. Der letzte Test hier haelt diese Entscheidung
//     als Regressionsschutz fest.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
// Der Sweep
// ---------------------------------------------------------------------------

/// Unsere impliziten Animations-Widgets. Materials eigene Bausteine
/// (`AnimatedPhysicalModel` in `Material`, `AnimatedDefaultTextStyle` in
/// `ListTile`) stehen bewusst NICHT drin: deren Dauern gehoeren dem Framework,
/// wir koennen sie nicht setzen und sie sind kein Befund unserer Screens.
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
  // TweenAnimationBuilder ist generisch -> `TweenAnimationBuilder<double>`.
  return _unsereTypen.contains(name) || name.startsWith('TweenAnimationBuilder');
}

/// Alle implizit animierten Widgets unterhalb von [wurzel], deren Dauer NICHT
/// auf 0 kollabiert ist. Leere Liste = die Flaeche respektiert den Schalter.
///
/// `TextField`/`InputDecorator` werden samt Unterbaum uebersprungen: Materials
/// Eingabe-Deko blendet Hint und Fehlertext mit ihren eigenen, im Framework
/// fest verdrahteten 200 ms ein.
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
// Huelle
// ---------------------------------------------------------------------------

/// Wie die App unter aktiviertem „Bewegung reduzieren" laeuft. Die
/// `MediaQueryData` wird aus der echten View abgeleitet und nur um das Flag
/// ergaenzt — ein blankes `MediaQueryData()` haette Groesse 0 und wuerde jedes
/// Layout kaputtmessen.
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
    // Vier Fundstellen in einer Datei: Karten-Rahmen (AnimatedContainer),
    // Aufklapp-Hoehe (AnimatedSize), Chevron (AnimatedRotation) und die
    // Fokus-Aufhellung des Gramm-Feldes (AnimatedContainer).
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

    // Gegenprobe: ohne den Schalter laeuft die Karte weiter animiert. Sonst
    // koennte der Test auch dann gruen sein, wenn jemand die Animationen
    // ersatzlos entfernt haette.
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
      // Die Chip-Leiste scrollt sich im PostFrame-Callback ins Bild. Unter
      // reduzierter Bewegung MUSS das ein Sprung sein: `animateTo` mit
      // `Duration.zero` bricht in DrivenScrollActivity an
      // `assert(duration > Duration.zero)`.
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
      // Ein Tag weit hinten in der Leiste: der Streifen MUSS scrollen, damit
      // der gewaehlte Chip sichtbar wird. Genau hier lag die Falle — mit
      // `motionDuration` allein waere daraus `animateTo(..., Duration.zero)`
      // geworden, und DrivenScrollActivity haette an
      // `assert(duration > Duration.zero)` geworfen.
      await _pump(
        tester,
        MealAnalysisScreen(
          dailyConsumedKcal: 0,
          selectedDate: DateTime.now().subtract(const Duration(days: 20)),
        ),
      );
      // Der Sprung passiert im PostFrame-Callback des ersten Frames.
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

      // Und sie gleitet nicht nach: eine laufende Scroll-Animation waere im
      // naechsten Frame weitergerueckt.
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
      // EIN Frame ohne Zeitvorschub. Vorher lagen hier 40 ms Versatz je Zeile
      // plus 280 ms Einblendung — die dritte Zeile war erst nach 400 ms da.
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

      // Aufraeumen: der eigene Dismiss-Timer haengt am Snackbar-Inhalt.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('MealLoadingCard — bewusste Ausnahme', () {
    // Diese Karte IST die Rueckmeldung waehrend der Foto-Analyse. Ihr
    // 7-Sekunden-Fortschritt darf NICHT auf 0 kollabieren: der Balken saesse
    // sonst ab der ersten Sekunde bei 95 % und die Stufenanzeige stuende
    // dauerhaft auf „Gleich fertig...", waehrend das Netz noch laeuft.
    // Der Test haelt die Entscheidung fest, damit sie niemand „aufraeumt".
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

      // Die Text-Ueberblendung der Stufen ist dagegen reine Deko und muss weg.
      expect(
        _offeneAnimationen(tester, find.byType(MealLoadingCard)),
        _keineBewegung,
      );
      await tester.pump(const Duration(seconds: 8));
    });
  });
}
