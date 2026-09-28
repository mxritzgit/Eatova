// The readable export report shows persisted German fallbacks in the active
// language, read together with their sibling fields exactly as the screens
// resolve them. The lossless JSON and the CSV keep every stored value raw.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/export_document.dart';
import 'package:eatova/src/widgets/shared/export_sections.dart';

import '../support/harness.dart';

/// Stored exactly as `MealAnalysisResult.adjustedToGrams` writes it.
const _legacyGramsDensity =
    'Manuell angepasst: 250 g statt der ursprünglichen Portion. Kalorien neu '
    'berechnet mit 180 kcal pro 100 g.';

void main() {
  group('Export-Bericht', () {
    final source = jsonEncode(<String, dynamic>{
      'format': 'eatova-export/1',
      'logged_meals': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'm1',
          'logged_at': '2026-09-28T12:00:00Z',
          'meal_name': 'Produkt 4001 · Milka',
          'barcode': '4001',
          'payload': <String, dynamic>{
            'mealName': 'Produkt 4001 · Milka',
            'protein': '12,5 g',
            'portionNotes': _legacyGramsDensity,
            'sourceLabel': 'OpenFoodFacts',
            'confidence': 'Datenbank',
            'barcode': '4001',
            'brand': 'Milka',
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'name': 'Zutat'},
              <String, dynamic>{'name': 'Mein Brot'},
            ],
          },
        },
        <String, dynamic>{
          'id': 'm2',
          'logged_at': '2026-09-27T12:00:00Z',
          'payload': <String, dynamic>{
            'mealName': 'Linsensuppe',
            'portionNotes':
                '2 Portionen · Eigenes Rezept Selbst angelegt. Werte beruhen '
                'auf deinen Angaben.',
            'sourceLabel': 'recipe',
          },
        },
      ],
      'favorite_meals': <Map<String, dynamic>>[
        <String, dynamic>{
          'favorite_key': 'name:unbekannte mahlzeit',
          'payload': <String, dynamic>{
            'mealName': 'Unbekannte Mahlzeit',
            'sourceLabel': 'Foto-KI',
          },
        },
      ],
      'user_recipes': <Map<String, dynamic>>[
        <String, dynamic>{
          'slug': 'user_import_abc',
          'title': 'Eigenes Rezept',
          'description': 'Suppe\n\nQuelle: https://example.com/a',
          'structured_ingredients': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'Produkt 4001',
              'source': 'openFoodFacts',
              'product_code': '4001',
            },
          ],
        },
      ],
      'chat_sessions': <Map<String, dynamic>>[
        <String, dynamic>{'title': 'Mahlzeit'},
      ],
    });

    String report(AppLocalizations l10n) => ExportDocument.parse(source).report(
      'Export',
      (key) => key,
      value: (fields, path, value) =>
          exportReadableValue(fields, path, value, l10n),
    );

    test('der lesbare Bericht loest auf, JSON und CSV bleiben roh', () {
      final en = report(enL10n);
      for (final line in const <String>[
        '/meal_name: Product 4001 · Milka',
        '/payload/mealName: Product 4001 · Milka',
        '/payload/protein: 12.5 g',
        '/payload/portionNotes: Adjusted manually: 250 g instead of the '
            'original portion. Calories recalculated at 180 kcal per 100 g.',
        '/payload/sourceLabel: OpenFoodFacts',
        '/payload/confidence: Database',
        '/payload/items/1/name: Ingredient',
        '/payload/items/2/name: Mein Brot',
        '/payload/portionNotes: 2 servings · Your recipe Self-added. Values '
            'are based on what you entered.',
        '/payload/mealName: Unknown meal',
        '/payload/sourceLabel: Photo AI',
        '/title: Your recipe',
        '/description: Suppe\n\nSource: https://example.com/a',
        '/structured_ingredients/1/name: Product 4001',
        // A chat title is not a meal payload and stays as stored.
        '/title: Mahlzeit',
      ]) {
        expect(en, contains(line));
      }

      final de = report(deL10n);
      for (final line in const <String>[
        '/meal_name: Produkt 4001 · Milka',
        '/payload/protein: 12,5 g',
        '/payload/portionNotes: $_legacyGramsDensity',
        '/payload/items/1/name: Zutat',
        '/payload/mealName: Unbekannte Mahlzeit',
        '/title: Eigenes Rezept',
        '/description: Suppe\n\nQuelle: https://example.com/a',
      ]) {
        expect(de, contains(line));
      }

      final document = ExportDocument.parse(source);
      expect(document.json, contains('"mealName": "Unbekannte Mahlzeit"'));
      expect(document.json, contains('"protein": "12,5 g"'));
      expect(document.json, contains(jsonEncode(_legacyGramsDensity)));
      final csv = document.sections
          .firstWhere((s) => s.key == 'logged_meals')
          .csv;
      expect(csv, contains('"Produkt 4001 · Milka"'));
      expect(csv, contains('"12,5 g"'));
    });
  });

  group('Export-Vorschau und Abschnitts-Kopie', () {
    final section = ExportDocument.parse(
      jsonEncode(<String, dynamic>{
        'favorite_meals': <Map<String, dynamic>>[
          <String, dynamic>{
            'favorite_key': 'name:unbekannte mahlzeit',
            'payload': <String, dynamic>{
              'mealName': 'Unbekannte Mahlzeit',
              'protein': '12,5 g',
            },
          },
        ],
      }),
    ).sections.single;

    for (final (locale, name, protein) in const [
      (Locale('en'), 'Unknown meal', '12.5 g'),
      (Locale('de'), 'Unbekannte Mahlzeit', '12,5 g'),
    ]) {
      testWidgets('${locale.languageCode}: Karte und Kopie zeigen $name', (
        tester,
      ) async {
        String? copied;
        await pumpLocalized(
          tester,
          ExportSectionView(
            section: section,
            onCopy: (text) async => copied = text,
          ),
          locale: locale,
          scrollable: true,
        );
        await tester.tap(
          find.byKey(const ValueKey('export-expand-favorite_meals')),
        );
        await tester.pumpAndSettle();

        expect(find.text(name), findsOneWidget);
        expect(find.text(protein), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('export-copy-favorite_meals')),
        );
        await tester.pump();
        expect(copied, contains(': $name'));
        expect(copied, contains(': $protein'));
      });
    }
  });
}
