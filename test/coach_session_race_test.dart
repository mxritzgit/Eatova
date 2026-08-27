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

// Audit 2026-08-14: a reply belongs to the session its question came from, and
// a failure must not eat the typed text.
//
// `_send` only checked `mounted` after the await, but the screen stays mounted
// and the session button stays usable, so a reply to session A was appended to
// the messages of session B — a coach bubble in a foreign conversation without
// its question. The same held one door further in `_switchToSession`, which
// also wrote the error state of the session just left, and reset `_sending`,
// letting two requests run in parallel (two daily slots from one gesture).
//
// The input field is cleared before the request, so a failed send must restore
// it. And the (i) sheet used to fall back to the standard daily limit when the
// quota RPC failed, telling a user with no quota left that all questions were
// still free.
//
// The tests hold replies open on completers and switch sessions in between,
// which is the only way to open the window the bug lives in. The first test is
// the positive counter-check: flipping `!=` to `==` would discard every reply
// while the findsNothing tests stayed green.

class _RaceCoach extends CoachChatService {
  _RaceCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _RaceCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _RaceCoach(client, 'user-123');
  }

  /// Message in session B's history: proof that B is shown when A's reply
  /// arrives.
  static const String verlaufB = 'Das ist der Verlauf von Sitzung B.';

  /// Same for session C, needed for the A -> B -> C switch where B's late
  /// history would overwrite C's.
  static const String verlaufC = 'Das ist der Verlauf von Sitzung C.';

  /// Pending send jobs in arrival order; tests resolve them by hand to place
  /// the session switch mid-request.
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];

  /// Session ids of the `send()` calls, in order.
  final List<String> gesendeteSessions = <String>[];

  /// While true every `loadHistory` call hangs on a completer, so a second
  /// switch can happen while the first history is still in flight.
  bool verlaufHaengt = false;

  /// Pending history jobs, keyed by session id.
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

  /// History of a session: A is empty, B and C each carry one unmistakable
  /// message.
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

  /// The state the server reports.
  ChatQuotaSnapshot quota = const ChatQuotaSnapshot(
    used: 0,
    remaining: 5,
    dailyLimit: 5,
  );

  /// Makes the quota RPC fail: the service throws instead of inventing
  /// numbers (W6-07) and `_quota` stays null.
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
      // The coach uses context.l10n, and AppLocalizations.of() throws on the
      // first build without localization.
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        // `disableAnimations` stills the thinking dots, orb and motion;
        // otherwise pumpAndSettle never settles while `_sending` runs.
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

/// Switches to the conversation with this title via the sessions sheet.
Future<void> _wechsleAufSitzung(WidgetTester tester, String titel) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(titel));
  await tester.pumpAndSettle();
}

/// Pumps a few frames without waiting for settle: while a history hangs the
/// spinner never stops, so `pumpAndSettle` would just time out. The durations
/// cover the 250 ms sheet transition with room to spare.
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Like [_wechsleAufSitzung], but for a hanging history.
Future<void> _wechsleAufSitzungOhneRuhe(
  WidgetTester tester,
  String titel,
) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await _pumpFrames(tester);
  await tester.tap(find.text(titel));
  await _pumpFrames(tester);
}

/// Opens the (i) sheet via the header button.
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

      // The composer is free again: the in-flight counter is back to 0.
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

      // Only now does the reply to session A's question arrive.
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

      // The bubble is discarded, the daily slot is not: dropping the quota
      // with the reply would keep claiming all questions are free.
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

      // The switch used to reset `_sending`, so typing and sending in B fired
      // a second request while the first still ran: two daily slots from one
      // gesture.
      await _tippenUndSenden(tester, 'Frage aus Sitzung B');
      expect(
        svc.gesendeteSessions,
        <String>['s1'],
        reason: 'solange eine Anfrage laeuft, geht keine zweite raus',
      );

      // Switching stays usable, and once the first request has an outcome the
      // new session can send, even if the reply was discarded.
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

      // The slow load of the abandoned session arrives first.
      svc.offeneVerlaeufe['s2']!.complete(_RaceCoach.verlaufVon('s2'));
      await _pumpFrames(tester);
      expect(
        find.text(_RaceCoach.verlaufB),
        findsNothing,
        reason: 'oben steht Chat C — ein Verlauf unter fremdem Sitzungs-Label '
            'sind Gesundheitsdaten am falschen Ort',
      );

      // And C still arrives.
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
    'Fehlschlag: die Frage bleibt als Blase mit Marker, das Feld bleibt leer',
    (tester) async {
      // Fix run 2026-08-27 (F5-01): draft restore AND retry marker were two
      // homes for the same text — the send button produced a duplicate. The
      // marker is the only one now.
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
        isEmpty,
        reason: 'die Frage lebt in der Blase mit „Nicht gesendet" weiter, '
            'nicht ein zweites Mal im Feld',
      );
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget);
    },
  );

  testWidgets(
    'Erneut senden ueberschreibt keinen NEU getippten Entwurf',
    (tester) async {
      // Fix run 2026-08-27 (F5-01): the failure itself no longer touches the
      // field, so the only path that clears it is the retry — `_send` always
      // clears, even with `textOverride`, and must hand the draft back.
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Erste Frage');
      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Schon die naechste Frage',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();

      expect(svc.offen, hasLength(2), reason: 'der Retry ging als Request raus');
      expect(
        _feldText(tester),
        'Schon die naechste Frage',
        reason: 'den gerade entstehenden Text zu ueberschreiben waere '
            'schlimmer als der Verlust des alten',
      );
    },
  );

  testWidgets(
    'Erneut senden mit derselben Frage im Feld: das Feld bleibt leer',
    (tester) async {
      final svc = _RaceCoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Erste Frage');
      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      // Typed the failed question again by hand, then chose the retry.
      await tester.enterText(
        find.byKey(const ValueKey('coach-input')),
        'Erste Frage',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();

      expect(svc.offen, hasLength(2), reason: 'der Retry ging als Request raus');
      expect(
        _feldText(tester),
        isEmpty,
        reason: 'der Wiederholversuch hat genau diesen Text verbraucht — ihn '
            'zurueckzulegen hiesse, ihn ein drittes Mal anzubieten',
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
