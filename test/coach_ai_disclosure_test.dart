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

// C8 — AI interaction disclosure in the coach tab (EU AI Act Art. 50(1)).
//
// These tests pin both halves: the AI is visible BEFORE typing, and the detail
// (which data, sent where) lives in the (i) sheet.
//
// `service: null` is the screen's built-in offline state (logged out): no
// network, no bootstrap, but hero and composer render normally.
//
// The (i) sheet exists in two versions — `_CoachInfoSheet` (known quota) and
// `_CoachInfoSheetUnbekannt`. Both carry the same disclosure block, so the
// last two tests check BOTH against the same list of l10n keys; changing one
// side only turns exactly one of them red.

/// Usable area of an iPhone 16 Pro: the binding's 800x600 default is shorter
/// than any target device and overflows the hero.
const _usableSize = Size(402, 781);

/// Networkless coach service reporting a KNOWN quota — the only way to open
/// the second sheet version.
///
/// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
/// constructor that fails every widget test.
class _QuotaCoach extends CoachChatService {
  _QuotaCoach(super.client, super.userId);

  static _QuotaCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _QuotaCoach(client, 'user-123');
  }

  @override
  Future<List<ChatSession>> loadSessions() async => const <ChatSession>[];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 2, remaining: 3, dailyLimit: 5);
}

/// The disclosure as it must appear in EVERY sheet version: in tree order and
/// without a single hardcoded user-facing string.
List<String> _c8Block(AppLocalizations l10n) => <String>[
      l10n.coachTitle,
      l10n.coachInfoIntro,
      l10n.coachInfoDataLabel,
      l10n.coachInfoBulletWeight,
      l10n.coachInfoBulletMacros,
      l10n.coachInfoBulletMeals,
      l10n.coachInfoProvider,
      l10n.coachInfoLimitLabel,
    ];

/// All text content in the open (i) sheet, in tree order.
List<String> _sheetTexte(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('coach-info-sheet')),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .toList();

Future<void> _pumpCoach(WidgetTester tester, {CoachChatService? service}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // The coach calls context.l10n, so without localizations
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
        // Orb and composer animate forever otherwise, so pumpAndSettle would
        // time out.
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: CoachChatScreen(service: service, userName: 'Moritz'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Leerzustand nennt die KI, bevor der Nutzer tippt',
      (tester) async {
    await _pumpCoach(tester);

    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-ai-note')), findsOneWidget);
    expect(find.textContaining('KI'), findsAtLeastNWidgets(1));
  });

  testWidgets('Composer-Platzhalter macht die KI auch im laufenden Chat sichtbar',
      (tester) async {
    await _pumpCoach(tester);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.decoration?.hintText, contains('KI'));
  });

  testWidgets('(i)-Sheet nennt Daten und Empfaenger, nicht nur das Kontingent',
      (tester) async {
    await _pumpCoach(tester);

    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);

    // WHAT is sent: the four parts of home_store.coachContext.
    expect(find.textContaining('Gewicht'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Kalorien'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Makros'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Mahlzeiten'), findsAtLeastNWidgets(1));

    // WHERE it goes: third party and country.
    expect(find.textContaining('USA'), findsAtLeastNWidgets(1));

    // The daily quota stays reachable in the same sheet.
    expect(find.textContaining('Fragen heute frei'), findsOneWidget);
  });

  testWidgets('Hero-Hinweis oeffnet dasselbe (i)-Sheet', (tester) async {
    await _pumpCoach(tester);

    final note = find.byKey(const ValueKey('coach-ai-note'));
    await tester.ensureVisible(note);
    await tester.pumpAndSettle();
    await tester.tap(note);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
  });

  testWidgets(
      'die Offenlegung steht in der Fassung fuer UNBEKANNTES Kontingent '
      'vollstaendig und unveraendert', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('de'));
    // No service means no quota snapshot -> _CoachInfoSheetUnbekannt.
    await _pumpCoach(tester);
    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await tester.pumpAndSettle();

    expect(
      _sheetTexte(tester).take(_c8Block(l10n).length).toList(),
      _c8Block(l10n),
      reason: 'die zweite Fassung des Sheets ist ein eigener Bauplan — dieser '
          'Test faellt um, sobald sie vom Original abweicht',
    );
    expect(
      find.byKey(const ValueKey('coach-info-limit-unbekannt')),
      findsOneWidget,
      reason: 'nur der Zahlenteil unterscheidet die beiden Fassungen',
    );
  });

  testWidgets(
      'die Offenlegung steht in der Fassung fuer BEKANNTES Kontingent '
      'wortgleich', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('de'));
    await _pumpCoach(tester, service: _QuotaCoach.create());
    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await tester.pumpAndSettle();

    expect(
      _sheetTexte(tester).take(_c8Block(l10n).length).toList(),
      _c8Block(l10n),
      reason: 'beide Fassungen werden gegen DIESELBE Liste geprueft — eine '
          'einseitig geaenderte Offenlegung macht genau einen der beiden '
          'Tests rot',
    );
    expect(
      find.byKey(const ValueKey('coach-info-limit-unbekannt')),
      findsNothing,
    );
  });
}
