import 'dart:async';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'support/harness.dart';

final _date = DateTime(2026, 9, 8, 12);

CoachTrainingProposal _proposal({String title = 'Kraft und Beweglichkeit'}) =>
    CoachTrainingProposal(
      title: title,
      description: 'Zwei Einheiten mit Kurzhanteln und eigenem Körpergewicht.',
      goal: 'Kraft aufbauen',
      workouts: [
        TrainingWorkout(
          title: 'Ganzkörper',
          exercises: [
            TrainingExercise(
              name: 'Kniebeuge',
              sets: 3,
              reps: 10,
              restSeconds: 60,
            ),
            TrainingExercise(
              name: 'Unterarmstütz',
              sets: 2,
              durationSeconds: 30,
              restSeconds: 45,
              notes: 'Ruhig weiteratmen.',
            ),
          ],
        ),
        TrainingWorkout(
          title: 'Beweglichkeit',
          exercises: [
            TrainingExercise(
              name: 'Schulterkreisen',
              sets: 1,
              durationSeconds: 60,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );

ChatMessage _draftMessage() => ChatMessage(
  id: 'server-plan-1',
  role: ChatRole.assistant,
  content: 'Dein Trainingsplan.',
  createdAt: _date,
  trainingPlanProposal: _proposal(),
);

class _PlanCoach extends CoachChatService {
  _PlanCoach(SupabaseClient client) : super(client, 'user-a');

  static _PlanCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _PlanCoach(client);
  }

  final calls = <({String wish, String locale, String session})>[];
  List<ChatMessage> history = [];
  List<ChatMessage> fallbackHistory = [];
  CoachDataUnavailable? fallbackHistoryFailure;
  Completer<List<ChatSession>>? pendingSessionRefresh;
  Completer<List<ChatMessage>>? pendingFallbackHistory;
  int sessionLoads = 0;
  final historyLoads = <String>[];
  Completer<CoachPlanReply>? pending;
  CoachChatException? failure;
  bool refusal = false;

  @override
  Future<List<ChatSession>> loadSessions() async {
    sessionLoads++;
    if (sessionLoads > 1 && pendingSessionRefresh != null) {
      return pendingSessionRefresh!.future;
    }
    return sessionList;
  }

  List<ChatSession> get sessionList => [
    for (final id in ['a', 'b'])
      ChatSession(
        id: id,
        title: 'Chat $id',
        createdAt: _date,
        lastMessageAt: _date,
        messageCount: 0,
      ),
  ];

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    historyLoads.add(sessionId);
    if (sessionId == 'a') return history;
    if (fallbackHistoryFailure != null) throw fallbackHistoryFailure!;
    return pendingFallbackHistory?.future ?? fallbackHistory;
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachPlanReply> requestPlan(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    calls.add((wish: wish, locale: locale, session: sessionId));
    if (failure != null) throw failure!;
    return pending?.future ??
        CoachPlanReply(
          reply: refusal
              ? 'Dafür erstelle ich keinen Plan.'
              : 'Dein Trainingsplan.',
          refusal: refusal,
          proposal: _proposal(),
          sessionId: sessionId,
          assistantMessageId: 'server-plan-1',
          remaining: 4,
          dailyLimit: 5,
        );
  }
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(
  WidgetTester tester,
  _PlanCoach service, {
  Future<SyncDelivery> Function(TrainingPlan)? onCreate,
  Set<String> savedIds = const {},
  VoidCallback? onOpenTraining,
  Locale locale = const Locale('de'),
  double scale = 1,
  Size size = const Size(402, 820),
  int planDraftRequest = 0,
}) async {
  await pumpLocalized(
    tester,
    CoachChatScreen(
      service: service,
      onCreateTrainingPlan: onCreate,
      userTrainingPlanIds: savedIds,
      onOpenTraining: onOpenTraining,
      planDraftRequest: planDraftRequest,
    ),
    locale: locale,
    textScale: scale,
    surfaceSize: size,
    padding: const EdgeInsets.all(20),
    safeArea: false,
  );
  await _frames(tester);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await _frames(tester);
}

Future<void> _review(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('coach-plan-review'));
  await tester.ensureVisible(action);
  await tester.pump();
  await tester.tap(action);
  await _frames(tester);
}

Future<void> _confirm(WidgetTester tester) async {
  final action = find.text('Trainingsplan übernehmen');
  await tester.ensureVisible(action);
  await tester.tap(action);
  await _frames(tester);
}

Future<void> _selectSession(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await _frames(tester);
  await tester.tap(find.text('Chat $id'));
  await _frames(tester);
}

CoachPlanReply _remappedReply({String? assistantId}) => CoachPlanReply(
  reply: 'Dein Plan im Ersatzgespräch.',
  refusal: false,
  sessionId: 'b',
  assistantMessageId: assistantId,
  proposal: _proposal(),
  remaining: 4,
  dailyLimit: 5,
);

void main() {
  for (final historyUnavailable in [false, true]) {
    testWidgets(
      'Remapped ephemeral plan remains adoptable when history is ${historyUnavailable ? 'unavailable' : 'empty'}',
      (tester) async {
        final coach = _PlanCoach.create()
          ..pending = Completer<CoachPlanReply>();
        if (historyUnavailable) {
          coach.fallbackHistoryFailure = const CoachDataUnavailable('history');
        }
        final plans = <TrainingPlan>[];
        await _mount(
          tester,
          coach,
          onCreate: (plan) async {
            plans.add(plan);
            return SyncDelivery.delivered;
          },
        );
        await _send(tester, '/plan Zwei Tage');
        coach.pending!.complete(_remappedReply());
        await _frames(tester);
        expect(coach.historyLoads, ['a', 'b']);
        expect(find.byKey(const ValueKey('coach-plan-card')), findsOneWidget);
        if (historyUnavailable) {
          expect(
            find.text(
              tester
                  .element(find.byKey(const ValueKey('screen-coach')))
                  .l10n
                  .coachErrorHistoryUnavailable,
            ),
            findsOneWidget,
          );
        }
        expect(find.byKey(const ValueKey('coach-unsent-retry')), findsNothing);
        expect(plans, isEmpty);
        await _review(tester);
        await _confirm(tester);
        expect(plans.single.id, startsWith('coach_local-p-'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final alreadyInHistory in [false, true]) {
    testWidgets(
      'Remapped plan merges server ID without duplication (persisted: $alreadyInHistory)',
      (tester) async {
        final coach = _PlanCoach.create()
          ..pending = Completer<CoachPlanReply>()
          ..fallbackHistory = alreadyInHistory ? [_draftMessage()] : [];
        final plans = <TrainingPlan>[];
        await _mount(
          tester,
          coach,
          onCreate: (plan) async {
            plans.add(plan);
            return SyncDelivery.delivered;
          },
        );
        await _send(tester, '/plan Zwei Tage');
        coach.pending!.complete(_remappedReply(assistantId: 'server-plan-1'));
        await _frames(tester);
        expect(find.byKey(const ValueKey('coach-plan-card')), findsOneWidget);
        await _review(tester);
        await _confirm(tester);
        expect(plans.single.id, trainingPlanIdForMessage('server-plan-1'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Navigation during remap refresh never pulls the user back', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..pending = Completer<CoachPlanReply>();
    await _mount(tester, coach);
    await _send(tester, '/plan Zwei Tage');
    coach.pendingSessionRefresh = Completer<List<ChatSession>>();
    coach.pending!.complete(_remappedReply());
    await _frames(tester);
    await _selectSession(tester, 'b');
    await _selectSession(tester, 'a');
    coach.pendingSessionRefresh!.complete(coach.sessionList);
    await _frames(tester);
    expect(coach.historyLoads, ['a', 'b', 'a']);
    expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final whileLoadingHistory in [false, true]) {
    testWidgets(
      'Account replacement during remap ${whileLoadingHistory ? 'history' : 'refresh'} discards old answer',
      (tester) async {
        final coach = _PlanCoach.create()
          ..pending = Completer<CoachPlanReply>();
        await _mount(tester, coach);
        await _send(tester, '/plan Zwei Tage');
        if (whileLoadingHistory) {
          coach.pendingFallbackHistory = Completer<List<ChatMessage>>();
        } else {
          coach.pendingSessionRefresh = Completer<List<ChatSession>>();
        }
        coach.pending!.complete(_remappedReply());
        await _frames(tester);
        final other = _PlanCoach.create();
        await _mount(tester, other);
        // Returning to the same service instance must not revive its old request.
        await _mount(tester, coach);
        if (whileLoadingHistory) {
          coach.pendingFallbackHistory!.complete([_draftMessage()]);
        } else {
          coach.pendingSessionRefresh!.complete(coach.sessionList);
        }
        await _frames(tester);
        expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
        expect(other.historyLoads, isEmpty);
        if (!whileLoadingHistory) expect(coach.historyLoads, ['a']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Navigation during remap history discards old fallback history and draft',
    (tester) async {
      final coach = _PlanCoach.create()..pending = Completer<CoachPlanReply>();
      await _mount(tester, coach);
      await _send(tester, '/plan Zwei Tage');
      coach.pendingFallbackHistory = Completer<List<ChatMessage>>();
      coach.pending!.complete(_remappedReply());
      await _frames(tester);
      await _selectSession(tester, 'a');
      coach.pendingFallbackHistory!.complete([_draftMessage()]);
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
      expect(coach.historyLoads, ['a', 'b', 'a']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Command discovery filters prefixes and never sends on selection',
    (tester) async {
      final coach = _PlanCoach.create();
      await _mount(tester, coach);
      await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('coach-command-recipe')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('coach-command-plan')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('coach-input')), '/P');
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-command-recipe')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('coach-command-plan')));
      await _frames(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('coach-input')))
            .controller!
            .text,
        '/plan ',
      );
      expect(coach.calls, isEmpty);
      await _send(tester, '/plan');
      expect(coach.calls, isEmpty);
      expect(find.textContaining('Beschreibe nach /plan'), findsOneWidget);
    },
  );

  testWidgets('Plan request is localized and remains an unsaved draft', (
    tester,
  ) async {
    final coach = _PlanCoach.create();
    var saves = 0;
    await _mount(
      tester,
      coach,
      locale: const Locale('en'),
      onCreate: (_) async {
        saves++;
        return SyncDelivery.delivered;
      },
    );
    await _send(tester, '/PLAN\nZwei Tage mit Kurzhanteln');
    expect(coach.calls.single.wish, 'Zwei Tage mit Kurzhanteln');
    expect(coach.calls.single.locale, 'en');
    expect(find.text('Training plan · Draft'), findsOneWidget);
    expect(find.text('2 workout days · 3 exercises'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-plan-card')), findsOneWidget);
    expect(saves, 0);
  });

  testWidgets('Cancel review leaves the proposal without saving', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..history = [_draftMessage()];
    var saves = 0;
    await _mount(
      tester,
      coach,
      onCreate: (_) async {
        saves++;
        return SyncDelivery.delivered;
      },
    );
    await _review(tester);
    expect(find.text('Ganzkörper'), findsOneWidget);
    expect(find.text('Kniebeuge'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('training-editor-close')));
    await _frames(tester);
    expect(saves, 0);
    expect(find.byKey(const ValueKey('coach-plan-review')), findsOneWidget);
  });

  testWidgets('Confirmed adoption saves a stable ID once and opens Training', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..history = [_draftMessage()];
    final plans = <TrainingPlan>[];
    final ids = <String>{};
    var opens = 0;
    await _mount(
      tester,
      coach,
      savedIds: ids,
      onOpenTraining: () => opens++,
      onCreate: (plan) async {
        plans.add(plan);
        ids.add(plan.id);
        return SyncDelivery.queuedOffline;
      },
    );
    await _review(tester);
    expect(plans, isEmpty);
    await _confirm(tester);
    expect(plans, hasLength(1));
    expect(plans.single.id, trainingPlanIdForMessage('server-plan-1'));
    expect(find.byKey(const ValueKey('coach-plan-review')), findsNothing);
    expect(find.text('Übernommen'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('coach-plan-open-training')),
    );
    await tester.tap(find.byKey(const ValueKey('coach-plan-open-training')));
    expect(opens, 1);
    ids.clear();
    await _mount(
      tester,
      coach,
      savedIds: ids,
      onCreate: (_) async => SyncDelivery.delivered,
    );
    expect(find.byKey(const ValueKey('coach-plan-review')), findsOneWidget);
  });

  testWidgets(
    'Failed adoption stays in the sheet and permits an explicit retry',
    (tester) async {
      final coach = _PlanCoach.create()..history = [_draftMessage()];
      var attempts = 0;
      final ids = <String>{};
      await _mount(
        tester,
        coach,
        savedIds: ids,
        onCreate: (plan) async {
          attempts++;
          if (attempts == 1) throw StateError('private database detail');
          ids.add(plan.id);
          return SyncDelivery.delivered;
        },
      );
      await _review(tester);
      await _confirm(tester);
      expect(attempts, 1);
      expect(find.textContaining('private database detail'), findsNothing);
      expect(find.text('Trainingsplan übernehmen'), findsOneWidget);
      expect(find.text('Übernommen'), findsNothing);
      await _confirm(tester);
      expect(attempts, 2);
      expect(find.text('Übernommen'), findsOneWidget);
    },
  );

  testWidgets('A replacement account cannot adopt an older open review', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..history = [_draftMessage()];
    var oldWrites = 0;
    var newWrites = 0;
    await _mount(
      tester,
      coach,
      onCreate: (_) async {
        oldWrites++;
        return SyncDelivery.delivered;
      },
    );
    await _review(tester);
    await _mount(
      tester,
      _PlanCoach.create(),
      onCreate: (_) async {
        newWrites++;
        return SyncDelivery.delivered;
      },
    );
    await _confirm(tester);
    expect(oldWrites, 0);
    expect(newWrites, 0);
    expect(find.text('Trainingsplan übernehmen'), findsOneWidget);
  });

  testWidgets('Late generation is not shown in a different conversation', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..pending = Completer<CoachPlanReply>();
    await _mount(tester, coach);
    await _send(tester, '/plan Drei Tage');
    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await _frames(tester);
    await tester.tap(find.text('Chat b'));
    await _frames(tester);
    coach.pending!.complete(
      CoachPlanReply(
        reply: 'Plan aus Chat a',
        refusal: false,
        sessionId: 'a',
        proposal: _proposal(),
        remaining: 0,
        dailyLimit: 5,
      ),
    );
    await _frames(tester);
    expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
    expect(find.text('Plan aus Chat a'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('coach-input')))
          .enabled,
      isFalse,
    );
  });

  testWidgets(
    'A late save result cannot announce success in a replacement account',
    (tester) async {
      final coach = _PlanCoach.create()..history = [_draftMessage()];
      final pending = Completer<SyncDelivery>();
      var writes = 0;
      await _mount(
        tester,
        coach,
        onCreate: (_) {
          writes++;
          return pending.future;
        },
      );
      await _review(tester);
      await _confirm(tester);
      await _mount(tester, _PlanCoach.create());
      pending.complete(SyncDelivery.delivered);
      await _frames(tester);
      expect(writes, 1);
      expect(find.text('Trainingsplan übernehmen'), findsOneWidget);
      expect(find.textContaining('Trainingsplan gespeichert'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A malformed historical message ID cannot crash or save a plan', (
    tester,
  ) async {
    final coach = _PlanCoach.create()
      ..history = [
        ChatMessage(
          id: '../invalid',
          role: ChatRole.assistant,
          content: '',
          createdAt: _date,
          trainingPlanProposal: _proposal(),
        ),
      ];
    var writes = 0;
    await _mount(
      tester,
      coach,
      onCreate: (_) async {
        writes++;
        return SyncDelivery.delivered;
      },
    );
    await _review(tester);
    expect(find.byKey(const ValueKey('training-editor-save')), findsNothing);
    expect(writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Refusals never show an adoptable plan', (tester) async {
    final coach = _PlanCoach.create()..refusal = true;
    await _mount(tester, coach);
    await _send(tester, '/plan Ungeeigneter Wunsch');
    expect(find.byKey(const ValueKey('coach-plan-card')), findsNothing);
    expect(find.text('Dafür erstelle ich keinen Plan.'), findsOneWidget);
  });

  testWidgets('Edits are applied only when the user confirms adoption', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..history = [_draftMessage()];
    final plans = <TrainingPlan>[];
    await _mount(
      tester,
      coach,
      onCreate: (plan) async {
        plans.add(plan);
        return SyncDelivery.delivered;
      },
    );
    await _review(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('training-editor-edit')),
    );
    await tester.tap(find.byKey(const ValueKey('training-editor-edit')));
    await _frames(tester);
    await tester.enterText(
      find.byKey(const ValueKey('training-editor-title')),
      'Mein persönlicher Plan',
    );
    expect(plans, isEmpty);
    await _confirm(tester);
    expect(plans.single.title, 'Mein persönlicher Plan');
    expect(plans.single.workouts, hasLength(2));
    expect(plans.single.id, trainingPlanIdForMessage('server-plan-1'));
  });

  testWidgets('An in-flight adoption blocks repeated save and dismissal', (
    tester,
  ) async {
    final coach = _PlanCoach.create()..history = [_draftMessage()];
    final result = Completer<SyncDelivery>();
    var saves = 0;
    await _mount(
      tester,
      coach,
      onCreate: (_) {
        saves++;
        return result.future;
      },
    );
    await _review(tester);
    await _confirm(tester);
    await tester.tap(find.byKey(const ValueKey('training-editor-save')));
    await _frames(tester);
    expect(saves, 1);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('training-editor-close')),
          )
          .onPressed,
      isNull,
    );
    result.complete(SyncDelivery.delivered);
    await _frames(tester);
    expect(saves, 1);
  });

  testWidgets(
    'Failed generation retries the plan and preserves an unrelated draft',
    (tester) async {
      final coach = _PlanCoach.create()
        ..failure = const CoachChatException('Verbindung unterbrochen');
      await _mount(tester, coach);
      await _send(tester, '/plan Drei Tage');
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Noch eine Frage',
      );
      coach.failure = null;
      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await _frames(tester);
      expect(coach.calls, hasLength(2));
      expect(coach.calls.last.wish, 'Drei Tage');
      expect(find.text('/plan Drei Tage'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('coach-input')))
            .controller!
            .text,
        'Noch eine Frage',
      );
    },
  );

  testWidgets(
    'A plan finishing after disposal does not write or update disposed notifiers',
    (tester) async {
      final coach = _PlanCoach.create()..pending = Completer<CoachPlanReply>();
      var saves = 0;
      await _mount(
        tester,
        coach,
        onCreate: (_) async {
          saves++;
          return SyncDelivery.delivered;
        },
      );
      await _send(tester, '/plan Drei Tage');
      await tester.pumpWidget(const SizedBox());
      coach.pending!.complete(
        CoachPlanReply(
          reply: 'Plan',
          refusal: false,
          sessionId: 'a',
          proposal: _proposal(),
        ),
      );
      await _frames(tester);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Both commands remain usable on a short screen with large text', (
    tester,
  ) async {
    final errors = await collectOverflows(() async {
      await _mount(
        tester,
        _PlanCoach.create(),
        scale: 2,
        size: const Size(320, 568),
      );
      await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
      await _frames(tester);
      final plan = find.text('/plan');
      await tester.ensureVisible(plan);
      await tester.pump();
      await tester.tap(plan);
      await _frames(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('coach-input')))
            .controller!
            .text,
        '/plan ',
      );
    });
    expect(errors, isEmpty, reason: describeOverflows(errors));
  });

  testWidgets('Training entry prepares the command without consuming quota', (
    tester,
  ) async {
    final coach = _PlanCoach.create();
    await _mount(tester, coach, planDraftRequest: 1);
    expect(coach.calls, isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('coach-input')))
          .controller!
          .text,
      '/plan ',
    );
  });

  for (final locale in [const Locale('de'), const Locale('en')]) {
    testWidgets(
      'Plan card and review reflow at 320px with 2x text (${locale.languageCode})',
      (tester) async {
        final coach = _PlanCoach.create()..history = [_draftMessage()];
        final errors = await collectOverflows(() async {
          await _mount(
            tester,
            coach,
            locale: locale,
            scale: 2,
            size: const Size(320, 568),
            onCreate: (_) async => SyncDelivery.delivered,
          );
          await _review(tester);
          expect(find.text('Kniebeuge'), findsOneWidget);
        });
        expect(errors, isEmpty, reason: describeOverflows(errors));
      },
    );
  }
}
