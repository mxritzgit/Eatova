import 'dart:io';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wiring guard for the encrypted production SQLite path in LocalCache.create.
///
/// The logic is well covered (`secure_cache_store_test.dart` drives
/// `EncryptedKeyValueStore` directly), but the one line attaching it to the
/// production path was not: no other test calls `LocalCache.create`, and every
/// cache test injects a plaintext `InMemoryKeyValueStore`. Dropping the
/// encryption there would store the diary, weight series and body metrics in
/// the clear with a green suite.
///
/// Therefore this asserts **the result on disk**, not the source:
/// `EATOVA1:` is the envelope format's magic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 'user-verdrahtung';
  late Directory directory;

  LoggedMeal mahlzeit() => LoggedMeal(
        id: 'm-1',
        result: const MealAnalysisResult(
          mealName: 'Lachsbowl mit Reis',
          caloriesKcal: 780,
          estimatedGrams: 420,
          kcalPer100G: 185.7,
          protein: '46 g',
          carbs: '61 g',
          fat: '28 g',
          confidence: 'high',
          portionNotes: '',
        ),
        loggedAt: DateTime(2026, 8, 8, 12, 30),
      );

  setUp(() async {
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('eatova_wiring_');
    LocalCache.debugDatabasePath = '${directory.path}/cache.sqlite';
  });

  tearDown(() async {
    await DurableCacheStore.closeAll();
    CacheKeyProvider.debugReset();
    LocalCache.debugDatabasePath = null;
    await directory.delete(recursive: true);
  });

  test(
      'LocalCache.create legt das Tagebuch verschluesselt ab — nicht im '
      'Klartext', () async {
    final cache = await LocalCache.create(userId);
    expect(cache, isNotNull,
        reason: 'ohne DEK gaebe es gar keinen Cache — dann prueft der Test '
            'nichts');

    await cache!.writeLoggedMeals(<LoggedMeal>[mahlzeit()]);
    await cache.releaseStorage();

    final raw = await SqliteKeyValueStore.open(LocalCache.debugDatabasePath!);
    addTearDown(raw.close);
    final snapshot = await raw.readAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.contains(userId)), isEmpty);
    final slots = snapshot.values.keys.where((k) => k.contains(userId)).toList();
    expect(slots, isNotEmpty, reason: 'irgendwo muss der Blob liegen');

    for (final slot in slots) {
      final wert = snapshot.values[slot];
      if (wert is! String) continue;
      expect(wert, startsWith('EATOVA1:'),
          reason: '$slot traegt kein Envelope-Magic — der Inhalt liegt roh da');
      expect(wert, isNot(contains('Lachsbowl')),
          reason: 'der Mahlzeitenname ist Essverhalten, also Art.-9-nah');
      expect(wert, isNot(contains('780')),
          reason: 'Kalorien sind ein Gesundheitsdatum');
    }
  });

  test('was verschluesselt abgelegt wurde, liest derselbe Cache wieder',
      () async {
    final cache = (await LocalCache.create(userId))!;
    await cache.writeLoggedMeals(<LoggedMeal>[mahlzeit()]);
    await cache.releaseStorage();
    CacheKeyProvider.debugReset();

    // Reopen the file and reread the OS key, as on a cold start.
    final zweite = (await LocalCache.create(userId))!;
    addTearDown(zweite.releaseStorage);
    final gelesen = await zweite.readLoggedMeals();

    expect(gelesen, isNotNull);
    expect(gelesen!.single.result.mealName, 'Lachsbowl mit Reis');
    expect(gelesen.single.result.caloriesKcal, 780);
  });

  test(
      'ein fremder Nutzer kann den Blob nicht lesen — die AAD bindet den Slot',
      () async {
    final a = (await LocalCache.create('user-a'))!;
    addTearDown(a.releaseStorage);
    await a.writeLoggedMeals(<LoggedMeal>[mahlzeit()]);

    final raw = await SqliteKeyValueStore.open(LocalCache.debugDatabasePath!);
    addTearDown(raw.close);
    const fremderSlot = 'eatova.v1.logged_meals.user-a';
    final blob = (await raw.getString(fremderSlot))!;

    // Move the same ciphertext into another user's slot.
    await raw.setString(
        fremderSlot.replaceAll('user-a', 'user-b'), blob);

    final b = (await LocalCache.create('user-b'))!;
    addTearDown(b.releaseStorage);
    expect(await b.readLoggedMeals(), anyOf(isNull, isEmpty),
        reason: 'ein verschobener Slot darf sich nicht entschluesseln lassen');
  });

  test('headless release keeps a foreground handle usable', () async {
    final foreground = (await LocalCache.create(userId))!;
    final background = (await LocalCache.create(userId, background: true))!;
    await background.releaseStorage();
    await background.releaseStorage();
    await foreground.writeLoggedMeals([mahlzeit()]);
    expect((await foreground.readLoggedMeals())!.single.id, 'm-1');
    await foreground.releaseStorage();
  });
}
