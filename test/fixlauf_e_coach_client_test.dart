import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

// Fix run 2026-08-27, package E (coach client):
//
//  F5-01  a failed question lives ONLY in the unsent marker — the field is not
//         refilled, and sending the same text again replaces the bubble.
//  F5-05  the mic renders on iOS only (the speech channel has no Android
//         implementation).
//  F5-06  dictation fills the field and never sends by itself.
//  F5-09  "new conversation" carries the localized title; stored placeholders
//         display localized.
//  F5-11  thinking dots show in the session that is sending, not in the one
//         the user switched to.

class _ECoach extends CoachChatService {
  _ECoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue's constructor timer trips every
  /// widget test.
  static _ECoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _ECoach(client, 'user-123');
  }

  List<ChatSession> sessions = <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 8, 1),
      lastMessageAt: DateTime(2026, 8, 27),
      messageCount: 1,
    ),
    ChatSession(
      id: 's2',
      title: 'Chat B',
      createdAt: DateTime(2026, 8, 2),
      lastMessageAt: DateTime(2026, 8, 26),
      messageCount: 1,
    ),
  ];

  final List<String> gesendeteTexte = <String>[];
  final List<Completer<CoachChatReply>> offen = <Completer<CoachChatReply>>[];
  final List<String> neueSessionTitel = <String>[];

  @override
  Future<List<ChatSession>> loadSessions() async => sessions;

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<String?> createSession({required String title}) async {
    neueSessionTitel.add(title);
    return 's-neu';
  }

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
      {int limit = 100}) async {
    return <ChatMessage>[
      ChatMessage(
        id: 'm-$sessionId',
        role: ChatRole.assistant,
        content: 'Verlauf $sessionId',
        createdAt: DateTime(2026, 8, 26),
      ),
    ];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

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

/// Dictation stub: resolves with [text] right away, or — with [haengt] — only
/// once `stop()` is called.
class _Diktat extends CoachSpeechInput {
  _Diktat(this.text, {this.haengt = false});

  final String text;
  final bool haengt;
  Completer<String?>? _laufend;

  @override
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) {
    if (!haengt) return Future<String?>.value(text);
    final c = Completer<String?>();
    _laufend = c;
    return c.future;
  }

  @override
  Future<void> stop() async {
    _laufend?.complete(text);
    _laufend = null;
  }
}

const Size _usableSize = Size(402, 781);

/// Runs [body] as iOS. Reset in `finally`, not in a tearDown: the binding
/// checks foundation vars before tearDowns run.
Future<void> _alsIOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpCoach(
  WidgetTester tester,
  _ECoach service, {
  Locale locale = const Locale('de'),
  CoachSpeechInput speechInput = const CoachSpeechInput(),
}) async {
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
        // Motion off, or `pumpAndSettle` never returns while sending.
        data: MediaQueryData.fromView(tester.view)
            .copyWith(disableAnimations: true),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: CoachChatScreen(
              service: service,
              userName: 'Moritz',
              speechInput: speechInput,
            ),
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

/// Bubbles only: `find.text` would also match the composer.
int _blasenMit(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.byType(Text))
    .where((w) => w.data == text)
    .length;

TextField _feld(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('coach-input')));

const CoachChatReply _antwort = CoachChatReply(
  reply: 'Antwort vom Coach.',
  refusal: false,
  sessionId: 's1',
  remaining: 4,
  dailyLimit: 5,
);

void main() {
  group('F5-01 Fehlschlag: Marker statt Entwurf', () {
    testWidgets(
        'nach dem Fehlschlag bleibt das Feld leer; derselbe Text ueber den '
        'Senden-Knopf ersetzt die Blase, statt sie zu verdoppeln',
        (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      const frage = 'Wie viel Protein fehlt mir heute noch?';
      await _tippenUndSenden(tester, frage);
      svc.offen.first.completeError(
        const CoachChatException('Verbindung fehlgeschlagen.'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(_feld(tester).controller?.text, '',
          reason: 'Draft-Restore UND Marker waren doppelt — der Marker bleibt');
      expect(_blasenMit(tester, frage), 1);

      await _tippenUndSenden(tester, frage);

      expect(svc.gesendeteTexte, <String>[frage, frage]);
      expect(_blasenMit(tester, frage), 1,
          reason: 'die alte unsent-Blase weicht der neuen mit gleichem Text');
      expect(find.byKey(const ValueKey('coach-unsent')), findsNothing,
          reason: 'ein neuer Versuch laeuft — der alte Marker ist erledigt');

      svc.offen.last.complete(_antwort);
      await tester.pumpAndSettle();
      expect(_blasenMit(tester, frage), 1);
      expect(find.text('Antwort vom Coach.'), findsOneWidget);
    });

    testWidgets(
        'Fehlschlag → Erneut senden → zweiter Fehlschlag → Senden-Knopf: '
        'immer genau eine Blase, drei Requests', (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      const frage = 'Passt Lachs heute noch rein?';
      await _tippenUndSenden(tester, frage);
      svc.offen[0].completeError(const CoachChatException('Fehler 1'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();
      svc.offen[1].completeError(const CoachChatException('Fehler 2'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(_blasenMit(tester, frage), 1);
      expect(_feld(tester).controller?.text, '');

      await _tippenUndSenden(tester, frage);

      expect(svc.gesendeteTexte, <String>[frage, frage, frage]);
      expect(_blasenMit(tester, frage), 1);
      expect(find.byKey(const ValueKey('coach-unsent')), findsNothing);
    });

    testWidgets(
        'anderer Text nach dem Fehlschlag: die alte Blase bleibt MIT Marker, '
        'die neue steht daneben', (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage A');
      svc.offen.first.completeError(const CoachChatException('Fehler'));
      await tester.pumpAndSettle();

      await _tippenUndSenden(tester, 'Frage B');

      expect(_blasenMit(tester, 'Frage A'), 1);
      expect(_blasenMit(tester, 'Frage B'), 1);
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget,
          reason: 'A ging nie raus — ohne Marker saehe die Blase zugestellt '
              'aus');
      expect(svc.gesendeteTexte, <String>['Frage A', 'Frage B']);

      svc.offen.last.complete(_antwort);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-unsent')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-unsent-retry')), findsOneWidget,
          reason: 'B ist zugestellt, A wartet weiter auf den Wiederholversuch');

      // The retry still targets A: it resends A and replaces A's bubble.
      await tester.tap(find.byKey(const ValueKey('coach-unsent-retry')));
      await tester.pumpAndSettle();
      expect(svc.gesendeteTexte, <String>['Frage A', 'Frage B', 'Frage A']);
      expect(_blasenMit(tester, 'Frage A'), 1);
      expect(find.byKey(const ValueKey('coach-unsent')), findsNothing);
    });
  });

  group('F5-05 Mikro nur auf iOS', () {
    testWidgets('unter Android (Test-Default) gibt es keinen Mikro-Knopf',
        (tester) async {
      await _pumpCoach(tester, _ECoach.create());
      expect(find.byKey(const ValueKey('coach-mic')), findsNothing,
          reason: 'der MethodChannel eatova/speech existiert nur im iOS-Runner');
      expect(find.byKey(const ValueKey('coach-send')), findsOneWidget);
    });

    testWidgets('unter iOS steht der Mikro-Knopf im Composer', (tester) async {
      await _alsIOS(() async {
        await _pumpCoach(tester, _ECoach.create());
        expect(find.byKey(const ValueKey('coach-mic')), findsOneWidget);
      });
    });
  });

  group('F5-06 Diktat fuellt das Feld, sendet nicht', () {
    testWidgets('erkannter Text landet mit Cursor am Ende im Feld',
        (tester) async {
      await _alsIOS(() async {
        final svc = _ECoach.create();
        const gesprochen = 'Wie viele Kalorien hat ein Apfel';
        await _pumpCoach(tester, svc, speechInput: _Diktat(gesprochen));

        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await tester.pumpAndSettle();

        final feld = _feld(tester);
        expect(feld.controller?.text, gesprochen);
        expect(feld.controller?.selection.baseOffset, gesprochen.length);
        expect(feld.focusNode?.hasFocus, isTrue);
        expect(svc.gesendeteTexte, isEmpty,
            reason: 'ein falsch erkannter Satz darf keinen Tages-Slot kosten');
        expect(_blasenMit(tester, gesprochen), 0);

        // The user reviews and sends by hand.
        await tester.tap(find.byKey(const ValueKey('coach-send')));
        await tester.pumpAndSettle();
        expect(svc.gesendeteTexte, <String>[gesprochen]);
      });
    });

    testWidgets('Stop waehrend listen: Feld gefuellt, nichts gesendet',
        (tester) async {
      await _alsIOS(() async {
        final svc = _ECoach.create();
        const gesprochen = 'Was esse ich heute Abend';
        await _pumpCoach(
          tester,
          svc,
          speechInput: _Diktat(gesprochen, haengt: true),
        );

        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await tester.pumpAndSettle();
        expect(find.text('Ich höre zu…'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await tester.pumpAndSettle();

        expect(find.text('Ich höre zu…'), findsNothing);
        expect(_feld(tester).controller?.text, gesprochen);
        expect(svc.gesendeteTexte, isEmpty);
      });
    });
  });

  group('F5-09 Session-Titel lokalisiert', () {
    for (final (locale, erwartet) in <(Locale, String)>[
      (const Locale('de'), 'Neue Unterhaltung'),
      (const Locale('en'), 'New conversation'),
    ]) {
      testWidgets('„Neu" uebergibt unter ${locale.languageCode} „$erwartet"',
          (tester) async {
        final svc = _ECoach.create();
        await _pumpCoach(tester, svc, locale: locale);

        await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
        await tester.pumpAndSettle();

        expect(svc.neueSessionTitel, <String>[erwartet]);
      });

      testWidgets(
          'gespeicherte Platzhalter zeigen unter ${locale.languageCode} '
          '„$erwartet", echte Titel bleiben', (tester) async {
        final svc = _ECoach.create()
          ..sessions = <ChatSession>[
            for (final (i, titel) in <String>[
              'Neue Unterhaltung',
              'New conversation',
              'Allgemein',
              '',
              'Protein am Abend',
            ].indexed)
              ChatSession(
                id: 's$i',
                title: titel,
                createdAt: DateTime(2026, 8, 1),
                lastMessageAt: DateTime(2026, 8, 27),
                messageCount: 1,
              ),
          ];
        await _pumpCoach(tester, svc, locale: locale);

        await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
        await tester.pumpAndSettle();

        expect(find.text(erwartet), findsNWidgets(4));
        expect(find.text('Protein am Abend'), findsOneWidget);
        expect(find.text('Allgemein'), findsNothing);
      });
    }
  });

  group('F5-11 Denk-Punkte nur in der sendenden Session', () {
    testWidgets('Sitzungswechsel waehrend der Antwort zeigt in B keine Punkte',
        (tester) async {
      final svc = _ECoach.create();
      await _pumpCoach(tester, svc);

      await _tippenUndSenden(tester, 'Frage in A');
      expect(find.byKey(const ValueKey('coach-thinking')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat B'));
      await tester.pumpAndSettle();

      expect(find.text('Verlauf s2'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-thinking')), findsNothing,
          reason: 'B wartet auf nichts — die Punkte gehoeren zu A');

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat A'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('coach-thinking')), findsOneWidget,
          reason: 'zurueck in A laeuft die Anfrage noch');

      svc.offen.first.complete(_antwort);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('coach-thinking')), findsNothing);
    });
  });
}
