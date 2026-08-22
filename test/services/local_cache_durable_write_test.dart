import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';

// Review 2026-08-19, finding 1: the outbox write went through the same
// silently-swallowing path as the speed cache.
//
// The difference matters: the diary and favorites also live on the server, so
// a lost cache write costs one network load. The outbox and pending stats
// deltas exist nowhere else — if that write is lost (unreadable AES key,
// plugin channel error, encode error), the offline meal is gone while the UI
// says it is syncing.
//
// This file pins the split: sync-state slots report failure to the caller AND
// to the CrashReporter, mirror slots stay deliberately silent, and the report
// carries only a slot short name and error type — never key or value.

/// Store whose `setString` throws for selected slots. Models the failure BELOW
/// the cache (crypto decorator or plugin channel), which is where a real throw
/// originates.
class _SchreibfehlerStore implements KeyValueStore {
  _SchreibfehlerStore(this.faelltAus);

  final bool Function(String key) faelltAus;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> getString(String key) async => data[key];

  @override
  Future<void> setString(String key, String value) async {
    if (faelltAus(key)) throw StateError('Slot nicht schreibbar');
    data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    data.remove(key);
  }
}

const String _pii = 'Rueckenschmerzen nach dem Kebab';
const String _uid = 'user-durable';

MealAnalysisResult _result() => const MealAnalysisResult(
      mealName: 'Doener Teller',
      caloriesKcal: 820,
      estimatedGrams: 480,
      kcalPer100G: 170.8,
      protein: '48 g',
      carbs: '62 g',
      fat: '38 g',
      confidence: 'Mittel',
      portionNotes: _pii,
      sourceLabel: 'Foto-KI',
    );

LoggedMeal _meal(String id) => LoggedMeal(
      id: id,
      result: _result(),
      loggedAt: DateTime(2026, 8, 19, 12, 30),
      forcedSlot: MealSlot.lunch,
      localDay: '2026-08-19',
    );

void main() {
  final berichte = <({Object error, String? context})>[];

  setUp(() {
    berichte.clear();
    CrashReporter.debugSentrySink = (error, stack, context) {
      berichte.add((error: error, context: context));
    };
  });
  tearDown(() => CrashReporter.debugSentrySink = null);

  // `capture` runs unawaited — wait one microtask.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('Sync-Zustands-Slots melden Misserfolg', () {
    test('writeOutbox liefert false und meldet den Fehlschlag', () async {
      final store =
          _SchreibfehlerStore((k) => k == 'eatova.v1.outbox.$_uid');
      final cache = LocalCache(store, _uid);

      final ok = await cache.writeOutbox(
          [SyncOp.mealInsert(_meal('m-1'), trackDay: true)]);
      await settle();

      expect(ok, isFalse,
          reason: 'Ohne Rueckgabewert hat der Aufrufer keinen Ausgang — die '
              'Mahlzeit gilt als eingereiht, liegt aber nirgends.');
      expect(store.data.containsKey('eatova.v1.outbox.$_uid'), isFalse);
      expect(berichte, hasLength(1));
      expect(berichte.single.context, 'cache_durable_write');
    });

    test('writePendingStatsDeltas liefert false und meldet', () async {
      final store =
          _SchreibfehlerStore((k) => k == 'eatova.v1.pending_stats.$_uid');
      final cache = LocalCache(store, _uid);

      final ok = await cache.writePendingStatsDeltas(
          meals: 3, weightLogs: 1, requestId: 'req-1');
      await settle();

      expect(ok, isFalse);
      expect(berichte.single.context, 'cache_durable_write');
    });

    test('gelungener Write liefert true und meldet nichts', () async {
      final cache = LocalCache(_SchreibfehlerStore((_) => false), _uid);

      expect(await cache.writeOutbox([SyncOp.mealDelete('m-1')]), isTrue);
      expect(
          await cache.writePendingStatsDeltas(meals: 1, weightLogs: 0), isTrue);
      await settle();

      expect(berichte, isEmpty,
          reason: 'Der Normalfall darf das Sentry-Kontingent nicht anfassen.');
    });
  });

  group('Spiegel-Slots bleiben bewusst still', () {
    test('ein gescheiterter Tagebuch-Write meldet nichts und wirft nicht',
        () async {
      final cache = LocalCache(_SchreibfehlerStore((_) => true), _uid);

      await cache.writeLoggedMeals([_meal('m-1')]);
      await cache.writeFavorites(const []);
      await settle();

      expect(berichte, isEmpty,
          reason: 'Tagebuch und Favoriten stehen auf dem Server — ein '
              'verlorener Cache-Write kostet einen Netz-Load, keinen Inhalt. '
              'Sonst waere jeder Flugmodus-Start ein Sentry-Issue.');
    });
  });

  group('Der Report traegt keine Nutzerdaten', () {
    test('weder Mahlzeit noch User-ID noch Storage-Key', () async {
      final store =
          _SchreibfehlerStore((k) => k == 'eatova.v1.outbox.$_uid');
      final cache = LocalCache(store, _uid);

      await cache.writeOutbox([SyncOp.mealInsert(_meal('m-1'), trackDay: true)]);
      await settle();

      final text = berichte.single.error.toString();
      expect(text, contains('UnwritableCacheSlot'),
          reason: 'Der Fehlertyp ist die ganze Diagnose — er muss den '
              'Sanitizer ueberleben.');
      expect(text, isNot(contains(_pii)));
      expect(text, isNot(contains('Doener')));
      expect(text, isNot(contains(_uid)));
    });

    test('das Fehlerobjekt selbst haelt nur Slot-Kurzname und Fehlertyp', () {
      const fehler = UnwritableCacheSlot('outbox', 'PlatformException');

      expect(fehler.toString(), contains('outbox'));
      expect(fehler.toString(), contains('PlatformException'));
      expect(fehler.toString(), isNot(contains('eatova.v1.')));
    });
  });
}
