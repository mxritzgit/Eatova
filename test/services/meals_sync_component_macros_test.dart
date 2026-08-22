import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/services/meals_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// B8, sync half: `MealComponent` carries optional macros
/// (`proteinG`/`carbsG`/`fatG`); `adjustedToItems` may sum them only when
/// **all** items have them, otherwise the meal stays "unknown".
///
/// `meals_sync` serializes separately from `MealComponent.toJson`, so losing
/// macros there would fail silently: correct right after editing, `-` after
/// the next cold start.
void main() {
  const salatMitOel = MealAnalysisResult(
    mealName: 'Salat mit Hähnchen',
    caloriesKcal: 560,
    estimatedGrams: 420,
    kcalPer100G: 133.33,
    protein: '35 g',
    carbs: '12 g',
    fat: '32 g',
    confidence: 'medium',
    portionNotes: '',
    items: <MealComponent>[
      MealComponent(
        name: 'Salat mit Hähnchen',
        grams: 400,
        caloriesKcal: 380,
        kcalPer100G: 95,
        proteinG: 35,
        carbsG: 12,
        fatG: 12,
      ),
      MealComponent(
        name: 'Olivenöl',
        grams: 20,
        caloriesKcal: 180,
        kcalPer100G: 900,
        proteinG: 0,
        carbsG: 0,
        fatG: 20,
      ),
    ],
  );

  test(
      'B8: Makros pro Bestandteil ueberleben den Sync-Roundtrip — sonst '
      'stehen die gerade korrigierten Werte nach dem Kaltstart auf "-"', () {
    final zurueck = mealResultFromJson(mealResultToJson(salatMitOel));

    expect(zurueck.items, hasLength(2));
    expect(zurueck.items[0].proteinG, 35);
    expect(zurueck.items[0].carbsG, 12);
    expect(zurueck.items[0].fatG, 12);
    expect(zurueck.items[1].proteinG, 0,
        reason: '0 g ist eine Aussage, nicht "unbekannt" — darf nicht zu null '
            'werden');
    expect(zurueck.items[1].fatG, 20);
  });

  test(
      'B8: nach dem Roundtrip summiert adjustedToItems die Makros weiterhin '
      'exakt, statt auf Massenskalierung zurueckzufallen', () {
    final zurueck = mealResultFromJson(mealResultToJson(salatMitOel));

    expect(zurueck.items.every((c) => c.hasMacros), isTrue);
    // B8 scenario: 20 g of oil mean ~32 g fat overall; mass scaling
    // (factor 1.05) would have produced 12.6 g.
    expect(zurueck.adjustedToItems(zurueck.items).fat, '32 g');
  });

  test(
      'B8: fehlende Makros bleiben fehlend — der Roundtrip erfindet keine 0 g',
      () {
    const ohneMakros = MealAnalysisResult(
      mealName: 'Scan ohne Makros',
      caloriesKcal: 300,
      estimatedGrams: 200,
      kcalPer100G: 150,
      protein: '-',
      carbs: '-',
      fat: '-',
      confidence: 'low',
      portionNotes: '',
      items: <MealComponent>[
        MealComponent(name: 'Teller', grams: 200, caloriesKcal: 300),
      ],
    );

    final zurueck = mealResultFromJson(mealResultToJson(ohneMakros));

    expect(zurueck.items.single.proteinG, isNull);
    expect(zurueck.items.single.carbsG, isNull);
    expect(zurueck.items.single.fatG, isNull);
    expect(zurueck.items.single.hasMacros, isFalse);
  });

  test('B8: Alt-Zeilen ohne Makro-Schluessel laden weiterhin sauber', () {
    // Rows written before wave 2.
    final alt = <String, dynamic>{
      'mealName': 'Alte Zeile',
      'caloriesKcal': 500,
      'estimatedGrams': 300,
      'kcalPer100G': 166.7,
      'protein': '20 g',
      'carbs': '50 g',
      'fat': '15 g',
      'confidence': 'medium',
      'items': <dynamic>[
        <String, dynamic>{
          'name': 'Alter Posten',
          'grams': 300,
          'caloriesKcal': 500,
        },
      ],
    };

    final geladen = mealResultFromJson(alt);

    expect(geladen.items.single.proteinG, isNull);
    expect(geladen.items.single.hasMacros, isFalse);
    expect(geladen.fat, '15 g', reason: 'die Mahlzeiten-Makros bleiben');
  });
}
