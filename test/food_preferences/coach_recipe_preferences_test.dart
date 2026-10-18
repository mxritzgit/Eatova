// /recipe and the user's food preferences (C3): the narrow `preferences`
// field instead of the whole app context (P5-02 stays), its wire form, the
// screen passing it on, and no content in error reports.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';

import '../support/harness.dart';

const FoodPreferences _vegan = FoodPreferences(
  diet: DietPreference.vegan,
  avoidances: <FoodAvoidance>{FoodAvoidance.nuts, FoodAvoidance.lactose},
  dislikes: 'Koriander',
);

const Map<String, Object> _recipeBody = <String, Object>{
  'reply': 'Rezeptvorschlag: Tofu-Curry.',
  'recipe': <String, Object>{
    'title': 'Tofu-Curry',
    'description': 'Pflanzlich.',
    'portion': '1 Schale',
    'ingredients': '- 200 g Tofu',
    'preparation': '1. Kochen.',
    'calories_kcal': 600,
    'protein_g': 30,
    'carbs_g': 60,
    'fat_g': 20,
    'estimated_g': 450,
  },
  'session_id': 's1',
};

/// A service over a mock HTTP client; [bodies] collects every function body.
CoachChatService _service(
  List<Map<String, dynamic>> bodies, {
  int status = 200,
  Object body = _recipeBody,
}) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/functions/v1/coach-chat')) {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return http.Response(
        jsonEncode(body),
        status,
        headers: const {'Content-Type': 'application/json'},
      );
    }),
  );
  addTearDown(client.dispose);
  return CoachChatService(client, 'user-123');
}

void main() {
  group('wire form', () {
    test('only what is set, codes in display order', () {
      expect(recipePreferencesPayload(_vegan), <String, Object>{
        'diet': 'vegan',
        'avoid': <String>['lactose', 'nuts'],
        'dislikes': 'Koriander',
      });
      expect(
        recipePreferencesPayload(
          const FoodPreferences(avoidances: <FoodAvoidance>{FoodAvoidance.egg}),
        ),
        <String, Object>{
          'avoid': <String>['egg'],
        },
      );
      expect(recipePreferencesPayload(const FoodPreferences()), isEmpty);
    });

    test(
      'with preferences: the field travels, the app context does not',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final svc = _service(bodies);
        final reply = await svc.requestRecipeWithPreferences(
          'Curry',
          sessionId: 's1',
          locale: 'de',
          preferences: _vegan,
        );
        expect(reply.proposal?.title, 'Tofu-Curry');
        final body = bodies.single;
        expect(body['mode'], 'recipe');
        expect(body['preferences'], <String, Object>{
          'diet': 'vegan',
          'avoid': <String>['lactose', 'nuts'],
          'dislikes': 'Koriander',
        });
        expect(body.containsKey('user_context'), isFalse, reason: 'P5-02');
      },
    );

    test(
      'without preferences, or with nothing set, there is no field',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final svc = _service(bodies);
        await svc.requestRecipe('Curry', sessionId: 's1', locale: 'de');
        await svc.requestRecipeWithPreferences(
          'Curry',
          sessionId: 's1',
          locale: 'de',
          preferences: const FoodPreferences(),
        );
        expect(bodies, hasLength(2));
        for (final body in bodies) {
          expect(body.containsKey('preferences'), isFalse);
          expect(body.containsKey('user_context'), isFalse);
        }
      },
    );

    test('a rejected field is reported without its content', () async {
      final reports = <String>[];
      CrashReporter.debugSentrySink = (error, stack, context) =>
          reports.add('$context $error');
      addTearDown(() => CrashReporter.debugSentrySink = null);
      final svc = _service(
        <Map<String, dynamic>>[],
        status: 400,
        body: const <String, Object>{'error': 'invalid_preferences'},
      );
      await expectLater(
        svc.requestRecipeWithPreferences(
          'Curry',
          sessionId: 's1',
          locale: 'de',
          preferences: _vegan,
        ),
        throwsA(isA<CoachChatException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(reports, isNotEmpty);
      for (final report in reports) {
        expect(report, isNot(contains('Koriander')));
        expect(report, isNot(contains('lactose')));
        expect(report, isNot(contains('vegan')));
      }
    });
  });

  group('the screen hands the preferences to /recipe only', () {
    Future<_PrefsCoach> pump(
      WidgetTester tester, {
      FoodPreferences? preferences,
    }) async {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(402, 781) * 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final svc = _PrefsCoach.create();
      await pumpLocalized(
        tester,
        CoachChatScreen(
          service: svc,
          userName: 'Moritz',
          userContext: 'App language of the user: de.',
          recipePreferences: preferences,
        ),
        padding: EdgeInsets.zero,
        safeArea: false,
        settle: true,
      );
      return svc;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await tester.pumpAndSettle();
    }

    testWidgets('with preferences set', (tester) async {
      final svc = await pump(tester, preferences: _vegan);
      await type(tester, '/recipe Curry');
      expect(svc.withPreferences, <FoodPreferences>[_vegan]);
      expect(svc.plainRecipes, 0);
      expect(find.text('Tofu-Curry'), findsWidgets);

      await type(tester, 'Wie viel Protein fehlt mir?');
      expect(svc.chatContexts, <String?>[
        'App language of the user: de.',
      ], reason: 'the chat keeps its context, /recipe never gets it');
    });

    testWidgets('without preferences: the plain request', (tester) async {
      final svc = await pump(tester);
      await type(tester, '/recipe Curry');
      expect(svc.plainRecipes, 1);
      expect(svc.withPreferences, isEmpty);
    });
  });
}

class _PrefsCoach extends CoachChatService {
  _PrefsCoach(super.client, super.userId);

  static _PrefsCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _PrefsCoach(client, 'user-123');
  }

  int plainRecipes = 0;
  final List<FoodPreferences> withPreferences = <FoodPreferences>[];
  final List<String?> chatContexts = <String?>[];

  CoachRecipeReply _reply(String sessionId) => CoachRecipeReply(
    reply: 'Rezeptvorschlag: Tofu-Curry.',
    refusal: false,
    proposal: CoachRecipeProposal.fromJson(
      _recipeBody['recipe']! as Map<String, Object>,
    ),
    remaining: 4,
    dailyLimit: 5,
    sessionId: sessionId,
  );

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    chatContexts.add(userContext);
    return CoachChatReply(
      reply: 'Antwort vom Coach.',
      refusal: false,
      sessionId: sessionId,
    );
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    plainRecipes++;
    return _reply(sessionId);
  }

  @override
  Future<CoachRecipeReply> requestRecipeWithPreferences(
    String wish, {
    required String sessionId,
    required String locale,
    required FoodPreferences preferences,
  }) async {
    withPreferences.add(preferences);
    return _reply(sessionId);
  }
}
