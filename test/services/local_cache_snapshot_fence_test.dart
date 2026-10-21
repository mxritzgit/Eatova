import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';

// A store snapshot is guarded by the version of every hydrated slot, but only
// the slots it writes may be decoded: decoding and re-encoding the others
// (above all a multi-MB training history) blocked the UI isolate at every
// cold start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const weightKey = 'eatova.v1.weight_log.u';

  test('ein nur bewachter, nicht geschriebener Slot wird nicht dekodiert',
      () async {
    final kv = InMemoryKeyValueStore({weightKey: 'kein JSON'});
    final cache = LocalCache(kv, 'u');
    final guards = (await cache.readMutationSnapshot(allowPartial: true))
        .snapshot
        .versions;
    expect(guards, contains(weightKey));

    // Decoding the guarded slot would throw a FormatException here.
    await cache.commitStoreSnapshot(
      expectedVersions: Map.of(guards),
      profile: const UserProfile(onboardingCompleted: true),
    );

    expect((await cache.readProfile())!.onboardingCompleted, isTrue);
    expect(await kv.getString(weightKey), 'kein JSON');
  });

  test('ein geänderter bewachter Slot bleibt ein Konflikt', () async {
    final kv = InMemoryKeyValueStore({weightKey: '{"items":[]}'});
    final cache = LocalCache(kv, 'u');
    final guards = (await cache.readMutationSnapshot(allowPartial: true))
        .snapshot
        .versions;
    await kv.setString(weightKey, '{"items":[]} ');

    await expectLater(
      cache.commitStoreSnapshot(
        expectedVersions: Map.of(guards),
        profile: const UserProfile(onboardingCompleted: true),
      ),
      throwsA(isA<KeyValueConflict>()),
    );
    expect(await cache.readProfile(), isNull);
  });
}
