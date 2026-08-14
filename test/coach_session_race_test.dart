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

// Audit 2026-08-14, Befund A + B — die Antwort gehoert der Sitzung, aus der
// die Frage kam, und ein Fehlschlag frisst den getippten Text nicht.
//
// Die Kette hinter A: `_send` prueft nach dem `await` nur `mounted`. Der Screen
// bleibt seit D6 dauerhaft gemountet und der Sitzungs-Knopf bleibt waehrend des
// Sendens bedienbar — die Antwort auf die Frage aus Sitzung A wurde deshalb an
// `_messages` angehaengt, das zu diesem Zeitpunkt laengst den Verlauf von
// Sitzung B trug. Ergebnis: eine Coach-Blase in einer fremden Unterhaltung,
// ohne die zugehoerige Frage. Dass `_switchToSession` `_sending` stehen liess,
// stellte den Composer der neuen Sitzung obendrein tot.
//
// Kette hinter B: das Eingabefeld wird VOR dem Request geleert; scheitert er,
// war eine lange Frage weg.
//
// Kette hinter C: das (i)-Sheet bekam zwei `int` gereicht und fiel bei
// unbekanntem Kontingent auf ChatQuotaSnapshot.standardTageslimit zurueck —
// nach einem gescheiterten Quota-RPC las ein Nutzer mit verbrauchtem
// Kontingent „5 von 5 Fragen heute frei" samt vollem Balken.
//
// Der Test haelt die Antwort ueber einen Completer offen und wechselt dazwischen
// die Sitzung — nur so entsteht das Zeitfenster, in dem der Fehler lebt.
//
// Nachtrag Abschluss-Review 2026-08-14 (W2/W2b): derselbe Fehler stand eine
// Tuer weiter in `_switchToSession` — dort pruefte nur `mounted`, und der
// CoachDataUnavailable-Arm schrieb sogar den Fehlerzustand der VERLASSENEN
// Sitzung. Dazu kam, dass der Wechsel `_sending` auf false stellte: damit
// liessen sich zwei Anfragen parallel absetzen (in A senden, wechseln, in B
// senden) — zwei Tages-Slots aus einem Bedienschritt.
//
// Ausserdem nagelte diese Datei den Sitzungs-Vergleich bisher nur NEGATIV
// fest: dreht man `!=` auf `==`, wird JEDE Antwort verworfen und die Suite
// bleibt gruen. Die positive Gegenprobe steht deshalb jetzt als erster Test.

class _RaceCoach extends CoachChatService {
  _RaceCoach(super.client, super.userId);

  /// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
  /// periodischen Timer, an dem jeder Widget-Test scheitert.
  static _RaceCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _RaceCoach(client, 'user-123');
  }

  /// Nachricht, die im Verlauf von Sitzung B steht — der Beleg dafuer, dass
  /// wirklich B angezeigt wird, wenn die Antwort auf A eintrifft.
  static const String verlaufB = 'Das ist der Verlauf von Sitzung B.';

  /// Dasselbe fuer Sitzung C: den braucht der Wechsel A -> B -> C, in dem der
  /// Nachzuegler von B den Verlauf von C ueberschreiben wuerde.
  static const String verlaufC = 'Das ist der Verlauf von Sitzung C.';

  /// Offene Sende-Auftraege in Eingangsreihenfolge; der Test loest sie von
  /// Hand auf, um den Wechsel MITTEN im Request zu setzen.
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];

  /// Sitzungs-Ids der `send()`-Aufrufe, in Reihenfolge.
  final List<String> gesendeteSessions = <String>[];

  /// Solange true, haengt JEDER `loadHistory`-Aufruf an einem Completer —
  /// nur so laesst sich ein zweiter Wechsel setzen, waehrend der erste
  /// Verlauf noch unterwegs ist.
  bool verlaufHaengt = false;

  /// Offene Verlaufs-Auftraege, gekeyt an der Sitzungs-Id.
  final Map<String, Completer<List<ChatMessage>>> offeneVerlaeufe =
      <String, Completer<List<ChatMessage>>>{};

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 8, 1),
      lastMessageAt: DateTime(2026, 8, 13),
      messageCount: 0,
    ),
    ChatSession(
      id: 's2',
      title: 'Chat B',
      createdAt: DateTime(2026, 8, 2),
      lastMessageAt: DateTime(2026, 8, 12),
      messageCount: 1,
    ),
    ChatSession(
      id: 's3',
      title: 'Chat C',
      createdAt: DateTime(2026, 8, 3),
      lastMessageAt: DateTime(2026, 8, 11),
      messageCount: 1,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  /// Verlauf einer Sitzung — Sitzung A ist leer, B und C tragen je eine
  /// unverwechselbare Nachricht.
  static List<ChatMessage> verlaufVon(String sessionId) => switch (sessionId) {
    's2' => <ChatMessage>[
      ChatMessage(
        id: 'm-b1',
        role: ChatRole.assistant,
        content: verlaufB,
        createdAt: DateTime(2026, 8, 12),
      ),
    ],
    's3' => <ChatMessage>[
      ChatMessage(
        id: 'm-c1',
        role: ChatRole.assistant,
        content: verlaufC,
        createdAt: DateTime(2026, 8, 11),
      ),
    ],
    _ => const <ChatMessage>[],
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

  /// Stand, den der Server nennt.
  ChatQuotaSnapshot quota = const ChatQuotaSnapshot(
    used: 0,
    remaining: 5,
    dailyLimit: 5,
  );

  /// Der Quota-RPC scheitert — der Service wirft dann, statt Zahlen zu
  /// erfinden (W6-07), und `_quota` bleibt null.
  bool quotaUnbekannt = false;

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    if (quotaUnbekannt) {
      throw const CoachDataUnavailable('Test: Quota-RPC gescheitert');
    }
    return quota;
  }

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
  }) {
    gesendeteSessions.add(sessionId);
    final auftrag = Completer<CoachChatReply>();
    offen.add(auftrag);
    return auftrag.future;
  }
}

const Size _usableSize = Size(402, 781);

Future<void> _pumpCoach(WidgetTester tester, _RaceCoach service) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
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
        // `disableAnimations` haelt Denk-Punkte, Orb und Motion still —
        // sonst kommt pumpAndSettle bei laufendem `_sending` nie an.
        data: MediaQueryData.fromView(
          tester.view,
        ).copyWith(disableAnimations: true),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: CoachChatScreen(service: service, userName: 'Moritz'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tippenUndSenden(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

/// Wechselt ueber das Sessions-Sheet auf die Unterhaltung mit diesem Titel.
Future<void> _wechsleAufSitzung(WidgetTester tester, String titel) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(titel));
  await tester.pumpAndSettle();
}

/// Ein paar Frames pumpen, OHNE auf Ruhe zu warten.
///
/// Haengt ein Verlauf, dreht sich der Lade-Kringel endlos — `pumpAndSettle`
/// liefe dann in seinen Timeout, statt etwas ueber den Zustand auszusagen.
/// Die Dauern reichen fuer die Sheet-Transition (250 ms) mit Reserve.
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Wie [_wechsleAufSitzung], aber fuer den Fall, dass der Verlauf haengt.
Future<void> _wechsleAufSitzungOhneRuhe(
  WidgetTester tester,
  String titel,
) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await _pumpFrames(tester);
  await tester.tap(find.text(titel));
  await _pumpFrames(tester);
}

/// Oeffnet das (i)-Sheet ueber den Kopfzeilen-Knopf.
Future<void> _oeffneInfoSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-info')));
  await tester.pumpAndSettle();
}

String _feldText(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const ValueKey('coach-input')))
        .controller
        ?.text ??
    '';

void main() {
  testWidgets(
    'ohne Wechsel: die Antwort erscheint in DER Sitzung, in der gesendet wurde',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage aus Sitzung A');
      svc.offen.first.complete(
        const CoachChatReply(
          reply: 'Antwort auf die Frage aus Sitzung A',
          refusal: false,
          sessionId: 's1',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Antwort auf die Frage aus Sitzung A'),
        findsOneWidget,
        reason:
            'Gegenprobe zum Sitzungs-Vergleich: dreht jemand `!=` auf `==`, '
            'verwirft der Screen JEDE Antwort — die reinen '
            'findsNothing-Tests blieben davon gruen',
      );
      expect(
        find.text('Frage aus Sitzung A'),
        findsOneWidget,
        reason: 'die Frage steht weiter ueber der Antwort',
      );

      // Und der Composer ist wieder frei: der In-Flight-Zaehler steht nach
      // dem Ausgang wieder auf 0.
      await _tippenUndSenden(tester, 'Und noch eine Frage');
      expect(svc.gesendeteSessions, <String>['s1', 's1']);
    },
  );

  testWidgets(
    'Sitzungswechsel waehrend der Antwort: die Antwort auf A taucht NICHT in '
    'B auf',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage aus Sitzung A');
      expect(svc.gesendeteSessions, <String>['s1']);
      expect(svc.offen, hasLength(1), reason: 'die Antwort steht noch aus');

      await _wechsleAufSitzung(tester, 'Chat B');
      expect(
        find.text(_RaceCoach.verlaufB),
        findsOneWidget,
        reason: 'ab hier sieht der Nutzer Sitzung B',
      );

      // Jetzt erst trifft die Antwort auf die Frage aus Sitzung A ein.
      svc.offen.first.complete(
        const CoachChatReply(
          reply: 'Antwort auf die Frage aus Sitzung A',
          refusal: false,
          sessionId: 's1',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Antwort auf die Frage aus Sitzung A'),
        findsNothing,
        reason: 'die Antwort gehoert Sitzung A — in B stuende sie ohne die '
            'zugehoerige Frage da',
      );
      expect(
        find.text(_RaceCoach.verlaufB),
        findsOneWidget,
        reason: 'Sitzung B bleibt unveraendert',
      );

      // Die Blase ist verworfen — der Tages-Slot ist es nicht. Faellt der
      // Quota-Stand mit der Antwort weg, behauptet die Anzeige weiter „5 frei".
      await _oeffneInfoSheet(tester);
      expect(
        find.textContaining('4 von 5 Fragen heute frei'),
        findsOneWidget,
        reason: 'das Kontingent gehoert dem Nutzer, nicht der Sitzung',
      );
    },
  );

  testWidgets(
    'Sitzungswechsel setzt den Sende-Zustand nicht zurueck: kein zweiter '
    'Request neben dem laufenden',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage aus Sitzung A');
      await _wechsleAufSitzung(tester, 'Chat B');

      // Frueher stellte der Wechsel `_sending` auf false — ein Tippen +
      // Senden in B schickte damit eine ZWEITE Anfrage los, waehrend die
      // erste noch lief: zwei Tages-Slots aus einem Bedienschritt.
      await _tippenUndSenden(tester, 'Frage aus Sitzung B');
      expect(
        svc.gesendeteSessions,
        <String>['s1'],
        reason: 'solange eine Anfrage laeuft, geht keine zweite raus',
      );

      // Der Wechsel selbst bleibt benutzbar, und sobald die erste Anfrage
      // einen Ausgang hat, ist die neue Sitzung sendebereit — auch dann,
      // wenn die Antwort verworfen wurde.
      svc.offen.first.complete(
        const CoachChatReply(
          reply: 'Antwort auf die Frage aus Sitzung A',
          refusal: false,
          sessionId: 's1',
          remaining: 4,
          dailyLimit: 5,
        ),
      );
      await tester.pumpAndSettle();

      await _tippenUndSenden(tester, 'Frage aus Sitzung B');
      expect(
        svc.gesendeteSessions,
        <String>['s1', 's2'],
        reason: 'der Composer darf nach dem Ausgang nicht gesperrt bleiben — '
            'der Zaehler wird auch fuer verworfene Antworten freigegeben',
      );
    },
  );

  testWidgets(
    'Wechsel A -> B -> C: der Nachzuegler von B ueberschreibt den Verlauf von '
    'C nicht',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);
      svc.verlaufHaengt = true;

      await _wechsleAufSitzungOhneRuhe(tester, 'Chat B');
      await _wechsleAufSitzungOhneRuhe(tester, 'Chat C');
      expect(
        svc.offeneVerlaeufe.keys,
        containsAll(<String>['s2', 's3']),
        reason: 'beide Verlaeufe sind unterwegs',
      );

      // Der langsame Load der VERLASSENEN Sitzung trifft zuerst ein.
      svc.offeneVerlaeufe['s2']!.complete(_RaceCoach.verlaufVon('s2'));
      await _pumpFrames(tester);
      expect(
        find.text(_RaceCoach.verlaufB),
        findsNothing,
        reason: 'oben steht Chat C — ein Verlauf unter fremdem Sitzungs-Label '
            'sind Gesundheitsdaten am falschen Ort',
      );

      // Und C kommt trotzdem an.
      svc.offeneVerlaeufe['s3']!.complete(_RaceCoach.verlaufVon('s3'));
      await tester.pumpAndSettle();
      expect(find.text(_RaceCoach.verlaufC), findsOneWidget);
      expect(find.text(_RaceCoach.verlaufB), findsNothing);
    },
  );

  testWidgets(
    'Wechsel A -> B -> C: auch der Fehler von B bleibt bei B',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);
      svc.verlaufHaengt = true;

      await _wechsleAufSitzungOhneRuhe(tester, 'Chat B');
      await _wechsleAufSitzungOhneRuhe(tester, 'Chat C');

      svc.offeneVerlaeufe['s2']!.completeError(
        const CoachDataUnavailable('Test: Verlauf von B nicht ladbar'),
      );
      await _pumpFrames(tester);

      expect(
        find.textContaining('Verlauf konnte nicht geladen werden'),
        findsNothing,
        reason: 'der Fehlerzustand gehoert der Sitzung, die ihn ausgeloest '
            'hat — nicht der, die der Nutzer gerade ansieht',
      );
      expect(
        find.byKey(const ValueKey('coach-loading')),
        findsOneWidget,
        reason: 'C laedt noch — der Fehler von B darf den Spinner nicht '
            'abraeumen und eine geladene Sitzung vortaeuschen',
      );

      svc.offeneVerlaeufe['s3']!.complete(_RaceCoach.verlaufVon('s3'));
      await tester.pumpAndSettle();
      expect(find.text(_RaceCoach.verlaufC), findsOneWidget);
      expect(
        find.textContaining('Verlauf konnte nicht geladen werden'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Fehlschlag: der getippte Text steht wieder im Eingabefeld',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      const frage =
          'Eine lange Frage zu meinen Restmakros, die ich nach einem '
          'Netzabbruch nicht noch einmal tippen moechte.';
      await _tippenUndSenden(tester, frage);
      expect(
        _feldText(tester),
        isEmpty,
        reason: 'optimistisch geleert, solange der Request laeuft',
      );

      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Verbindung fehlgeschlagen.'), findsOneWidget);
      expect(
        _feldText(tester),
        frage,
        reason: 'gesendet wurde die Frage nicht — sie darf nicht verloren '
            'gehen, nur weil das Feld vorab geleert wurde',
      );
    },
  );

  testWidgets(
    'Fehlschlag ueberschreibt keinen NEU getippten Entwurf',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Erste Frage');
      // Tippen ist waehrend einer laufenden Antwort erlaubt (_canType).
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Schon die naechste Frage',
      );
      await tester.pump();

      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      expect(
        _feldText(tester),
        'Schon die naechste Frage',
        reason: 'den gerade entstehenden Text zu ueberschreiben waere '
            'schlimmer als der Verlust des alten',
      );
    },
  );

  testWidgets(
    'unbekanntes Kontingent: das (i)-Sheet nennt weder Zahl noch Balken',
    (tester) async {
      final svc = _RaceCoach.create()..quotaUnbekannt = true;
      await _pumpCoach(tester, svc);

      await _oeffneInfoSheet(tester);

      expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('coach-info-limit-unbekannt')),
        findsOneWidget,
        reason: 'der Abschnitt bleibt — nur ohne erfundene Zahl',
      );
      expect(
        find.textContaining('von 5 Fragen heute frei'),
        findsNothing,
        reason: 'niemand hat gesagt, wie viele Fragen frei sind — ein Nutzer '
            'mit verbrauchtem Kontingent laese hier "5 von 5"',
      );
      expect(
        find.text('5 / 5'),
        findsNothing,
        reason: 'der volle Balken behauptet dasselbe wie die Zahl',
      );
      expect(
        find.textContaining('USA'),
        findsAtLeastNWidgets(1),
        reason: 'die C8-Offenlegung steht auch in diesem Fall im Sheet',
      );
    },
  );

  testWidgets(
    'bekanntes Kontingent: Zahl und Balken stehen unveraendert im Sheet',
    (tester) async {
      final svc = _RaceCoach.create()
        ..quota = const ChatQuotaSnapshot(used: 2, remaining: 3, dailyLimit: 5);
      await _pumpCoach(tester, svc);

      await _oeffneInfoSheet(tester);

      expect(find.textContaining('3 von 5 Fragen heute frei'), findsOneWidget);
      expect(find.text('3 / 5'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('coach-info-limit-unbekannt')),
        findsNothing,
      );
    },
  );
}
