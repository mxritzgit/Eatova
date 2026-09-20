import 'dart:convert';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import 'fixtures.dart';

class _HistoryCoach extends CoachChatService {
  _HistoryCoach(super.client, super.userId);

  @override
  Future<List<ChatSession>> loadSessions() async => [
    ChatSession(
      id: 'session-A',
      title: 'A',
      createdAt: DateTime.utc(2026, 9, 8),
      lastMessageAt: DateTime.utc(2026, 9, 8),
      messageCount: 1,
    ),
  ];

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => [ChatMessage.fromRow(trainingMessage())];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester tester, Future<Object?> operation) async {
  var done = false;
  final completion = operation.whenComplete(() => done = true);
  for (var frame = 0; frame < 100 && !done; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done, isTrue, reason: 'The confirmed operation must finish');
  await completion;
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the same Coach proposal can be adopted again after an online delete',
    (tester) async {
      late FixlaufSetup setup;
      await tester.runAsync(() async {
        setup = fixlaufSetup();
        setup.server.profileRow = serverProfileRow(completedProfile);
        await setup.cache!.writeProfile(completedProfile);
        await bootStore(setup.store);
      });
      final coach = _HistoryCoach(setup.store.sync!.client, kFixlaufUser);
      final adopted = <TrainingPlan>[];
      final saves = <Future<SyncDelivery>>[];
      await pumpLocalized(
        tester,
        ListenableBuilder(
          listenable: setup.store,
          builder: (_, _) => CoachChatScreen(
            service: coach,
            userTrainingPlanIds: setup.store.trainingPlans
                .map((p) => p.id)
                .toSet(),
            userTrainingPlanSourceIds: {
              for (final plan in setup.store.trainingPlans)
                if (plan.coachSourceId case final sourceId?) sourceId,
            },
            onCreateTrainingPlan: (plan) {
              adopted.add(plan);
              final save = setup.store.adoptTrainingPlan(plan);
              saves.add(save);
              return save;
            },
          ),
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(430, 900),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'coach-plan-review');
      await _tap(tester, 'training-editor-save');
      await _finish(tester, saves.last);
      expect(setup.server.trainingRows, hasLength(1));
      final originalId = setup.store.trainingPlans.single.id;
      final originalIncarnation = setup.store.trainingPlans.single.incarnation;
      final originalRequest = setup.server.requests
          .where(
            (request) => request.url.path.endsWith('/rpc/apply_sync_operation'),
          )
          .map(
            (request) =>
                (jsonDecode(request.body) as Map).cast<String, dynamic>(),
          )
          .firstWhere((body) => body['p_kind'] == 'trainingPlanUpsert');

      await _finish(tester, setup.store.deleteTrainingPlan(originalId));
      expect(setup.server.trainingRows, isEmpty);
      expect(setup.store.trainingPlans, isEmpty);
      await _tap(tester, 'coach-plan-review');
      await _tap(tester, 'training-editor-save');
      await _finish(tester, saves.last);

      expect(
        setup.server.trainingRows,
        hasLength(1),
        reason: 'A new explicit confirmation must create a usable plan',
      );
      expect(setup.store.trainingPlans, hasLength(1));
      expect(adopted.last.id, originalId);
      final currentIncarnation = setup.store.trainingPlans.single.incarnation;
      expect(
        currentIncarnation,
        greaterThan(originalIncarnation),
        reason: 'The deleted incarnation remains retired',
      );
      expect(find.byKey(const ValueKey('coach-plan-review')), findsNothing);
      await _finish(
        tester,
        setup.store.sync!.client.rpc(
          'apply_sync_operation',
          params: originalRequest,
        ),
      );
      expect(
        setup.server.trainingRows.keys,
        [adopted.last.id],
        reason:
            'An old receipt replay must not resurrect the deleted incarnation',
      );
      expect(
        setup.server.trainingRows.values.single['incarnation'],
        currentIncarnation,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
