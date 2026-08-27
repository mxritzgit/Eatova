import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/harness.dart';

// Downside of the D6 fix: the coach screen stays mounted in the IndexedStack,
// so `_bootstrap()` runs only ONCE per app run. With the quota exhausted the
// composer is disabled and no send() response can correct the counter, so
// anyone leaving the app open across UTC midnight stayed locked out until a
// cold start. The lever is `TickerMode`: the invisible tab is muted, returning
// to the coach flips it to `true`.

class _MidnightService extends CoachChatService {
  _MidnightService(super.client, super.userId);

  int quotaCalls = 0;

  /// From which `loadQuotaToday()` call on the quota is full again.
  int resetAtCall = 2;

  static _MidnightService create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _MidnightService(client, 'user-123');
  }

  @override
  Future<List<ChatSession>> loadSessions() async => const <ChatSession>[];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
          {int limit = 100}) async =>
      const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaCalls++;
    return quotaCalls >= resetAtCall
        ? const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5)
        : const ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5);
  }
}

/// Minimal replica of the tab shell: `IndexedStack` + `TickerMode`, as
/// `eatova_home_page.dart` builds it.
class _TabHost extends StatefulWidget {
  const _TabHost({required this.service});

  final CoachChatService service;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  int _index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(
          index: _index,
          children: <Widget>[
            TickerMode(
              enabled: _index == 0,
              child: CoachChatScreen(service: widget.service, userName: 'M'),
            ),
            TickerMode(
              enabled: _index == 1,
              child: const Center(child: Text('anderer Tab')),
            ),
          ],
        ),
        bottomNavigationBar: TextButton(
          key: const ValueKey('switch-tab'),
          onPressed: () => setState(() => _index = _index == 0 ? 1 : 0),
          child: const Text('wechseln'),
        ),
      );
}

Future<void> _wechsleTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('switch-tab')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
      'Rueckkehr auf den Coach-Tab holt den Tageszaehler neu — sonst bleibt '
      'der Nutzer ueber Mitternacht bis zum Kaltstart ausgesperrt',
      (tester) async {
    final svc = _MidnightService.create();
    await pumpLocalized(
      tester,
      _TabHost(service: svc),
      // The host brings its own Scaffold.
      scaffold: false,
      safeArea: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(svc.quotaCalls, 1, reason: 'Bootstrap: 0 uebrig, Composer gesperrt');
    expect(find.text('Limit für heute erreicht'), findsOneWidget);

    await _wechsleTab(tester); // away
    await _wechsleTab(tester); // and back

    expect(svc.quotaCalls, 2, reason: 'die Rueckkehr muss neu fragen');
    expect(find.text('Limit für heute erreicht'), findsNothing,
        reason: 'nach dem Reset ist der Composer wieder frei');
  });

  testWidgets('das Verlassen des Tabs allein fragt nichts ab', (tester) async {
    final svc = _MidnightService.create();
    await pumpLocalized(
      tester,
      _TabHost(service: svc),
      // The host brings its own Scaffold.
      scaffold: false,
      safeArea: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _wechsleTab(tester); // away only

    expect(svc.quotaCalls, 1,
        reason: 'ein Request im Hintergrund waere reine Verschwendung');
  });

  testWidgets(
      'ist das Kontingent wirklich aufgebraucht, bleibt der Composer gesperrt',
      (tester) async {
    final svc = _MidnightService.create()..resetAtCall = 99;
    await pumpLocalized(
      tester,
      _TabHost(service: svc),
      // The host brings its own Scaffold.
      scaffold: false,
      safeArea: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await _wechsleTab(tester);
    await _wechsleTab(tester);

    expect(svc.quotaCalls, 2, reason: 'einmal nachgefragt');
    expect(find.text('Limit für heute erreicht'), findsOneWidget,
        reason: 'das Limit gilt weiterhin');
  });
}
