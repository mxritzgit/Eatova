import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

final _date = DateTime(2026, 9, 8, 12);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _proposal = CoachRecipeProposal(
  title: 'Rezept aus A',
  description: 'Ein Vorschlag.',
  portion: 'Eine Portion',
  ingredients: '100 g Reis',
  preparation: 'Reis kochen.',
  caloriesKcal: 350,
  proteinG: 10,
  carbsG: 60,
  fatG: 5,
  estimatedGrams: 250,
);

class _Coach extends CoachChatService {
  _Coach(SupabaseClient client) : super(client, 'user-a');

  static _Coach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Coach(client);
  }

  final sessions = <String>['a', 'b'];
  Completer<List<ChatMessage>>? pendingHistory;
  String pendingHistorySession = 'b';
  Completer<void>? pendingDelete;
  final pendingRecipe = Completer<CoachRecipeReply>();
  bool historyFails = false;
  bool recipeInHistory = false;
  int recipeCalls = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => [
    for (final id in sessions)
      ChatSession(
        id: id,
        title: 'Chat $id',
        createdAt: _date,
        lastMessageAt: _date,
        messageCount: 0,
      ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 'a';

  @override
  Future<String?> createSession({required String title}) async {
    sessions.add('new');
    return 'new';
  }

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) {
    if (historyFails) {
      return Future.error(const CoachDataUnavailable('History failed'));
    }
    if (sessionId == pendingHistorySession && pendingHistory != null) {
      return pendingHistory!.future;
    }
    return Future.value([
      if (sessionId == 'a' && recipeInHistory)
        ChatMessage(
          id: 'recipe-a',
          role: ChatRole.assistant,
          content: 'Rezeptvorschlag',
          createdAt: _date,
          recipeProposal: _proposal,
        ),
    ]);
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<void> deleteSession(String sessionId) async {
    await pendingDelete?.future;
    sessions.remove(sessionId);
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) {
    recipeCalls++;
    return pendingRecipe.future;
  }
}

class _Images extends RecipeImageStore {
  _Images(Directory directory) : super(baseDirectory: () async => directory);

  Future<bool>? proposalSave;
  bool? saved;

  @override
  Future<bool> saveProposalImage({
    required String messageId,
    required Uint8List bytes,
  }) => proposalSave = super
      .saveProposalImage(messageId: messageId, bytes: bytes)
      .then((value) => saved = value);
}

class _Speech extends CoachSpeechInput {
  final pending = <Completer<String?>>[];
  int stops = 0;

  @override
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) {
    final result = Completer<String?>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<void> stop() async => stops++;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _drainIo(WidgetTester tester, bool Function() finished) async {
  for (var i = 0; i < 100 && !finished(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(finished(), isTrue, reason: 'Die lokale Dateioperation endet');
}

Future<void> _mount(
  WidgetTester tester,
  _Coach coach, {
  CoachSpeechInput speech = const CoachSpeechInput(),
  ValueNotifier<bool>? visible,
  VoidCallback? onCreate,
}) async {
  final screen = CoachChatScreen(
    service: coach,
    speechInput: speech,
    onCreateRecipe: onCreate == null
        ? null
        : (_) async {
            onCreate();
            return SyncDelivery.delivered;
          },
  );
  await pumpLocalized(
    tester,
    visible == null
        ? screen
        : ValueListenableBuilder<bool>(
            valueListenable: visible,
            child: screen,
            builder: (_, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
          ),
    surfaceSize: const Size(402, 820),
    safeArea: false,
    padding: const EdgeInsets.all(16),
  );
  await _frames(tester);
}

Future<void> _openSessions(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await _frames(tester);
}

Future<void> _switch(WidgetTester tester, String id) async {
  await _openSessions(tester);
  await tester.tap(find.text('Chat $id'));
  await _frames(tester);
}

void main() {
  for (final fails in [false, true]) {
    testWidgets('Neuer Chat beendet alten History-Load (Fehler: $fails)', (
      tester,
    ) async {
      final coach = _Coach.create();
      await _mount(tester, coach);
      coach.pendingHistory = Completer<List<ChatMessage>>();
      await _switch(tester, 'b');
      expect(find.byKey(const ValueKey('coach-loading')), findsOneWidget);

      await _openSessions(tester);
      await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
      await _frames(tester);
      if (fails) {
        coach.pendingHistory!.completeError(
          const CoachDataUnavailable('Late history error'),
        );
      } else {
        coach.pendingHistory!.complete([]);
      }
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-loading')), findsNothing);
      expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('coach-input')))
            .enabled,
        isTrue,
      );
    });
  }

  testWidgets('Neuer Chat loescht vorherigen History-Fehler', (tester) async {
    final coach = _Coach.create()..historyFails = true;
    await _mount(tester, coach);
    expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
    await _openSessions(tester);
    await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
    await _frames(tester);
    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
  });

  testWidgets('Neuer Chat gewinnt gegen verspaeteten Bootstrap', (
    tester,
  ) async {
    final coach = _Coach.create()
      ..pendingHistorySession = 'a'
      ..pendingHistory = Completer<List<ChatMessage>>();
    await _mount(tester, coach);
    await _openSessions(tester);
    await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
    await _frames(tester);
    coach.pendingHistory!.complete([
      ChatMessage(
        id: 'old-bootstrap',
        role: ChatRole.assistant,
        content: 'Veralteter Bootstrap-Verlauf',
        createdAt: _date,
      ),
    ]);
    await _frames(tester);
    expect(find.text('Veralteter Bootstrap-Verlauf'), findsNothing);
    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
  });

  testWidgets('Geschlossenes Sessions-Sheet erhaelt kein Delete-setState', (
    tester,
  ) async {
    final coach = _Coach.create()..pendingDelete = Completer<void>();
    await _mount(tester, coach);
    await _openSessions(tester);
    await tester.tap(find.byIcon(Icons.delete_outline_rounded).last);
    await _frames(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Löschen'));
    await _frames(tester);
    Navigator.of(tester.element(find.text('Chat b'))).pop();
    await _frames(tester);
    coach.pendingDelete!.complete();
    await _frames(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
  });

  for (final transition in ['none', 'account', 'purge', 'relogin', 'dispose']) {
    testWidgets('Rezeptbild nach Chatwechsel (Uebergang: $transition)', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('eatova-coach-');
      final images = _Images(directory);
      RecipeImageStore.instance = images;
      await images.setActiveUser('user-a');
      addTearDown(() {
        RecipeImageStore.resetInstance();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final coach = _Coach.create();
      var creations = 0;
      await _mount(tester, coach, onCreate: () => creations++);
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        '/recipe Reis',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await _frames(tester);
      expect(coach.recipeCalls, 1);
      await _switch(tester, 'b');
      if (transition == 'account') {
        await tester.runAsync(() => images.setActiveUser('user-b'));
      } else if (transition == 'purge') {
        await tester.runAsync(images.clear);
      } else if (transition == 'relogin') {
        await tester.runAsync(() async {
          await images.setActiveUser(null);
          await images.setActiveUser('user-a');
        });
      } else if (transition == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      }
      coach.pendingRecipe.complete(
        CoachRecipeReply(
          reply: 'Rezeptvorschlag',
          refusal: false,
          proposal: _proposal.withImageBytes(_png),
          sessionId: 'a',
          assistantMessageId: 'recipe-a',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await _frames(tester);
      if (images.proposalSave != null) {
        await _drainIo(tester, () => images.saved != null);
      }
      expect(find.byKey(const ValueKey('coach-recipe-card')), findsNothing);
      expect(creations, 0, reason: 'Speichern braucht explizite Bestaetigung');
      if (transition != 'none') {
        expect(images.proposalSave, isNull);
        expect(
          directory.existsSync()
              ? directory.listSync(recursive: true).whereType<File>()
              : const <File>[],
          isEmpty,
        );
      } else {
        expect(images.proposalSave, isNotNull);
        await _drainIo(tester, () => images.saved != null);
        expect(images.saved, isTrue);
        expect(
          await tester.runAsync(() => images.readProposalImage('recipe-a')),
          orderedEquals(_png),
        );
        coach.recipeInHistory = true;
        await _switch(tester, 'a');
        await _drainIo(
          tester,
          () => find
              .byKey(const ValueKey('coach-recipe-card'))
              .evaluate()
              .isNotEmpty,
        );
        await _frames(tester);
        expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(creations, 0);
      }
    });
  }

  for (final action in ['tab', 'dispose', 'paused']) {
    testWidgets('Spracherkennung endet bei $action', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final speech = _Speech();
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        await _mount(tester, _Coach.create(), speech: speech, visible: visible);
        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await _frames(tester);
        expect(speech.pending, hasLength(1));
        if (action == 'tab') {
          visible.value = false;
        } else if (action == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        await _frames(tester);
        final stopCount = speech.stops;
        speech.pending.first.complete('Veraltetes Diktat');
        await _frames(tester);
        expect(stopCount, 1);
        expect(tester.takeException(), isNull);
        if (action != 'dispose') {
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('coach-input')))
                .controller!
                .text,
            isEmpty,
          );
        }
        if (action == 'paused') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'Altes Diktat ueberschreibt keine neue Aufnahme nach Tabwechsel',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final speech = _Speech();
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        await _mount(tester, _Coach.create(), speech: speech, visible: visible);
        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await _frames(tester);
        visible.value = false;
        await _frames(tester);
        visible.value = true;
        await _frames(tester);
        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await _frames(tester);
        expect(speech.pending, hasLength(2));
        speech.pending.first.complete('Veraltetes Diktat');
        await _frames(tester);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('coach-input')))
              .controller!
              .text,
          isEmpty,
        );
        speech.pending.last.complete('Aktuelles Diktat');
        await _frames(tester);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('coach-input')))
              .controller!
              .text,
          'Aktuelles Diktat',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
