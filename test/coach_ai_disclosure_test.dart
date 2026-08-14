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

// C8 — Offenlegung der KI-Interaktion im Coach-Tab (Art. 50 Abs. 1 EU-AI-Act).
//
// Bis zum Review stand in der UI nirgends „KI": der Tab heisst „Coach", der
// Leerzustand fragt „Wie kann ich dir helfen?", der Platzhalter sagt „Frag
// Eatova…" und der (i)-Button zeigte nur das Tageskontingent. Dass jede
// Nachricht zusaetzlich einen Tages-Snapshot (Gewicht, Ziel, Kalorien, Makros,
// Namen der geloggten Mahlzeiten) an einen Drittanbieter in den USA schickt,
// war ausschliesslich in PRIVACY.md nachlesbar.
//
// Diese Tests fixieren beides: die KI ist VOR dem Tippen sichtbar, und das
// Detail (welche Daten, wohin) steht im (i)-Sheet.
//
// `service: null` ist der eingebaute Offline-Zustand des Screens (nicht
// eingeloggt): kein Netz, kein Bootstrap, aber Hero + Composer rendern normal.
//
// Nachtrag Abschluss-Review 2026-08-14: das (i)-Sheet gibt es in ZWEI
// Fassungen — `_CoachInfoSheet` (bekanntes Kontingent, coach_composer.dart)
// und `_CoachInfoSheetUnbekannt` (coach_chat_screen.dart). Beide tragen
// denselben C8-Offenlegungsblock, und genau der ist der
// datenschutzrechtlich relevante Teil (Art. 50 Abs. 1 EU-AI-Act). Solange die
// Fassungen zwei Bauplaene sind, erreicht eine kuenftige Aenderung nur eine
// von beiden — deshalb prueft der letzte Test hier BEIDE gegen dieselbe Liste
// von l10n-Keys: ein einseitig geaenderter Block macht ihn rot.

/// Nutzbare Flaeche eines iPhone 16 Pro — die 800x600-Standardview des
/// Testbindings ist kuerzer als jedes Zielgeraet und laesst den Hero
/// ueberlaufen (vgl. food_tab_layout_test.dart).
const _usableSize = Size(402, 781);

/// Coach-Service ohne Netz, der ein BEKANNTES Kontingent meldet — nur mit ihm
/// laesst sich die zweite Sheet-Fassung ueberhaupt oeffnen.
///
/// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
/// periodischen Timer, an dem jeder Widget-Test scheitert.
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

/// Die Offenlegung, wie sie in JEDER Fassung des Sheets stehen muss — in
/// Baum-Reihenfolge und ohne einen einzigen hartkodierten Nutzertext.
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

/// Alle Text-Inhalte im geoeffneten (i)-Sheet, in Baum-Reihenfolge.
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
      // Der Coach ruft seit der i18n-Migration (Paket 4) context.l10n — ohne
      // Lokalisierung wirft AppLocalizations.of() beim ersten Build.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        // Orb + Composer animieren sonst endlos -> pumpAndSettle liefe aus.
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

    // WAS mitgeht — die vier Bestandteile aus home_store.coachContext.
    expect(find.textContaining('Gewicht'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Kalorien'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Makros'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Mahlzeiten'), findsAtLeastNWidgets(1));

    // WOHIN es geht — Drittanbieter und Land.
    expect(find.textContaining('USA'), findsAtLeastNWidgets(1));

    // Das Tageskontingent bleibt im selben Sheet erreichbar.
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
    // Ohne Service gibt es keinen Quota-Snapshot -> _CoachInfoSheetUnbekannt.
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
