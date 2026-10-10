import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/speech_input.dart';

// SpeechInput is the Dart side of `eatova/speech` for the Coach and the meal
// description (docs/MEAL-DESCRIBE.md, Speech). These tests drive the channel
// the way EatovaSpeechPlugin (iOS) and SpeechBridge (Android) do: arguments,
// partials bound to the newest call's token, the {text, reason} result and
// the typed failures.

const MethodChannel _channel = MethodChannel('eatova/speech');
const StandardMethodCodec _codec = StandardMethodCodec();

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Stand-in for the native side: records calls, holds each listen open until
/// the test answers it.
class _Native {
  final calls = <MethodCall>[];
  final _open = <Completer<Object?>>[];
  Object? Function(MethodCall call)? otherMethods;

  void install() {
    _messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'listen') {
        final result = Completer<Object?>();
        _open.add(result);
        return result.future;
      }
      return otherMethods?.call(call);
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_channel, null));
  }

  Map<Object?, Object?> get lastListenArguments =>
      calls.lastWhere((c) => c.method == 'listen').arguments
          as Map<Object?, Object?>;

  /// Native -> Dart, like `channel.invokeMethod("partial", ...)`.
  Future<void> partial(Object? arguments) => _messenger.handlePlatformMessage(
    'eatova/speech',
    _codec.encodeMethodCall(MethodCall('partial', arguments)),
    (_) {},
  );

  /// Completes the oldest open listen.
  void answer(Object? value) => _open.removeAt(0).complete(value);

  void fail(Object error) => _open.removeAt(0).completeError(error);
}

/// Lets a pending listen's invokeMethod reach the mock handler.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platforms', () {
    test('supportedOn: iOS and Android only', () {
      for (final platform in TargetPlatform.values) {
        expect(
          SpeechInput.supportedOn(platform),
          platform == TargetPlatform.iOS || platform == TargetPlatform.android,
          reason: platform.name,
        );
      }
    });

    test('streamsPartialsOn: iOS only (Android shows the system dialog)', () {
      for (final platform in TargetPlatform.values) {
        expect(
          SpeechInput.streamsPartialsOn(platform),
          platform == TargetPlatform.iOS,
          reason: platform.name,
        );
      }
    });
  });

  group('listen arguments', () {
    test(
      'defaults: gym vocabulary and 1000 units, as the Coach always had',
      () async {
        final native = _Native()..install();
        final done = const SpeechInput().listen(localeId: 'de_DE', token: 7);
        await _settle();
        expect(native.lastListenArguments, <String, Object?>{
          'localeId': 'de_DE',
          'token': 7,
          'vocabulary': 'gym',
          'maxUnits': 1000,
        });
        native.answer(<String, Object?>{'text': 'x', 'reason': 'final'});
        await done;
      },
    );

    test('food vocabulary and the caller cap travel by name', () async {
      final native = _Native()..install();
      final done = const SpeechInput().listen(
        localeId: 'en_US',
        token: 3,
        vocabulary: SpeechVocabulary.food,
        maxChars: 500,
      );
      await _settle();
      expect(native.lastListenArguments, <String, Object?>{
        'localeId': 'en_US',
        'token': 3,
        'vocabulary': 'food',
        'maxUnits': 500,
      });
      native.answer(null);
      await done;
    });
  });

  group('result', () {
    Future<(String?, List<SpeechEnd>)> run(Object? nativeResult) async {
      final native = _Native()..install();
      final ends = <SpeechEnd>[];
      final done = const SpeechInput().listen(
        localeId: 'de_DE',
        token: 1,
        onEnd: ends.add,
      );
      await _settle();
      native.answer(nativeResult);
      return (await done, ends);
    }

    test('final text comes back unchanged, end = stopped', () async {
      final (text, ends) = await run(<String, Object?>{
        'text': 'Nutella mit einer Scheibe Toast',
        'reason': 'final',
      });
      expect(text, 'Nutella mit einer Scheibe Toast');
      expect(ends, <SpeechEnd>[SpeechEnd.stopped]);
    });

    test(
      'Android dialog dismissed: null text, reason cancel -> null, stopped',
      () async {
        final (text, ends) = await run(<String, Object?>{
          'text': null,
          'reason': 'cancel',
        });
        expect(text, isNull);
        expect(ends, <SpeechEnd>[SpeechEnd.stopped]);
      },
    );

    test(
      'an empty or blank transcript is "nothing recognized" -> null',
      () async {
        for (final empty in <String>['', '   ']) {
          final (text, _) = await run(<String, Object?>{
            'text': empty,
            'reason': 'cancel',
          });
          expect(text, isNull, reason: '"$empty"');
        }
      },
    );

    test(
      'length and limit reach onEnd; every other reason is stopped',
      () async {
        const expected = <String?, SpeechEnd>{
          'length': SpeechEnd.length,
          'limit': SpeechEnd.limit,
          'final': SpeechEnd.stopped,
          'stop': SpeechEnd.stopped,
          'cancel': SpeechEnd.stopped,
          'something-new': SpeechEnd.stopped,
          null: SpeechEnd.stopped,
        };
        for (final MapEntry(key: reason, value: end) in expected.entries) {
          final (text, ends) = await run(<String, Object?>{
            'text': 'zwei Eier',
            'reason': reason,
          });
          expect(text, 'zwei Eier', reason: '$reason');
          expect(ends, <SpeechEnd>[end], reason: '$reason');
        }
      },
    );

    test('no result map at all: null text, stopped', () async {
      final (text, ends) = await run(null);
      expect(text, isNull);
      expect(ends, <SpeechEnd>[SpeechEnd.stopped]);
    });

    test('onEnd runs before listen returns the text', () async {
      final native = _Native()..install();
      final order = <String>[];
      final done = const SpeechInput()
          .listen(localeId: 'de_DE', token: 1, onEnd: (_) => order.add('end'))
          .then((_) => order.add('text'));
      await _settle();
      native.answer(<String, Object?>{'text': 'Skyr', 'reason': 'length'});
      await done;
      expect(order, <String>['end', 'text']);
    });
  });

  group('partials', () {
    test(
      'only partials with the running call\'s token reach onPartial',
      () async {
        final native = _Native()..install();
        final seen = <String>[];
        final done = const SpeechInput().listen(
          localeId: 'de_DE',
          token: 2,
          onPartial: seen.add,
        );
        await _settle();

        await native.partial(<String, Object?>{'token': 1, 'text': 'alt'});
        await native.partial(<String, Object?>{'token': 2, 'text': 'Nutella'});
        await native.partial(<String, Object?>{
          'token': 2,
          'text': 'Nutella mit',
        });
        expect(seen, <String>['Nutella', 'Nutella mit']);

        native.answer(<String, Object?>{
          'text': 'Nutella mit',
          'reason': 'stop',
        });
        await done;
        // The call is over: even its own token is stale now.
        await native.partial(<String, Object?>{'token': 2, 'text': 'spaet'});
        expect(seen, <String>['Nutella', 'Nutella mit']);
      },
    );

    test(
      'a newer call takes the binding; the older one ending keeps it',
      () async {
        final native = _Native()..install();
        final first = <String>[];
        final second = <String>[];
        final firstDone = const SpeechInput().listen(
          localeId: 'de_DE',
          token: 1,
          onPartial: first.add,
        );
        final secondDone = const SpeechInput().listen(
          localeId: 'en_US',
          token: 2,
          onPartial: second.add,
        );
        await _settle();

        await native.partial(<String, Object?>{
          'token': 1,
          'text': 'Haferflocken',
        });
        expect(first, isEmpty);
        expect(second, isEmpty);

        native.answer(<String, Object?>{'text': '', 'reason': 'cancel'});
        await firstDone;
        await native.partial(<String, Object?>{'token': 2, 'text': 'oatmeal'});
        expect(second, <String>['oatmeal']);
        expect(first, isEmpty);

        native.answer(<String, Object?>{'text': 'oatmeal', 'reason': 'final'});
        await secondDone;
      },
    );

    test('malformed partials are ignored', () async {
      final native = _Native()..install();
      final seen = <String>[];
      final done = const SpeechInput().listen(
        localeId: 'de_DE',
        token: 5,
        onPartial: seen.add,
      );
      await _settle();
      await native.partial(null);
      await native.partial('Skyr');
      await native.partial(<String, Object?>{'token': 5, 'text': 42});
      await native.partial(<String, Object?>{'token': '5', 'text': 'Skyr'});
      expect(seen, isEmpty);
      native.answer(null);
      await done;
    });
  });

  group('failures', () {
    Future<SpeechFailure> failureFor(Object error) async {
      final native = _Native()..install();
      final done = const SpeechInput().listen(localeId: 'de_DE', token: 1);
      await _settle();
      native.fail(error);
      try {
        await done;
      } on SpeechInputException catch (e) {
        return e.failure;
      }
      fail('listen() should have thrown');
    }

    const expected = <String, SpeechFailure>{
      'permission_denied': SpeechFailure.permissionDenied,
      'PERMISSION_DENIED': SpeechFailure.permissionDenied,
      'microphone_permission': SpeechFailure.permissionDenied,
      'denied': SpeechFailure.permissionDenied,
      'unavailable': SpeechFailure.unavailable,
      'recognizer_unavailable': SpeechFailure.unavailable,
      'busy': SpeechFailure.busy,
      'recognition_failed': SpeechFailure.failed,
      'error': SpeechFailure.failed,
      '': SpeechFailure.failed,
    };
    for (final MapEntry(key: code, value: failure) in expected.entries) {
      test('PlatformException "$code" -> ${failure.name}', () async {
        expect(
          await failureFor(
            PlatformException(code: code, message: 'system text, never shown'),
          ),
          failure,
        );
      });
    }

    test('no native channel (MissingPluginException) -> unavailable', () async {
      // No mock handler: the test binding throws MissingPluginException.
      await expectLater(
        const SpeechInput().listen(localeId: 'de_DE', token: 1),
        throwsA(
          isA<SpeechInputException>().having(
            (e) => e.failure,
            'failure',
            SpeechFailure.unavailable,
          ),
        ),
      );
    });

    test('a failed call releases its partial binding', () async {
      final native = _Native()..install();
      final seen = <String>[];
      final done = const SpeechInput().listen(
        localeId: 'de_DE',
        token: 9,
        onPartial: seen.add,
      );
      await _settle();
      native.fail(PlatformException(code: 'recognition_failed'));
      await expectLater(done, throwsA(isA<SpeechInputException>()));
      await native.partial(<String, Object?>{'token': 9, 'text': 'spaet'});
      expect(seen, isEmpty);
    });

    test('the exception names only the typed failure', () {
      expect(
        const SpeechInputException(SpeechFailure.busy).toString(),
        'SpeechInputException(busy)',
      );
    });
  });

  group('stop, cancel, available', () {
    test('stop and cancel reach the native side', () async {
      final native = _Native()..install();
      await const SpeechInput().stop();
      await const SpeechInput().cancel();
      expect(native.calls.map((c) => c.method), <String>['stop', 'cancel']);
    });

    test('stop and cancel are best effort: errors never escape', () async {
      final native = _Native()..install();
      native.otherMethods = (_) => throw PlatformException(code: 'x');
      await const SpeechInput().stop();
      await const SpeechInput().cancel();
      _messenger.setMockMethodCallHandler(_channel, null);
      await const SpeechInput().stop();
      await const SpeechInput().cancel();
    });

    test('available passes the locale and reads a bool', () async {
      final native = _Native()..install();
      native.otherMethods = (_) => true;
      expect(await const SpeechInput().available(localeId: 'en_US'), isTrue);
      expect(native.calls.single.method, 'available');
      expect(native.calls.single.arguments, <String, Object?>{
        'localeId': 'en_US',
      });
      native.otherMethods = (_) => false;
      expect(await const SpeechInput().available(), isFalse);
      native.otherMethods = (_) => null;
      expect(await const SpeechInput().available(), isFalse);
    });

    test(
      'available is false when the check fails or no channel exists',
      () async {
        final native = _Native()..install();
        native.otherMethods = (_) => throw PlatformException(code: 'x');
        expect(await const SpeechInput().available(), isFalse);
        _messenger.setMockMethodCallHandler(_channel, null);
        expect(await const SpeechInput().available(), isFalse);
      },
    );
  });

  test('no transcript reaches debugPrint', () async {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    addTearDown(() => debugPrint = original);

    final native = _Native()..install();
    final done = const SpeechInput().listen(
      localeId: 'de_DE',
      token: 4,
      onPartial: (_) {},
    );
    await _settle();
    await native.partial(<String, Object?>{'token': 4, 'text': 'Magerquark'});
    native.answer(<String, Object?>{'text': 'Magerquark', 'reason': 'final'});
    await done;
    native.otherMethods = (_) => throw PlatformException(code: 'x');
    await const SpeechInput().cancel();

    expect(printed, isEmpty);
  });
}
