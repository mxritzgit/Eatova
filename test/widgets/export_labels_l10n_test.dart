import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/widgets/shared/export_sections.dart';

// The export keeps German wire keys (`vollstaendigkeitUnbekannt`, `gekappt`
// with `grenzeProSektion`/`sektionen`/`zeilenAufDemServer`) and the section
// `user_recipe_history`. Without a mapping, the label fallback humanised the
// raw key, so English readers saw "Vollstaendigkeit Unbekannt" and German
// readers "User recipe history". Every key the export writes has a label in
// both languages now.

/// Mirrors the fallback: a humanised raw key is what must NOT appear.
bool _looksRaw(String label, String key) {
  final spaced = key
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase();
  return label.toLowerCase() == spaced;
}

void main() {
  // German only: an English label may legitimately read like its snake_case
  // key ("Training plans"), a German one never does.
  test('jede exportierte Tabelle hat eine deutsche Beschriftung', () {
    for (final table in DataExportService.alleExportTabellen) {
      final label = exportLabel(table, deL10n);
      expect(_looksRaw(label, table), isFalse, reason: '$table -> $label');
    }
  });

  test('KI-Nutzung ist beschriftet', () {
    expect(exportLabel('ai_provider_user_usage', deL10n), 'KI-Nutzung');
    expect(exportLabel('ai_provider_user_usage', enL10n), 'AI usage');
  });

  for (final l10n in [deL10n, enL10n]) {
    group('Sprache ${l10n.localeName}', () {
      test('Vollstaendigkeits- und Kappungsangaben', () {
        expect(
          exportLabel('vollstaendigkeitUnbekannt', l10n),
          l10n.exportCompletenessUnknown,
        );
        expect(exportLabel('user_recipe_history', l10n), l10n.exportRecipeHistory);
        expect(
          exportLabel('/grenzeProSektion', l10n),
          l10n.exportFieldCapPerSection,
        );
        expect(
          exportLabel('/sektionen/0', l10n),
          '${l10n.exportFieldCappedSections} › 0',
        );
        expect(
          exportLabel('/zeilenAufDemServer/logged_meals', l10n),
          '${l10n.exportFieldServerRowCount} › ${l10n.exportMeals}',
        );
      });

      test('bestehende Beschriftungen bleiben unveraendert', () {
        expect(exportLabel('gekappt', l10n), l10n.exportCapped);
        expect(exportLabel('unvollstaendig', l10n), l10n.exportMissing);
        expect(exportLabel('/payload/mealName', l10n),
            '${l10n.exportFieldPayload} › ${l10n.exportFieldMealName}');
      });
    });
  }
}
