// Die Text- und Formathelfer des Tabs „Heute".
//
// Drei der hier gepruefen Funktionen sind bewusste KOPIEN von Code, der
// anderswo privat oder `@visibleForTesting` ist (Begruessung aus
// coach_hero.dart, Tausenderpunkt aus calories_overview_card.dart, Tageslabel
// aus meal_analysis_screen.dart). Diese Tests sind der Drift-Melder: weicht
// eine Kopie vom Original ab, faellt es hier auf und nicht erst im UI.
//
// Seit der i18n-Migration (Paket 1, 2026-08-10) brauchen die textgebenden
// Helfer ein [AppLocalizations] — hier fest `de` (die Erwartungswerte bleiben
// wortgleich zum Bestand, Regel 1 aus docs/I18N_PAKETE.md). `todayEyebrow`
// initialisiert die `intl`-Datumssymbole selbst (einmalig, s.
// today_texts.dart) — kein Extra-Setup hier noetig.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/today/today_texts.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

LoggedMeal _meal(String name, {int kcal = 400, MealSlot? slot}) => LoggedMeal(
      id: name,
      loggedAt: DateTime(2026, 8, 9, 12),
      forcedSlot: slot,
      result: MealAnalysisResult(
        mealName: name,
        caloriesKcal: kcal,
        estimatedGrams: 300,
        kcalPer100G: 133,
        protein: '30 g',
        carbs: '40 g',
        fat: '12 g',
        confidence: 'Mittel',
        portionNotes: 'Test.',
      ),
    );

void main() {
  group('greetingForHour — dieselben Schwellen wie der Coach-Hero', () {
    test('die vier Faecher an ihren Kanten', () {
      // coach_hero.dart:13-19: <5 / <11 / <17 / sonst.
      expect(greetingForHour(0, _de), 'Gute Nacht');
      expect(greetingForHour(4, _de), 'Gute Nacht');
      expect(greetingForHour(5, _de), 'Guten Morgen');
      expect(greetingForHour(10, _de), 'Guten Morgen');
      expect(greetingForHour(11, _de), 'Hallo');
      expect(greetingForHour(16, _de), 'Hallo');
      expect(greetingForHour(17, _de), 'Guten Abend');
      expect(greetingForHour(23, _de), 'Guten Abend');
    });

    test('todayGreeting liest die Wanduhr ueber clock.now()', () {
      withClock(Clock.fixed(DateTime(2026, 8, 9, 7, 30)), () {
        expect(todayGreeting(_de), 'Guten Morgen');
      });
      withClock(Clock.fixed(DateTime(2026, 8, 9, 22, 5)), () {
        expect(todayGreeting(_de), 'Guten Abend');
      });
    });
  });

  group('todayEyebrow — deutsches Datum in Versalien', () {
    test('Wochentag, Tag und Monat', () {
      expect(todayEyebrow(DateTime(2026, 8, 9), _de), 'SONNTAG, 9. AUGUST');
      expect(todayEyebrow(DateTime(2026, 8, 10), _de), 'MONTAG, 10. AUGUST');
    });

    test('Umlaut-Monat bleibt ein Umlaut', () {
      expect(todayEyebrow(DateTime(2026, 3, 29), _de), 'SONNTAG, 29. MÄRZ');
    });

    test('Jahres- und Monatsgrenzen', () {
      expect(
          todayEyebrow(DateTime(2026, 1, 1), _de), 'DONNERSTAG, 1. JANUAR');
      expect(todayEyebrow(DateTime(2026, 12, 31), _de),
          'DONNERSTAG, 31. DEZEMBER');
      expect(
          todayEyebrow(DateTime(2026, 2, 28), _de), 'SAMSTAG, 28. FEBRUAR');
    });
  });

  group('kcalThousands — verhaltensgleich zu _formatThousands', () {
    test('Tausenderpunkte ab vier Stellen', () {
      expect(kcalThousands(0, _de), '0');
      expect(kcalThousands(999, _de), '999');
      expect(kcalThousands(1000, _de), '1.000');
      expect(kcalThousands(2200, _de), '2.200');
      expect(kcalThousands(12345, _de), '12.345');
      expect(kcalThousands(1234567, _de), '1.234.567');
    });

    test('das Minuszeichen steht vor der Gruppierung', () {
      expect(kcalThousands(-1234, _de), '-1.234');
      expect(kcalThousands(-42, _de), '-42');
    });

    test('unter en steht ein Komma statt des Punkts', () {
      final en = lookupAppLocalizations(const Locale('en'));
      expect(kcalThousands(2200, en), '2,200');
      expect(kcalThousands(1234567, en), '1,234,567');
    });
  });

  group('todayDateLabel — zeichengleich zu foodDateSelectedLabel', () {
    // Anker wie in meal_analysis_date_strip_test.dart: der Montag NACH der
    // Fruehjahrsumstellung. Mit Duration-Arithmetik lieferte der 25.03. hier
    // „Vor 4 Tagen" (119 Stunden), richtig sind fuenf Kalendertage.
    final montagNachUmstellung = DateTime(2026, 3, 30);

    test('Heute / Gestern / Vor N Tagen', () {
      expect(
        todayDateLabel(montagNachUmstellung, DateTime(2026, 3, 30), _de),
        'Heute',
      );
      expect(
        todayDateLabel(montagNachUmstellung, DateTime(2026, 3, 29), _de),
        'Gestern',
      );
      expect(
        todayDateLabel(montagNachUmstellung, DateTime(2026, 3, 25), _de),
        'Vor 5 Tagen',
      );
    });

    test('die Uhrzeit spielt keine Rolle', () {
      expect(
        todayDateLabel(
          DateTime(2026, 8, 9, 23, 59),
          DateTime(2026, 8, 9, 0, 1),
          _de,
        ),
        'Heute',
      );
    });
  });

  group('mealSlotSubtitle', () {
    test('leerer Slot traegt den wortgleichen Leertext', () {
      expect(
        mealSlotSubtitle(const <LoggedMeal>[], _de),
        'Noch nichts geloggt',
      );
    });

    test('Namen mit Mittelpunkt verbunden', () {
      expect(
        mealSlotSubtitle(<LoggedMeal>[_meal('Haferbrei')], _de),
        'Haferbrei',
      );
      expect(
        mealSlotSubtitle(
            <LoggedMeal>[_meal('Haferbrei'), _meal('Kaffee')], _de),
        'Haferbrei · Kaffee',
      );
    });
  });

  group('coachTeaser', () {
    test('leerer Tag lockt zum ersten Log', () {
      expect(
        coachTeaser(dayIsEmpty: true, remainingProteinG: 130, l10n: _de),
        'Logge deine erste Mahlzeit — ich baue deinen Tag darum herum.',
      );
    });

    test('offenes Protein wird konkret benannt', () {
      expect(
        coachTeaser(dayIsEmpty: false, remainingProteinG: 38, l10n: _de),
        'Dir fehlen noch 38 g Protein. Soll ich dir etwas vorschlagen?',
      );
    });

    test('erfuelltes Protein-Ziel bekommt einen eigenen Zweig', () {
      expect(
        coachTeaser(dayIsEmpty: false, remainingProteinG: 0, l10n: _de),
        'Dein Protein-Ziel steht. Soll ich auf den Rest des Tages schauen?',
      );
    });

    test('ein Archivtag bekommt eine tagesneutrale Zeile', () {
      // Beide Tagesaussagen waeren auf einem abgelaufenen Tag falsch: „logge
      // deine erste Mahlzeit — ich baue deinen Tag darum herum" fordert zum
      // Nachtragen in die Vergangenheit auf, und ein Abendessen-Vorschlag
      // gegen offenes Protein kommt fuer vorgestern zu spaet. Der Coach
      // rechnet ohnehin mit HEUTE (HomeStore.coachContext).
      const neutral = 'Frag den Coach nach Ideen für deine Ziele.';
      expect(
        coachTeaser(
          dayIsEmpty: true,
          remainingProteinG: 130,
          l10n: _de,
          isToday: false,
        ),
        neutral,
      );
      expect(
        coachTeaser(
          dayIsEmpty: false,
          remainingProteinG: 38,
          l10n: _de,
          isToday: false,
        ),
        neutral,
      );
      expect(
        coachTeaser(
          dayIsEmpty: false,
          remainingProteinG: 0,
          l10n: _de,
          isToday: false,
        ),
        neutral,
      );
    });
  });

  group('todayInitial — gespiegelt zu HomeStore.profileInitial', () {
    test('erster Buchstabe des Vornamens, gross', () {
      expect(todayInitial('Moritz'), 'M');
      expect(todayInitial('moritz kern'), 'M');
      expect(todayInitial('  ada  lovelace '), 'A');
    });

    test('leerer Name faellt auf S zurueck', () {
      expect(todayInitial(''), 'S');
      expect(todayInitial('   '), 'S');
    });
  });
}
