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

// D6 (Coach-Haelfte) — Nachweis, dass der IndexedStack von Agent W3-01 genuegt.
//
// Der Review haelt fest: `_bootstrap()` feuert loadSessions + loadHistory +
// loadQuotaToday bei JEDEM Tab-Besuch neu (mit Spinner), und ein getippter
// Entwurf ist weg. Beides haengt aber ausschliesslich daran, dass
// eatova_home_page.dart den Teilbaum unmountet: `_bootstrap()` laeuft in
// initState, und der Entwurf lebt in einem TextEditingController, den
// _CoachChatScreenState besitzt — anders als das Rezepte-Suchfeld, das gar
// keinen Controller hat und deshalb auch mit IndexedStack noch Arbeit braucht.
//
// Dieser Test stellt genau die Bedingung her, die der IndexedStack schafft
// (der Screen bleibt gemountet, waehrend ein anderer Tab sichtbar ist) und
// haelt fest: kein Nachladen, Entwurf bleibt. Im Coach war deshalb nichts zu
// reparieren — der Test schuetzt das Ergebnis gegen ein spaeteres Zurueckfallen
// auf einen unmountenden Rahmen.
//
// Bekannte Kehrseite (kein Fix in diesem Auftrag, s. Bericht): dauerhaft
// gemountet heisst auch, dass `_bootstrap()` nur noch EINMAL pro App-Lauf
// laeuft. Die Quota wird danach nur aus den send()-Antworten fortgeschrieben —
// ein Reset um Mitternacht (UTC) erreicht den Screen erst beim Kaltstart.

/// CoachChatService ohne Netz, der jeden Ladeaufruf mitzaehlt.
/// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
/// periodischen Timer, an dem jeder Widget-Test scheitert.
class _CountingService extends CoachChatService {
  _CountingService(super.client, super.userId);

  int sessionCalls = 0;
  int historyCalls = 0;
  int quotaCalls = 0;

  static _CountingService create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _CountingService(client, 'user-123');
  }

  List<int> get calls => <int>[sessionCalls, historyCalls, quotaCalls];

  @override
  Future<List<ChatSession>> loadSessions() async {
    sessionCalls++;
    return const <ChatSession>[];
  }

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
      {int limit = 100}) async {
    historyCalls++;
    return const <ChatMessage>[];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaCalls++;
    return const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
  }
}

/// Minimaler Nachbau des Tab-Rahmens MIT IndexedStack: beide Kinder bleiben
/// gemountet, sichtbar ist nur das ausgewaehlte.
class _TabHost extends StatefulWidget {
  const _TabHost({required this.service});

  final CoachChatService service;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          CoachChatScreen(service: widget.service, userName: 'Moritz'),
          const Center(child: Text('anderer Tab')),
        ],
      ),
      bottomNavigationBar: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            key: const ValueKey('to-coach'),
            onPressed: () => setState(() => _index = 0),
            child: const Text('Coach'),
          ),
          TextButton(
            key: const ValueKey('to-other'),
            onPressed: () => setState(() => _index = 1),
            child: const Text('Anderer'),
          ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets(
      'Tab-Wechsel im IndexedStack: kein Neuladen, Entwurf bleibt stehen',
      (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(402, 781) * 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _CountingService.create();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _TabHost(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Bootstrap ist durch: Spinner weg, Composer nutzbar.
    final afterBootstrap = service.calls;
    expect(service.historyCalls, 1);
    expect(service.quotaCalls, 1);

    await tester.enterText(
      find.byKey(const ValueKey('coach-input')),
      'Mein halbfertiger Entwurf',
    );
    await tester.pumpAndSettle();

    // Weg und zurueck.
    await tester.tap(find.byKey(const ValueKey('to-other')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('to-coach')));
    await tester.pumpAndSettle();

    // Kein einziger Ladeaufruf ist nachgefeuert — also auch kein Spinner.
    expect(service.calls, afterBootstrap);

    // Und der Entwurf steht noch da.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.controller?.text, 'Mein halbfertiger Entwurf');
  });
}
