// Visual evidence for the Coach surfaces coach_redesign does not reach
// (light mode pass, 2026-10-04): the three proposal cards in a conversation,
// the recipe confirmation sheet, the training brief, the chat list sheet,
// the composer with a typed message and its command menu, and the (i)
// sheet.
//
//   coach-cards-recipe       /recipe card with an AI photo and its badge
//   coach-cards-recipe-sheet the confirmation sheet over the chat
//   coach-cards-recipe-noimage  a recipe card whose photo failed: the art
//   coach-cards-recipe-added    the same card once added: the done capsule
//   coach-cards-recipe-sheet-320-x2  the sheet at 320 px with 2x text
//   coach-cards-plan         a training plan proposal
//   coach-cards-log          a /log workout draft
//   coach-cards-brief        the training brief from "/plan" (no plan)
//   coach-cards-brief-goal   the same brief with an own goal typed
//   coach-cards-brief-de     the brief in German (the long labels)
//   coach-cards-sessions     the chat list sheet
//   coach-cards-sessions-empty  the chat list without a conversation
//   coach-cards-typing       the composer with text (send enabled)
//   coach-cards-commands     the "/" command menu above the composer
//   coach-cards-info         the (i) sheet: what the coach sees
//
// Shots are written only with DARK_REDESIGN_CAPTURE or
// DESIGN_CAPTURE_BRIGHTNESS; the normal pass checks that each surface shows.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/coach_workout_log.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/training_workout.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/recipes/recipe_photo.dart' show RecipeArt;

import '../flows/flow_test_helpers.dart' show settleFrames;
import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _at = DateTime(2026, 9, 28, 19);

ChatMessage _user(String id, String text) =>
    ChatMessage(id: id, role: ChatRole.user, content: text, createdAt: _at);

ChatMessage _recipeAnswer({bool image = true}) => ChatMessage(
  id: 'recipe-answer',
  role: ChatRole.assistant,
  content: 'Recipe proposal: Chicken curry with rice.',
  createdAt: _at,
  recipeProposal: CoachRecipeProposal(
    title: 'Chicken curry with rice',
    description: 'Creamy, mild and high in protein.',
    portion: '1 large plate',
    ingredients: '- 180 g chicken breast\n- 70 g basmati rice',
    preparation: '1. Cook the rice.\n2. Sear the chicken.',
    caloriesKcal: 610,
    proteinG: 52,
    carbsG: 64,
    fatG: 14,
    estimatedGrams: 450,
    imageBytes: image
        ? File('assets/recipes/hahnchen_curry_mit_reis.jpg').readAsBytesSync()
        : null,
  ),
);

ChatMessage _planAnswer() => ChatMessage(
  id: 'plan-answer',
  role: ChatRole.assistant,
  content: 'Your training plan.',
  createdAt: _at,
  trainingPlanProposal: CoachTrainingProposal(
    title: 'Strength and mobility',
    description: 'Two sessions with dumbbells and bodyweight.',
    goal: 'Build strength',
    workouts: [
      TrainingWorkout(
        title: 'Full body',
        exercises: [
          TrainingExercise(name: 'Squat', sets: 3, reps: 10, restSeconds: 60),
          TrainingExercise(
            name: 'Plank',
            sets: 2,
            durationSeconds: 30,
            restSeconds: 45,
          ),
        ],
      ),
      TrainingWorkout(
        title: 'Mobility',
        exercises: [
          TrainingExercise(
            name: 'Shoulder circles',
            sets: 1,
            durationSeconds: 60,
            restSeconds: 0,
          ),
        ],
      ),
    ],
  ),
);

ChatMessage _logAnswer() => ChatMessage(
  // A UUID: the card derives its history id from it, so Add is offered.
  id: '6f1d2a4e-8b3c-4d5e-9f60-7a8b9c0d1e2f',
  role: ChatRole.assistant,
  content: 'Workout draft.',
  createdAt: _at,
  workoutLogProposal: const CoachWorkoutLog(
    title: 'Upper Body Push',
    performedOn: '2026-09-28',
    durationMinutes: 50,
    exercises: [
      CoachWorkoutLogExercise(
        name: 'Bench press',
        kind: CoachWorkoutLogKind.reps,
        sets: [
          CoachWorkoutLogSet(reps: 8, weightKg: 80),
          CoachWorkoutLogSet(reps: 8, weightKg: 80),
          CoachWorkoutLogSet(reps: 6, weightKg: 75),
        ],
      ),
      CoachWorkoutLogExercise(
        name: 'Plank',
        kind: CoachWorkoutLogKind.timed,
        durationSeconds: 45,
        sets: [CoachWorkoutLogSet(), CoachWorkoutLogSet()],
      ),
    ],
  ),
);

class _HistoryCoach extends CoachChatService {
  _HistoryCoach(
    super.client,
    super.userId,
    this.history, {
    this.quotaKnown = true,
    this.noSessions = false,
  });

  static _HistoryCoach create(
    List<ChatMessage> history, {
    bool quotaKnown = true,
    bool noSessions = false,
  }) => _HistoryCoach(
    SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    )..auth.stopAutoRefresh(),
    'user-capture',
    history,
    quotaKnown: quotaKnown,
    noSessions: noSessions,
  );

  final List<ChatMessage> history;

  /// False fails the quota RPC, so the (i) sheet shows its number-free twin.
  final bool quotaKnown;

  /// The chat list comes back empty: the sheet's calm empty state.
  final bool noSessions;

  @override
  Future<List<ChatSession>> loadSessions() async => noSessions
      ? const <ChatSession>[]
      : <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Dinner ideas',
      createdAt: _at,
      lastMessageAt: _at,
      messageCount: history.length,
    ),
    ChatSession(
      id: 's2',
      title: 'Push day plan',
      createdAt: _at.subtract(const Duration(days: 2)),
      lastMessageAt: _at.subtract(const Duration(days: 2)),
      messageCount: 6,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => history;

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    if (!quotaKnown) throw const CoachDataUnavailable('capture: offline');
    return const ChatQuotaSnapshot(used: 1, remaining: 4, dailyLimit: 5);
  }
}

Future<void> _pumpCoach(
  WidgetTester tester,
  List<ChatMessage> history, {
  Locale locale = const Locale('en'),
  bool quotaKnown = true,
  bool noSessions = false,
  Set<String> userRecipeSlugs = const <String>{},
  double width = 390,
  double textScale = 1,
}) async {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        CoachChatScreen(
          service: _HistoryCoach.create(
            history,
            quotaKnown: quotaKnown,
            noSessions: noSessions,
          ),
          onCreateRecipe: (_) async => SyncDelivery.delivered,
          onCreateTrainingPlan: (_) async => SyncDelivery.delivered,
          onLogWorkout: (_) async => TrainingLogSaveOutcome.saved,
          trainingHistoryAuthoritative: true,
          userRecipeSlugs: userRecipeSlugs,
        ),
        locale: locale,
        safeArea: false,
        textScale: textScale,
      ),
    ),
  );
  await settleFrames(tester, rounds: 60);
  await precacheDesignImages(tester);
  await settleFrames(tester);
}

void main() {
  setUpAll(loadDesignFonts);

  testWidgets('recipe card and its confirmation sheet', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', '/recipe chicken curry'),
      _recipeAnswer(),
    ]);
    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-recipe-ai-badge')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-recipe');

    await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
    await settleFrames(tester);
    await precacheDesignImages(tester);
    expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-recipe-sheet');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recipe card without a photo, then added', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', '/recipe chicken curry'),
      _recipeAnswer(image: false),
    ]);
    final card = find.byKey(const ValueKey('coach-recipe-card'));
    // The recipes' glowing bowl, never the striped wireframe.
    expect(
      find.descendant(of: card, matching: find.byType(RecipeArt)),
      findsOneWidget,
    );
    expect(find.byType(ImagePlaceholder), findsNothing);
    await captureDesignShot(tester, 'coach-cards-recipe-noimage');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());

    // Once the recipe exists, the card locks into its done state.
    await _pumpCoach(
      tester,
      [_user('u1', '/recipe chicken curry'), _recipeAnswer(image: false)],
      userRecipeSlugs: {FitnessRecipe.coachProposalSlug('recipe-answer')},
    );
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing);
    expect(find.text('Added'), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-recipe-added');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recipe sheet at 320 px and 2x text', (tester) async {
    await _pumpCoach(
      tester,
      [_user('u1', '/recipe chicken curry'), _recipeAnswer()],
      width: 320,
      textScale: 2,
    );
    final add = find.byKey(const ValueKey('coach-recipe-add'));
    await tester.ensureVisible(add);
    await settleFrames(tester);
    await tester.tap(add);
    await settleFrames(tester);
    await precacheDesignImages(tester);
    final sheet = find.byKey(const ValueKey('coach-recipe-sheet'));
    expect(sheet, findsOneWidget);
    // The model's markers give way to the dots and the step badges.
    expect(find.text('180 g chicken breast'), findsOneWidget);
    expect(find.text('Sear the chicken.'), findsOneWidget);
    await tester.drag(sheet, const Offset(0, -420));
    await settleFrames(tester);
    await captureDesignShot(tester, 'coach-cards-recipe-sheet-320-x2');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('chat list without a conversation', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', 'Build me a plan for two days a week.'),
      _planAnswer(),
    ], noSessions: true);
    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('coach-sessions-empty')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-sessions-empty');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('training plan card', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', 'Build me a plan for two days a week.'),
      _planAnswer(),
    ]);
    expect(find.byKey(const ValueKey('coach-plan-card')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-plan');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('training brief from the plan command', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', 'Build me a plan for two days a week.'),
      _planAnswer(),
    ]);
    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await settleFrames(tester);
    await tester.tap(find.byKey(const ValueKey('coach-command-plan')));
    await settleFrames(tester);
    // No plan selected: nothing to choose but a new plan, the default goal
    // is a quick goal, and the action is on screen at once.
    expect(
      find.byKey(const ValueKey('coach-brief-intent-adapt')),
      findsNothing,
    );
    expect(
      tester
          .widget<FilterChipPill>(
            find.byKey(const ValueKey('coach-brief-goal-general')),
          )
          .selected,
      isTrue,
    );
    final submit = find.byKey(const ValueKey('coach-brief-submit'));
    expect(
      tester.widget<PrimaryActionButton>(submit).label,
      'Create plan draft',
    );
    expect(submit.hitTestable(), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-brief');

    // "Own goal" opens the goal field under the chips.
    final own = find.byKey(const ValueKey('coach-brief-goal-own'));
    await tester.ensureVisible(own);
    await settleFrames(tester);
    await tester.tap(own);
    await settleFrames(tester);
    await tester.enterText(
      find.byKey(const ValueKey('coach-brief-goal')),
      'Run a 10K in under an hour',
    );
    await settleFrames(tester);
    // The goal section at the top: chips, "Own goal" chosen, the field.
    await tester.ensureVisible(
      find.byKey(const ValueKey('coach-brief-goal-general')),
    );
    await settleFrames(tester);
    await captureDesignShot(tester, 'coach-cards-brief-goal');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('training brief in German: the long labels', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', 'Build me a plan for two days a week.'),
      _planAnswer(),
    ], locale: const Locale('de'));
    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await settleFrames(tester);
    await tester.tap(find.byKey(const ValueKey('coach-command-plan')));
    await settleFrames(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('coach-brief-experience-beginner')),
    );
    await settleFrames(tester);
    expect(
      tester
          .widget<PrimaryActionButton>(
            find.byKey(const ValueKey('coach-brief-submit')),
          )
          .label,
      'Planentwurf erstellen',
    );
    await captureDesignShot(tester, 'coach-cards-brief-de');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('workout log card, chat list and typing', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', '/log bench 3 sets, plank twice'),
      _logAnswer(),
    ]);
    expect(
      find.byKey(const ValueKey('coach-workout-log-card')),
      findsOneWidget,
    );
    await captureDesignShot(tester, 'coach-cards-log');

    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('coach-sessions-new')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-sessions');
    await tester.tapAt(const Offset(195, 120));
    await settleFrames(tester);

    await tester.enterText(
      find.byKey(const ValueKey('coach-input')),
      'Was that enough volume?',
    );
    await settleFrames(tester);
    await captureDesignShot(tester, 'coach-cards-typing');

    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('coach-command-menu')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-commands');
    await tester.enterText(find.byKey(const ValueKey('coach-input')), '');
    await settleFrames(tester);

    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
    await captureDesignShot(tester, 'coach-cards-info');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // The number-free twin after a failed quota RPC: same title and shell.
  testWidgets('info sheet without a quota', (tester) async {
    await _pumpCoach(tester, [
      _user('u1', '/log bench 3 sets, plank twice'),
      _logAnswer(),
    ], quotaKnown: false);
    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await settleFrames(tester);
    expect(
      find.byKey(const ValueKey('coach-info-limit-unbekannt')),
      findsOneWidget,
    );
    await captureDesignShot(tester, 'coach-cards-info-unknown');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
