import 'dart:async';
import 'dart:io';

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
import 'package:eatova/src/theme/app_tokens.dart';

// Design-Refactor 2026-08-09, Paket „Coach".
//
// Diese Datei haelt fest, was der Umbau NEU zusichert (Kopfzeile, Blasen,
// Composer ohne Theme-Kasten) und was er NICHT veraendern darf (ein Vorschlag
// fuellt nur das Feld, „Verlauf nicht ladbar" zeigt weder Hero noch
// Vorschlaege). Die Zustands-Zusicherungen des Screens liegen weiter in den
// sieben bestehenden coach_*-Dateien; hier steht nur, was Optik heisst.

/// Nutzbare Flaeche eines iPhone 16 Pro. Die 800x600-Standardview des
/// Testbindings ist kuerzer als jedes Zielgeraet und laesst den Hero
/// ueberlaufen (vgl. coach_ai_disclosure_test.dart).
const Size _usableSize = Size(402, 781);

/// Bleibt im Zuhoer-Zustand haengen: `listen()` loest nie auf, `_listening`
/// bleibt also true, bis der Test fertig ist.
class _EndlosMikro extends CoachSpeechInput {
  const _EndlosMikro();

  @override
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) =>
      Completer<String?>().future;

  @override
  Future<void> stop() async {}
}

class _FakeCoach extends CoachChatService {
  _FakeCoach(super.client, super.userId);

  /// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
  /// periodischen Timer, an dem jeder Widget-Test scheitert.
  static _FakeCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FakeCoach(client, 'user-123');
  }

  List<ChatMessage> history = const <ChatMessage>[];
  bool historyFails = false;
  ChatQuotaSnapshot quota =
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
  int sendCalls = 0;

  /// Gesetzt: `send()` haengt (fuer den Denk-Zustand).
  Completer<CoachChatReply>? sendGate;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat A',
          createdAt: DateTime(2026, 8, 1),
          lastMessageAt: DateTime(2026, 8, 8),
          messageCount: 2,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
      {int limit = 100}) async {
    if (historyFails) {
      throw const CoachDataUnavailable('Verlauf nicht abrufbar');
    }
    return history;
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async => quota;

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
  }) {
    sendCalls++;
    final gate = sendGate;
    if (gate != null) return gate.future;
    return Future<CoachChatReply>.value(
      CoachChatReply(
        reply: 'Antwort vom Coach.',
        refusal: false,
        remaining: 4,
        sessionId: sessionId,
      ),
    );
  }
}

ChatMessage _msg(String content, ChatRole role) => ChatMessage(
      id: '$role-$content',
      role: role,
      content: content,
      createdAt: DateTime(2026, 8, 8, 12),
    );

Future<void> _pumpCoach(
  WidgetTester tester, {
  required _FakeCoach service,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  CoachSpeechInput speechInput = const CoachSpeechInput(),
  Locale locale = const Locale('de'),
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Wer in einem Test zweimal pumpt (hell/dunkel im selben Rumpf), bekommt
  // sonst DENSELBEN Element-Baum zurueck: gleiche Widget-Typen an gleicher
  // Stelle heisst Wiederverwendung, und damit ueberleben State (z. B. ein
  // laufendes Mikro) und offene Routen (ein Sheet aus dem ersten Durchlauf)
  // den Moduswechsel. Der leere Zwischenschritt wirft den Baum weg.
  await tester.pumpWidget(const SizedBox.shrink());

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // Der Coach ruft seit der i18n-Migration (Paket 4) context.l10n — ohne
      // Lokalisierung wirft AppLocalizations.of() beim ersten Build.
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        // Aus der echten View abgeleitet statt frisch gebaut: ein blankes
        // MediaQueryData haette Size.zero, und alles, was seine Breite oder
        // Hoehe daraus liest, rechnete mit 0.
        // `disableAnimations`: sonst laufen Orb, Mic-Puls und Denk-Punkte
        // endlos und pumpAndSettle laeuft aus.
        data: MediaQueryData.fromView(tester.view).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Padding(
            // Dieselbe Schale wie eatova_home_page.dart: der Tab bekommt
            // seinen Seitenrand von aussen, der Screen setzt innen 0.
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: CoachChatScreen(
              service: service,
              userName: 'Moritz',
              streak: 3,
              speechInput: speechInput,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Die Blase um einen Nachrichtentext: der naechste [Container] mit
/// [BoxDecoration] oberhalb des Textes.
BoxDecoration _bubbleDecoration(WidgetTester tester, String text) {
  final container = tester
      .widgetList<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)),
      )
      .firstWhere((c) => c.decoration is BoxDecoration);
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('Kopf traegt Marke, Zustandszeile und die drei Bedienelemente',
      (tester) async {
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      await _pumpCoach(tester, service: _FakeCoach.create(), brightness: brightness);

      expect(find.text('KI-Coach'), findsOneWidget);
      expect(find.text('Sieht dein heutiges Log'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-info')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-sessions-open')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Nutzer-Blase liegt in Forest, Coach-Blase auf surf mit line-Rand',
      (tester) async {
    final svc = _FakeCoach.create()
      ..history = <ChatMessage>[
        _msg('Was soll ich abends essen?', ChatRole.user),
        _msg('Nimm Lachs mit Suesskartoffel.', ChatRole.assistant),
      ];
    await _pumpCoach(tester, service: svc);

    const t = AppTokens.dark;
    final user = _bubbleDecoration(tester, 'Was soll ich abends essen?');
    expect(user.color, t.forest);

    final coach = _bubbleDecoration(tester, 'Nimm Lachs mit Suesskartoffel.');
    expect(coach.color, t.surf,
        reason: 'der Coach bekommt in der neuen Sprache eine eigene Flaeche, '
            'nicht mehr Plain-Text auf dem Seitengrund');
    expect((coach.border! as Border).top.color, t.line);
  });

  testWidgets('Nutzer-Text steht in onForest, Coach-Text in ink', (tester) async {
    final svc = _FakeCoach.create()
      ..history = <ChatMessage>[
        _msg('Meine Frage', ChatRole.user),
        _msg('Meine Antwort', ChatRole.assistant),
      ];
    await _pumpCoach(tester, service: svc, brightness: Brightness.light);

    const t = AppTokens.light;
    expect(tester.widget<Text>(find.text('Meine Frage')).style?.color,
        t.onForest);
    expect(tester.widget<Text>(find.text('Meine Antwort')).style?.color, t.ink);
  });

  testWidgets('Vorschlag fuellt nur das Feld und sendet nicht', (tester) async {
    final svc = _FakeCoach.create();
    await _pumpCoach(tester, service: svc);

    const vorschlag = 'Was soll ich heute noch essen?';
    await tester.tap(find.byKey(const ValueKey('coach-suggestion-0')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.controller?.text, vorschlag);
    expect(svc.sendCalls, 0,
        reason: 'die Quota ist knapp — der Nutzer behaelt die Kontrolle vor '
            'dem Abschicken');
  });

  testWidgets('Composer-Feld traegt keine Theme-Fuellung und keinen Rahmen',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    final deco = field.decoration!;
    // Ohne diese vier Ueberschreibungen schlaegt inputDecorationTheme durch
    // (filled: true + OutlineInputBorder) und es sitzt ein zweiter gefuellter,
    // gerahmter Kasten in der Composer-Kapsel.
    expect(deco.filled, isFalse);
    expect(deco.border, InputBorder.none);
    expect(deco.enabledBorder, InputBorder.none);
    expect(deco.focusedBorder, InputBorder.none);
    expect(deco.disabledBorder, InputBorder.none);
  });

  testWidgets('Verlauf nicht ladbar zeigt weder Hero noch Vorschlaege',
      (tester) async {
    final svc = _FakeCoach.create()..historyFails = true;
    await _pumpCoach(tester, service: svc);

    expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
    expect(find.byKey(const ValueKey('coach-suggestion-0')), findsNothing,
        reason: '„Frag doch mal…" ueber einem Banner, das sagt, der Verlauf '
            'sei nicht ladbar, waere ein Widerspruch');
    expect(find.textContaining('Verlauf konnte nicht geladen'), findsOneWidget);
  });

  testWidgets('knappes Kontingent zeigt den Hinweis', (tester) async {
    final svc = _FakeCoach.create()
      ..quota = const ChatQuotaSnapshot(used: 3, remaining: 2, dailyLimit: 5);
    await _pumpCoach(tester, service: svc);

    expect(find.byKey(const ValueKey('coach-quota-hint')), findsOneWidget);
    expect(find.text('Noch 2 Fragen heute'), findsOneWidget);
  });

  testWidgets('Coach ueberlebt textScaler 2.0 — Hero und Konversation',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create(), textScale: 2.0);
    expect(tester.takeException(), isNull);

    final svc = _FakeCoach.create()
      ..history = <ChatMessage>[
        _msg('Eine ziemlich lange Nutzerfrage ueber Makros und Kalorien',
            ChatRole.user),
        _msg('Eine ebenso lange Antwort mit Zahlen und Empfehlungen darin',
            ChatRole.assistant),
      ];
    await _pumpCoach(
      tester,
      service: svc,
      brightness: Brightness.light,
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Denk-Punkte respektieren reduzierte Bewegung', (tester) async {
    final svc = _FakeCoach.create()..sendGate = Completer<CoachChatReply>();
    await _pumpCoach(tester, service: svc);

    await tester.enterText(
      find.byKey(const ValueKey('coach-input')),
      'Wie viel Protein fehlt mir?',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coach-send')));
    // Terminiert nur, wenn _ThinkingRow seinen Dauer-Controller unter
    // disableAnimations anhaelt — sonst laeuft pumpAndSettle in den Timeout.
    await tester.pumpAndSettle();

    expect(svc.sendCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('der Zuhoer-Zustand des Mikros ist in beiden Modi sichtbar',
      (tester) async {
    // `lime` auf der hellen Composer-Kapsel kaeme im Hellmodus auf rund
    // 1,2:1 — das Mikro saehe aus, als sei nichts passiert, obwohl es
    // zuhoert. Der Zustand faerbt sich deshalb in `accent`.
    for (final (brightness, tokens) in <(Brightness, AppTokens)>[
      (Brightness.dark, AppTokens.dark),
      (Brightness.light, AppTokens.light),
    ]) {
      await _pumpCoach(
        tester,
        service: _FakeCoach.create(),
        brightness: brightness,
        speechInput: const _EndlosMikro(),
      );

      final mic = find.byKey(const ValueKey('coach-mic'));
      final glyph = find.descendant(
        of: mic,
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      expect(tester.widget<Icon>(glyph).color, tokens.ink2,
          reason: 'im Ruhezustand bleibt das Mikro eine stille Beschriftung');

      await tester.tap(mic);
      await tester.pumpAndSettle();

      expect(tester.widget<Icon>(glyph).color, tokens.accent);
      expect(find.text('Ich höre zu…'), findsOneWidget);
    }
  });

  testWidgets('Sessions-Sheet steht in beiden Modi mit Liste und „Neu"',
      (tester) async {
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      await _pumpCoach(
        tester,
        service: _FakeCoach.create(),
        brightness: brightness,
      );

      await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
      await tester.pumpAndSettle();

      expect(find.text('Coach-Sessions'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-sessions-new')), findsOneWidget);
      expect(find.text('Chat A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Info-Sheet traegt die C8-Offenlegung in beiden Modi',
      (tester) async {
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      await _pumpCoach(
        tester,
        service: _FakeCoach.create(),
        brightness: brightness,
      );

      await tester.tap(find.byKey(const ValueKey('coach-info')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
      expect(find.text('Das schickt jede Frage mit'), findsOneWidget);
      expect(find.textContaining('OpenRouter'), findsOneWidget);
      expect(find.textContaining('5 von 5 Fragen heute frei'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Attach-Sheet schliesst sich selbst, nicht den Screen',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    await tester.tap(find.byKey(const ValueKey('coach-attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-gallery')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('coach-camera')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-camera')), findsNothing);
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget,
        reason: 'der Pop muss die Sheet-Route treffen, nicht die darunter');
  });

  test('kein app_colors und keine harte Farbe mehr im Coach', () {
    final dir = Directory('lib/src/screens/coach');
    final verboten = <String>[
      'app_colors',
      'Color(0x',
      'coachAccent',
      'textPrimary',
      'textMuted',
      'surfaceSoft',
      'hairline',
      'cardShadow',
    ];
    final treffer = <String>[];
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final quelle = file.readAsStringSync();
      for (final wort in verboten) {
        if (quelle.contains(wort)) {
          treffer.add('${file.uri.pathSegments.last}: $wort');
        }
      }
    }
    expect(treffer, isEmpty,
        reason: 'Farbe kommt ausschliesslich aus context.t (AppTokens)');
  });

  group('EN-Render-Smoke (i18n-Paket 4, Spec §6)', () {
    // Rendert unter Locale `en` in beiden Helligkeiten: kein Absturz, und
    // mindestens eine echte englische Uebersetzung steht im Baum. Muster:
    // test/recipes_design_test.dart (Paket 3).
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      testWidgets('Coach-Tab rendert unter en in $brightness ohne Ausnahme',
          (tester) async {
        await _pumpCoach(
          tester,
          service: _FakeCoach.create(),
          brightness: brightness,
          locale: const Locale('en'),
        );

        expect(tester.takeException(), isNull,
            reason: 'Rendering unter en/$brightness ist fehlgeschlagen');
        // „KI-Coach" -> „AI Coach", „Wie kann ich dir helfen?" ->
        // „How can I help you?".
        expect(find.text('AI Coach'), findsOneWidget);
        expect(find.text('How can I help you?'), findsOneWidget);
      });
    }
  });
}
