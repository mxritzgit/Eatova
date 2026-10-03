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
