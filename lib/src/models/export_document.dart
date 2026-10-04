import 'dart:convert';

import 'fitness_recipe.dart';

/// Readable text of one report field. [fields] is the whole flattened record
/// (see [exportFields]), so a value can be read together with its siblings.
typedef ExportValueText =
    String Function(Map<String, dynamic> fields, String path, dynamic value);

/// Presentation and portable output of an export. Unknown fields are retained.
class ExportDocument {
  ExportDocument._(this.data, this.sections);

  factory ExportDocument.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected an export object');
    }
    final keys = decoded.keys.toList()..sort(_compareKeys);
    final data = <String, dynamic>{};
    for (final key in keys) {
      final value = _ordered(decoded[key]);
      // Only sort table rows. Ingredient, workout and other nested arrays
      // carry meaningful order and must survive export unchanged.
      if (value is List && value.every((row) => row is Map)) {
        value.sort(_compareRows);
      }
      data[key] = value;
    }
    return ExportDocument._(data, [
      for (final entry in data.entries)
        if (!_metadata.contains(entry.key))
          ExportSection(entry.key, entry.value),
    ]);
  }

  final Map<String, dynamic> data;
  final List<ExportSection> sections;

  static const _metadata = ['format', 'exportedAt', 'userId'];
  static const _order = [
    ..._metadata,
    'profiles',
    'lifetime_stats',
    'logged_meals',
    'favorite_meals',
    'weight_log',
    'user_recipes',
    'planned_meals',
    'shopping_checks',
    'training_plans',
    'training_history',
    'training_history_deletions',
    'chat_sessions',
    'chat_messages',
    'chat_quota_usage',
    'unvollstaendig',
    'gekappt',
  ];

  int get recordCount => sections.fold(0, (n, section) => n + section.count);
  String get json => const JsonEncoder.withIndent('  ').convert(data);

  /// Readable text report. [value] may present stored values for reading;
  /// [json] and [ExportSection.csv] always stay raw.
  String report(
    String title,
    String Function(String) label, {
    ExportValueText? value,
  }) {
    final buffer = StringBuffer('$title\n${'=' * title.length}\n');
    for (final key in _metadata) {
      if (data.containsKey(key)) {
        buffer.writeln('${label(key)}: ${exportValue(data[key])}');
      }
    }
    for (final section in sections) {
      buffer.write('\n${section.report(label, value: value)}');
    }
    return buffer.toString();
  }

  static int _compareKeys(String a, String b) {
    final ai = _order.indexOf(a);
    final bi = _order.indexOf(b);
    if (ai != bi) {
      return (ai < 0 ? _order.length : ai).compareTo(
        bi < 0 ? _order.length : bi,
      );
    }
    return a.compareTo(b);
  }

  static dynamic _ordered(dynamic value) {
    if (value is Map<String, dynamic>) {
      const first = [
        'name',
        'title',
        'mealName',
        'logged_at',
        'date',
        'local_day',
        'payload',
        'caloriesKcal',
        'kcal',
        'grams',
        'estimatedGrams',
        'protein',
        'carbs',
        'fat',
      ];
      const last = ['id', 'user_id'];
      int rank(String key) => first.contains(key)
          ? first.indexOf(key)
          : last.contains(key)
          ? first.length + 1 + last.indexOf(key)
          : first.length;
      final keys = value.keys.toList()
        ..sort((a, b) {
          final result = rank(a).compareTo(rank(b));
          return result == 0 ? a.compareTo(b) : result;
        });
      return {for (final key in keys) key: _ordered(value[key])};
    }
    if (value is List) return value.map(_ordered).toList();
    return value;
  }

  static int _compareRows(dynamic a, dynamic b) {
    // Newest first, with deterministic ties; text-based collections by name.
    DateTime? timestamp(Map<dynamic, dynamic> row) {
      for (final key in const [
        'logged_at',
        'measured_at',
        'date',
        'local_day',
        'created_at',
        'updated_at',
        'deleted_at',
      ]) {
        final value = row[key];
        if (value is String) {
          final date = DateTime.tryParse(value);
          if (date != null) return date;
        }
      }
      return null;
    }

    final ad = timestamp(a as Map);
    final bd = timestamp(b as Map);
    if (ad != null && bd != null) {
      final result = bd.compareTo(ad);
      if (result != 0) return result;
    } else if (ad != null || bd != null) {
      return ad == null ? 1 : -1;
    }
    for (final key in ['name', 'title', 'id']) {
      final result = '${a[key] ?? ''}'.compareTo('${b[key] ?? ''}');
      if (result != 0) return result;
    }
    return jsonEncode(a).compareTo(jsonEncode(b));
  }
}

class ExportSection {
  ExportSection(this.key, this.value);

  final String key;
  final dynamic value;

  /// Derived once: the recipe projection parses every row, and the report and
  /// the paged view read the records per row.
  late final List<dynamic> records = () {
    final rows = value is List ? value as List : [value];
    return key == 'user_recipes' ? rows.map(_recipePresentation).toList() : rows;
  }();

  /// Readable exports gain context; raw JSON and every original field survive.
  static dynamic _recipePresentation(dynamic row) {
    if (row is! Map<String, dynamic> ||
        row.containsKey('eatova_serving_projection') ||
        row['slug'] is! String || row['ingredients'] is! String ||
        row['batch_servings'] is! num ||
        row['categories'] is! List ||
        (row['categories'] as List).any((c) => c is! String) ||
        const ['calories_kcal', 'protein_g', 'carbs_g', 'fat_g'].any(
          (key) => row[key] is! num || !(row[key] as num).isFinite || (row[key] as num) < 0)) {
      return row;
    }
    try {
      final recipe = FitnessRecipe.fromRow(row);
      if (!recipe.hasImportedIngredientContext || recipe.hasStructuredIngredients) return row;
      final projection = recipe.ingredientProjectionForServings(1);
      return <String, dynamic>{
        ...row,
        'eatova_serving_projection': {
          'source_ingredients_basis': switch (recipe.ingredientsBasis) {
            RecipeIngredientsBasis.perRecipe => 'per_recipe',
            RecipeIngredientsBasis.perServing => 'per_serving',
            RecipeIngredientsBasis.unspecified => 'unspecified',
          },
          'nutrition_basis': recipe.hasUnclearNutritionBasis ? 'unspecified' : 'per_serving',
          'nutrition_complete': !recipe.hasMissingNutrition,
          'ingredients_per_serving': projection.isScaled ? projection.text : null,
        },
      };
    } on FormatException {
      return row;
    }
  }
  int get count => records.length;

  String report(String Function(String) label, {ExportValueText? value}) {
    final title = '${label(key)} ($count)';
    final buffer = StringBuffer('$title\n${'-' * title.length}\n');
    for (var i = 0; i < records.length; i++) {
      buffer.writeln('#${i + 1}');
      final fields = exportFields(records[i], expandLists: true);
      for (final field in fields.entries) {
        final text =
            value?.call(fields, field.key, field.value) ??
            exportValue(field.value);
        buffer.writeln('${label(field.key)}: $text');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// RFC-style CSV with an explicit union of fields, stable column order and
  /// spreadsheet formula escaping. JSON remains the lossless typed format.
  String get csv {
    final rows = records.map(exportFields).toList();
    final columns = rows.expand((row) => row.keys).toSet().toList()..sort();
    if (columns.isEmpty) return '';
    return [
      columns.map(_csvCell).join(','),
      for (final row in rows)
        columns
            .map((key) => _csvCell(row.containsKey(key) ? row[key] : ''))
            .join(','),
    ].join('\r\n');
  }

  static String _csvCell(dynamic cell) {
    var value = exportValue(cell);
    // Untrusted names/messages must not become formulas when pasted in Excel.
    final trimmed = value.trimLeft();
    if (cell is String &&
        (RegExp(r'^[=+@-]').hasMatch(trimmed) ||
            value.startsWith('\t') ||
            value.startsWith('\r'))) {
      value = "'$value";
    }
    return '"${value.replaceAll('"', '""')}"';
  }
}

/// JSON-pointer paths avoid collisions between nested and literal field names.
Map<String, dynamic> exportFields(dynamic record, {bool expandLists = false}) {
  final fields = <String, dynamic>{};
  void visit(dynamic value, String path) {
    if (value is Map && value.isNotEmpty) {
      for (final entry in value.entries) {
        final key = entry.key
            .toString()
            .replaceAll('~', '~0')
            .replaceAll('/', '~1');
        visit(entry.value, '$path/$key');
      }
    } else if (expandLists && value is List && value.isNotEmpty) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], '$path/${i + 1}');
      }
    } else {
      fields[path.isEmpty ? '/' : path] = value;
    }
  }

  visit(record, '');
  return fields;
}

String exportValue(dynamic value) =>
    value is String ? value : jsonEncode(value);
