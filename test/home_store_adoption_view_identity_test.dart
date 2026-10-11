import 'package:flutter_test/flutter_test.dart';

import 'outbox/outbox_test_helpers.dart' as h;

// The Training tab's StoreSelector compares `pendingTrainingAdoptions` by
// identity. The view was rebuilt on every outbox commit, so a logged meal
// (or its delivery) handed out a new empty list and rebuilt the Training tab
// although no adoption had changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ein Outbox-Commit ohne Adoptionen behält die Ansicht', () async {
    final env = h.setup();
    env.server.offline = true;
    await env.cache.writeProfile(h.testProfile());
    await h.bootUntilIdle(env.store);

    final before = env.store.pendingTrainingAdoptions;
    final outboxBefore = env.store.pendingOutbox.length;
    await env.store.addResultToDailyTotal(h.mealResult('Offline-Bowl'));
    await h.settle();

    expect(env.store.pendingOutbox.length, greaterThan(outboxBefore));
    expect(env.store.pendingTrainingAdoptions, isEmpty);
    expect(identical(env.store.pendingTrainingAdoptions, before), isTrue);
  });
}
