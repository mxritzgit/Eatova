import 'dart:async';

import 'package:eatova/src/services/recipe_share_receiver.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('eatova/recipe_share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late RecipeShareReceiver receiver;
  late StreamSubscription<SharedRecipeSource> subscription;
  late List<SharedRecipeSource> received;
  final ownerA = 'a' * 64;
  final ownerB = 'b' * 64;

  setUp(() {
    receiver = RecipeShareReceiver(channel: channel);
    receiver.bindOwner(ownerA);
    received = [];
    subscription = receiver.shares.listen(received.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await receiver.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'delivers cold start shares once and trims surrounding whitespace',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => [
          {'id': 'cold', 'text': '  https://www.tiktok.com/@cook/video/123  '},
        ],
      );
      await receiver.start();
      await receiver.refresh();
      expect(received.map((value) => value.id), ['cold']);
      expect(received.single.text, 'https://www.tiktok.com/@cook/video/123');
    },
  );

  test('warm share event and foreground both drain the native inbox', () async {
    var count = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => [
        {'id': 'share-${count++}', 'text': 'Recipe text'},
      ],
    );
    await receiver.start();
    final event = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('sharesAvailable')),
      (_) => event.complete(),
    );
    await event.future;
    receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await receiver.refresh();
    expect(received.length, greaterThanOrEqualTo(3));
    expect(received.map((value) => value.id).toSet().length, received.length);
  });

  test('rejects malformed and oversized platform payloads', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => [
        null,
        {'id': 123, 'text': 'recipe'},
        {'id': '', 'text': 'recipe'},
        {'id': 'empty', 'text': '  '},
        {'id': 'large', 'text': 'a' * (RecipeShareReceiver.maxTextLength + 1)},
        {'id': 'null-byte', 'text': 'recipe\u0000text'},
        {'id': 'valid', 'text': '1 tomato\nCook for 5 minutes'},
      ],
    );
    await receiver.start();
    expect(received.map((value) => value.id), ['valid']);
  });

  test('account switch discards an in-flight share before delivery', () async {
    final response = Completer<Object?>();
    var clearCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clearPending') {
        clearCount++;
        return null;
      }
      return response.future;
    });
    final started = receiver.start();
    await receiver.clearPending();
    response.complete([
      {'id': 'old-account', 'text': 'Private recipe'},
    ]);
    await started;
    expect(received, isEmpty);
    expect(clearCount, 1);
  });

  test('event received during a drain triggers a second pass', () async {
    final first = Completer<Object?>();
    var drains = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      drains++;
      if (drains == 1) return first.future;
      return [
        {'id': 'later', 'text': 'Later recipe'},
      ];
    });
    final initial = receiver.start();
    final again = receiver.refresh();
    first.complete([
      {'id': 'first', 'text': 'First recipe'},
    ]);
    await Future.wait([initial, again]);
    expect(drains, 2);
    expect(received.map((value) => value.id), ['first', 'later']);
  });

  test(
    'disposing while native consume is pending suppresses delivery',
    () async {
      final response = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => response.future);
      final started = receiver.start();
      await subscription.cancel();
      await receiver.dispose();
      response.complete([
        {'id': 'late', 'text': 'Recipe'},
      ]);
      await started;
      expect(received, isEmpty);
    },
  );

  test('missing native plugin is harmless on unsupported platforms', () async {
    await receiver.start();
    await receiver.clearPending();
    expect(received, isEmpty);
  });

  test('temporarily locked inbox retries on the next refresh', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      if (attempts++ == 0) {
        throw PlatformException(code: 'share_inbox_unavailable');
      }
      return [
        {'id': 'unlocked', 'text': 'Recipe'},
      ];
    });
    await receiver.start();
    expect(received, isEmpty);
    await receiver.refresh();
    expect(received.single.id, 'unlocked');
  });

  test('does not consume source text before a listener exists', () async {
    await subscription.cancel();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return [];
    });
    await receiver.start();
    expect(calls, 0);
  });

  test(
    'requires an explicit initial owner before consuming native state',
    () async {
      await subscription.cancel();
      await receiver.dispose();
      receiver = RecipeShareReceiver(channel: channel);
      subscription = receiver.shares.listen(received.add);
      final arguments = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        arguments.add(call.arguments);
        return [];
      });
      await receiver.start();
      await receiver.refresh();
      expect(arguments, isEmpty);
      await expectLater(receiver.clearPending(), throwsStateError);
      receiver.bindOwner(null);
      await receiver.refresh();
      expect(arguments, [
        {'owner': null},
      ]);
    },
  );

  test('consume and clear carry the current nonsecret owner scope', () async {
    final calls = <(String, Object?)>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add((call.method, call.arguments));
      return call.method == 'consumePending' ? [] : null;
    });
    await receiver.start();
    receiver.bindOwner(ownerB);
    await receiver.clearPending();
    await receiver.refresh();
    expect(calls.map((call) => call.$1), [
      'consumePending',
      'clearPending',
      'consumePending',
    ]);
    expect(calls.map((call) => call.$2), [
      {'owner': ownerA},
      {'owner': ownerB},
      {'owner': ownerB},
    ]);
  });

  test(
    'owner binding invalidates an earlier consume without relying on clear',
    () async {
      final response = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => response.future);
      final started = receiver.start();
      receiver.bindOwner(ownerB);
      response.complete([
        {'id': 'old-owner', 'text': 'Old account recipe'},
      ]);
      await started;
      expect(received, isEmpty);
    },
  );

  test('rejects malformed owner keys without including them in errors', () {
    const invalid = 'not-an-owner-secret';
    expect(
      () => receiver.bindOwner(invalid),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'sanitized diagnostic',
          isNot(contains(invalid)),
        ),
      ),
    );
  });
}
