import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';

// CoachSpeechInput is now a thin adapter over SpeechInput. On the wire the
// Coach must stay what it was: gym vocabulary, the composer cap, the same
// end reasons and localized messages.

const MethodChannel _channel = MethodChannel('eatova/speech');
const StandardMethodCodec _codec = StandardMethodCodec();

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late List<Completer<Object?>> open;

  setUp(() {
    calls = <MethodCall>[];
    open = <Completer<Object?>>[];
    _messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method != 'listen') return null;
      final result = Completer<Object?>();
      open.add(result);
      return result.future;
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_channel, null));
  });

  test('listen sends the coach settings: gym words, composer cap', () async {
    final done = const CoachSpeechInput().listen(
      localeId: 'en_US',
      l10n: enL10n,
      token: 11,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'listen');
    expect(calls.single.arguments, <String, Object?>{
      'localeId': 'en_US',
      'token': 11,
      'vocabulary': 'gym',
      'maxUnits': kCoachMaxInputChars,
    });
    expect(kCoachMaxInputChars, 1000, reason: 'the iOS default it mirrors');
    open.single.complete(<String, Object?>{'text': 'bench', 'reason': 'final'});
    expect(await done, 'bench');
  });

  test('partials pass through for the current token; ends map 1:1', () async {
    for (final (reason, end) in const <(String, CoachSpeechEnd)>[
      ('length', CoachSpeechEnd.length),
      ('limit', CoachSpeechEnd.limit),
      ('cancel', CoachSpeechEnd.stopped),
      ('final', CoachSpeechEnd.stopped),
    ]) {
      final seen = <String>[];
      final ends = <CoachSpeechEnd>[];
      final done = const CoachSpeechInput().listen(
        l10n: deL10n,
        token: 4,
        onPartial: seen.add,
        onEnd: ends.add,
      );
      await Future<void>.delayed(Duration.zero);
      for (final (token, text) in const <(int, String)>[
        (3, 'alt'),
        (4, 'drei Saetze'),
      ]) {
        await _messenger.handlePlatformMessage(
          'eatova/speech',
          _codec.encodeMethodCall(
            MethodCall('partial', <String, Object?>{
              'token': token,
              'text': text,
            }),
          ),
          (_) {},
        );
      }
      open.removeAt(0).complete(<String, Object?>{
        'text': 'drei Saetze',
        'reason': reason,
      });
      expect(await done, 'drei Saetze');
      expect(seen, <String>['drei Saetze'], reason: reason);
      expect(ends, <CoachSpeechEnd>[end], reason: reason);
    }
  });

  test('a missing plugin is the localized "unavailable" text', () async {
    _messenger.setMockMethodCallHandler(_channel, null);
    await expectLater(
      const CoachSpeechInput().listen(l10n: enL10n),
      throwsA(
        isA<CoachSpeechException>().having(
          (e) => e.message,
          'message',
          enL10n.coachSpeechUnavailable,
        ),
      ),
    );
  });
}
