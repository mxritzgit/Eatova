import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

// Adopting a Coach recipe whose picture cannot be stored showed an error
// toast and, a moment later, the success toast — which removes the current
// one. Users read only "saved". Like the recipe form (T6), the adoption now
// reports both facts in ONE message.

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

CoachRecipeProposal _proposal({Uint8List? image}) => CoachRecipeProposal(
  title: 'Linsen-Bowl',
  description: 'Warm und sättigend.',
  portion: '1 Schale',
  ingredients: '- 120 g Linsen',
  preparation: '1. Linsen kochen.',
  caloriesKcal: 540,
  proteinG: 32,
  carbsG: 60,
  fatG: 14,
  estimatedGrams: 420,
  imageBytes: image,
);

class _History extends CoachChatService {
  _History(super.client, super.userId, this.history);

  factory _History.of(List<ChatMessage> history) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _History(client, 'user-1', history);
  }

  final List<ChatMessage> history;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat',
      createdAt: DateTime(2026, 9, 1),
      lastMessageAt: DateTime(2026, 9, 1),
      messageCount: history.length,
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
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

/// Stands in for a full disk or a missing documents folder.
class _NoSpace extends RecipeImageStore {
  @override
  Future<String?> save({required Uint8List bytes}) async => null;
}

class _Stored extends RecipeImageStore {
  @override
  Future<String?> save({required Uint8List bytes}) async =>
      '${RecipeImageStore.referencePrefix}photo.jpg';
}

Future<List<FitnessRecipe>> _adopt(
  WidgetTester tester, {
  required RecipeImageStore images,
  required CoachRecipeProposal proposal,
}) async {
  RecipeImageStore.instance = images;
  addTearDown(RecipeImageStore.resetInstance);
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final saved = <FitnessRecipe>[];
  final slugs = <String>{};
  await pumpLocalized(
    tester,
    CoachChatScreen(
      service: _History.of([
        ChatMessage(
          id: 'proposal-1',
          role: ChatRole.assistant,
          content: 'Rezeptvorschlag',
          createdAt: DateTime(2026, 9, 1),
          recipeProposal: proposal,
        ),
      ]),
      userName: 'Alex',
      onCreateRecipe: (recipe) async {
        saved.add(recipe);
        slugs.add(recipe.slug);
        return SyncDelivery.delivered;
      },
      userRecipeSlugs: slugs,
    ),
    // The coach tab owns its gutters (the shell passes no padding).
    padding: EdgeInsets.zero,
    safeArea: false,
    settle: true,
  );
  await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
  await tester.pumpAndSettle();
  final confirm = find.byKey(const ValueKey('coach-recipe-sheet-confirm'));
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  return saved;
}

void main() {
  testWidgets('fehlgeschlagenes Foto: eine Meldung nennt beides', (
    tester,
  ) async {
    final saved = await _adopt(
      tester,
      images: _NoSpace(),
      proposal: _proposal(image: _png),
    );
    final l10n = tester.element(find.byType(CoachChatScreen)).l10n;

    expect(saved.single.imageAsset, isEmpty, reason: 'Rezept ohne Bild');
    expect(
      find.text(
        deliveryHint(
          l10n.recipesSavedWithoutPhoto('Linsen-Bowl'),
          SyncDelivery.delivered,
          l10n,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        deliveryHint(
          l10n.recipesSavedSuccess('Linsen-Bowl'),
          SyncDelivery.delivered,
          l10n,
        ),
      ),
      findsNothing,
      reason: 'ein reines "gespeichert" verschweigt das verlorene Foto',
    );
  });

  testWidgets('gespeichertes Foto: die normale Erfolgsmeldung', (
    tester,
  ) async {
    final saved = await _adopt(
      tester,
      images: _Stored(),
      proposal: _proposal(image: _png),
    );
    final l10n = tester.element(find.byType(CoachChatScreen)).l10n;

    expect(saved.single.imageAsset, 'local:photo.jpg');
    expect(
      find.text(
        deliveryHint(
          l10n.recipesSavedSuccess('Linsen-Bowl'),
          SyncDelivery.delivered,
          l10n,
        ),
      ),
      findsOneWidget,
    );
  });
}
