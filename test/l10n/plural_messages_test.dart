import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';

// Counted nouns must agree with their number in BOTH languages. German used
// to print "vor 1 Tagen", "1 Sätze übersprungen" or "Noch 1 Sekunden" (the
// last one as the countdown's screen-reader label), and English "1 reps".
// Every case below can really be 1 at its call site.

void main() {
  group('Deutsch', () {
    final l = deL10n;

    test('Tage, Wochen, Sekunden', () {
      expect(l.coachTimeDaysAgo(1), 'vor 1 Tag');
      expect(l.coachTimeDaysAgo(3), 'vor 3 Tagen');
      expect(l.profileGoalProgressWeeks(2, 1), 'Noch 2 kg · Ziel in ca. 1 Woche');
      expect(l.profileGoalProgressWeeks(2, 5), 'Noch 2 kg · Ziel in ca. 5 Wochen');
      expect(
        l.profileGoalProgressWeeksOpen(1, 1),
        'Noch 1 kg · Ziel frühestens in ca. 1 Woche',
      );
      expect(
        l.onboardingTimelineEstimate(70, 1),
        '70 kg in ca. 1 Woche erreichbar.',
      );
      expect(
        l.onboardingTimelineEstimate(70, 12),
        '70 kg in ca. 12 Wochen erreichbar.',
      );
      expect(
        l.onboardingTimelineEstimateOpen(70, 1),
        startsWith('70 kg frühestens in ca. 1 Woche erreichbar'),
      );
      expect(l.trainingTimerSecondsRemaining(1), 'Noch 1 Sekunde');
      expect(l.trainingTimerSecondsRemaining(30), 'Noch 30 Sekunden');
    });

    test('Saetze, Wiederholungen, Eintraege', () {
      expect(l.trainingTimerSkipped(1), '1 Satz übersprungen');
      expect(l.trainingTimerSkipped(2), '2 Sätze übersprungen');
      expect(l.trainingHistoryRepsValue(1), '1 Wiederholung');
      expect(l.trainingHistoryRepsValue(8), '8 Wiederholungen');
      expect(l.trainingTimerProgress(0, 1), '0 von 1 Satz geschafft');
      expect(l.trainingTimerProgress(2, 3), '2 von 3 Sätzen geschafft');
      expect(
        l.trainingTimerSaveSets(1),
        '1 Satz speichern (Rest überspringen)',
      );
      expect(
        l.trainingTimerSaveSets(3),
        '3 Sätze speichern (Rest überspringen)',
      );
      expect(l.profileUnitEntries(1), 'Eintrag');
      expect(l.profileUnitEntries(4), 'Einträge');
      expect(l.exportSummary(1, 1), '1 Bereich · 1 Datensatz');
      expect(l.exportSummary(3, 42), '3 Bereiche · 42 Datensätze');
    });

    test('Portionen mit Dezimalkomma', () {
      expect(l.recipePortionPresetLabel(1), '1 Portion');
      expect(l.recipePortionPresetLabel(0.5), '0,5 Portionen');
      expect(l.recipePortionPresetLabel(2), '2 Portionen');
    });

    test('Einheiten auf dem Einkaufszettel, auch mit Bruch', () {
      expect(l.mealPlanUnitCan(1, '1'), '1 Dose');
      expect(l.mealPlanUnitCan(1.5, '1 1/2'), '1 1/2 Dosen');
      expect(l.mealPlanUnitJar(2, '2'), '2 Gläser');
      expect(l.mealPlanUnitClove(1, '1'), '1 Zehe');
      expect(l.mealPlanUnitPinch(3, '2–3'), '2–3 Prisen');
      expect(l.mealPlanUnitTub(2, '2'), '2 Becher');
      expect(l.mealPlanReceiptBatchNoteSpoken(1), '(Rezept für 1 Portion)');
      expect(l.mealPlanReceiptBatchNoteSpoken(4), '(Rezept für 4 Portionen)');
      expect(
        l.mealPlanReceiptBatchNoteSpoken(2.5),
        '(Rezept für 2,5 Portionen)',
      );
      expect(
        l.mealPlanNoIngredientsNote(1, 'Pizza (Mo)'),
        'Ohne Zutatenliste: Pizza (Mo). Rezept vor dem Einkauf prüfen.',
      );
      expect(
        l.mealPlanNoIngredientsNote(2, 'Pizza (Mo), Suppe (Do)'),
        'Ohne Zutatenliste: Pizza (Mo), Suppe (Do). Rezepte vor dem Einkauf '
        'prüfen.',
      );
    });
  });

  group('English', () {
    final l = enL10n;

    test('days, weeks, seconds', () {
      expect(l.coachTimeDaysAgo(1), '1 day ago');
      expect(l.profileGoalProgressWeeks(2, 1), '2 kg to go · goal in about 1 week');
      expect(l.trainingTimerSecondsRemaining(1), '1 second remaining');
      expect(l.trainingTimerSecondsRemaining(30), '30 seconds remaining');
    });

    test('sets, reps, entries', () {
      expect(l.trainingTimerSkipped(1), '1 set skipped');
      expect(l.trainingTimerSkipped(2), '2 sets skipped');
      expect(l.trainingHistoryRepsValue(1), '1 rep');
      expect(l.trainingHistoryRepsValue(8), '8 reps');
      expect(l.trainingPageSetsReps(3, 1), '3 × 1 rep');
      expect(l.trainingPageSetsReps(3, 10), '3 × 10 reps');
      expect(l.trainingTimerProgress(0, 1), '0 of 1 set completed');
      expect(l.trainingTimerProgress(2, 3), '2 of 3 sets completed');
      expect(l.profileUnitEntries(1), 'entry');
      expect(l.profileUnitEntries(4), 'entries');
      expect(l.exportSummary(1, 1), '1 section · 1 record');
      expect(l.exportSummary(3, 42), '3 sections · 42 records');
    });

    test('servings with a decimal point', () {
      expect(l.recipePortionPresetLabel(1), '1 serving');
      expect(l.recipePortionPresetLabel(0.5), '0.5 servings');
      expect(l.recipePortionPresetLabel(2), '2 servings');
    });

    test('shopping receipt units, also with a fraction', () {
      expect(l.mealPlanUnitCan(1, '1'), '1 can');
      expect(l.mealPlanUnitCan(1.5, '1 1/2'), '1 1/2 cans');
      expect(l.mealPlanUnitBunch(2, '2'), '2 bunches');
      expect(l.mealPlanUnitClove(1, '1'), '1 clove');
      expect(l.mealPlanUnitPinch(3, '2–3'), '2–3 pinches');
      expect(l.mealPlanReceiptBatchNoteSpoken(1), '(recipe serves 1)');
      expect(l.mealPlanReceiptBatchNoteSpoken(4), '(recipe serves 4)');
      expect(
        l.mealPlanNoIngredientsNote(2, 'Pizza (Mo), Soup (Th)'),
        'No ingredient list: Pizza (Mo), Soup (Th). Check the recipes before '
        'shopping.',
      );
    });
  });
}
