import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

// Coach design refactor: this file pins what the redesign guarantees (header,
// bubbles, composer without a theme box) and what it must not change. The
// state assertions live in the existing coach_* files; this one is about
// appearance.

/// Usable area of an iPhone 16 Pro. The binding's 800x600 default view is
/// shorter than any target device and lets the hero overflow.
const Size _usableSize = Size(402, 781);

/// Stays in the listening state: `listen()` never resolves, so `_listening`
/// remains true until the test ends.
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

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
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

  /// When set, `send()` hangs (for the thinking state).
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

  // Pumping twice in one test (light/dark) would otherwise reuse the SAME
  // element tree, so state (a running mic) and open routes (a sheet from the
  // first pass) survive the mode switch. The empty step throws the tree away.
  await tester.pumpWidget(const SizedBox.shrink());

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // The coach calls context.l10n; without localization
      // AppLocalizations.of() throws on the first build.
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        // Derived from the real view, not freshly built: a blank
        // MediaQueryData would have Size.zero. `disableAnimations` stops the
        // endless orb/mic/thinking animations that would time out
        // pumpAndSettle.
        data: MediaQueryData.fromView(tester.view).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Padding(
            // Same shell as eatova_home_page.dart: the tab gets its side
            // padding from outside, the screen uses 0 inside.
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

/// The bubble around a message text: the nearest [Container] with a
/// [BoxDecoration] above the text.
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

  testWidgets('Tippen rebuildet die Konversation nicht — nur der Composer '
      'haengt am Entwurf', (tester) async {
    // Perf round 2026-08-31, finding 3: the draft lived as screen state, so
    // every keystroke rebuilt the whole screen including all visible bubbles.
    final svc = _FakeCoach.create()
      ..history = <ChatMessage>[
        _msg('Was soll ich abends essen?', ChatRole.user),
        _msg('Nimm Lachs mit Suesskartoffel.', ChatRole.assistant),
      ];
    await _pumpCoach(tester, service: svc);

    final vorher = tester.widget(find.byType(ListView));
    await tester.enterText(
        find.byKey(const ValueKey('coach-input')), 'Wie viel Protein noch?');
    await tester.pump();
    final nachher = tester.widget(find.byType(ListView));
    expect(identical(vorher, nachher), isTrue,
        reason: 'Ein Tastendruck darf nicht die Nachrichtenliste neu bauen — '
            'der Entwurf gehoert allein dem Composer und dem Befehls-Menue.');

    // The draft still reaches its two consumers: "/" opens the command menu,
    // a non-command draft closes it again.
    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('coach-command-menu')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('coach-input')), 'x');
    await tester.pump();
    expect(find.byKey(const ValueKey('coach-command-menu')), findsNothing);
  });

  testWidgets('Composer-Feld traegt keine Theme-Fuellung und keinen Rahmen',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    final deco = field.decoration!;
    // Without these overrides inputDecorationTheme bleeds through (filled +
    // OutlineInputBorder) and a second boxed field sits in the composer.
    expect(deco.filled, isFalse);
    expect(deco.border, InputBorder.none);
    expect(deco.enabledBorder, InputBorder.none);
    expect(deco.focusedBorder, InputBorder.none);
    expect(deco.disabledBorder, InputBorder.none);

    // The capsule itself (nearest AnimatedContainer above the field): soft
    // surface with shadow, NO hairline — the rejected look (F5-04).
    final kapsel = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('coach-input')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final kapselDeco = kapsel.decoration! as BoxDecoration;
    expect(kapselDeco.border, isNull,
        reason: 'rahmenlose Eingabe: Tiefe kommt vom Schatten, nicht von line');
    expect(kapselDeco.boxShadow, isNotEmpty);
    expect(kapselDeco.color, AppTokens.dark.field);
  });

  testWidgets('Fokus hellt die Composer-Kapsel auf (field → fieldFocus), kein Ring',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    BoxDecoration kapsel() => tester
        .widget<AnimatedContainer>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('coach-input')),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        )
        .decoration! as BoxDecoration;

    const t = AppTokens.dark;
    expect(kapsel().color, t.field);

    await tester.tap(find.byKey(const ValueKey('coach-input')));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byKey(const ValueKey('coach-input')))
        .focusNode
        ?.hasFocus, isTrue);
    expect(kapsel().color, t.fieldFocus,
        reason: 'Fokus = Flaechen-Aufhellung, nicht Rahmen');
    expect(kapsel().border, isNull);
  });

  testWidgets('„Abbrechen" im Loesch-Dialog bleibt leise (ink2, nicht accent)',
      (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    const t = AppTokens.dark;
    final abbrechen = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.widgetWithText(TextButton, 'Abbrechen'),
        matching: find.text('Abbrechen'),
      ),
    );
    expect(abbrechen.text.style?.color, t.ink2,
        reason: 'ein lautes Abbrechen neben dem roten Loeschen kehrt die '
            'Gewichtung um');
    expect(abbrechen.text.style?.color, isNot(t.accent));

    final loeschen = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.widgetWithText(TextButton, 'Löschen'),
        matching: find.text('Löschen'),
      ),
    );
    expect(loeschen.text.style?.color, t.danger);
  });

  testWidgets('Verlauf nicht ladbar zeigt keinen Hero', (tester) async {
    final svc = _FakeCoach.create()..historyFails = true;
    await _pumpCoach(tester, service: svc);

    expect(find.byKey(const ValueKey('coach-empty')), findsNothing,
        reason: 'der Leerzustand behauptet „noch keine Unterhaltung", '
            'waehrend der Verlauf existiert — stattdessen Fehler-Banner');
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
    // Only terminates if _ThinkingRow stops its endless controller under
    // disableAnimations; otherwise pumpAndSettle times out.
    await tester.pumpAndSettle();

    expect(svc.sendCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('der Zuhoer-Zustand des Mikros ist in beiden Modi sichtbar',
      (tester) async {
    // The mic renders on iOS only (the speech channel lives in the iOS
    // runner); tests run as Android by default. Reset in `finally`, not in a
    // tearDown: the binding checks foundation vars before tearDowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      // `lime` on the light composer capsule reaches only ~1.2:1, so the mic
      // would look idle while listening. The state uses `accent` instead.
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
    } finally {
      debugDefaultTargetPlatformOverride = null;
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

  // The source guard "kein app_colors und keine harte Farbe mehr im Coach"
  // moved to test/repo_rules_test.dart, where `lib/` is walked once.

  group('EN-Render-Smoke (i18n-Paket 4, Spec §6)', () {
    // Renders under locale `en` in both brightnesses: no crash, and at least
    // one real English translation is in the tree.
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
        // The German header strings become their English counterparts.
        expect(find.text('AI Coach'), findsOneWidget);
        expect(find.text('How can I help you?'), findsOneWidget);
      });
    }
  });
}
