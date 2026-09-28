import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/export_document.dart';
import '../../models/fitness_recipe.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/persisted_labels.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

/// Readable value of one export field for the text report and the preview.
///
/// Persisted German fallbacks, adjustment notes, macro texts and origin codes
/// resolve into [l10n], read together with their sibling fields exactly as
/// the app screens do. Everything else, including all user text, stays as
/// stored. The JSON and CSV outputs never pass through here.
String exportReadableValue(
  Map<String, dynamic> fields,
  String path,
  dynamic value,
  AppLocalizations l10n,
) {
  if (value is! String) return exportValue(value);
  final cut = path.lastIndexOf('/');
  final parent = cut < 0 ? '' : path.substring(0, cut);
  final key = path.substring(cut + 1);
  String? text(String fieldPath) {
    final field = fields[fieldPath];
    return field is String ? field : null;
  }

  // Diary and favorite payloads carry `mealName` next to these fields.
  if (text('$parent/mealName') != null) {
    final barcode = text('$parent/barcode');
    final source = text('$parent/sourceLabel');
    switch (key) {
      case 'mealName':
        return MealAnalysisResult.resolveMealName(
          value,
          l10n,
          barcode: barcode,
          sourceLabel: source,
        );
      case 'portionNotes':
        return MealAnalysisResult.resolvePortionNotes(
          value,
          l10n,
          sourceLabel: source,
        );
      case 'protein' || 'carbs' || 'fat':
        return PersistedLabels.macroText(value, l10n);
      case 'sourceLabel':
        return MealResultSource.resolve(value)?.label(l10n) ?? value;
      case 'confidence':
        return MealResultConfidence.resolve(value)?.label(l10n) ?? value;
    }
  }
  final item = RegExp(r'^(.*)/items/\d+/name$').firstMatch(path);
  if (item != null && text('${item[1]}/mealName') != null) {
    return MealAnalysisResult.resolveItemName(
      value,
      l10n,
      mealName: text('${item[1]}/mealName'),
      barcode: text('${item[1]}/barcode'),
      sourceLabel: text('${item[1]}/sourceLabel'),
    );
  }
  // The `logged_meals.meal_name` column mirrors the payload's name.
  if (path == '/meal_name') {
    return MealAnalysisResult.resolveMealName(
      value,
      l10n,
      barcode: text('/payload/barcode') ?? text('/barcode'),
      sourceLabel: text('/payload/sourceLabel'),
    );
  }
  // Recipe rows and snapshots (own recipes, plans, history) carry a slug.
  if (text('$parent/slug') != null) {
    if (key == 'title' && value == PersistedLabels.ownRecipeTitle) {
      return l10n.recipesOwnTitle;
    }
    if (key == 'description' &&
        (text('$parent/slug')!.startsWith('user_import_') ||
            fields.entries.any(
              (e) =>
                  e.key.startsWith('$parent/categories/') &&
                  e.value is String &&
                  (e.value as String).startsWith(recipeIngredientsBasisPrefix),
            ))) {
      return FitnessRecipe.resolveImportSourceLine(value, l10n);
    }
  }
  if (key == 'name' && text('$parent/source') == 'openFoodFacts') {
    return PersistedLabels.resolveProductName(
          value,
          text('$parent/product_code') ?? '',
          l10n,
        ) ??
        value;
  }
  return value;
}

String exportLabel(String key, AppLocalizations l10n) =>
    _sectionLabel(key, l10n) ??
    key
        .split('/')
        .where((part) => part.isNotEmpty)
        .map((part) {
          final name = part
              .replaceAll('~1', '/')
              .replaceAll('~0', '~')
              .replaceAll('_', ' ')
              .replaceAllMapped(
                RegExp(r'([a-z])([A-Z])'),
                (m) => '${m[1]} ${m[2]}',
              );
          return _fieldLabel(
            part,
            l10n,
            name.isEmpty
                ? name
                : '${name[0].toUpperCase()}${name.substring(1)}',
          );
        })
        .join(' › ');

/// Sections and export metadata. The export keeps German wire keys
/// (`unvollstaendig`, `gekappt`, ...); only their labels are localized.
String? _sectionLabel(String key, AppLocalizations l10n) => switch (key) {
  'profiles' => l10n.exportProfiles,
  'lifetime_stats' => l10n.exportStats,
  'logged_meals' => l10n.exportMeals,
  'favorite_meals' => l10n.exportFavorites,
  'weight_log' => l10n.exportWeight,
  'user_recipes' => l10n.exportRecipes,
  'planned_meals' => l10n.exportMealPlan,
  'shopping_checks' => l10n.exportShopping,
  'training_plans' => l10n.exportTrainingPlans,
  'training_history' => l10n.exportTrainingHistory,
  'training_history_deletions' => l10n.exportTrainingDeletions,
  'chat_sessions' => l10n.exportChats,
  'chat_messages' => l10n.exportMessages,
  'chat_quota_usage' => l10n.exportQuota,
  'ai_provider_user_usage' => l10n.exportAiUsage,
  'unvollstaendig' => l10n.exportMissing,
  'gekappt' => l10n.exportCapped,
  'format' => l10n.exportFormat,
  'exportedAt' => l10n.exportDate,
  'userId' => l10n.exportAccount,
  'user_recipe_history' => l10n.exportRecipeHistory,
  'vollstaendigkeitUnbekannt' => l10n.exportCompletenessUnknown,
  _ => null,
};

String _fieldLabel(String key, AppLocalizations l10n, String fallback) =>
    switch (key) {
      'eatova_serving_projection' => l10n.exportRecipePortionProjection,
      'id' => l10n.exportFieldId,
      'user_id' => l10n.exportFieldUserId,
      'created_at' => l10n.exportFieldCreatedAt,
      'updated_at' => l10n.exportFieldUpdatedAt,
      'logged_at' => l10n.exportFieldLoggedAt,
      'local_day' => l10n.exportFieldLocalDay,
      'date' => l10n.exportFieldDate,
      'payload' => l10n.exportFieldPayload,
      'mealName' => l10n.exportFieldMealName,
      'name' => l10n.exportFieldName,
      'title' => l10n.exportFieldTitle,
      'caloriesKcal' => l10n.exportFieldCaloriesKcal,
      'kcal' => l10n.exportFieldKcal,
      'protein_g' => l10n.exportFieldProteinG,
      'carbs_g' => l10n.exportFieldCarbsG,
      'fat_g' => l10n.exportFieldFatG,
      'estimatedGrams' => l10n.exportFieldEstimatedGrams,
      'grams' => l10n.exportFieldGrams,
      'weight_kg' => l10n.exportFieldWeightKg,
      'slot' => l10n.exportFieldSlot,
      'content' => l10n.exportFieldContent,
      'role' => l10n.exportFieldRole,
      'session_id' => l10n.exportFieldSessionId,
      'items' => l10n.exportFieldItems,
      'email' => l10n.exportFieldEmail,
      'display_name' => l10n.exportFieldDisplayName,
      'sourceLabel' => l10n.exportFieldSourceLabel,
      'confidence' => l10n.exportFieldConfidence,
      'portionNotes' => l10n.exportFieldPortionNotes,
      'protein' => l10n.exportFieldProtein,
      'carbs' => l10n.exportFieldCarbs,
      'fat' => l10n.exportFieldFat,
      'explanation' => l10n.exportFieldExplanation,
      'grenzeProSektion' => l10n.exportFieldCapPerSection,
      'sektionen' => l10n.exportFieldCappedSections,
      'zeilenAufDemServer' => l10n.exportFieldServerRowCount,
      // Section names appear inside paths, e.g. the server row counts.
      _ => _sectionLabel(key, l10n) ?? fallback,
    };

String exportDisplayDate(BuildContext context, String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final date = parsed.toLocal();
  final local = MaterialLocalizations.of(context);
  return '${local.formatShortDate(date)} · ${local.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}

class ExportSectionView extends StatefulWidget {
  const ExportSectionView({
    super.key,
    required this.section,
    required this.onCopy,
  });

  final ExportSection section;
  final Future<void> Function(String) onCopy;

  @override
  State<ExportSectionView> createState() => _ExportSectionViewState();
}

class _ExportSectionViewState extends State<ExportSectionView>
    with AutomaticKeepAliveClientMixin {
  static const pageSize = 3;
  bool _expanded = false;
  int _page = 0;

  @override
  bool get wantKeepAlive => _expanded;

  @override
  void didUpdateWidget(ExportSectionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = context.t;
    final l10n = context.l10n;
    final section = widget.section;
    final start = _page * pageSize;
    final end = (start + pageSize).clamp(0, section.count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('export-expand-${section.key}'),
            borderRadius: BorderRadius.circular(rControl),
            onTap: () {
              setState(() => _expanded = !_expanded);
              updateKeepAlive();
            },
            child: Semantics(
              expanded: _expanded,
              button: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 4,
                ),
                child: Row(
                  children: [
                    Icon(Icons.table_rows_outlined, color: t.accent, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            exportLabel(section.key, l10n),
                            style: AppType.ui(
                              15,
                              weight: FontWeight.w700,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            l10n.exportRecordCount(section.count),
                            style: AppType.ui(12, color: t.ink2),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: t.ink2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded) ...[
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: ValueKey('export-copy-${section.key}'),
                onPressed: () => widget.onCopy(
                  section.report(
                    (key) => exportLabel(key, l10n),
                    value: (fields, path, value) =>
                        exportReadableValue(fields, path, value, l10n),
                  ),
                ),
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: Text(l10n.exportCopySection),
              ),
              TextButton.icon(
                key: ValueKey('export-csv-${section.key}'),
                onPressed: section.count == 0
                    ? null
                    : () => widget.onCopy(section.csv),
                icon: const Icon(Icons.grid_on_outlined, size: 18),
                label: Text(l10n.exportCopyCsv),
              ),
            ],
          ),
          if (section.count == 0)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.exportEmptySection,
                style: AppType.ui(13, color: t.ink2),
              ),
            ),
          for (var i = start; i < end; i++)
            _ExportRecord(record: section.records[i], number: i + 1),
          if (section.count > pageSize)
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.exportPageRange(start + 1, end, section.count),
                    style: AppType.ui(12, color: t.ink2),
                  ),
                ),
                IconButton(
                  key: ValueKey('export-prev-${section.key}'),
                  tooltip: l10n.exportPrevious,
                  onPressed: _page == 0 ? null : () => setState(() => _page--),
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  key: ValueKey('export-next-${section.key}'),
                  tooltip: l10n.exportNext,
                  onPressed: end >= section.count
                      ? null
                      : () => setState(() => _page++),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
        ],
        Divider(height: 1, color: t.line),
      ],
    );
  }
}

class _ExportRecord extends StatelessWidget {
  const _ExportRecord({required this.record, required this.number});
  final dynamic record;
  final int number;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final fields = exportFields(record, expandLists: true);
    // Large JSONB payloads remain fully extractable without thousands of
    // selectable paragraphs or unbounded text layout in the preview.
    final entries = fields.entries.take(24);
    final shortened =
        fields.length > 24 ||
        entries.any((entry) => exportValue(entry.value).length > 400);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        color: t.surf2,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.exportRecordNumber(number),
              style: AppType.ui(12, weight: FontWeight.w700, color: t.accent),
            ),
            for (final field in entries) ...[
              const SizedBox(height: 12),
              Text(
                exportLabel(field.key, l10n),
                style: AppType.ui(11, color: t.ink2),
              ),
              const SizedBox(height: 3),
              SelectableText(
                _preview(
                  field.value is String &&
                          RegExp(r'(?:_at|At|/date)$').hasMatch(field.key)
                      ? exportDisplayDate(context, field.value as String)
                      : exportReadableValue(
                          fields,
                          field.key,
                          field.value,
                          l10n,
                        ),
                ),
                style: AppType.ui(14, color: t.ink, height: 1.4),
              ),
            ],
            if (shortened) ...[
              const SizedBox(height: 12),
              Text(
                l10n.exportPreviewShortened,
                style: AppType.ui(12, color: t.ink2),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _preview(String text) => text.length <= 400
      ? text
      : '${String.fromCharCodes(text.runes.take(400))}…';
}
