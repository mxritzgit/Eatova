// Der Tab „Heute" (Design-Refactor 2026-08-09).
//
// Der Harness stellt die SCHALE nach, in der der Screen spaeter haengt:
// Eatova-Theme, Telefon-Viewport und das Padding, das
// eatova_home_page.dart:420-424 bereits liefert (SafeArea + 20/12/20/12). Nur
// so laesst sich pruefen, dass der Screen KEINEN zweiten Seitenrand setzt.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

/// Sonntag, 9. August 2026, 10:00 — weit weg von jeder Tagesgrenze.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

LoggedMeal _meal(String name, MealSlot slot, int kcal) => LoggedMeal(
      id: '$name-${slot.name}',
      loggedAt: DateTime(2026, 8, 9, 12),
      forcedSlot: slot,
      result: MealAnalysisResult(
        mealName: name,
        caloriesKcal: kcal,
        estimatedGrams: 300,
        kcalPer100G: 120,
        protein: '30 g',
        carbs: '40 g',
        fat: '12 g',
        confidence: 'Mittel',
        portionNotes: 'Test.',
      ),
    );

Widget _harness(
  Widget child, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEatovaTheme(brightness),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
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
  );
}

Future<void> _pumpToday(
  WidgetTester tester, {
  UserProfile profile = const UserProfile(),
  String userName = 'Moritz',
  String? profileInitial,
  int consumedKcal = 0,
  int burnedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
  List<LoggedMeal> meals = const <LoggedMeal>[],
  DateTime? selectedDate,
  int streak = 0,
  bool dayLoading = false,
  ValueChanged<DateTime>? onDateSelected,
  VoidCallback? onOpenCoach,
  VoidCallback? onOpenProfile,
  ValueChanged<MealSlot>? onOpenMealSlot,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  // Die Ladekarte dreht einen CircularProgressIndicator endlos —
  // `pumpAndSettle` wuerde dort nie settlen.
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _harness(
      TodayScreen(
        userName: userName,
        profile: profile,
        consumedKcal: consumedKcal,
        burnedKcal: burnedKcal,
        macroProgress: macroProgress,
        meals: meals,
        selectedDate: selectedDate ?? startOfDay(clock.now()),
        streak: streak,
        profileInitial: profileInitial,
        dayLoading: dayLoading,
        onDateSelected: onDateSelected,
        onOpenCoach: onOpenCoach,
        onOpenProfile: onOpenProfile,
        onOpenMealSlot: onOpenMealSlot,
      ),
      brightness: brightness,
      textScaler: textScaler,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

Finder _in(String key, String text) => find.descendant(
      of: find.byKey(ValueKey<String>(key)),
      matching: find.text(text),
    );

/// Scrollt [ziel] in die Sicht — der Screen ist laenger als ein Telefon.
Future<void> _scrollTo(WidgetTester tester, Finder ziel) async {
  await tester.scrollUntilVisible(ziel, 220,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

/// Dasselbe ohne `pumpAndSettle` — die Ladekarte dreht endlos, dort settlet
/// nichts. Bricht ab, sobald [ziel] gebaut ist (die ListView baut ihre unteren
/// Kinder erst beim Heranscrollen).
Future<void> _scrollToUnsettled(WidgetTester tester, Finder ziel) async {
  for (var i = 0; i < 14 && ziel.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(ziel, findsOneWidget, reason: 'Ziel liess sich nicht heranscrollen');
}

void main() {
  group('Kalorien-Hero', () {
    testWidgets('das Ziel bleibt roh, das Verbrannte steckt im Rest',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2000),
          consumedKcal: 500,
          burnedKcal: 300,
        );
      });

      // UMGESCHRIEBEN (Verifikation 2026-08-09). Der Test nagelte vorher
      // „Ziel 2.300 kcal" fest — die Summe aus Tagesziel und Verbranntem.
      // Einen Tab weiter zeigt die Food-Zusammenfassung fuer denselben Tag
      // „2.000 kcal" in ihrer ZIEL-Kachel; der Nutzer sah zwei Zahlen fuer
      // dasselbe Wort. „Ziel" ist der Wert aus den Einstellungen, das
      // verbrannte Guthaben gehoert in die verbleibende Zahl (so hielt es
      // auch die abgeloeste calories_overview_card.dart:34-39).
      expect(_textOf(tester, 'today-kcal-goal'), 'Ziel 2.000 kcal');
      // Der Rest rechnet weiterhin gegen Ziel + Verbranntes: 2000+300-500.
      expect(_textOf(tester, 'today-kcal-remaining'), '1.800');
      expect(find.text('kcal übrig'), findsOneWidget);
      // Und die Rechnung bleibt nachvollziehbar: das Verbrannte steht als
      // eigene Kachel da.
      expect(_in('today-stat-burned', '300'), findsOneWidget);
    });

    testWidgets('eine Ueberschreitung zeigt den Betrag und wechselt die Einheit',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2000),
          consumedKcal: 2600,
        );
      });

      expect(_textOf(tester, 'today-kcal-remaining'), '600');
      expect(find.text('kcal drüber'), findsOneWidget);
      expect(find.text('kcal übrig'), findsNothing);
    });

    testWidgets('ohne Verbranntes steht der Gedankenstrich', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, consumedKcal: 800);
      });

      expect(_in('today-stat-burned', '—'), findsOneWidget);
      expect(_in('today-stat-eaten', '800'), findsOneWidget);
    });

    testWidgets('der Streak kommt fertig herein und wird nur angezeigt',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, streak: 12);
      });

      expect(_in('today-stat-streak', '12'), findsOneWidget);
    });

    testWidgets('ein Tagesziel von 0 stuerzt nicht ab', (tester) async {
      // Kaputte/unvollstaendige Profile kommen aus dem Netz. Der Rechenkern
      // faengt das mit `goal <= 0 -> 1` ab (calories_overview_card.dart:34) —
      // ohne diesen Zweig waere `eaten / adjustedGoal` eine Division durch 0.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 0),
          consumedKcal: 400,
        );
      });

      expect(tester.takeException(), isNull);
      expect(_textOf(tester, 'today-kcal-goal'), 'Ziel 1 kcal');
      expect(_textOf(tester, 'today-kcal-remaining'), '399');
      expect(find.text('kcal drüber'), findsOneWidget);
    });

    // VERSCHOBEN aus test/widgets/calories_overview_glass_test.dart
    // („der Fortschritt ist fuer einen Screenreader vorhanden"). Die
    // Food-Zusammenfassung, die dieselbe Ansage trug, ist am 2026-08-10 aus
    // dem Food-Tab entfernt worden — der Hero ist seitdem die EINZIGE Flaeche,
    // an der ein Screenreader den Tagesfortschritt erfaehrt. Der TickGauge ist
    // ein CustomPaint und damit semantisch leer; ohne diese Annotation gaebe es
    // den Fortschritt fuer einen Screenreader gar nicht. Geprueft wird deshalb
    // der WERT, nicht nur die Existenz des Labels (das taten wir schon).
    testWidgets('der Screenreader hoert den Fortschritt als Prozentwert',
        (tester) async {
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2200),
          consumedKcal: 1100,
        );
      });

      // RegExp statt Gleichheit: der Hero verschmilzt den Gauge-Knoten mit den
      // Texten darum herum, das Label steht also nicht allein im Knoten.
      final gauge = find.bySemanticsLabel(RegExp('Kalorienfortschritt'));
      expect(gauge, findsOneWidget);
      expect(
        tester.getSemantics(gauge).value,
        contains('50 Prozent des Tagesziels gegessen'),
      );
      handle.dispose();
    });
  });

  group('Makros', () {
    testWidgets('drei Balken gegen die Ziele des Profils', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          profile: const UserProfile(
            proteinGoalG: 130,
            carbsGoalG: 240,
            fatGoalG: 70,
          ),
          macroProgress:
              const MacroProgress(proteinG: 42.4, carbsG: 80, fatG: 20, kcal: 700),
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-macros-card')));
      final balken = tester
          .widgetList<MacroBar>(find.byType(MacroBar))
          .toList(growable: false);
      expect(balken.length, 3);
      expect(balken[0].label, 'Protein');
      expect(balken[0].value, 42);
      expect(balken[0].goal, 130);
      expect(balken[1].label, 'Kohlenhydrate');
      expect(balken[1].goal, 240);
      expect(balken[2].label, 'Fett');
      expect(balken[2].goal, 70);
    });
  });

  group('Mahlzeiten', () {
    testWidgets('vier Slots mit wortgleichen Titeln, Namen und kcal-Summen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          meals: <LoggedMeal>[
            _meal('Haferbrei', MealSlot.breakfast, 320),
            _meal('Kaffee', MealSlot.breakfast, 20),
            _meal('Lachsbowl', MealSlot.dinner, 610),
          ],
        );
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-meals-card')));

      expect(_in('today-meal-row-breakfast', 'Frühstück'), findsOneWidget);
      expect(_in('today-meal-row-breakfast', 'Haferbrei · Kaffee'),
          findsOneWidget);
      expect(_in('today-meal-row-breakfast', '340'), findsOneWidget);

      expect(_in('today-meal-row-lunch', 'Mittagessen'), findsOneWidget);
      expect(_in('today-meal-row-lunch', 'Noch nichts geloggt'), findsOneWidget);

      expect(_in('today-meal-row-dinner', 'Abendessen'), findsOneWidget);
      expect(_in('today-meal-row-dinner', '610'), findsOneWidget);

      expect(_in('today-meal-row-snack', 'Snacks'), findsOneWidget);
    });

    testWidgets('dayLoading ersetzt die Karte durch die Ladekarte',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true, settle: false);
      });

      expect(find.byKey(const ValueKey('today-day-loading')), findsOneWidget);
      expect(find.text('Tag wird geladen…'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-meals-card'), skipOffstage: false),
          findsNothing);
      // Die Ueberschrift bleibt stehen, sonst springt der Screen beim Laden.
      expect(find.text('Heutige Mahlzeiten'), findsOneWidget);
    });

    testWidgets('waehrend des Ladens behauptet der Coach keinen leeren Tag',
        (tester) async {
      // `meals` ist beim Laden leer, OHNE dass der Tag leer WAERE. Der
      // Leer-Teaser waere hier eine Aussage ueber ungeladene Daten — und
      // spraenge eine Sekunde spaeter auf einen anderen Satz um.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true, settle: false);
      });

      await _scrollToUnsettled(
          tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsNothing,
      );
    });
  });

  group('Datums-Streifen', () {
    testWidgets('auf heute ist der Vorwaerts-Pfeil taub', (tester) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, onDateSelected: (d) => gewaehlt = d);
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Heute');

      await tester.tap(find.byKey(const ValueKey('today-date-next')));
      await tester.pumpAndSettle();
      expect(gewaehlt, isNull, reason: 'die Zukunft hat keine Daten');

      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 8, 8));
    });

    testWidgets('auf gestern fuehrt der Vorwaerts-Pfeil zurueck auf heute',
        (tester) async {
      DateTime? gewaehlt;
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          selectedDate: DateTime(2026, 8, 8),
          onDateSelected: (d) => gewaehlt = d,
        );
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Gestern');

      await tester.tap(find.byKey(const ValueKey('today-date-next')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 8, 9));
    });

    testWidgets('der Rueckwaerts-Schritt ueberlebt die Zeitumstellung',
        (tester) async {
      // B5-Anker: mit `subtract(Duration(days: 1))` landete der 30.03.2026 in
      // Europe/Berlin auf dem 28.03. um 23:00 — der Sonntag fiel aus der
      // Leiste, und jede von dort geloggte Mahlzeit bekam den falschen
      // local_day.
      DateTime? gewaehlt;
      await withClock(Clock.fixed(DateTime(2026, 3, 30, 9)), () async {
        await _pumpToday(tester, onDateSelected: (d) => gewaehlt = d);
      });

      await tester.tap(find.byKey(const ValueKey('today-date-prev')));
      await tester.pumpAndSettle();
      expect(gewaehlt, DateTime(2026, 3, 29));
    });

    testWidgets('ein Archivtag heisst nicht mehr „Heutige Mahlzeiten"',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          selectedDate: DateTime(2026, 8, 4),
          consumedKcal: 1200,
        );
      });

      expect(_textOf(tester, 'today-date-selected-label'), 'Vor 5 Tagen');
      expect(find.text('Mahlzeiten'), findsOneWidget);
      expect(find.text('Heutige Mahlzeiten'), findsNothing);
      // Die Eyebrow folgt dem GEWAEHLTEN Tag, nicht der Wanduhr — sonst
      // widerspraeche sie dem Streifen direkt darunter.
      expect(_textOf(tester, 'today-eyebrow'), 'DIENSTAG, 4. AUGUST');
    });

    testWidgets('auf einem Archivtag lockt der Coach nicht ins Nachtragen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, selectedDate: DateTime(2026, 8, 4));
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(find.text('Frag den Coach nach Ideen für deine Ziele.'),
          findsOneWidget);
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsNothing,
        reason: 'der 4. August ist vorbei — dort ist nichts mehr zu bauen',
      );
    });

    testWidgets('heute lockt er weiterhin zum ersten Log', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-banner')));
      expect(
        find.text('Logge deine erste Mahlzeit — ich baue deinen Tag darum '
            'herum.'),
        findsOneWidget,
      );
    });
  });

  group('Aktionen', () {
    // UMGESCHRIEBEN (Nutzer-Entscheid 2026-08-10): der Test tippte hier vorher
    // zusaetzlich auf „Essen loggen" und erwartete den `onLogFood`-Rueckruf.
    testWidgets('Profil, Slot und Coach melden sich zurueck', (tester) async {
      var profil = 0;
      var coach = 0;
      MealSlot? slot;

      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          onOpenProfile: () => profil++,
          onOpenCoach: () => coach++,
          onOpenMealSlot: (s) => slot = s,
        );
      });

      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await tester.pumpAndSettle();
      expect(profil, 1);

      await _scrollTo(
          tester, find.byKey(const ValueKey('today-meal-row-dinner')));
      await tester.tap(find.byKey(const ValueKey('today-meal-row-dinner')));
      await tester.pumpAndSettle();
      expect(slot, MealSlot.dinner);

      await _scrollTo(tester, find.byKey(const ValueKey('today-coach-cta')));
      await tester.tap(find.byKey(const ValueKey('today-coach-cta')));
      await tester.pumpAndSettle();
      expect(coach, 1);
    });

    testWidgets('das Profil-Badge traegt die durchgereichte Initiale',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, userName: 'Moritz', profileInitial: 'Q');
      });
      expect(_in('today-profile', 'Q'), findsOneWidget);
    });

    testWidgets('ohne durchgereichte Initiale zaehlt der Name', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, userName: 'ada lovelace');
      });
      expect(_in('today-profile', 'A'), findsOneWidget);
    });
  });

  group('Der schwebende „Essen loggen"-Knopf ist fort', () {
    // UMGESCHRIEBEN, nicht geloescht (Nutzer-Entscheid 2026-08-10): der Knopf
    // entfaellt ersatzlos. Zum Loggen fuehren die Mahlzeiten-Zeilen in den
    // Food-Tab — zwei Wege zum selben Ziel waren einer zu viel. Die Tests
    // bleiben als Wachposten stehen, damit der Knopf nicht unbemerkt
    // zurueckkehrt.
    testWidgets('weder Key noch Beschriftung sind noch im Baum',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      expect(
        find.byKey(const ValueKey('today-log-food'), skipOffstage: false),
        findsNothing,
      );
      expect(find.text('Essen loggen', skipOffstage: false), findsNothing);
      expect(
        find.byType(PrimaryActionButton, skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('die Wurzel ist eine reine Liste ohne Knopf-Reserve',
        (tester) async {
      // Die untere Reserve wuchs frueher mit der Systemschrift mit (sie musste
      // die Knopfhoehe freihalten). Ohne Knopf ist sie eine glatte 12 — bei
      // jeder Textgroesse.
      for (final skalierung in <TextScaler>[
        TextScaler.noScaling,
        const TextScaler.linear(2.0),
      ]) {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(tester, textScaler: skalierung);
        });

        // Der Cast ist die eigentliche Aussage: die Wurzel ist wieder eine
        // ListView, kein Stack. (Ein `findsNothing` auf Stack ginge nicht —
        // das Coach-Banner bringt selbst einen mit.)
        final liste = tester
            .widget<ListView>(find.byKey(const ValueKey('screen-today')));
        expect(liste.padding, const EdgeInsets.fromLTRB(0, 0, 0, 12),
            reason: 'Reserve bei $skalierung');
      }
    });
  });

  group('Robustheit', () {
    testWidgets('ohne den Knopf-Stack bleibt jede Kombination layoutbar',
        (tester) async {
      // Bis 2026-08-10 war die Wurzel ein Stack aus Liste + schwebendem Knopf.
      // Diese Matrix haelt fest, dass die reine ListView in keiner Kombination
      // bricht — auch nicht ganz unten, wo die ListView ihre Kinder erst beim
      // Heranscrollen baut.
      for (final helligkeit in Brightness.values) {
        for (final skalierung in <TextScaler>[
          TextScaler.noScaling,
          const TextScaler.linear(2.0),
        ]) {
          for (final mitMahlzeiten in <bool>[false, true]) {
            final fall = '$helligkeit / $skalierung / '
                'Mahlzeiten=$mitMahlzeiten';
            await withClock(Clock.fixed(_jetzt), () async {
              await _pumpToday(
                tester,
                brightness: helligkeit,
                textScaler: skalierung,
                consumedKcal: mitMahlzeiten ? 610 : 0,
                meals: mitMahlzeiten
                    ? <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)]
                    : const <LoggedMeal>[],
              );
            });
            expect(tester.takeException(), isNull, reason: fall);

            await _scrollTo(
                tester, find.byKey(const ValueKey('today-coach-banner')));
            expect(tester.takeException(), isNull,
                reason: 'nach unten gescrollt: $fall');
          }
        }
      }
    });

    testWidgets('auch waehrend dayLoading bleibt die Liste heil',
        (tester) async {
      for (final helligkeit in Brightness.values) {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: helligkeit,
            textScaler: const TextScaler.linear(2.0),
            dayLoading: true,
            settle: false,
          );
        });
        expect(tester.takeException(), isNull, reason: '$helligkeit');

        await _scrollToUnsettled(
            tester, find.byKey(const ValueKey('today-coach-banner')));
        expect(tester.takeException(), isNull,
            reason: 'nach unten gescrollt: $helligkeit');
      }
    });

    testWidgets('rendert in beiden Helligkeiten ohne Ausnahme', (tester) async {
      for (final helligkeit in Brightness.values) {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: helligkeit,
            consumedKcal: 1400,
            burnedKcal: 220,
            streak: 5,
            meals: <LoggedMeal>[_meal('Lachsbowl', MealSlot.dinner, 610)],
          );
        });
        expect(tester.takeException(), isNull,
            reason: 'Rendering unter $helligkeit ist fehlgeschlagen');
      }
    });

    testWidgets('ueberlebt textScaler 2.0 ohne Ueberlauf', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          textScaler: const TextScaler.linear(2.0),
          consumedKcal: 12345,
          burnedKcal: 1234,
          streak: 365,
          macroProgress: const MacroProgress(
              proteinG: 120, carbsG: 200, fatG: 60, kcal: 1900),
          meals: <LoggedMeal>[
            _meal('Ofengemüse mit Feta und Kichererbsen', MealSlot.dinner, 610),
          ],
        );
      });
      expect(tester.takeException(), isNull);

      // Auch nach unten gescrollt darf nichts ueberlaufen.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('die Hero-Kennzahlen schrumpfen, statt umzubrechen',
        (tester) async {
      // Die drei Kacheln teilen sich die Kartenbreite zu je einem Drittel
      // (~92 px). Bei textScaler 2.0 sind „12.345" und „VERBRANNT" breiter als
      // das. Ohne FittedBox brach der Text mitten im Wort um — die Zahl stand
      // als Buchstabensalat untereinander (gemessen: 174 px statt 24). Ein
      // Text-Ueberlauf WIRFT nicht, deshalb faengt das kein
      // `takeException`-Test.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          textScaler: const TextScaler.linear(2.0),
          consumedKcal: 12345,
          burnedKcal: 1234,
          streak: 365,
        );
      });

      for (final fall in const <List<String>>[
        <String>['today-stat-eaten', '12.345', 'GEGESSEN'],
        <String>['today-stat-burned', '1.234', 'VERBRANNT'],
        <String>['today-stat-streak', '365', 'TAGE-STREAK'],
      ]) {
        final kachel = find.byKey(ValueKey<String>(fall[0]));
        final kachelBreite = tester.getSize(kachel).width;

        for (final text in <String>[fall[1], fall[2]]) {
          final zeile = find.descendant(of: kachel, matching: find.text(text));
          expect(zeile, findsOneWidget);
          // Einzeilig: 20 bzw. 10.5 px Grundschrift ergeben bei 2.0 hoechstens
          // ~48 px Zeilenhoehe — alles darueber ist ein Umbruch.
          expect(
            tester.getSize(zeile).height,
            lessThan(80),
            reason: '„$text" ist in ${fall[0]} umgebrochen',
          );
        }

        // Und die geschrumpfte Darstellung bleibt in der Kachel.
        for (final box in tester.widgetList<FittedBox>(
          find.descendant(of: kachel, matching: find.byType(FittedBox)),
        )) {
          expect(box.fit, BoxFit.scaleDown);
        }
        for (final element in find
            .descendant(of: kachel, matching: find.byType(FittedBox))
            .evaluate()) {
          expect(
            (element.renderObject! as RenderBox).size.width,
            lessThanOrEqualTo(kachelBreite + 0.5),
          );
        }
      }
    });

    // VERSCHOBEN aus test/widgets/calories_overview_glass_test.dart
    // („ueberleben in $brightness die Systemschrift 2.0"). Die grosse Restzahl
    // stand bis 2026-08-10 auf ZWEI Flaechen; seit die Food-Zusammenfassung
    // entfernt ist, steht sie nur noch hier — und zwar mit 66 px Grundschrift,
    // also der groessten Zahl der App. Gemessen wird die FITTEDBOX: der Text
    // darin behaelt seine ungeschrumpfte Groesse, die Verkleinerung steckt in
    // der Transformation darueber.
    //
    // Beide Modi, weil der Hellmodus andere Randstaerken und damit andere
    // Innenmasse hat (DESIGN_REFACTOR §7.2).
    for (final helligkeit in Brightness.values) {
      testWidgets('die Restzahl schrumpft in $helligkeit bei Systemschrift 2.0, '
          'statt den Hero zu sprengen', (tester) async {
        await withClock(Clock.fixed(_jetzt), () async {
          await _pumpToday(
            tester,
            brightness: helligkeit,
            textScaler: const TextScaler.linear(2.0),
            profile: const UserProfile(dailyKcalGoal: 99999),
            consumedKcal: 12345,
            burnedKcal: 1234,
          );
        });

        expect(tester.takeException(), isNull);
        final hero = find.byKey(const ValueKey('today-kcal-hero'));
        final zahl = find.byKey(const ValueKey('today-kcal-remaining'));
        expect(zahl, findsOneWidget);
        final kasten =
            find.ancestor(of: zahl, matching: find.byType(FittedBox)).first;
        expect(tester.widget<FittedBox>(kasten).fit, BoxFit.scaleDown);
        expect(
          tester.getSize(kasten).width,
          lessThanOrEqualTo(tester.getSize(hero).width),
        );
      });
    }

    testWidgets('die Vorlese-Beschriftungen tragen echte Umlaute',
        (tester) async {
      // Ein Semantics-Label ist gesprochener Text — „Profil oeffnen" liest
      // der Screenreader auch so vor.
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, selectedDate: DateTime(2026, 8, 8));
      });

      // RegExp statt Gleichheit: das Profil-Badge verschmilzt sein Label mit
      // der Initiale darunter zu „Profil öffnen\nM".
      expect(find.bySemanticsLabel(RegExp('Profil öffnen')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Tag zurück')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Tag vor')), findsOneWidget);
      // Der Tick-Gauge ist ein CustomPaint — ohne diese Annotation waere der
      // Fortschritt fuer einen Screenreader gar nicht vorhanden.
      expect(find.bySemanticsLabel(RegExp('Kalorienfortschritt')),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('setzt keinen zweiten Seitenrand', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('today-kcal-hero'))).dx,
        20,
        reason: 'die Schale liefert die 20 px bereits — 40 waere doppelt',
      );
    });

    testWidgets('die Wurzel traegt weiterhin screen-today', (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester);
      });
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    });
  });
}
