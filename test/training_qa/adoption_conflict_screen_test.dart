import 'dart:async';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'fixtures.dart';

TrainingPlan _plan(String id) => TrainingPlan(
  id: id,
  proposal: CoachTrainingProposal.fromJson(trainingDraft())!,
);

Widget _screen({
  required List<TrainingPlan> plans,
  required TrainingPlan conflict,
  required Future<void> Function(TrainingPlan) review,
  Future<void> Function(TrainingPlan)? discard,
  VoidCallback? start,
  VoidCallback? update,
}) => TrainingScreen(
  plans: plans,
  selectedPlanId: plans.first.id,
  adoptionConflicts: [conflict],
  onReviewAdoption: review,
  onDiscardAdoption: discard,
  onCreatePlan: (_) async => SyncDelivery.delivered,
  onUpdatePlan: (_, _) async {
    update?.call();
    return SyncDelivery.delivered;
  },
  onSelectPlan: (_) async {},
  onDeletePlan: (_) async => SyncDelivery.delivered,
  onStartWorkout: (_, _) => start?.call(),
  onOpenCoach: () {},
);

void main() {
  testWidgets('an unselected conflict stays reachable and shares one review', (
    tester,
  ) async {
    final conflict = _plan('coach_message-1');
    final gate = Completer<void>();
    final reviewed = <TrainingPlan>[];
    await pumpLocalized(
      tester,
      _screen(
        plans: [_plan('another-plan'), conflict],
        conflict: conflict,
        review: (plan) async {
          reviewed.add(plan);
          await gate.future;
        },
      ),
    );
    final review = find.byKey(const ValueKey('training-review-adoption'));
    await tester.ensureVisible(review);
    await tester.pumpAndSettle();
    await tester.tap(review);
    await tester.tap(review);
    await tester.pump();
    expect(reviewed.map((plan) => plan.toJson()), [conflict.toJson()]);
    expect(tester.widget<TextButton>(review).onPressed, isNull);
    expect(find.byKey(const ValueKey('training-start')), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(review).onPressed, isNotNull);
  });

  for (final locale in [const Locale('de'), const Locale('en')]) {
    testWidgets(
      'conflict review preserves the draft on cancel in ${locale.languageCode}',
      (tester) async {
        final conflict = _plan('coach_message-1');
        var starts = 0;
        var updates = 0;
        var confirmations = 0;
        await pumpLocalized(
          tester,
          _screen(
            plans: [conflict],
            conflict: conflict,
            start: () => starts++,
            update: () => updates++,
            discard: (_) async {},
            review: (plan) async {
              final context = tester.element(find.byType(TrainingScreen));
              await showTrainingPlanEditor(
                context,
                initialDraft: plan.proposal,
                explanation: context.l10n.trainingAdoptionReviewBody(
                  'Current remote plan',
                ),
                onSave: (_) async {
                  confirmations++;
                  return SyncDelivery.delivered;
                },
              );
            },
          ),
          locale: locale,
          surfaceSize: const Size(320, 568),
          textScale: 2,
        );
        expect(find.byKey(const ValueKey('training-start')), findsNothing);
        final review = find.byKey(const ValueKey('training-review-adoption'));
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.textContaining('Current remote plan'), findsOneWidget);
        expect(find.text(conflict.title), findsWidgets);
        expect(confirmations, 0);
        await tester.tap(find.byKey(const ValueKey('training-editor-close')));
        await tester.pumpAndSettle();
        expect(confirmations, 0);
        expect(starts, 0);
        expect(updates, 0);
        expect(
          find.byKey(const ValueKey('training-review-adoption')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
