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

// Covers `_humanizeTimestamp`'s >=7-day date fallback, reachable only through
// the rendered `_SessionTile`: 'de' stays byte-identical to 'dd.MM.yyyy' and
// 'en' renders the same pattern without throwing.

const Size _usableSize = Size(402, 781);

class _FakeCoach extends CoachChatService {
  _FakeCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue's constructor starts a periodic
  /// timer that fails every widget test. `loadHistory`/`loadQuotaToday` are
  /// overridden so the bootstrap sends no real queries.
  static _FakeCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FakeCoach(client, 'user-123');
  }

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        // Far in the past, so the >= 7 day threshold holds on any run.
        ChatSession(
          id: 's1',
          title: 'Alte Unterhaltung',
          createdAt: DateTime(2020, 3, 1),
          lastMessageAt: DateTime(2020, 3, 5),
          messageCount: 2,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
          {int limit = 100}) async =>
      const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

Future<void> _pumpCoach(WidgetTester tester, {required Locale locale}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(disableAnimations: true),
        child: Scaffold(
          body: CoachChatScreen(
            service: _FakeCoach.create(),
            userName: 'Moritz',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Sessions-Sheet: Alt-Datum bleibt unter de byte-gleich dd.MM.yyyy',
      (tester) async {
    await _pumpCoach(tester, locale: const Locale('de'));

    expect(find.text('05.03.2020'), findsOneWidget);
  });

  testWidgets('Sessions-Sheet: dasselbe Zahlenformat unter en, kein Crash',
      (tester) async {
    await _pumpCoach(tester, locale: const Locale('en'));

    // Same pattern as 'de' on purpose ('MM/dd' would be ambiguous); the point
    // is that DateFormat(..., 'en') resolves at all.
    expect(find.text('05.03.2020'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
