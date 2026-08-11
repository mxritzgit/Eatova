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

// Review-Fixwelle (2026-08-11): `_humanizeTimestamp`s >=7-Tage-Datumsfallback
// war der einzige neue Formatierungspfad des Scan/Coach-PRs ohne eigenen
// Test (die Funktion selbst ist library-privat in coach_sessions.dart — nur
// ueber die gerenderte `_SessionTile` im Sessions-Sheet erreichbar, Muster
// coach_design_test.dart). Deckt: 'de' bleibt byte-gleich 'dd.MM.yyyy'
// (Bestand vor der intl-Umstellung), 'en' rendert dasselbe numerische Muster
// UND wirft nicht (Beleg, dass DateFormat(..., 'en') tatsaechlich lokalisiert
// aufgeloest wird, nicht nur zufaellig gleich aussieht).

const Size _usableSize = Size(402, 781);

class _FakeCoach extends CoachChatService {
  _FakeCoach(super.client, super.userId);

  /// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
  /// periodischen Timer, an dem jeder Widget-Test scheitert (Muster
  /// coach_design_test.dart). `loadHistory`/`loadQuotaToday` sind ebenfalls
  /// ueberschrieben — die Basisklasse wuerde sonst echte Supabase-Queries
  /// ueber den Mock-Client schicken; der Sessions-Bootstrap in
  /// `_bootstrapIntern` braucht beide, bevor er `_sessions` ueberhaupt
  /// setzt.
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
        // Weit in der Vergangenheit, nicht relativ zu DateTime.now() gewaehlt:
        // die diff.inDays >= 7-Schwelle greift so unabhaengig vom Testlauf-
        // Datum sicher, und der erwartete Text bleibt deterministisch.
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

    // Bewusst dasselbe Muster wie 'de' (Design-Entscheidung, s. Kommentar in
    // coach_sessions.dart): ein Wechsel zu 'MM/dd' waere zwischen US- und
    // GB/DE-Lesern zweideutig. Der Beleg hier ist, dass DateFormat(...,
    // 'en') ueberhaupt erfolgreich aufloest (kein LocaleDataException) und
    // dasselbe Ergebnis liefert wie unter 'de'.
    expect(find.text('05.03.2020'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
