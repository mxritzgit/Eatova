import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verdrahtungs-Wächter für `local_cache.dart:104`
/// (`EncryptedKeyValueStore.create(base)`) — gefunden von Agent W6-02.
///
/// Es ist dieselbe Klasse wie C5 und D1: Die **Logik** ist gründlich getestet
/// (`secure_cache_store_test.dart` treibt `EncryptedKeyValueStore` direkt),
/// aber die eine Zeile, die sie an den Produktionspfad hängt, war es nicht.
///
/// Warum die Bestandstests das nicht fangen: `LocalCache.create` wird in
/// keinem von ihnen aufgerufen. Der öffentliche Konstruktor nimmt bewusst
/// einen nackten `KeyValueStore`, und alle Cache-Tests injizieren
/// `InMemoryKeyValueStore` mit Klartext. Wer Zeile 104 durch `final store =
/// base;` ersetzt, legt 35 Tage Tagebuch, die Gewichtsreihe und die
/// Körpermaße wieder unverschlüsselt ab — bei grüner Suite.
///
/// Genau der Fund, den `7f895f9` mit der Cache-Verschlüsselung geschlossen hat.
///
/// Geprüft wird deshalb **das Ergebnis auf der Platte**, nicht der Quelltext:
/// `EATOVA1:` ist das Magic des Envelope-Formats.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = 'user-verdrahtung';

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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
      'LocalCache.create legt das Tagebuch verschluesselt ab — nicht im '
      'Klartext', () async {
    final cache = await LocalCache.create(userId);
    expect(cache, isNotNull,
        reason: 'ohne DEK gaebe es gar keinen Cache — dann prueft der Test '
            'nichts');

    await cache!.writeLoggedMeals(<LoggedMeal>[mahlzeit()]);

    final prefs = await SharedPreferences.getInstance();
    final slots = prefs.getKeys().where((k) => k.contains(userId)).toList();
    expect(slots, isNotEmpty, reason: 'irgendwo muss der Blob liegen');

    for (final slot in slots) {
      final wert = prefs.get(slot);
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

    // Zweite Instanz auf demselben Speicher: so sieht ein Kaltstart aus.
    final zweite = (await LocalCache.create(userId))!;
    final gelesen = await zweite.readLoggedMeals();

    expect(gelesen, isNotNull);
    expect(gelesen!.single.result.mealName, 'Lachsbowl mit Reis');
    expect(gelesen.single.result.caloriesKcal, 780);
  });

  test(
      'ein fremder Nutzer kann den Blob nicht lesen — die AAD bindet den Slot',
      () async {
    final a = (await LocalCache.create('user-a'))!;
    await a.writeLoggedMeals(<LoggedMeal>[mahlzeit()]);

    final prefs = await SharedPreferences.getInstance();
    final fremderSlot =
        prefs.getKeys().firstWhere((k) => k.contains('logged_meals'));
    final blob = prefs.getString(fremderSlot)!;

    // Denselben Ciphertext in den Slot eines anderen Users schieben.
    await prefs.setString(
        fremderSlot.replaceAll('user-a', 'user-b'), blob);

    final b = (await LocalCache.create('user-b'))!;
    expect(await b.readLoggedMeals(), anyOf(isNull, isEmpty),
        reason: 'ein verschobener Slot darf sich nicht entschluesseln lassen');
  });
}
