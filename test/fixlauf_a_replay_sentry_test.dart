import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-04: the live write already filtered network errors
// (`captureSyncFailure`), but the replay 30 s later, the stats flush, the
// delete restore and the direct-error path still used `capture` — so every
// offline replay pass raised one Sentry event per op. Same rule as
// test/sentry_offline_noise_test.dart, driven through the store paths.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gemeldet = <Object>[];
  final kontexte = <String?>[];

  setUp(() {
    gemeldet.clear();
    kontexte.clear();
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
      kontexte.add(context);
    };
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  Future<FixlaufSetup> bootOnline() async {
    final s = fixlaufSetup();
    s.server.profileRow = serverProfileRow(completedProfile);
    await bootStore(s.store);
    return s;
  }

  test('Offline-Replay meldet nichts an Sentry', () async {
    final s = await bootOnline();
    s.server.offline = true;
    s.store.addResultToDailyTotal(mealResult('Zug'));
    await settle();
    // Meal insert plus its recents upsert.
    expect(s.store.pendingOutbox, hasLength(2), reason: 'Vorbedingung');
    gemeldet.clear();

    // Resume flush -> replay pass offline.
    s.store.flushPendingWrites();
    await settle();

    expect(gemeldet, isEmpty,
        reason: 'ein Netzfehler im Replay ist der vorgesehene Fluss, kein '
            'Vorfall: ${kontexte.join(', ')}');
    expect(s.store.pendingOutbox, hasLength(2), reason: 'Ops bleiben liegen');
  });

  // The sixth site of the same rule, and the loudest one: `_safeLoad` wraps
  // all SIX boot loads. Unfiltered that is six Sentry events per offline cold
  // start — more than every other path here together, and nothing in the suite
  // measured it.
  test('Kaltstart offline meldet nichts an Sentry', () async {
    final s = fixlaufSetup();
    s.server.profileRow = serverProfileRow(completedProfile);
    s.server.offline = true;

    await bootStore(s.store);

    expect(gemeldet, isEmpty,
        reason: 'Cache-dann-Netz ist der vorgesehene Fluss, kein Vorfall: '
            '${kontexte.join(', ')}');
    expect(s.store.bootUnanswered, isTrue,
        reason: 'gefiltert heisst nicht verschwiegen — der Nutzer sieht den '
            'Verbindungszustand');
  });

  test('Offline-Stats-Flush meldet nichts an Sentry', () async {
    final s = await bootOnline();
    s.store.addResultToDailyTotal(mealResult('Geliefert'));
    await settle();
    // Meal delivered live -> delta pending in the 600 ms debounce.
    s.server.offline = true;
    gemeldet.clear();

    s.store.flushPendingWrites();
    await settle();

    expect(gemeldet, isEmpty, reason: kontexte.join(', '));
  });

  test('Offline-Nachladen eines Archivtags meldet nichts, zeigt aber den '
      'Offline-Hinweis', () async {
    final s = await bootOnline();
    s.server.offline = true;
    gemeldet.clear();

    s.store.setFoodDate(DateTime.now().subtract(const Duration(days: 60)));
    await settle();

    expect(gemeldet, isEmpty, reason: kontexte.join(', '));
    expect(s.snacks.tones, contains(SnackTone.error),
        reason: 'der Nutzer erfaehrt weiterhin, dass der Tag nicht geladen '
            'werden konnte');
  });

  test('Kontrolle: ein echter Serverfehler im Replay geht weiterhin an '
      'Sentry', () async {
    final s = await bootOnline();
    s.server.rejectMealWrites = true;
    s.store.addResultToDailyTotal(mealResult('Kaputt'));
    await settle();
    gemeldet.clear();

    s.store.flushPendingWrites();
    await settle();

    expect(gemeldet, isNotEmpty,
        reason: '500 vom Server ist ein Vorfall, den sonst niemand sieht');
    expect(kontexte, contains('outbox-replay-mealInsert'));
  });
}
