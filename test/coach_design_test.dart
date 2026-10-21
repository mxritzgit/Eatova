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
import 'package:eatova/src/theme/app_tokens.dart';

// Coach design: what the dark redesign (2026-09-28) must keep for the user:
// the AI named for screen readers, readable bubble pairs, the borderless
// composer, text scaling, reduced motion, a visible listening state. The
// state assertions live in the other coach_* files, the info sheet's
// disclosure in coach_ai_disclosure_test.dart.

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
    int token = 0,
    ValueChanged<String>? onPartial,
    ValueChanged<CoachSpeechEnd>? onEnd,
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
    void Function(String text)? onPartialReply,
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
            // Same shell as eatova_home_page.dart: the coach tab owns its
            // gutters, the shell passes no padding.
            padding: EdgeInsets.zero,
            child: CoachChatScreen(
              service: service,
              userName: 'Moritz',
              // The shell always hands the day context to a signed-in coach.
              userContext: 'Kontext',
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
  testWidgets('Kopf: Screenreader hoeren "KI-Coach", beide Knoepfe sind '
      'mindestens 44 dp gross', (tester) async {
    await _pumpCoach(tester, service: _FakeCoach.create());

    // Visible "Coach" like the design; screen readers hear "KI-Coach".
    expect(tester.widget<Text>(find.text('Coach')).semanticsLabel, 'KI-Coach');
    for (final key in ['coach-sessions-open', 'coach-info']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
  });

  testWidgets('Blasen tragen ihr lesbares Paar: Nutzer forest/onForest, '
      'Coach surf/ink', (tester) async {
    final svc = _FakeCoach.create()
      ..history = <ChatMessage>[
        _msg('Was soll ich abends essen?', ChatRole.user),
        _msg('Nimm Lachs mit Suesskartoffel.', ChatRole.assistant),
      ];
    await _pumpCoach(tester, service: svc);

    const t = AppTokens.dark;
    const frage = 'Was soll ich abends essen?';
    const antwort = 'Nimm Lachs mit Suesskartoffel.';
    expect(_bubbleDecoration(tester, frage).color, t.forest);
    expect(tester.widget<Text>(find.text(frage)).style?.color, t.onForest);
    expect(_bubbleDecoration(tester, antwort).color, t.surf);
    expect(tester.widget<Text>(find.text(antwort)).style?.color, t.ink);
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

  // The owner's input rule (AGENTS.md): borderless soft fill, focus is a
  // lighter fill, never a ring.
  testWidgets('Composer: keine Theme-Fuellung, kein Rahmen; Fokus hellt die '
      'Kapsel auf (field -> fieldFocus)', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('coach-input')));
    await tester.pumpAndSettle();
    final fokussiert = tester
        .widget<AnimatedContainer>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('coach-input')),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        )
        .decoration! as BoxDecoration;
    expect(fokussiert.color, AppTokens.dark.fieldFocus,
        reason: 'Fokus = Flaechen-Aufhellung, nicht Rahmen');
    expect(fokussiert.border, isNull);
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
      // The listening state takes `accent` and idle takes `ink2`; the check
      // below keeps the two apart in both palettes.
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
}
