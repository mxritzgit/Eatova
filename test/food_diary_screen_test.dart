// The food tab after the 2026-08 design refactor: four slot cards carry the
// diary. Pins that plus DESIGN_REFACTOR §7.2 (both modes) and §5 (scale 2.0).
//
// The three hand-written brightness loops (plain render / textScale 2.0 /
// EN smoke) are one `renderMatrix` now: de+en x hell+dunkel x 1.0+2.0, so the
// combinations en@2.0 and en@hell@2.0 are covered for the first time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/theme/meal_slot_style.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

import 'support/harness.dart';

const _resultat = MealAnalysisResult(
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

LoggedMeal _mahlzeit({
  required MealSlot slot,
  String id = 'm1',
  DateTime? loggedAt,
  String? localDay,
}) =>
    LoggedMeal(
      id: id,
      result: _resultat,
      loggedAt: loggedAt ?? DateTime.now(),
      forcedSlot: slot,
      localDay: localDay,
    );

/// The shell pads every tab with `EdgeInsets.fromLTRB(20, 12, 20, 12)`.
const EdgeInsets _schalenrand = EdgeInsets.fromLTRB(20, 12, 20, 12);

/// The food tab in the same shell as EatovaHomePage.
Future<void> _pumpFoodTab(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  List<LoggedMeal> meals = const <LoggedMeal>[],
  int dailyConsumedKcal = 0,
  UserProfile profile = const UserProfile(),
  VoidCallback? onSettingsPressed,
  VoidCallback? onProfilePressed,
  Locale locale = const Locale('de'),
}) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: dailyConsumedKcal,
      profile: profile,
      loggedMeals: meals,
      onSettingsPressed: onSettingsPressed,
      onProfilePressed: onProfilePressed,
    ),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    padding: _schalenrand,
    settle: true,
  );
}

/// Same via a [RenderCase], so the matrix combination is applied 1:1.
Future<void> _pumpFall(
  WidgetTester tester,
  RenderCase c, {
  List<LoggedMeal> meals = const <LoggedMeal>[],
  int dailyConsumedKcal = 0,
}) async {
  pinPhoneViewport(tester);
  await c.pump(
    tester,
    MealAnalysisScreen(
      dailyConsumedKcal: dailyConsumedKcal,
      loggedMeals: meals,
    ),
    padding: _schalenrand,
    settle: true,
  );
}

Finder _inSlotkarte(String text) => find.descendant(
      of: find.byType(DiaryMealCard),
      matching: find.text(text),
    );

void main() {
  // One matrix instead of three brightness loops. English strings are longer
  // than German ones and catch overflows a de-only run never shows; the
  // assertions read the ARB, so they hold in every language.
  renderMatrix(
    'Der Food-Tab rendert overflow-frei',
    (tester, c) async {
      await _pumpFall(
        tester,
        c,
        meals: [
          _mahlzeit(slot: MealSlot.breakfast, id: 'a'),
          _mahlzeit(slot: MealSlot.snack, id: 'b'),
        ],
        dailyConsumedKcal: 640,
      );

      expect(tester.takeException(), isNull);
      expect(find.text(c.l10n.foodTitle), findsOneWidget);
      expect(_inSlotkarte(MealSlot.breakfast.label(c.l10n)), findsOneWidget);
      // Lunch and dinner stay empty — their placeholder comes from the ARB.
      expect(find.text(c.l10n.todayMealSlotEmpty), findsNWidgets(2));
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
    textScales: const <double>[1.0, 2.0],
  );

  testWidgets('unter en stehen die englischen Beschriftungen im Baum',
      (tester) async {
    // Counter-check to the matrix above: it reads the same ARB the widget
    // reads, so a regress in app_en.arb would pass unnoticed. One hard anchor
    // per language catches it — the label must really CHANGE with the
    // language, not just resolve to whatever the lookup returns.
    await _pumpFoodTab(tester, locale: const Locale('en'));

    expect(find.text('Nutrition'), findsOneWidget);
    expect(find.text('Ernährung'), findsNothing);
    expect(_inSlotkarte('Breakfast'), findsOneWidget);
    expect(find.text('Nothing logged yet'), findsNWidgets(4));
  });

  testWidgets('Vier Slot-Karten tragen die deutschen Slot-Namen',
      (tester) async {
    await _pumpFoodTab(tester);

    expect(find.byType(DiaryMealCard), findsNWidgets(4));
    for (final label in const [
      'Frühstück',
      'Mittagessen',
      'Abendessen',
      'Snacks',
    ]) {
      expect(_inSlotkarte(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('Ein leerer Tag zeigt vier Add-Slots und „Noch nichts geloggt"',
      (tester) async {
    await _pumpFoodTab(tester);

    expect(find.byType(DottedAddSlot), findsNWidgets(4));
    expect(find.text('Noch nichts geloggt'), findsNWidgets(4));
    expect(
      find.text('Tippe oben auf KI-Scan, Barcode oder Suche.'),
      findsOneWidget,
    );
  });

  testWidgets('Ein gefuellter Slot zeigt Summe und Anzahl statt des Leertexts',
      (tester) async {
    await _pumpFoodTab(
      tester,
      meals: [_mahlzeit(slot: MealSlot.lunch)],
      dailyConsumedKcal: 320,
    );

    expect(find.text('320 kcal · 1 Eintrag'), findsOneWidget);
    expect(find.text('Noch nichts geloggt'), findsNWidgets(3));
    expect(
      find.text('Tippe oben auf KI-Scan, Barcode oder Suche.'),
      findsNothing,
    );
  });

  testWidgets(
      'Der Plus-Knopf einer Slot-Karte oeffnet das Add-Sheet in genau diesem Slot',
      (tester) async {
    await _pumpFoodTab(tester);

    final plus = find.byKey(const ValueKey('food-slot-add-dinner'));
    expect(plus, findsOneWidget);
    await tester.ensureVisible(plus);
    await tester.tap(plus);
    await tester.pumpAndSettle();

    // The dinner slot leads, whatever the time-of-day heuristic says.
    bool gewaehlt(String name) => tester
        .widget<Semantics>(
          find
              .ancestor(
                of: find.byKey(ValueKey('slot-select-$name')),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties
        .selected!;

    expect(gewaehlt('dinner'), isTrue);
    expect(gewaehlt('breakfast'), isFalse);
  });

  testWidgets('Die Kopf-Kachel trennt Zahl und Beschriftung', (tester) async {
    await _pumpFoodTab(tester, dailyConsumedKcal: 1234);

    expect(find.text('1.234'), findsOneWidget);
    expect(find.text('KCAL HEUTE'), findsOneWidget);
    // The tab's ONLY kcal figure keeps number and unit separate; the flow
    // tests rely on that.
    expect(find.text('1.234 kcal'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // The calorie card is gone (user decision 2026-08-10): it duplicated the
  // "Today" tab and pushed the history below the fold on an 852 px screen.
  // -------------------------------------------------------------------------
  group('Ohne Kalorien-Karte', () {
    testWidgets('weder Karte noch ihre Kennzahlen stehen noch im Baum',
        (tester) async {
      await _pumpFoodTab(
        tester,
        dailyConsumedKcal: 1234,
        profile: const UserProfile(dailyKcalGoal: 2200),
      );

      for (final key in const <String>[
        'analyse-daily-kcal-card',
        'analyse-daily-kcal-total',
        'analyse-daily-kcal-goal',
        'analyse-daily-kcal-remaining',
      ]) {
        expect(
          find.byKey(ValueKey<String>(key), skipOffstage: false),
          findsNothing,
          reason: key,
        );
      }
      for (final text in const <String>[
        'TAGESBILANZ',
        'ZIEL',
        'GEGESSEN',
        'VERBRANNT',
        'kcal übrig',
        'kcal drüber',
      ]) {
        expect(find.text(text), findsNothing, reason: text);
      }
    });

    testWidgets('der Verlauf beginnt deutlich oberhalb der Falz',
        (tester) async {
      // With the card the history started at y=655 here, below the fold.
      await _pumpFoodTab(tester, dailyConsumedKcal: 1234);

      final verlauf = find.descendant(
        of: find.byKey(const ValueKey('kcal-meals-today-card')),
        matching: find.text('Verlauf'),
      );
      expect(verlauf, findsOneWidget);
      expect(
        tester.getTopLeft(verlauf).dy,
        lessThan(500),
        reason: 'der Verlauf ist wieder unter die Falz gerutscht',
      );
    });

    // A blur over a flat surface costs every frame while showing nothing.
    renderMatrix(
      'Der Food-Tab rastert nichts Teures',
      (tester, c) async {
        await _pumpFall(
          tester,
          c,
          meals: [_mahlzeit(slot: MealSlot.lunch)],
          dailyConsumedKcal: 320,
        );

        final tab = find.byKey(const ValueKey('screen-kcal-tracker'));
        expect(
          find.descendant(of: tab, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
        expect(
          find.descendant(of: tab, matching: find.byType(ImageFiltered)),
          findsNothing,
        );
      },
    );
  });

  testWidgets('Der Block traegt weiterhin die Ueberschrift „Verlauf"',
      (tester) async {
    await _pumpFoodTab(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kcal-meals-today-card')),
        matching: find.text('Verlauf'),
      ),
      findsOneWidget,
    );
  });

  // DATA-6: the diary's day filter must match the header's —
  // `mealsForFoodDate`, not `isSameDay(loggedAt)`, or a 23:45 meal counts in
  // the tile but vanishes from the diary.
  testWidgets('Eine Mahlzeit mit persistiertem local_day steht im Tagebuch '
      'des Tages, den ihr Schluessel nennt', (tester) async {
    final heute = DateTime.now();
    final gestern = DateTime(heute.year, heute.month, heute.day - 1, 23, 45);

    await _pumpFoodTab(
      tester,
      meals: [
        _mahlzeit(
          slot: MealSlot.dinner,
          loggedAt: gestern,
          localDay: localDayKey(heute),
        ),
      ],
      dailyConsumedKcal: 320,
    );

    expect(find.text('320 kcal · 1 Eintrag'), findsOneWidget);
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(find.text('Noch nichts geloggt'), findsNWidgets(3));
  });

  testWidgets('Die Kopf-Icons bleiben erreichbar', (tester) async {
    await _pumpFoodTab(
      tester,
      onSettingsPressed: () {},
      onProfilePressed: () {},
    );

    expect(find.byKey(const ValueKey('topbar-trends')), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar-profile')), findsOneWidget);
  });

  testWidgets('Ohne Callbacks bleiben Einstellungen und Profil verborgen',
      (tester) async {
    await _pumpFoodTab(tester);

    expect(find.byKey(const ValueKey('topbar-trends')), findsOneWidget);
    expect(find.byKey(const ValueKey('topbar-settings')), findsNothing);
    expect(find.byKey(const ValueKey('topbar-profile')), findsNothing);
  });
}
