import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// D6 (coach half) — proof that the IndexedStack suffices: `_bootstrap()` runs
// in initState and the draft lives in a state-owned controller, so both losses
// depended solely on the tab frame unmounting the subtree.
//
// Downside: `_bootstrap()` now runs ONCE per app run, so a UTC midnight quota
// reset only reaches the screen on cold start.

/// Networkless CoachChatService counting every load call. `stopAutoRefresh()`
/// is mandatory: GoTrue's constructor timer trips every widget test.
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

/// Minimal tab frame WITH IndexedStack: both children stay mounted.
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
        // The coach calls context.l10n; without localizations
        // AppLocalizations.of() throws on the first build.
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _TabHost(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final afterBootstrap = service.calls;
    expect(service.historyCalls, 1);
    expect(service.quotaCalls, 1);

    await tester.enterText(
      find.byKey(const ValueKey('coach-input')),
      'Mein halbfertiger Entwurf',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('to-other')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('to-coach')));
    await tester.pumpAndSettle();

    // Not a single load call fired again — so no spinner either.
    expect(service.calls, afterBootstrap);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.controller?.text, 'Mein halbfertiger Entwurf');
  });
}
