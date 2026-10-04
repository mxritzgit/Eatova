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
// `digitsOnly` turned "3,5" repetitions into 35 and saved them. The player's
// set cells ([TrainingSetValueField]) flag such input instead of saving it.

class _Satz {
  num? wert;
  bool gueltig = true;
}

const _feld = ValueKey('satz-feld');

Future<_Satz> _pumpSatz(
  WidgetTester tester,
  Locale locale, {
  required bool decimal,
}) async {
  final satz = _Satz();
  await pumpLocalized(
    tester,
    TrainingSetValueField(
      fieldKey: _feld,
      value: decimal ? 60 : 8,
      decimal: decimal,
      semanticLabel: 'Satz 1',
      onChanged: (value) => satz.wert = value,
      onValidityChanged: (valid) => satz.gueltig = valid,
    ),
    locale: locale,
    scrollable: true,
  );
  return satz;
}

Future<void> _tippe(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_feld), text);
  await tester.pump();
}

void main() {
  for (final locale in eingabeSprachen) {
    final l10n = l10nFuer(locale);
    final code = locale.languageCode;

    testWidgets('Satzgewicht [$code]: Komma, Punkt, Gruppe, keine Raterei',
        (tester) async {
      final satz = await _pumpSatz(tester, locale, decimal: true);

      for (final eingabe in const <String>['3,5', '3.5']) {
        await _tippe(tester, eingabe);
        expect(satz.gueltig, isTrue, reason: eingabe);
        expect(satz.wert, 3.5, reason: eingabe);
      }

      await _tippe(tester, '1.000');
      expect(satz.gueltig, isFalse, reason: 'frueher still 1 kg');
      expect(satz.wert, 3.5, reason: 'der letzte gueltige Wert bleibt');

      await _tippe(tester, '1.000,5');
      expect(satz.gueltig, isTrue);
      expect(satz.wert, 1000.5);
    });

    testWidgets('Wiederholungen [$code]: nur ganze Zahlen', (tester) async {
      final satz = await _pumpSatz(tester, locale, decimal: false);

      for (final (eingabe, _) in ganzzahlFaelle(l10n)) {
        await _tippe(tester, eingabe);
        expect(satz.gueltig, isFalse, reason: eingabe);
        expect(satz.wert, isNull, reason: '$eingabe wurde nie gemeldet');
      }
      await _tippe(tester, '12');
      expect(satz.gueltig, isTrue);
      expect(satz.wert, 12);
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
