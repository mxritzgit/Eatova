import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-09 (store half): `unawaited(_hydrateThenBoot())` had
// no catch, so a throw anywhere in the fire-and-forget boot chain became an
// unhandled zone error ("fatal" in Sentry) instead of a handled report. The
// notification init got its own fence in the profile part (F7-12); this test
// drives a throw the chain itself does not fence: the reminder opt-in read at
// the very end of the boot.

/// Cache whose notification slot throws on read, like a broken store.
class _KaputterSlotCache extends LocalCache {
  _KaputterSlotCache(super.store, super.userId);

  @override
  Future<bool?> readNotificationsEnabled() async =>
      throw StateError('notifications slot unreadable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ein Wurf am Ende der Boot-Kette wird gemeldet, nicht unhandled',
      () async {
    final gemeldet = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(context);
    };
    addTearDown(() => CrashReporter.debugSentrySink = null);

    final kv = InMemoryKeyValueStore();
    final s = fixlaufSetup(kv: kv, cache: _KaputterSlotCache(kv, kFixlaufUser));
    s.server.profileRow = serverProfileRow(completedProfile);

    // Without the guard the test runner reports the unhandled exception.
    await bootStore(s.store);

    expect(gemeldet, contains('boot'),
        reason: 'ein StateError ist kein Netzfehler und muss gemeldet werden');
    expect(s.store.profile.weightKg, 80,
        reason: 'der Boot davor bleibt wirksam');
    expect(s.store.bootUnanswered, isFalse);
  });
}
