import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, debugPrint, DebugPrintCallback;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/dictation_language.dart';
import 'package:eatova/src/services/screen_awake.dart';

import 'support/harness.dart';

// Spec §8 (Part D, Dart side): the owner dictated a minute of German/English
// and only the last ~3 words arrived. Native now accumulates and streams
// `partial {token, text}`; `listen` completes with `{text, reason}`. These
// tests drive that channel the way the iOS plugin does and pin the client:
// live partials, append to the draft, stale tokens, lifecycle, send while
// listening, the length/limit hints, the DE/EN pill, keep-awake and no
// transcript in any log.

const MethodChannel _speech = MethodChannel('eatova/speech');
const StandardMethodCodec _codec = StandardMethodCodec();

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Stand-in for EatovaSpeechPlugin (ios/Runner/AppDelegate.swift).
class _Native {
  final calls = <MethodCall>[];
  final _open = <Completer<Object?>>[];
  final tokens = <int>[];
  final locales = <String>[];
  String _lastText = '';

  void install() {
    _messenger.setMockMethodCallHandler(_speech, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listen':
          final args = call.arguments as Map<Object?, Object?>;
          tokens.add(args['token']! as int);
          locales.add(args['localeId']! as String);
          _lastText = '';
          final result = Completer<Object?>();
          _open.add(result);
          return result.future;
        case 'cancel':
          // Native completes at once with what it has.
          _complete(_lastText, 'cancel');
          return null;
        case 'stop':
          // Graceful: the final arrives later via [finish].
          return null;
      }
      return null;
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_speech, null));
  }

  int count(String method) => calls.where((c) => c.method == method).length;

  /// Native -> Dart, like `channel.invokeMethod("partial", ...)`.
  void partial(String text, {int? token}) {
    _lastText = text;
    unawaited(
      _messenger.handlePlatformMessage(
        'eatova/speech',
        _codec.encodeMethodCall(
          MethodCall('partial', <String, Object?>{
            'token': token ?? tokens.last,
            'text': text,
          }),
        ),
        (_) {},
      ),
    );
  }

  void finish(String text, {String reason = 'final'}) =>
      _complete(text, reason);

  void fail(String code) {
    final open = _open.where((c) => !c.isCompleted).toList();
    open.last.completeError(PlatformException(code: code));
  }

  void _complete(String text, String reason) {
    for (final open in _open.reversed) {
      if (!open.isCompleted) {
        open.complete(<String, Object?>{'text': text, 'reason': reason});
        return;
      }
    }
  }
}

class _Awake implements ScreenAwake {
  final calls = <bool>[];

  @override
  Future<void> setKeepAwake(bool on) async => calls.add(on);
}

class _Coach extends CoachChatService {
  _Coach(super.client, super.userId);

  static _Coach create([String userId = 'user-a']) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Coach(client, userId);
  }

  final sent = <String>[];
  final pending = <Completer<CoachChatReply>>[];

  @override
  Future<List<ChatSession>> loadSessions() async => [
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 10, 1),
      lastMessageAt: DateTime(2026, 10, 3),
      messageCount: 0,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => const <ChatMessage>[];

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
    void Function(String text)? onPartialReply,
  }) {
    sent.add(message);
    final reply = Completer<CoachChatReply>();
    pending.add(reply);
    return reply.future;
  }
}

/// The mic exists on iOS only. Reset in `finally`: the binding checks
/// foundation variables before tear-downs run.
Future<void> _ios(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

class _Setup {
  _Setup(this.services, this.visible);
  final ValueNotifier<_Coach> services;
  final ValueNotifier<bool> visible;
  _Coach get coach => services.value;
}

Future<_Setup> _mount(
  WidgetTester tester, {
  required _Awake awake,
  Locale locale = const Locale('de'),
  Size surfaceSize = const Size(402, 820),
  double textScale = 1.0,
}) async {
  final services = ValueNotifier<_Coach>(_Coach.create());
  final visible = ValueNotifier<bool>(true);
  addTearDown(services.dispose);
  addTearDown(visible.dispose);
  await pumpLocalized(
    tester,
    ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, enabled, __) => TickerMode(
        enabled: enabled,
        child: ValueListenableBuilder<_Coach>(
          valueListenable: services,
          builder: (_, coach, __) => CoachChatScreen(
            service: coach,
            userName: 'M',
            screenAwake: awake,
            dictationLanguageStore: const PrefsDictationLanguageStore(),
          ),
        ),
      ),
    ),
    locale: locale,
    surfaceSize: surfaceSize,
    textScale: textScale,
    safeArea: false,
  );
  await _frames(tester);
  return _Setup(services, visible);
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('coach-input')));

String _text(WidgetTester tester) => _field(tester).controller!.text;

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-mic')));
  await _frames(tester);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
}

bool _micListening(WidgetTester tester) =>
    tester
        .widget<Semantics>(find.byKey(const ValueKey('coach-mic')))
        .properties
        .label ==
    deL10n.coachMicLabelListening;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('Teilergebnisse erscheinen live im Feld; waehrenddessen ist es '
      'schreibgeschuetzt', (tester) async {
    await _ios(() async {
      final native = _Native()..install();
      await _mount(tester, awake: _Awake());
      await _tapMic(tester);

      expect(native.count('listen'), 1);
      expect(
        native.locales.single,
        'de_DE',
        reason: 'ohne gespeicherte Wahl gilt die App-Sprache',
      );
      expect(
        _field(tester).readOnly,
        isTrue,
        reason: 'Tippen darf nicht mit den Teilergebnissen rennen',
      );

      native.partial('Heute habe ich');
      await tester.pump();
      expect(_text(tester), 'Heute habe ich');

      native.partial('Heute habe ich Kniebeugen gemacht');
      await tester.pump();
      expect(_text(tester), 'Heute habe ich Kniebeugen gemacht');

      native.finish('Heute habe ich Kniebeugen gemacht.');
      await _frames(tester);
      expect(_text(tester), 'Heute habe ich Kniebeugen gemacht.');
      expect(_field(tester).readOnly, isFalse);
      expect(_micListening(tester), isFalse);
    });
  });

  for (final (draft, shown) in <(String, String)>[
    ('/log ', '/log '),
    ('/log', '/log '),
    ('Erst getippt,', 'Erst getippt, '),
  ]) {
    testWidgets('Diktat haengt sich an den Entwurf "$draft" an', (
      tester,
    ) async {
      await _ios(() async {
        final native = _Native()..install();
        await _mount(tester, awake: _Awake());
        await _type(tester, draft);
        await _tapMic(tester);

        native.partial('Bankdrücken 3 mal 8');
        await tester.pump();
        expect(
          _text(tester),
          '${shown}Bankdrücken 3 mal 8',
          reason: 'der Entwurf bleibt stehen, genau ein Leerzeichen',
        );

        native.finish('Bankdrücken 3 mal 8 mit 60 kg', reason: 'stop');
        await _frames(tester);
        final expected = '${shown}Bankdrücken 3 mal 8 mit 60 kg';
        expect(_text(tester), expected);
        expect(
          _field(tester).controller!.selection.baseOffset,
          expected.length,
        );
      });
    });
  }

  testWidgets('nach einem Tabwechsel wird ein Teilergebnis mit altem Token '
      'ignoriert', (tester) async {
    await _ios(() async {
      final native = _Native()..install();
      final setup = await _mount(tester, awake: _Awake());
      await _tapMic(tester);
      native.partial('Erster Teil');
      await tester.pump();

      setup.visible.value = false;
      await _frames(tester);
      setup.visible.value = true;
      await _frames(tester);
      await _tapMic(tester);
      expect(native.tokens, hasLength(2));
      expect(native.tokens.last, isNot(native.tokens.first));

      native.partial('Veraltet', token: native.tokens.first);
      await tester.pump();
      expect(_text(tester), 'Erster Teil');

      native.partial('zweiter Teil');
      await tester.pump();
      expect(_text(tester), 'Erster Teil zweiter Teil');
    });
  });

  for (final action in ['tab', 'paused']) {
    testWidgets('$action: Mikro sofort aus, gezeigter Text bleibt', (
      tester,
    ) async {
      await _ios(() async {
        final native = _Native()..install();
        final awake = _Awake();
        final setup = await _mount(tester, awake: awake);
        await _type(tester, 'Vorher');
        await _tapMic(tester);
        native.partial('gesprochen');
        await tester.pump();

        if (action == 'tab') {
          setup.visible.value = false;
        } else {
          tester.binding
            ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
            ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
            ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
        }
        await _frames(tester);

        expect(
          native.count('cancel'),
          1,
          reason: 'Lifecycle beendet sofort, nicht mit Nachlauf',
        );
        expect(native.count('stop'), 0);
        expect(_text(tester), 'Vorher gesprochen');
        expect(awake.calls, <bool>[true, false]);

        native.partial('spaeter', token: native.tokens.single);
        await tester.pump();
        expect(_text(tester), 'Vorher gesprochen');
        expect(tester.takeException(), isNull);

        if (action == 'paused') {
          tester.binding
            ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
            ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
            ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      });
    });
  }

  testWidgets('Kontowechsel verwirft den Text des laufenden Diktats', (
    tester,
  ) async {
    await _ios(() async {
      final native = _Native()..install();
      final awake = _Awake();
      final setup = await _mount(tester, awake: awake);
      await _type(tester, 'Vorher');
      await _tapMic(tester);
      native.partial('Konto A gesprochen');
      await tester.pump();
      expect(_text(tester), 'Vorher Konto A gesprochen');

      setup.services.value = _Coach.create('user-b');
      await _frames(tester);

      expect(native.count('cancel'), 1);
      expect(_text(tester), 'Vorher');
      expect(awake.calls, <bool>[true, false]);
      native.partial('Konto A spaeter', token: native.tokens.single);
      await tester.pump();
      expect(_text(tester), 'Vorher');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Dispose bricht sofort ab; spaete Ergebnisse werfen nicht', (
    tester,
  ) async {
    await _ios(() async {
      final native = _Native()..install();
      final awake = _Awake();
      await _mount(tester, awake: awake);
      await _tapMic(tester);
      native.partial('gesprochen');
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      expect(native.count('cancel'), 1);
      expect(native.count('stop'), 0);
      expect(awake.calls, <bool>[true, false]);

      native.partial('spaeter', token: native.tokens.single);
      await _frames(tester);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'Senden waehrend des Diktats stoppt es nur; gesendet wird erst beim '
    'zweiten Tippen',
    (tester) async {
      await _ios(() async {
        final native = _Native()..install();
        final setup = await _mount(tester, awake: _Awake());
        await _tapMic(tester);
        native.partial('Wie viel Protein');
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('coach-send')));
        await _frames(tester);
        expect(native.count('stop'), 1);
        expect(
          setup.coach.sent,
          isEmpty,
          reason: 'nie ungesehenen Text senden',
        );

        // A second mic tap while the final drains starts nothing new.
        await _tapMic(tester);
        expect(native.count('listen'), 1);
        expect(native.count('stop'), 1);

        native.finish('Wie viel Protein brauche ich heute?', reason: 'stop');
        await _frames(tester);
        expect(_text(tester), 'Wie viel Protein brauche ich heute?');
        expect(setup.coach.sent, isEmpty);

        await tester.tap(find.byKey(const ValueKey('coach-send')));
        await _frames(tester);
        expect(setup.coach.sent, <String>[
          'Wie viel Protein brauche ich heute?',
        ]);
      });
    },
  );

  testWidgets('der Mikro-Stopp geht auch, waehrend eine Anfrage laeuft', (
    tester,
  ) async {
    await _ios(() async {
      final native = _Native()..install();
      final setup = await _mount(tester, awake: _Awake());
      await _type(tester, 'Erste Frage');
      await tester.tap(find.byKey(const ValueKey('coach-send')));
      await _frames(tester);
      expect(setup.coach.pending, hasLength(1));

      await _tapMic(tester);
      expect(
        native.count('listen'),
        1,
        reason: 'diktieren geht wie tippen, waehrend der Coach antwortet',
      );
      native.partial('Zweite Frage');
      await tester.pump();

      await _tapMic(tester);
      expect(native.count('stop'), 1);
      native.finish('Zweite Frage', reason: 'stop');
      await _frames(tester);
      expect(_text(tester), 'Zweite Frage');
      expect(_micListening(tester), isFalse);
      expect(setup.coach.sent, <String>['Erste Frage']);
    });
  });

  testWidgets('ein leeres Endergebnis nimmt gezeigte Worte nicht zurueck', (
    tester,
  ) async {
    await _ios(() async {
      final native = _Native()..install();
      await _mount(tester, awake: _Awake());
      await _tapMic(tester);
      native.partial('die letzten Worte');
      await tester.pump();
      await _tapMic(tester);
      native.finish('', reason: 'stop');
      await _frames(tester);

      expect(_text(tester), 'die letzten Worte');
      expect(find.text(deL10n.coachErrorSpeechEmpty), findsNothing);
    });
  });

  for (final (reason, hint) in <(String, String)>[
    ('limit', deL10n.coachDictationLimitHint),
    ('length', deL10n.coachDictationLengthHint),
  ]) {
    testWidgets('Ende "$reason" behaelt den Text und zeigt den Hinweis', (
      tester,
    ) async {
      await _ios(() async {
        final native = _Native()..install();
        await _mount(tester, awake: _Awake());
        await _tapMic(tester);
        native.partial('Eine lange Erzaehlung');
        await tester.pump();
        native.finish('Eine lange Erzaehlung vom Training', reason: reason);
        await _frames(tester);

        expect(_text(tester), 'Eine lange Erzaehlung vom Training');
        expect(find.text(hint), findsOneWidget);
      });
    });
  }

  testWidgets(
    'Entwurf plus Diktat am Eingabelimit stoppt sanft mit Hinweis und '
    'kuerzt nichts',
    (tester) async {
      await _ios(() async {
        final native = _Native()..install();
        await _mount(tester, awake: _Awake());
        final draft = 'a' * (kCoachMaxInputChars - 10);
        await _type(tester, draft);
        await _tapMic(tester);

        native.partial('kurz');
        await tester.pump();
        expect(native.count('stop'), 0);

        native.partial('kurz und lang');
        await tester.pump();
        expect(
          native.count('stop'),
          1,
          reason: 'Entwurf + Leerzeichen + Diktat erreicht 1000 Einheiten',
        );

        native.finish('kurz und lang genug', reason: 'stop');
        await _frames(tester);
        expect(
          _text(tester),
          '$draft kurz und lang genug',
          reason: 'nie still kuerzen; der Nutzer kuerzt selbst',
        );
        expect(find.text(deL10n.coachDictationLengthHint), findsOneWidget);
      });
    },
  );

  testWidgets('Sprach-Pille wechselt DE/EN, startet neu, ersetzt nur den Text '
      'dieses Diktats und merkt sich die Wahl', (tester) async {
    await _ios(() async {
      final native = _Native()..install();
      final awake = _Awake();
      await _mount(tester, awake: awake);
      expect(
        find.byKey(const ValueKey('coach-dictation-language')),
        findsNothing,
        reason: 'die Pille steht nur waehrend des Zuhoerens',
      );
      await _type(tester, '/log ');
      await _tapMic(tester);
      final pill = find.byKey(const ValueKey('coach-dictation-language'));
      expect(pill, findsOneWidget);
      expect(find.text(deL10n.coachDictationLanguageDe), findsOneWidget);

      native.partial('bench press drei Saetze');
      await tester.pump();
      expect(_text(tester), '/log bench press drei Saetze');

      await tester.tap(pill);
      await _frames(tester);
      expect(native.count('cancel'), 1, reason: 'nur dieses Diktat endet');
      expect(native.locales, <String>['de_DE', 'en_US']);
      expect(_text(tester), '/log ');
      expect(find.text(deL10n.coachDictationLanguageEn), findsOneWidget);
      expect(awake.calls, <bool>[
        true,
      ], reason: 'der Neustart laesst den Bildschirm an');

      native.partial('bench press three sets', token: native.tokens.first);
      await tester.pump();
      expect(_text(tester), '/log ', reason: 'altes Token, alte Sprache');
      native.partial('bench press three sets');
      await tester.pump();
      expect(_text(tester), '/log bench press three sets');

      native.finish('bench press three sets of eight', reason: 'stop');
      await _frames(tester);
      expect(_text(tester), '/log bench press three sets of eight');
      expect(awake.calls, <bool>[true, false]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefsDictationLanguageStore.storageKey), 'en');
    });
  });

  testWidgets('die gemerkte Sprache gilt beim naechsten Start pro Geraet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PrefsDictationLanguageStore.storageKey: 'en',
    });
    await _ios(() async {
      final native = _Native()..install();
      await _mount(tester, awake: _Awake());
      await _tapMic(tester);
      expect(
        native.locales.single,
        'en_US',
        reason: 'deutsche App, aber zuletzt Englisch diktiert',
      );
      expect(find.text(deL10n.coachDictationLanguageEn), findsOneWidget);
    });
  });

  testWidgets('englische App: Englisch als Vorgabe, Pille fuer VoiceOver', (
    tester,
  ) async {
    await _ios(() async {
      final semantics = tester.ensureSemantics();
      final native = _Native()..install();
      await _mount(tester, awake: _Awake(), locale: const Locale('en'));
      await _tapMic(tester);
      expect(native.locales.single, 'en_US');

      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('coach-dictation-language')),
        ),
        isSemantics(
          label: enL10n.coachDictationLanguageLabel(
            enL10n.coachDictationLanguageEnglish,
          ),
          hint: enL10n.coachDictationLanguageSwitchHint(
            enL10n.coachDictationLanguageGerman,
          ),
          isButton: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });
  });

  testWidgets(
    'Pille, Mikro und Senden passen bei 390 px und 2-facher Schrift',
    (tester) async {
      await _ios(() async {
        final native = _Native()..install();
        await _mount(
          tester,
          awake: _Awake(),
          surfaceSize: const Size(390, 797),
          textScale: 2.0,
        );
        await _tapMic(tester);
        native.partial('Heute drei Saetze Kniebeugen');
        await tester.pump();

        expect(tester.takeException(), isNull);
        for (final key in [
          'coach-dictation-language',
          'coach-mic',
          'coach-send',
        ]) {
          final size = tester.getSize(find.byKey(ValueKey(key)));
          expect(size.width, greaterThanOrEqualTo(44), reason: key);
          expect(size.height, greaterThanOrEqualTo(44), reason: key);
        }
      });
    },
  );

  testWidgets(
    'Bildschirm bleibt beim Zuhoeren an, danach und bei Fehlern aus',
    (tester) async {
      await _ios(() async {
        final native = _Native()..install();
        final awake = _Awake();
        await _mount(tester, awake: awake);
        expect(awake.calls, isEmpty);

        await _tapMic(tester);
        expect(awake.calls, <bool>[true]);
        native.finish('fertig');
        await _frames(tester);
        expect(awake.calls, <bool>[true, false]);

        await _tapMic(tester);
        native.fail('permission_denied');
        await _frames(tester);
        expect(awake.calls, <bool>[true, false, true, false]);
        expect(find.text(deL10n.coachSpeechPermissionDenied), findsOneWidget);
      });
    },
  );

  testWidgets('kein Transkript erreicht debugPrint oder den Crash-Reporter', (
    tester,
  ) async {
    final printed = <String>[];
    final reported = <String>[];
    final DebugPrintCallback original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    CrashReporter.debugSentrySink = (error, stack, context) =>
        reported.add('$error $context');
    CrashReporter.debugBreadcrumbSink = reported.add;
    try {
      await _ios(() async {
        final native = _Native()..install();
        await _mount(tester, awake: _Awake());
        await _tapMic(tester);
        native.partial('GEHEIMNIS eins');
        await tester.pump();
        native.partial('GEHEIMNIS eins zwei', token: -1);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('coach-send')));
        await _frames(tester);
        native.finish('GEHEIMNIS eins zwei drei', reason: 'stop');
        await _frames(tester);
        await _tapMic(tester);
        native.partial('GEHEIMNIS vier');
        await tester.pump();
        native.fail('recognition_failed');
        await _frames(tester);
      });
    } finally {
      debugPrint = original;
      CrashReporter.debugSentrySink = null;
      CrashReporter.debugBreadcrumbSink = null;
    }
    expect(printed.where((m) => m.contains('GEHEIMNIS')), isEmpty);
    expect(reported.where((m) => m.contains('GEHEIMNIS')), isEmpty);
  });
}
