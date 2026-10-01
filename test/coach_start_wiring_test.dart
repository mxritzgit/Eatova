// Wiring of the redesigned Coach tab (dark redesign, 2026-09-28): every
// control of the start state and the composer is TAPPED here and its real
// outcome asserted — sheet opened, question sent through the screen's send
// path, command prepared, nothing sent. Data-bound values (the "From today's
// log" card and the context status) are checked against their sources; the
// shell half (numbers follow the store) lives in
// test/flows/coach_start_shell_flow_test.dart.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_day_brief.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

/// The design phone (390 x 844) minus the shell's safe areas.
const Size _usableSize = Size(390, 797);

const String _context = 'App language of the user: en. Heute gegessen: …';

/// The design scenario: 902 kcal and 51 g protein left, dinner open.
const CoachDayBrief _designDay = CoachDayBrief(
  state: CoachDayState.underBudget,
  budgetKcal: 2123,
  remainingKcal: 902,
  proteinGoalG: 162,
  proteinLeftG: 51,
  mealSlot: MealSlot.dinner,
  mainMealAhead: true,
);

class _Coach extends CoachChatService {
  _Coach(super.client, super.userId);

  static _Coach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Coach(client, 'user-wiring');
  }

  ChatQuotaSnapshot quota = const ChatQuotaSnapshot(
    used: 0,
    remaining: 5,
    dailyLimit: 5,
  );
  final List<({String message, String? userContext})> sent = [];
  final List<String> recipeWishes = <String>[];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Evening plan',
      createdAt: DateTime(2026, 9, 28),
      lastMessageAt: DateTime(2026, 9, 28),
      messageCount: 0,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async => quota;

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sent.add((message: message, userContext: userContext));
    return CoachChatReply(
      reply: 'Grilled salmon with greens fits.',
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
    String? userContext,
  }) async {
    recipeWishes.add(wish);
    return CoachRecipeReply(
      reply: 'Recipe idea: salmon bowl.',
      refusal: false,
      proposal: const CoachRecipeProposal(
        title: 'Salmon bowl',
        description: 'Light and high in protein.',
        portion: '1 bowl',
        ingredients: '- 150 g salmon',
        preparation: '1. Cook the rice.',
        caloriesKcal: 540,
        proteinG: 42,
        carbsG: 48,
        fatG: 18,
        estimatedGrams: 420,
      ),
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }
}

Future<AppLocalizations> _pump(
  WidgetTester tester, {
  required _Coach? service,
  CoachDayBrief? dayBrief = _designDay,
  String? userContext = _context,
  Locale locale = const Locale('en'),
  double textScale = 1,
  Size size = _usableSize,
  List<FitnessRecipe>? created,
}) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = size * 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final context = await pumpLocalizedContext(
    tester,
    CoachChatScreen(
      service: service,
      userName: 'Moritz',
      dayBrief: dayBrief,
      userContext: userContext,
      onCreateRecipe: created == null
          ? null
          : (recipe) async {
              created.add(recipe);
              return SyncDelivery.delivered;
            },
    ),
    locale: locale,
    textScale: textScale,
    // Like the shell (eatova_home_page.dart): the coach tab owns its
    // gutters, so it gets the full width.
    padding: EdgeInsets.zero,
    safeArea: false,
    settle: true,
  );
  return context.l10n;
}

String _summary(WidgetTester tester) => tester
    .widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('coach-log-summary')),
        matching: find.byType(RichText),
      ),
    )
    .text
    .toPlainText();

Finder _inList(Finder matching) => find.descendant(
  of: find.byKey(const ValueKey('coach-message-list')),
  matching: matching,
);

/// Scrolls [target] into view first: the chip row and the start state scroll
/// (the test font is wider and taller than Figtree).
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('coach-input')))
    .controller!
    .text;

void main() {
  group('header', () {
    testWidgets('the history button opens the sessions sheet', (tester) async {
      final l10n = await _pump(tester, service: _Coach.create());
      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.coachSessionsTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-sessions-new')), findsOneWidget);
      expect(find.text('Evening plan'), findsOneWidget);
    });

    testWidgets('the info button opens the data-sharing sheet', (tester) async {
      final l10n = await _pump(tester, service: _Coach.create());
      await tester.tap(find.byKey(const ValueKey('coach-info')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
      expect(find.text(l10n.coachInfoDataLabel), findsOneWidget);
    });

    testWidgets('"Sees today\'s log" shows only while context is sent', (
      tester,
    ) async {
      final l10n = await _pump(tester, service: _Coach.create());
      expect(
        find.byKey(const ValueKey('coach-context-status')),
        findsOneWidget,
      );
      expect(find.text(l10n.coachStatusLine), findsOneWidget);

      await _pump(tester, service: _Coach.create(), userContext: null);
      expect(
        find.byKey(const ValueKey('coach-context-status')),
        findsNothing,
        reason: 'without diary context the claim would be false',
      );
    });

    testWidgets('title reads "Coach", screen readers hear "AI Coach"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final l10n = await _pump(tester, service: _Coach.create());
      expect(find.text(l10n.navCoach), findsOneWidget);
      expect(find.bySemanticsLabel(l10n.coachTitle), findsOneWidget);
      for (final key in ['coach-sessions-open', 'coach-info']) {
        final button = find.byKey(ValueKey(key));
        expect(tester.getSize(button), const Size(44, 44));
        expect(
          tester.getSemantics(button),
          isSemantics(isButton: true, hasTapAction: true),
        );
      }
      handle.dispose();
    });
  });

  group('"From today\'s log" card', () {
    testWidgets('shows the day\'s numbers bold, with the protein hint', (
      tester,
    ) async {
      await _pump(tester, service: _Coach.create());
      expect(
        _summary(tester),
        'You have 902 kcal and 51 g protein left. A lean dinner closes the '
        'protein gap without going over.',
      );
      final spans = <String>[];
      tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(const ValueKey('coach-log-summary')),
              matching: find.byType(RichText),
            ),
          )
          .text
          .visitChildren((span) {
            if (span is TextSpan &&
                span.style?.fontWeight == FontWeight.w700 &&
                span.text != null) {
              spans.add(span.text!);
            }
            return true;
          });
      expect(spans, <String>['902 kcal', '51 g protein']);
    });

    testWidgets('the primary pill sends the meal question through the real '
        'send path and opens the chat', (tester) async {
      final svc = _Coach.create();
      final l10n = await _pump(tester, service: svc);
      final prompt = l10n.coachLogPromptSuggestMeal('dinner');
      expect(find.text(l10n.coachLogSuggestMeal('dinner')), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('coach-log-primary')));

      expect(svc.sent, hasLength(1));
      expect(svc.sent.single.message, prompt);
      expect(
        svc.sent.single.message,
        'Suggest a dinner that fits the rest '
        'of my day.',
      );
      expect(
        svc.sent.single.userContext,
        _context,
        reason: 'a prepared question carries the day like a typed one',
      );
      // Start state gone, the exchange is in the chat.
      expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
      expect(_inList(find.text(prompt)), findsOneWidget);
      expect(
        _inList(find.text('Grilled salmon with greens fits.')),
        findsOneWidget,
      );
    });

    testWidgets('the secondary pill sends "plan tomorrow"', (tester) async {
      final svc = _Coach.create();
      final l10n = await _pump(tester, service: svc);
      await _tap(tester, find.byKey(const ValueKey('coach-log-secondary')));
      expect(svc.sent.single.message, l10n.coachLogPromptPlanTomorrow);
      expect(
        _inList(find.text(l10n.coachLogPromptPlanTomorrow)),
        findsOneWidget,
      );
    });

    testWidgets('a draft typed before tapping a pill survives', (tester) async {
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'my own question',
      );
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('coach-log-primary')));
      expect(svc.sent, hasLength(1));
      expect(_field(tester), 'my own question');
    });

    testWidgets('pills and chips are disabled while the quota is used up', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final svc = _Coach.create()
        ..quota = const ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5);
      await _pump(tester, service: svc);
      for (final key in [
        'coach-log-primary',
        'coach-log-secondary',
        'coach-try-recipe',
        'coach-try-plan',
      ]) {
        expect(
          tester.getSemantics(find.byKey(ValueKey(key))),
          isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
          reason: key,
        );
        await _tap(tester, find.byKey(ValueKey(key)));
      }
      expect(svc.sent, isEmpty);
      expect(_field(tester), isEmpty);
      expect(find.byKey(const ValueKey('coach-brief-submit')), findsNothing);
      handle.dispose();
    });

    testWidgets('pills are real 44 px buttons with their label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final l10n = await _pump(tester, service: _Coach.create());
      for (final (key, label) in [
        ('coach-log-primary', l10n.coachLogSuggestMeal('dinner')),
        ('coach-log-secondary', l10n.coachLogPlanTomorrow),
      ]) {
        final pill = find.byKey(ValueKey(key));
        expect(tester.getSize(pill).height, greaterThanOrEqualTo(44));
        expect(
          tester.getSemantics(pill),
          isSemantics(
            label: label,
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
      }
      handle.dispose();
    });

    for (final (name, brief, text, primary, secondary)
        in <(String, CoachDayBrief, String, String, String?)>[
          (
            'nothing logged',
            const CoachDayBrief(
              state: CoachDayState.nothingLogged,
              budgetKcal: 2123,
              remainingKcal: 2123,
              proteinGoalG: 162,
              proteinLeftG: 162,
              mealSlot: MealSlot.breakfast,
              mainMealAhead: true,
            ),
            'Nothing logged yet today. Your budget is 2,123 kcal with 162 g '
                'protein.',
            'Suggest a breakfast',
            'Plan my day',
          ),
          (
            'protein goal met',
            const CoachDayBrief(
              state: CoachDayState.underBudget,
              budgetKcal: 2123,
              remainingKcal: 400,
              proteinGoalG: 162,
              proteinLeftG: 0,
              mealSlot: MealSlot.dinner,
              mainMealAhead: true,
            ),
            'You have 400 kcal left and your protein goal is met.',
            'Suggest a dinner',
            'Plan tomorrow',
          ),
          (
            'exactly on budget',
            const CoachDayBrief(
              state: CoachDayState.atBudget,
              budgetKcal: 2123,
              remainingKcal: 0,
              proteinGoalG: 162,
              proteinLeftG: 0,
              mealSlot: MealSlot.snack,
              mainMealAhead: false,
            ),
            "You've reached today's budget.",
            'Plan tomorrow',
            null,
          ),
          (
            'over budget',
            const CoachDayBrief(
              state: CoachDayState.overBudget,
              budgetKcal: 2123,
              remainingKcal: -1200,
              proteinGoalG: 162,
              proteinLeftG: 32,
              mealSlot: MealSlot.snack,
              mainMealAhead: false,
            ),
            "You're 1,200 kcal over today's budget. Still open: 32 g protein.",
            'Plan tomorrow',
            null,
          ),
        ]) {
      testWidgets('$name: honest sentence and matching pills', (tester) async {
        final svc = _Coach.create();
        await _pump(tester, service: svc, dayBrief: brief);
        expect(_summary(tester), text);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('coach-log-primary')),
            matching: find.text(primary),
          ),
          findsOneWidget,
        );
        if (secondary == null) {
          expect(
            find.byKey(const ValueKey('coach-log-secondary')),
            findsNothing,
          );
        } else {
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('coach-log-secondary')),
              matching: find.text(secondary),
            ),
            findsOneWidget,
          );
        }
      });
    }

    testWidgets('German: natural sentence, grouped thousands', (tester) async {
      await _pump(
        tester,
        service: _Coach.create(),
        locale: const Locale('de'),
        dayBrief: const CoachDayBrief(
          state: CoachDayState.nothingLogged,
          budgetKcal: 2123,
          remainingKcal: 2123,
          proteinGoalG: 162,
          proteinLeftG: 162,
          mealSlot: MealSlot.lunch,
          mainMealAhead: true,
        ),
      );
      expect(
        _summary(tester),
        'Heute ist noch nichts geloggt. Dein Budget: 2.123 kcal und 162 g '
        'Protein.',
      );
      expect(find.text('Mittagessen vorschlagen'), findsOneWidget);
      expect(find.text('Tag planen'), findsOneWidget);
    });

    testWidgets('without day numbers the card stays away', (tester) async {
      final l10n = await _pump(
        tester,
        service: _Coach.create(),
        dayBrief: null,
      );
      expect(find.byKey(const ValueKey('coach-log-card')), findsNothing);
      expect(find.text(l10n.coachHeroSubtitle), findsOneWidget);
    });
  });

  group('"Try asking" chips', () {
    testWidgets('the recipe chip prepares /recipe and sends nothing', (
      tester,
    ) async {
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      await _tap(tester, find.byKey(const ValueKey('coach-try-recipe')));
      expect(_field(tester), '/recipe ');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('coach-input')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(svc.sent, isEmpty);
      expect(svc.recipeWishes, isEmpty);
    });

    testWidgets('the plan chip opens the training brief and sends nothing', (
      tester,
    ) async {
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      await _tap(tester, find.byKey(const ValueKey('coach-try-plan')));
      expect(find.byKey(const ValueKey('coach-brief-submit')), findsOneWidget);
      expect(svc.sent, isEmpty);
    });

    testWidgets('the chip row takes taps and drags up to the screen edge', (
      tester,
    ) async {
      // The row runs past the content inset to the screen edge (design).
      // Every visible pixel of it must be live, not only the part inside
      // the 20 px inset.
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      final row = find.byKey(const ValueKey('coach-try-row'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final screenWidth = tester.getSize(find.byType(CoachChatScreen)).width;
      expect(
        screenWidth,
        _usableSize.width,
        reason: 'the tab owns the full width',
      );
      final plan = tester.getRect(find.byKey(const ValueKey('coach-try-plan')));
      expect(
        plan.right,
        greaterThan(screenWidth),
        reason: 'precondition: the second chip runs off the edge',
      );
      // 3 px from the edge: 17 px outside the old slot's reach.
      final edge = Offset(screenWidth - 3, plan.center.dy);
      expect(edge.dx, greaterThan(screenWidth - 20));

      final position = tester
          .state<ScrollableState>(
            find.descendant(of: row, matching: find.byType(Scrollable)),
          )
          .position;
      await tester.dragFrom(edge, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(
        position.pixels,
        greaterThan(0),
        reason: 'a drag from the edge scrolls the row',
      );
      position.jumpTo(0);
      await tester.pumpAndSettle();

      await tester.tapAt(edge);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('coach-brief-submit')),
        findsOneWidget,
        reason: 'the visible right end of the chip opens the brief',
      );
      expect(svc.sent, isEmpty);
    });

    testWidgets('recipe from the chip: the card writes nothing until the '
        'sheet is confirmed', (tester) async {
      final svc = _Coach.create();
      final created = <FitnessRecipe>[];
      final l10n = await _pump(tester, service: svc, created: created);
      await _tap(tester, find.byKey(const ValueKey('coach-try-recipe')));
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        '/recipe salmon bowl',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pumpAndSettle();

      expect(svc.recipeWishes, <String>['salmon bowl']);
      expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
      expect(created, isEmpty, reason: 'a proposal alone writes nothing');

      await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);
      expect(created, isEmpty, reason: 'opening the sheet writes nothing');
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      expect(created, isEmpty, reason: 'cancel writes nothing');

      await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('coach-recipe-sheet-confirm')),
      );
      await tester.tap(
        find.byKey(const ValueKey('coach-recipe-sheet-confirm')),
      );
      await tester.pumpAndSettle();
      expect(created, hasLength(1));
      expect(created.single.title, 'Salmon bowl');
    });
  });

  group('disclaimer', () {
    testWidgets('"What\'s shared" opens the data-sharing sheet', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final l10n = await _pump(tester, service: _Coach.create());
      final note = find.byKey(const ValueKey('coach-ai-note'));
      expect(find.textContaining(l10n.coachDisclaimer), findsOneWidget);
      expect(tester.getSize(note).height, greaterThanOrEqualTo(44));
      expect(
        tester.getSemantics(note),
        isSemantics(isLink: true, hasTapAction: true),
      );
      await _tap(tester, note);
      expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
      handle.dispose();
    });
  });

  group('composer', () {
    // "+" opening the attach sheet: coach_design_test.dart ('Attach-Sheet
    // schliesst sich selbst'), which also checks the pop.
    testWidgets('send is disabled while the field is empty', (tester) async {
      final handle = tester.ensureSemantics();
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      final send = find.byKey(const ValueKey('coach-send'));
      expect(
        tester.getSemantics(send),
        isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
      );
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(svc.sent, isEmpty);
      expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('typing and send posts the message and opens the chat', (
      tester,
    ) async {
      final svc = _Coach.create();
      await _pump(tester, service: svc);
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'How much protein is left?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pumpAndSettle();
      expect(svc.sent.single.message, 'How much protein is left?');
      expect(_inList(find.text('How much protein is left?')), findsOneWidget);
      expect(_field(tester), isEmpty);
    });

    testWidgets('capsule: 56 px, pill, no ring; 44 px controls', (
      tester,
    ) async {
      await _pump(tester, service: _Coach.create());
      final capsule = find.ancestor(
        of: find.byKey(const ValueKey('coach-input')),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(capsule.first).height, 56);
      final decoration =
          tester.widget<AnimatedContainer>(capsule.first).decoration!
              as BoxDecoration;
      expect(decoration.border, isNull, reason: 'inputs stay borderless');
      for (final key in ['coach-attach', 'coach-send']) {
        expect(tester.getSize(find.byKey(ValueKey(key))), const Size(44, 44));
      }
    });

    testWidgets('the mic appears only where speech input exists (iOS)', (
      tester,
    ) async {
      await _pump(tester, service: _Coach.create());
      expect(
        find.byKey(const ValueKey('coach-mic')),
        findsNothing,
        reason: 'the speech channel is implemented in the iOS runner only',
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await _pump(tester, service: _Coach.create());
        expect(find.byKey(const ValueKey('coach-mic')), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('layout', () {
    for (final (name, size, scale) in <(String, Size, double)>[
      ('390 px at 1.3x', _usableSize, 1.3),
      ('320 px at 1.0x', const Size(320, 521), 1.0),
      ('390 px at 2.0x', _usableSize, 2.0),
    ]) {
      testWidgets('start state has no overflow at $name', (tester) async {
        await _pump(
          tester,
          service: _Coach.create(),
          textScale: scale,
          size: size,
          locale: const Locale('de'),
        );
        expect(tester.takeException(), isNull);
        final primary = find.byKey(const ValueKey('coach-log-primary'));
        await tester.ensureVisible(primary);
        await tester.pumpAndSettle();
        expect(primary.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('while a question is in flight, a new chat shows the start '
        'state with every pill and chip disabled', (tester) async {
      // The one reachable way to see the start state mid-request: send from
      // the card, then open History and start a new conversation while the
      // answer is still pending (_startNewSession).
      final handle = tester.ensureSemantics();
      final gate = Completer<CoachChatReply>();
      final svc = _GatedCoach(gate);
      final l10n = await _pump(tester, service: svc);
      await _tap(tester, find.byKey(const ValueKey('coach-log-primary')));
      expect(svc.calls, 1);
      expect(find.byKey(const ValueKey('coach-empty')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
      await tester.pumpAndSettle();
      expect(svc.created, <String>[l10n.coachSessionDefaultTitle]);
      expect(
        find.byKey(const ValueKey('coach-empty')),
        findsOneWidget,
        reason: 'the new conversation opens on the start state',
      );

      const controls = <String>[
        'coach-log-primary',
        'coach-log-secondary',
        'coach-try-recipe',
        'coach-try-plan',
      ];
      for (final key in controls) {
        expect(
          tester.getSemantics(find.byKey(ValueKey(key))),
          isSemantics(isButton: true, isEnabled: false, hasEnabledState: true),
          reason: '$key must be off while the first question is in flight',
        );
        await _tap(tester, find.byKey(ValueKey(key)));
      }
      expect(svc.calls, 1, reason: 'no second question went out');
      expect(_field(tester), isEmpty, reason: '/recipe was not prepared');
      expect(
        find.byKey(const ValueKey('coach-brief-submit')),
        findsNothing,
        reason: 'the training brief did not open',
      );

      // Counter-check: once the first answer is in, the same controls work.
      gate.complete(
        const CoachChatReply(reply: 'ok', refusal: false, sessionId: 's1'),
      );
      await tester.pumpAndSettle();
      for (final key in controls) {
        expect(
          tester.getSemantics(find.byKey(ValueKey(key))),
          isSemantics(isButton: true, isEnabled: true, hasEnabledState: true),
          reason: key,
        );
      }
      handle.dispose();
    });
  });
}

/// A coach whose answer waits for [gate].
class _GatedCoach extends _Coach {
  _GatedCoach(this.gate)
    : super(
        SupabaseClient(
          'https://example.supabase.co',
          'test-anon-key',
          httpClient: MockClient((_) async => http.Response('[]', 200)),
        )..auth.stopAutoRefresh(),
        'user-gated',
      );

  final Completer<CoachChatReply> gate;
  int calls = 0;

  /// Titles of the sessions started through "New".
  final List<String> created = <String>[];

  @override
  Future<String?> createSession({required String title}) async {
    created.add(title);
    return 's${created.length + 1}';
  }

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    for (var i = created.length; i >= 1; i--)
      ChatSession(
        id: 's${i + 1}',
        title: created[i - 1],
        createdAt: DateTime(2026, 9, 28, 19),
        lastMessageAt: DateTime(2026, 9, 28, 19),
        messageCount: 0,
      ),
    ...await super.loadSessions(),
  ];

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) {
    calls++;
    return gate.future;
  }
}
