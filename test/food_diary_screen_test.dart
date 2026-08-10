// Der Food-Tab nach dem Design-Refactor 2026-08: statt Glas-Kalorienkarte +
// einer Verlaufsliste tragen vier Slot-Karten (Frühstück/Mittagessen/
// Abendessen/Snacks) das Tagebuch. Dieser Test nagelt die neue Struktur fest —
// inklusive der Pflichten aus DESIGN_REFACTOR §7.2 (beide Anzeige-Modi) und
// §5 (Textskalierung bis 2.0 overflow-frei).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/diary_meal_card.dart';

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

const Size _viewport = Size(393, 852);

/// Der Food-Tab in derselben Huelle wie EatovaHomePage: Scaffold, SafeArea und
/// das feste 20/12-Padding des Tabs.
Future<List<Object>> _pumpFoodTab(
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
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _viewport * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Overflows werden hier NICHT geschluckt, sondern gesammelt: genau das ist
  // die Aussage des Textskalierungs-Falls.
  final fehler = <Object>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    fehler.add(details.exception);
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // MealAnalysisScreen liest seit der i18n-Migration context.l10n.
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(textScale).clamp(maxScaleFactor: 2.0),
          size: _viewport,
        ),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: MealAnalysisScreen(
                dailyConsumedKcal: dailyConsumedKcal,
                profile: profile,
                loggedMeals: meals,
                onSettingsPressed: onSettingsPressed,
                onProfilePressed: onProfilePressed,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fehler;
}

void main() {
  // Pflicht aus DESIGN_REFACTOR §7.2. Bewusst zwei Faelle statt einer
  // Schleife: ein zweites pumpWidget mit anderem Theme im selben Fall laesst
  // pumpAndSettle nicht mehr zur Ruhe kommen (Theme-Lerp ueber laufende
  // Eintritts-Animationen).
  for (final brightness in Brightness.values) {
    testWidgets('Der Food-Tab rendert in $brightness ohne Ausnahme',
        (tester) async {
      final fehler = await _pumpFoodTab(
        tester,
        brightness: brightness,
        meals: [_mahlzeit(slot: MealSlot.lunch)],
        dailyConsumedKcal: 320,
      );
      expect(tester.takeException(), isNull);
      expect(fehler, isEmpty);
    });
  }

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
      expect(
        find.descendant(
          of: find.byType(DiaryMealCard),
          matching: find.text(label),
        ),
        findsOneWidget,
        reason: label,
      );
    }
  });

  testWidgets('Ein leerer Tag zeigt vier Add-Slots und „Noch nichts geloggt"',
      (tester) async {
    await _pumpFoodTab(tester);

    expect(find.byType(DottedAddSlot), findsNWidgets(4));
    // Je leerer Slot sagt es fuer sich; der Wegweiser steht einmal am Tag.
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

    // Unabhaengig von der Uhrzeit-Heuristik steht der Abendessen-Slot vorn.
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
    // Seit dem Wegfall der Zusammenfassungs-Karte (2026-08-10) ist die Kachel
    // die EINZIGE kcal-Angabe des Tabs — und sie setzt Zahl und Einheit
    // getrennt. Ein „1.234 kcal" am Stueck gibt es hier nicht mehr; die
    // Flow-Tests zaehlen genau darauf.
    expect(find.text('1.234 kcal'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Die Kalorien-Karte ist fort (Nutzer-Entscheid 2026-08-10).
  //
  // Sie zeigte Rest-kcal, ZIEL/GEGESSEN/VERBRANNT und drei Makro-Balken —
  // alles Dinge, die der Tab „Heute" einen Tipp entfernt vollstaendig traegt.
  // Bezahlt wurde die Wiederholung damit, dass der Verlauf, die eigentliche
  // Aufgabe DIESES Tabs, auf einem 852-px-Schirm unter die Falz rutschte.
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
      // Und die Beschriftungen, die nur sie trug.
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
      // Der Grund fuer die ganze Aenderung. Mit Karte begann „Verlauf" auf
      // diesem 393x852-Schirm bei y=655 — unter der Falz, obwohl er der
      // Hauptinhalt des Tabs ist.
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

    // VERSCHOBEN aus test/widgets/calories_overview_glass_test.dart
    // („Die Zusammenfassung rastert in $brightness nichts Teures"). Der
    // Pruefgegenstand wandert von der entfernten Karte auf den ganzen Tab:
    // ein Blur ueber einer einfarbigen Flaeche kostet in JEDEM Frame Zeit,
    // ohne etwas zu zeigen — und der weiche ImageFiltered-Glow gehoerte zur
    // abgeloesten Glas-Sprache.
    for (final brightness in Brightness.values) {
      testWidgets('Der Food-Tab rastert in $brightness nichts Teures',
          (tester) async {
        await _pumpFoodTab(
          tester,
          brightness: brightness,
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
      });
    }
  });

  // textScale-Pflicht aus DESIGN_REFACTOR §5, in BEIDEN Modi: der Hell-Modus
  // hat andere Randstaerken (1-px-Linien auf hellem Grund) und damit andere
  // Innenmasse als der Dunkel-Modus.
  for (final brightness in Brightness.values) {
    testWidgets('Der Food-Tab ueberlebt textScale 2.0 in $brightness '
        'overflow-frei', (tester) async {
      final fehler = await _pumpFoodTab(
        tester,
        brightness: brightness,
        textScale: 2.0,
        meals: [
          _mahlzeit(slot: MealSlot.breakfast, id: 'a'),
          _mahlzeit(slot: MealSlot.snack, id: 'b'),
        ],
        dailyConsumedKcal: 640,
      );

      expect(fehler, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

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

  // DATA-6: der Tages-Filter des Tagebuchs muss derselbe sein, aus dem die
  // Kopfzahl entsteht — `mealsForFoodDate`, nicht `isSameDay(loggedAt)`. Eine
  // 23:45-Mahlzeit, deren persistierter `local_day` auf HEUTE zeigt, waehrend
  // ihr `loggedAt` (unter geaendertem Zonen-/DST-Offset betrachtet) auf
  // gestern faellt, zaehlte sonst in der Kachel mit und fehlte im Tagebuch.
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

  group('EN-Render-Smoke (i18n-Paket 2, Spec §6)', () {
    // Rendert unter Locale `en` in beiden Helligkeiten: kein Absturz, und
    // mindestens eine echte englische Uebersetzung steht im Baum. Englische
    // Texte sind teils laenger als die deutschen — das faengt Overflows, die
    // ein reiner `de`-Lauf nie zeigen wuerde. Muster:
    // test/screens/today/today_screen_test.dart (Paket 1).
    for (final helligkeit in Brightness.values) {
      testWidgets('rendert unter en in $helligkeit ohne Ausnahme',
          (tester) async {
        final fehler = await _pumpFoodTab(
          tester,
          brightness: helligkeit,
          locale: const Locale('en'),
          meals: [_mahlzeit(slot: MealSlot.lunch)],
          dailyConsumedKcal: 320,
        );
        expect(tester.takeException(), isNull,
            reason: 'Rendering unter en/$helligkeit ist fehlgeschlagen');
        expect(fehler, isEmpty);

        // „Ernährung" -> „Nutrition", „Frühstück" -> „Breakfast".
        expect(find.text('Nutrition'), findsOneWidget);
        expect(find.text('Breakfast'), findsOneWidget);
        expect(find.text('Nothing logged yet'), findsWidgets);
      });
    }
  });
}
