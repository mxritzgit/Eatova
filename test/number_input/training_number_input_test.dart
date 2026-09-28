import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_actual_fields.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import '../support/harness.dart';
import 'number_input_cases.dart';

// Training: the set's weight is a decimal and read "1.000" as 1 kg; reps are
// whole and answered "3,5" with a generic message. In the plan editor
// `digitsOnly` turned "3,5" repetitions into 35 and saved them.

class _Satz {
  int? reps;
  double? kg;
  bool? gueltig;
}

Future<_Satz> _pumpSatz(WidgetTester tester, Locale locale) async {
  final satz = _Satz();
  await pumpLocalized(
    tester,
    Column(
      children: [
        TrainingActualFields(
          timed: false,
          reps: 8,
          weightKg: 60,
          onChanged: (reps, kg) {
            satz
              ..reps = reps
              ..kg = kg;
          },
          onValidityChanged: (valid) => satz.gueltig = valid,
        ),
        const TextField(key: ValueKey('anderswo')),
      ],
    ),
    locale: locale,
    scrollable: true,
  );
  return satz;
}

/// Types [text] and moves focus away — the fields only show errors after
/// they lost focus once.
Future<void> _tippe(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('anderswo')));
  await tester.pump();
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgets('Satzgewicht [$code]: Komma, Punkt, Gruppe, keine Raterei',
        (tester) async {
      final satz = await _pumpSatz(tester, locale);
      const feld = 'training-actual-weight';

      for (final eingabe in const <String>['3,5', '3.5']) {
        await _tippe(tester, feld, eingabe);
        expect(satz.gueltig, isTrue, reason: eingabe);
        expect(satz.kg, 3.5, reason: eingabe);
      }

      await _tippe(tester, feld, '1.000');
      expect(satz.gueltig, isFalse, reason: 'frueher still 1 kg');
      expect(satz.kg, 3.5, reason: 'der letzte gueltige Wert bleibt');
      expect(find.text(mehrdeutigHinweis(l10n)), findsOneWidget);

      await _tippe(tester, feld, '1.000,5');
      expect(satz.gueltig, isTrue);
      expect(satz.kg, 1000.5);
      expect(find.text(mehrdeutigHinweis(l10n)), findsNothing);
    });

    testWidgets('Wiederholungen [$code]: ganze Zahl mit klarem Hinweis',
        (tester) async {
      final satz = await _pumpSatz(tester, locale);
      const feld = 'training-actual-reps';

      for (final (eingabe, hinweis) in ganzzahlFaelle(l10n)) {
        await _tippe(tester, feld, eingabe);
        expect(satz.gueltig, isFalse, reason: eingabe);
        expect(find.text(hinweis), findsOneWidget, reason: eingabe);
      }
      await _tippe(tester, feld, '12');
      expect(satz.gueltig, isTrue);
      expect(satz.reps, 12);
    });

    testWidgets('Planeditor [$code]: 3,5 Wiederholungen werden nicht zu 35',
        (tester) async {
      CoachTrainingProposal? gespeichert;
      final entwurf = CoachTrainingProposal(
        title: 'Ganzkoerper',
        goal: 'Kraft',
        workouts: [
          TrainingWorkout(
            title: 'Tag A',
            exercises: [
              TrainingExercise(
                name: 'Kniebeuge',
                sets: 3,
                reps: 8,
                restSeconds: 90,
              ),
            ],
          ),
        ],
      );
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTrainingPlanEditor(
              context,
              initialDraft: entwurf,
              onSave: (value) async {
                gespeichert = value;
                return SyncDelivery.delivered;
              },
            ),
            child: const Text('Open'),
          ),
        ),
        locale: locale,
        surfaceSize: const Size(390, 844),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final bearbeiten = find.byKey(const ValueKey('training-editor-edit'));
      await tester.ensureVisible(bearbeiten);
      await tester.tap(bearbeiten);
      await tester.pumpAndSettle();

      const prefix = 'training-editor-exercise-0-0';
      final speichern = find.byKey(const ValueKey('training-editor-save'));
      for (final (suffix, gueltig) in const <(String, String)>[
        ('sets', '3'),
        ('repetitions', '8'),
        ('rest', '90'),
      ]) {
        final feld = find.byKey(ValueKey('$prefix-$suffix'));
        for (final (eingabe, hinweis) in ganzzahlFaelle(l10n)) {
          await tester.ensureVisible(feld);
          await tester.enterText(feld, eingabe);
          await tester.pumpAndSettle();
          // Four digits cover every bound (3600 s). "1.000,5" has five: the
          // budget keeps "1.000" visibly, which is then flagged, not saved.
          final imFeld = eingabe == '1.000,5' ? '1.000' : eingabe;
          final erwartet =
              eingabe == '1.000,5' ? mehrdeutigHinweis(l10n) : hinweis;
          expect(
            tester.widget<TextField>(feld).controller!.text,
            imFeld,
            reason: '$suffix: digitsOnly machte aus "$eingabe" eine andere '
                'Zahl',
          );
          await tester.tap(speichern);
          await tester.pumpAndSettle();
          expect(gespeichert, isNull, reason: '$suffix $eingabe');
          expect(
            find.text(erwartet),
            findsOneWidget,
            reason: '$suffix $eingabe',
          );
        }
        await tester.ensureVisible(feld);
        await tester.enterText(feld, gueltig);
        await tester.pumpAndSettle();
      }

      await tester.tap(speichern);
      await tester.pumpAndSettle();
      final uebung = gespeichert!.workouts.single.exercises.single;
      expect(uebung.sets, 3);
      expect(uebung.reps, 8);
      expect(uebung.restSeconds, 90);
    });
  }
}
