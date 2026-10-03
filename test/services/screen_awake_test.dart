import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/screen_awake.dart';

// Spec A6: keep-awake is one small channel, no package. The native side
// (Android MainActivity, iOS AppDelegate) answers `setKeepAwake {on: bool}`.

const MethodChannel _channel = MethodChannel('eatova/screen');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(MethodChannelScreenAwake.debugReset);
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('sendet setKeepAwake {on: true} und {on: false}', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });

    await const MethodChannelScreenAwake().setKeepAwake(true);
    await const MethodChannelScreenAwake().setKeepAwake(false);

    expect(calls.map((c) => c.method), ['setKeepAwake', 'setKeepAwake']);
    expect(calls.first.arguments, {'on': true});
    expect(calls.last.arguments, {'on': false});
  });

  // Ruling R16: the display flag is process-wide; the player and the Coach
  // dictation hold it as separate owners.
  test('ein Diktat-Ende löscht das Wachhalten des Players nicht', () async {
    final calls = <Object?>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.arguments);
      return null;
    });
    const awake = MethodChannelScreenAwake();

    await awake.setKeepAwake(true, owner: 'training-player');
    await awake.setKeepAwake(true);
    await awake.setKeepAwake(false);
    expect(calls, [
      {'on': true},
    ], reason: 'the player still holds the display');

    await awake.setKeepAwake(false, owner: 'training-player');
    expect(calls, [
      {'on': true},
      {'on': false},
    ]);
  });

  test('derselbe Halter zweimal schaltet nur einmal', () async {
    final calls = <Object?>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.arguments);
      return null;
    });
    const awake = MethodChannelScreenAwake();
    await awake.setKeepAwake(true, owner: 'training-player');
    await awake.setKeepAwake(true, owner: 'training-player');
    await awake.setKeepAwake(false, owner: 'other');
    expect(calls, [
      {'on': true},
    ]);
  });

  test('ohne native Gegenstelle: kein Wurf', () async {
    await expectLater(
      const MethodChannelScreenAwake().setKeepAwake(true),
      completes,
    );
  });

  test('ein Plattformfehler bricht den Ablauf nicht ab', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'window', message: 'no activity');
    });
    await expectLater(
      const MethodChannelScreenAwake().setKeepAwake(true),
      completes,
    );
  });

  test('NoopScreenAwake tut nichts', () async {
    await expectLater(const NoopScreenAwake().setKeepAwake(true), completes);
  });
}
