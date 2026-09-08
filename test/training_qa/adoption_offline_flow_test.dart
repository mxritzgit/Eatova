import 'dart:async';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../outbox/outbox_test_helpers.dart' as h;
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

HomeStore _store(SupabaseClient client, LocalCache cache) => HomeStore(
  sync: EatovaSync.forUser(client, 'A'),
  debugCache: cache,
  health: const NoopHealthService(),
  notificationService: const NoopNotificationService(),
  initialUserName: 'QA',
  emitSnack: h.SnackCapture().call,
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  testWidgets(
    'preview cancellation, duplicate confirmation, delete/re-add and offline reboot',
    (tester) async {
      final raw = InMemoryKeyValueStore();
      late final SupabaseClient client;
      late final LocalCache cache;
      late final HomeStore store;
      await tester.runAsync(() async {
        client = SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient(
            (_) async => throw http.ClientException('CI offline'),
          ),
        );
        cache = LocalCache(raw, 'A');
        store = _store(client, cache);
        await cache.writeProfile(const UserProfile(onboardingCompleted: true));
        await h.bootUntilIdle(store);
      });
      final coach = _HistoryCoach(client, 'A');
      var disposed = false;
      addTearDown(() async {
        if (!disposed) store.dispose();
        await client.dispose();
      });
      var adoptions = 0;
      final saveGate = Completer<void>();
      final saves = <Future<SyncDelivery>>[];
      Future<SyncDelivery> adopt(TrainingPlan plan) {
        adoptions++;
        final save = saveGate.future.then((_) => store.saveTrainingPlan(plan));
        saves.add(save);
        return save;
      }

      await pumpLocalized(
        tester,
        ListenableBuilder(
          listenable: store,
          builder: (_, _) => CoachChatScreen(
            service: coach,
            onCreateTrainingPlan: adopt,
            userTrainingPlanIds: store.trainingPlans
                .map((plan) => plan.id)
                .toSet(),
          ),
        ),
        locale: const Locale('en'),
        surfaceSize: const Size(430, 900),
      );
      await _frames(tester);
      expect(store.trainingPlans, isEmpty);
      expect(store.pendingOutbox, isEmpty);
      await _tap(tester, 'coach-plan-review');
      expect(adoptions, 0);
      expect(store.pendingOutbox, isEmpty);
      await _tap(tester, 'training-editor-close');
      await tester.pumpAndSettle();
      expect(adoptions, 0);
      await _tap(tester, 'coach-plan-review');
      final saveButton = find.byKey(const ValueKey('training-editor-save'));
      await tester.ensureVisible(saveButton);
      await tester.pump();
      // Both gestures happen before a rebuild; the actual busy guard owns dedupe.
      await tester.tap(saveButton);
      await tester.tap(saveButton);
      expect(adoptions, 1);
      saveGate.complete();
      await _frames(tester);
      await tester.runAsync(() async {
        await Future.wait(saves);
      });
      await tester.pumpAndSettle();
      expect(adoptions, 1);
      expect(store.trainingPlans.single.id, 'coach_server-message-1');
      expect(store.pendingOutbox.single.trainingPlan?.title, 'Two sessions');

      await tester.runAsync(() async {
        await store.deleteTrainingPlan('coach_server-message-1');
      });
      await _frames(tester);
      expect(store.trainingPlans, isEmpty);
      await _tap(tester, 'coach-plan-review');
      await _tap(tester, 'training-editor-save');
      await tester.runAsync(() async {
        await Future.wait(saves);
      });
      await tester.pumpAndSettle();
      expect(adoptions, 2);
      expect(store.trainingPlans, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await cache.flush();
        await cache.settle();
        store.dispose();
        disposed = true;
        final reopenedCache = LocalCache(raw, 'A');
        final reboot = _store(client, reopenedCache);
        try {
          await h.bootUntilIdle(reboot);
          expect(reboot.trainingPlans.single.id, 'coach_server-message-1');
          expect(reboot.trainingPlans.single.title, 'Two sessions');
          expect(
            reboot.pendingOutbox.last.trainingPlan?.id,
            'coach_server-message-1',
          );
          final otherAccount = LocalCache(raw, 'B');
          expect(await otherAccount.readTrainingPlans(), isNull);
          expect(await otherAccount.readOutbox(), isNull);
          otherAccount.close();
        } finally {
          reboot.dispose();
        }
      });
    },
  );
}
