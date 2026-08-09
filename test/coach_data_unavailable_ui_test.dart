import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Sentinel-Rest, Screen-Seite: „nicht ladbar/loeschbar" darf nie wie
// „leer/geloescht" aussehen.
//
//  * Verlauf: loadHistory wirft seit dem Service-Fix CoachDataUnavailable —
//    der Screen muss daraus einen Fehlerzustand machen, nicht den
//    Hero-Leerzustand (der behauptet „noch keine Unterhaltung").
//  * Loeschen: deleteSession wirft — die Session bleibt in der Liste stehen
//    und der Nutzer bekommt einen Hinweis, statt dass der Screen mit
//    „ist geloescht" weiterfaehrt.

class _Svc extends CoachChatService {
  _Svc(super.client, super.userId);

  bool historyFails = false;
  bool deleteFails = false;
  int deleteCalls = 0;

  static _Svc create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Svc(client, 'user-123');
  }

  List<ChatSession> _sessions = <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 8, 1),
      lastMessageAt: DateTime(2026, 8, 8),
      messageCount: 3,
    ),
    ChatSession(
      id: 's2',
      title: 'Chat B',
      createdAt: DateTime(2026, 8, 2),
      lastMessageAt: DateTime(2026, 8, 7),
      messageCount: 1,
    ),
  ];

  @override
  Future<List<ChatSession>> loadSessions() async => _sessions;

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
      {int limit = 100}) async {
    if (historyFails) {
      throw const CoachDataUnavailable('Verlauf nicht abrufbar');
    }
    return const <ChatMessage>[];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<void> deleteSession(String sessionId) async {
    deleteCalls++;
    if (deleteFails) {
      throw const CoachDataUnavailable('Loeschen fehlgeschlagen');
    }
    _sessions = _sessions.where((s) => s.id != sessionId).toList();
  }
}

/// Gedeckeltes Settle statt pumpAndSettle: der Coach-Screen traegt
/// Dauer-Animationen (Hero/Motion), an denen pumpAndSettle nie ankommt —
/// dasselbe Muster wie in clobber_guard_test.dart.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, _Svc svc) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    home: Scaffold(body: CoachChatScreen(service: svc, userName: 'Moritz')),
  ));
  await _settle(tester);
}

void main() {
  testWidgets(
      'Verlauf nicht ladbar -> Fehlerzustand mit Hinweis, NICHT der '
      'Hero-Leerzustand', (tester) async {
    final svc = _Svc.create()..historyFails = true;

    await _pump(tester, svc);

    expect(find.byKey(const ValueKey('coach-empty')), findsNothing,
        reason: 'der Leerzustand behauptet „noch keine Unterhaltung" — der '
            'Verlauf existiert aber, er war nur nicht ladbar');
    expect(find.textContaining('Verlauf konnte nicht geladen'), findsOneWidget);
  });

  testWidgets(
      'Loeschen scheitert -> Session bleibt in der Liste und es gibt einen '
      'Hinweis', (tester) async {
    final svc = _Svc.create()..deleteFails = true;

    await _pump(tester, svc);
    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await _settle(tester);
    // Bestaetigungs-Dialog.
    await tester.tap(find.widgetWithText(TextButton, 'Löschen'));
    await _settle(tester);

    expect(svc.deleteCalls, 1);
    expect(find.text('Chat A'), findsWidgets,
        reason: 'die Session ist NICHT geloescht — sie darf nicht aus der '
            'Liste verschwinden oder kommentarlos stehen bleiben');
    expect(find.textContaining('konnte nicht gelöscht'), findsOneWidget,
        reason: 'ohne Hinweis haelt der Nutzer den fehlgeschlagenen Zustand '
            'fuer einen Anzeigefehler');
  });
}
