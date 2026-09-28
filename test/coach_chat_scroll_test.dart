import 'dart:async';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'support/harness.dart';

// Sending a question, streaming the answer and finishing it must never scroll
// the chat past its end. On iOS the bouncing physics made every overshoot
// visible as a jump up and back down after each answer.

class _StreamCoach extends CoachChatService {
  _StreamCoach(super.client, super.userId);

  static _StreamCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _StreamCoach(client, 'user-scroll');
  }

  void Function(String text)? vorschau;
  Completer<CoachChatReply>? auftrag;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat',
          createdAt: DateTime(2026, 9, 1),
          lastMessageAt: DateTime(2026, 9, 1),
          messageCount: 12,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  // Long enough that the conversation scrolls.
  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
          {int limit = 100}) async =>
      List<ChatMessage>.generate(
        12,
        (i) => ChatMessage(
          id: 'm$i',
          role: i.isEven ? ChatRole.user : ChatRole.assistant,
          content: i.isEven
              ? 'Frage $i: Wie viel Protein brauche ich heute?'
              : 'Antwort $i: Etwa 1,6 bis 2 g pro Kilogramm Körpergewicht, '
                  'verteilt auf drei bis vier Mahlzeiten am Tag.',
          createdAt: DateTime(2026, 9, 1, 8, i),
        ),
      );

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
  }) {
    vorschau = onPartialReply;
    return (auftrag = Completer<CoachChatReply>()).future;
  }
}

ScrollPosition _liste(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byKey(const ValueKey('coach-message-list')),
      matching: find.byType(Scrollable),
    ))
    .position;

/// Pumps [frames] frames of 16 ms and records how far past the end the chat
/// was scrolled in each (0 when inside its extent).
Future<List<double>> _ueberstand(WidgetTester tester, int frames) async {
  final werte = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final pos = _liste(tester);
    werte.add(pos.pixels - pos.maxScrollExtent);
  }
  return werte;
}

const _antwort = 'Für deinen Muskelaufbau passen heute etwa 140 g Protein. '
    'Verteile sie auf drei Mahlzeiten und einen Snack, zum Beispiel '
    'Skyr am Morgen, Hähnchen mittags und Linsen am Abend. So erreichst du '
    'dein Ziel, ohne dass eine Mahlzeit zu schwer wird.';

Future<_StreamCoach> _oeffne(WidgetTester tester) async {
  final svc = _StreamCoach.create();
  await pumpLocalized(
    tester,
    CoachChatScreen(service: svc, userName: 'M'),
    surfaceSize: const Size(390, 844),
    reducedMotion: false,
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  expect(_liste(tester).maxScrollExtent, greaterThan(0),
      reason: 'Vorbedingung: der Verlauf muss scrollen');
  return svc;
}

Future<void> _sende(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
}

void _amEnde(WidgetTester tester, String reason) {
  final pos = _liste(tester);
  expect(pos.pixels, moreOrLessEquals(pos.maxScrollExtent, epsilon: 0.5),
      reason: reason);
}

void main() {
  testWidgets(
    'nach dem Laden steht der Chat exakt am Ende des Verlaufs',
    (tester) async {
      await _oeffne(tester);
      _amEnde(tester, 'die neueste Nachricht muss beim Oeffnen sichtbar sein');
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'waehrend die Antwort streamt, bleibt ihr Ende im Blick',
    (tester) async {
      final svc = await _oeffne(tester);
      await _sende(tester, 'Wie viel Protein?');
      await tester.pump(const Duration(milliseconds: 300));
      for (var n = 40; n <= _antwort.length; n += 40) {
        svc.vorschau!(_antwort.substring(0, n));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        _amEnde(tester, 'nach ${n} Zeichen ist das Ende der Antwort verdeckt');
      }
      svc.auftrag!.complete(const CoachChatReply(
        reply: _antwort,
        refusal: false,
        sessionId: 's1',
        remaining: 4,
        dailyLimit: 5,
      ));
      await tester.pump(const Duration(seconds: 1));
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'wer hochgescrollt hat, wird von Token und Abschluss nicht bewegt',
    (tester) async {
      final svc = await _oeffne(tester);
      await _sende(tester, 'Wie viel Protein?');
      await tester.pump(const Duration(milliseconds: 300));
      svc.vorschau!('Für deinen Muskelaufbau');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(
          find.byKey(const ValueKey('coach-message-list')),
          const Offset(0, 400));
      await tester.pump(const Duration(seconds: 1));
      final gelesen = _liste(tester).pixels;
      expect(gelesen, lessThan(_liste(tester).maxScrollExtent - 100),
          reason: 'Vorbedingung: der Nutzer liest weiter oben');
      svc.vorschau!(_antwort);
      await tester.pump(const Duration(milliseconds: 300));
      svc.auftrag!.complete(const CoachChatReply(
        reply: _antwort,
        refusal: false,
        sessionId: 's1',
        remaining: 4,
        dailyLimit: 5,
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(_liste(tester).pixels, moreOrLessEquals(gelesen, epsilon: 0.5),
          reason: 'die Leseposition darf nicht springen');
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'die Tastatur verdeckt die letzte Nachricht nicht',
    (tester) async {
      await _oeffne(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      _amEnde(tester, 'die letzte Nachricht muss ueber der Tastatur bleiben');
    },
    variant: TargetPlatformVariant.mobile(),
  );

  testWidgets(
    'Senden, Streamen und Abschluss scrollen nie ueber das Ende hinaus',
    (tester) async {
      final svc = await _oeffne(tester);

      await _sende(tester, 'Wie viel Protein?');
      final beimSenden = await _ueberstand(tester, 40);

      svc.vorschau!('Für deinen Muskelaufbau');
      final ersterToken = await _ueberstand(tester, 40);
      for (var n = 60; n <= _antwort.length; n += 60) {
        svc.vorschau!(_antwort.substring(0, n));
        await tester.pump(const Duration(milliseconds: 16));
      }
      svc.vorschau!(_antwort);
      svc.auftrag!.complete(const CoachChatReply(
        reply: _antwort,
        refusal: false,
        sessionId: 's1',
        remaining: 4,
        dailyLimit: 5,
      ));
      final beimAbschluss = await _ueberstand(tester, 60);
      await tester.pump(const Duration(seconds: 1));

      for (final (phase, werte) in <(String, List<double>)>[
        ('Senden', beimSenden),
        ('erster Token', ersterToken),
        ('Abschluss', beimAbschluss),
      ]) {
        final maximum = werte.reduce((a, b) => a > b ? a : b);
        expect(maximum, lessThanOrEqualTo(0.5),
            reason: '$phase: der Chat lief ${maximum.toStringAsFixed(1)} px '
                'ueber sein Ende hinaus');
      }
      final ende = _liste(tester);
      expect(ende.pixels, moreOrLessEquals(ende.maxScrollExtent, epsilon: 0.5),
          reason: 'die fertige Antwort steht am Ende im Blick');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.mobile(),
  );
}
