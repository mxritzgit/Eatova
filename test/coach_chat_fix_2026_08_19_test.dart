import 'dart:async';

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

// Komplettreview 2026-08-19, Coach-Paket — drei Befunde am Screen:
//
//  * Fund 1: Bricht das Netz weg, blieb die Frage eine ganz normale Blase. Der
//    einzige Weg zurueck war „nochmal tippen" (der Entwurf lag wieder im Feld)
//    — und der erzeugte eine ZWEITE Blase mit demselben Text. Die Sitzung trug
//    die Frage danach doppelt, das Modell bekam sie beim naechsten Mal auch
//    doppelt als Kontext.
//
//  * Fund 2: `build()` steckt den Verlauf in einen AnimatedSwitcher (220 ms)
//    und gibt jeder `_Conversation` denselben ScrollController. Beim
//    Sitzungswechsel haengen deshalb kurzzeitig ZWEI ListViews daran, und
//    `_scrollToEnd` griff auf `ScrollController.position` zu — das ist
//    `_positions.single` und wirft dann. `hasClients` faengt das nicht ab: es
//    prueft nur, ob ueberhaupt eine Liste angehaengt ist.
//
//  * Fund 3: Der Nachziehpfad des Tageszaehlers hing ausschliesslich am
//    Flankenwechsel des TickerMode, also am TAB-Wechsel. Wer um 23:50 seinen
//    letzten Slot verbraucht und die App AUF DEM COACH-TAB in den Hintergrund
//    schickt, kommt auf denselben Tab zurueck — keine Flanke, kein Nachziehen,
//    und weil bei erschoepftem Kontingent auch keine send()-Antwort mehr
//    kommt, blieb der Composer bis zum Kaltstart gesperrt.

class _FixCoach extends CoachChatService {
  _FixCoach(super.client, super.userId);

  /// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
  /// periodischen Timer, an dem jeder Widget-Test scheitert.
  static _FixCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FixCoach(client, 'user-123');
  }

  /// Unverwechselbare Nachrichten in beiden Sitzungen — ohne Verlauf stuende
  /// der Hero mit seinem Dauer-Orb im Bild.
  static const String verlaufA = 'Das ist der Verlauf von Sitzung A.';
  static const String verlaufB = 'Das ist der Verlauf von Sitzung B.';

  /// Texte der `send()`-Aufrufe in Reihenfolge — der Beleg dafuer, dass der
  /// Wiederholversuch bitgleich dasselbe schickt.
  final List<String> gesendeteTexte = <String>[];

  /// Offene Sende-Auftraege; der Test loest sie von Hand auf.
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];

  /// Solange true, haengt jeder `loadHistory`-Aufruf an einem Completer — nur
  /// so laesst sich der Verlauf MITTEN im AnimatedSwitcher-Uebergang
  /// einliefern.
  bool verlaufHaengt = false;

  final Map<String, Completer<List<ChatMessage>>> offeneVerlaeufe =
      <String, Completer<List<ChatMessage>>>{};

  int quotaAufrufe = 0;

  /// Staende, die der Server nacheinander nennt. Der letzte Eintrag gilt fuer
  /// alle weiteren Abfragen.
  List<ChatQuotaSnapshot> quotaFolge = const <ChatQuotaSnapshot>[
    ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5),
  ];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat A',
          createdAt: DateTime(2026, 8, 1),
          lastMessageAt: DateTime(2026, 8, 19),
          messageCount: 1,
        ),
        ChatSession(
          id: 's2',
          title: 'Chat B',
          createdAt: DateTime(2026, 8, 2),
          lastMessageAt: DateTime(2026, 8, 18),
          messageCount: 1,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  static List<ChatMessage> verlaufVon(String sessionId) => switch (sessionId) {
        's2' => <ChatMessage>[
            ChatMessage(
              id: 'm-b1',
              role: ChatRole.assistant,
              content: verlaufB,
              createdAt: DateTime(2026, 8, 18),
            ),
          ],
        _ => <ChatMessage>[
            ChatMessage(
              id: 'm-a1',
              role: ChatRole.assistant,
              content: verlaufA,
              createdAt: DateTime(2026, 8, 19),
            ),
          ],
      };

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) {
    if (!verlaufHaengt) {
      return Future<List<ChatMessage>>.value(verlaufVon(sessionId));
    }
    final auftrag = Completer<List<ChatMessage>>();
    offeneVerlaeufe[sessionId] = auftrag;
    return auftrag.future;
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    quotaAufrufe++;
    final index = quotaAufrufe - 1;
    return index < quotaFolge.length ? quotaFolge[index] : quotaFolge.last;
  }

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
  }) {
    gesendeteTexte.add(message);
    final auftrag = Completer<CoachChatReply>();
    offen.add(auftrag);
    return auftrag.future;
  }
}

const Size _usableSize = Size(402, 781);

Widget _app(
  _FixCoach service,
  MediaQueryData basis, {
  required bool bewegungAus,
}) =>
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      // Der Coach ruft seit der i18n-Migration context.l10n — ohne
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
        data: bewegungAus ? basis.copyWith(disableAnimations: true) : basis,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: CoachChatScreen(service: service, userName: 'Moritz'),
          ),
        ),
      ),
    );

/// Aufbau mit stillgestellter Bewegung — Denk-Punkte, Orb und Uebergaenge
/// stehen still, sonst kommt `pumpAndSettle` bei laufendem `_sending` nie an.
Future<void> _pumpCoachRuhig(WidgetTester tester, _FixCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _app(service, MediaQueryData.fromView(tester.view), bewegungAus: true),
  );
  await tester.pumpAndSettle();
}

/// Aufbau MIT Bewegung — nur so entsteht das 220-ms-Fenster des
/// AnimatedSwitchers, in dem Fund 2 lebt. Deshalb hier ueberall feste Pumps
/// statt `pumpAndSettle`.
Future<void> _pumpCoachBewegt(WidgetTester tester, _FixCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _app(service, MediaQueryData.fromView(tester.view), bewegungAus: false),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tippenUndSenden(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

/// Zaehlt AUSSCHLIESSLICH Blasen. `find.text` matcht auch die `EditableText`
/// des Composers — und nach einem Fehlschlag steht der Entwurf wieder im Feld,
/// die Frage waere also doppelt gefunden, ohne dass es eine zweite Blase gibt.
int _blasenMit(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.byType(Text))
    .where((w) => w.data == text)
    .length;

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // Fund 1 — die fehlgeschlagene Nachricht
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Fehlschlag: die Frage wird als „nicht gesendet" gekennzeichnet, und der '
    'Wiederholversuch ersetzt dieselbe Blase statt eine zweite anzulegen',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);

      const frage = 'Wie viel Protein fehlt mir heute noch?';
      await _tippenUndSenden(tester, frage);
      expect(svc.gesendeteTexte, <String>[frage]);

      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsOneWidget,
        reason: 'ohne Kennzeichnung sieht die Blase aus wie abgeschickt',
      );
      expect(find.text('Nicht gesendet'), findsOneWidget);
      expect(find.text('Erneut senden'), findsOneWidget);
      expect(_blasenMit(tester, frage), 1);

      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();

      expect(
        svc.gesendeteTexte,
        <String>[frage, frage],
        reason: 'derselbe Text, bitgleich — nicht aus dem Feld rekonstruiert',
      );
      expect(
        _blasenMit(tester, frage),
        1,
        reason: 'DAS ist der Befund: der zweite Versuch darf keine zweite '
            'Blase mit demselben Text erzeugen',
      );

      svc.offen.last.complete(
        const CoachChatReply(
          reply: 'Dir fehlen noch 38 g.',
          refusal: false,
          sessionId: 's1',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsNothing,
        reason: 'zugestellt ist zugestellt — die Kennzeichnung muss weg',
      );
      expect(_blasenMit(tester, frage), 1);
      expect(find.text('Dir fehlen noch 38 g.'), findsOneWidget);
    },
  );

  testWidgets(
    'erschoepftes Kontingent: gekennzeichnet, aber ohne Wiederhol-Knopf',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);

      await _tippenUndSenden(tester, 'Noch eine Frage');
      svc.offen.first.completeError(
        const CoachQuotaExceeded(
          message: 'Tageslimit erreicht. Morgen geht es weiter.',
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsOneWidget,
        reason: 'gesendet wurde sie nicht — das gilt auch beim Tageslimit',
      );
      expect(
        find.byKey(const ValueKey('coach-unsent-retry')),
        findsNothing,
        reason: 'ein Knopf, der nichts ausloesen kann, ist eine Aufforderung, '
            'die nicht eingeloest wird',
      );
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Fund 2 — zwei Verlaeufe am selben ScrollController
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Sitzungswechsel MITTEN im 220-ms-Uebergang sprengt _scrollToEnd nicht',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachBewegt(tester, svc);
      expect(find.text(_FixCoach.verlaufA), findsOneWidget);

      // Ab hier haengt der Verlauf, damit der Test bestimmt, WANN die zweite
      // ListView in den Baum kommt.
      svc.verlaufHaengt = true;
      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Chat B'));
      // Bewusst OHNE pumpAndSettle: der ausgehende Verlauf von Sitzung A
      // blendet 220 ms lang weiter mit und haengt so lange am Controller.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      svc.offeneVerlaeufe['s2']!.complete(_FixCoach.verlaufVon('s2'));
      // Dieser Frame baut den Verlauf von B — jetzt sind es zwei Positionen,
      // und der Post-Frame-Callback ruft _scrollToEnd.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        tester.takeException(),
        isNull,
        reason: '`ScrollController.position` ist `_positions.single` und '
            'wirft, sobald zwei Listen angehaengt sind',
      );

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(_FixCoach.verlaufB), findsOneWidget);
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Fund 3 — Mitternachts-Aussperrung
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Resume zieht den Tageszaehler nach — der Tab-Wechsel allein reicht '
    'nicht, wenn der Coach-Tab die ganze Nacht oben lag',
    (tester) async {
      final svc = _FixCoach.create()
        ..quotaFolge = const <ChatQuotaSnapshot>[
          ChatQuotaSnapshot(used: 5, remaining: 0, dailyLimit: 5),
          ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5),
        ];
      await _pumpCoachRuhig(tester, svc);

      expect(svc.quotaAufrufe, 1);
      expect(
        find.text('Limit für heute erreicht'),
        findsOneWidget,
        reason: 'Ausgangslage: der letzte Slot ist um 23:50 verbraucht',
      );

      (tester.state(find.byType(CoachChatScreen)) as WidgetsBindingObserver)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(svc.quotaAufrufe, 2, reason: 'der Resume muss neu fragen');
      expect(
        find.text('Limit für heute erreicht'),
        findsNothing,
        reason: 'nach der Tagesgrenze vergibt der Server wieder Slots',
      );
    },
  );

  testWidgets(
    'der Gang in den Hintergrund fragt nichts ab',
    (tester) async {
      final svc = _FixCoach.create();
      await _pumpCoachRuhig(tester, svc);
      expect(svc.quotaAufrufe, 1);

      final beobachter =
          tester.state(find.byType(CoachChatScreen)) as WidgetsBindingObserver;
      beobachter.didChangeAppLifecycleState(AppLifecycleState.inactive);
      beobachter.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(
        svc.quotaAufrufe,
        1,
        reason: 'ein Request im Hintergrund waere reine Verschwendung',
      );
    },
  );
}
