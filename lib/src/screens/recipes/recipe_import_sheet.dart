import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/recipe_import_result.dart';
import '../../services/recipe_import_service.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import 'recipe_import_nutrition.dart';

/// Reviewing, selecting and editing a shared recipe never writes user data.
Future<FitnessRecipe?> showRecipeImportSheet({
  required BuildContext context,
  required RecipeImportService service,
  required Future<SyncDelivery> Function(FitnessRecipe) onSave,
  required bool Function() sessionIsCurrent,
  String initialText = '',
  bool Function(String slug)? isSaved,
}) => showEatovaSheet<FitnessRecipe>(
  context,
  RecipeImportSheet(
    service: service,
    onSave: onSave,
    sessionIsCurrent: sessionIsCurrent,
    initialText: initialText,
    isSaved: isSaved,
  ),
  dragHandle: false,
  enableDrag: false,
);

class RecipeImportSheet extends StatefulWidget {
  const RecipeImportSheet({
    super.key,
    required this.service,
    required this.onSave,
    required this.sessionIsCurrent,
    this.initialText = '',
    this.isSaved,
  });

  final RecipeImportService service;
  final Future<SyncDelivery> Function(FitnessRecipe) onSave;
  final bool Function() sessionIsCurrent;
  final String initialText;
  final bool Function(String slug)? isSaved;

  @override
  State<RecipeImportSheet> createState() => _RecipeImportSheetState();
}

class _RecipeImportSheetState extends State<RecipeImportSheet> {
  final _scroll = ScrollController();
  late final TextEditingController _text;
  final _title = TextEditingController();
  final _portion = TextEditingController();
  final _ingredients = TextEditingController();
  final _preparation = TextEditingController();
  final Map<String, RecipeImportCandidate> _drafts = {};
  final Map<String, String> _slugs = {};
  final Map<String, FitnessRecipe> _attemptedRecipes = {};
  final Set<String> _savedSlugs = {};
  final Set<String> _editedCandidates = {};
  RecipeImportResult? _result;
  RecipeImportCandidate? _selected;
  FitnessRecipe? _lastSaved;
  String? _savedText;
  String? _saveMessage;
  bool _loading = false;
  bool _saving = false;
  bool _editing = false;
  bool _askingToDiscard = false;
  bool _showInput = true;
  String? _error;
  String? _editError;

  bool get _busy => _loading || _saving;
  bool get _hasUserChanges =>
      _editedCandidates.isNotEmpty ||
      _text.text != (_savedText ?? widget.initialText) ||
      (_editing && _fieldsChanged);

  bool get _fieldsChanged {
    final candidate = _selected;
    return candidate != null &&
        (_title.text != candidate.title ||
            _portion.text != candidate.portion ||
            _ingredients.text != candidate.ingredients ||
            _preparation.text != candidate.preparation);
  }

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText);
    for (final field in [_text, _title, _portion, _ingredients, _preparation]) {
      field.addListener(_fieldChanged);
    }
    if (widget.initialText.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _extract();
      });
    }
  }

  void _fieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final field in [_text, _title, _portion, _ingredients, _preparation]) {
      field.dispose();
    }
    super.dispose();
  }

  bool _checkSession() {
    if (widget.sessionIsCurrent()) return true;
    setState(() {
      _error = context.l10n.recipeEditSessionChanged;
      if (_selected == null) _showInput = true;
    });
    _scrollToTop();
    return false;
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  bool _candidateSaved(RecipeImportCandidate candidate) {
    final slug = _slugs[candidate.id];
    return slug != null &&
        (_savedSlugs.contains(slug) || (widget.isSaved?.call(slug) ?? false));
  }

  Future<void> _extract() async {
    if (_busy || _text.text.trim().isEmpty || !_checkSession()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _showInput = false;
    });
    try {
      final result = await widget.service.extract(
        _text.text.trim(),
        locale: context.l10n.localeName,
      );
      if (!mounted || !_checkSession()) return;
      setState(() {
        _result = result;
        _drafts.clear();
        _editedCandidates.clear();
        _slugs.clear();
        _attemptedRecipes.clear();
        _saveMessage = null;
        for (final candidate in result.candidates) {
          _slugs[candidate.id] = candidate.stableSlug(result.sourceUrl);
        }
        _selected = result.candidates.length == 1
            ? result.candidates.single
            : null;
        _editing = false;
        _showInput =
            result.status != RecipeImportStatus.ready ||
            result.candidates.isEmpty;
      });
      _scrollToTop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _importError(error);
        _showInput = true;
      });
      _scrollToTop();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _importError(Object error) {
    final l10n = context.l10n;
    if (error is! RecipeImportException) {
      return directSyncErrorMessage(error, l10n);
    }
    return switch (error.failure) {
      RecipeImportFailure.invalidInput => l10n.recipeImportInvalidInput,
      RecipeImportFailure.reauthRequired => l10n.recipeImportReauth,
      RecipeImportFailure.rateLimited => l10n.recipeImportRateLimited,
      RecipeImportFailure.unavailable => l10n.recipeImportUnavailable,
      RecipeImportFailure.invalidResponse => l10n.recipeImportInvalidResponse,
      RecipeImportFailure.timeout => l10n.recipeImportTimeout,
      RecipeImportFailure.network => l10n.commonSyncErrorOffline,
    };
  }

  void _select(RecipeImportCandidate candidate) {
    if (_busy || _candidateSaved(candidate)) return;
    setState(() {
      _selected = _drafts[candidate.id] ?? candidate;
      _editing = false;
      _error = null;
    });
    _scrollToTop();
  }

  void _edit() {
    final candidate = _selected!;
    _title.text = candidate.title;
    _portion.text = candidate.portion;
    _ingredients.text = candidate.ingredients;
    _preparation.text = candidate.preparation;
    setState(() {
      _editing = true;
      _editError = null;
    });
    _scrollToTop();
  }

  bool _applyEdits() {
    if (_title.text.trim().isEmpty || _ingredients.text.trim().isEmpty) {
      setState(() => _editError = context.l10n.recipeImportRequiredFields);
      return false;
    }
    final values = [
      _title.text,
      _portion.text,
      _ingredients.text,
      _preparation.text,
    ];
    const limits = [160, 200, 8000, 10000];
    for (var i = 0; i < values.length; i++) {
      if (values[i].length > limits[i]) {
        setState(() => _editError = context.l10n.recipesTextTooLongError);
        return false;
      }
    }
    final previous = _selected!;
    final changed = _fieldsChanged;
    final candidate = previous.copyWith(
      title: _title.text.trim(),
      portion: _portion.text.trim(),
      ingredients: _ingredients.text.trim(),
      preparation: _preparation.text.trim(),
      clearNutrition:
          _portion.text.trim() != previous.portion ||
          _ingredients.text.trim() != previous.ingredients,
    );
    FocusScope.of(context).unfocus();
    setState(() {
      _drafts[candidate.id] = candidate;
      _selected = candidate;
      _slugs[candidate.id] = candidate.stableSlug(_result?.sourceUrl);
      if (changed) _editedCandidates.add(candidate.id);
      _editing = false;
      _editError = null;
    });
    _scrollToTop();
    return true;
  }

  Future<void> _save() async {
    if (_busy || _selected == null || !_checkSession()) return;
    if (_editing && !_applyEdits()) return;
    final candidate = _selected!;
    final slug = _slugs.putIfAbsent(
      candidate.id,
      () => candidate.stableSlug(_result?.sourceUrl),
    );
    if (_savedSlugs.contains(slug) || (widget.isSaved?.call(slug) ?? false)) {
      setState(() => _error = context.l10n.recipeImportAlreadySaved);
      _scrollToTop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      final recipe = _attemptedRecipes.putIfAbsent(
        candidate.id,
        () => candidate.toRecipe(
          slug: slug,
          sourceUrl: _result?.sourceUrl,
          sourceLabel: context.l10n.recipeImportSourceLabel,
        ),
      );
      final delivery = await widget.onSave(recipe);
      if (!mounted || !_checkSession()) return;
      final message = deliveryHint(
        context.l10n.recipesSavedSuccess(recipe.title),
        delivery,
        context.l10n,
      );
      if (_result!.candidates.length == 1) {
        showAppSnack(context, message, icon: Icons.bookmark_added_rounded);
        Navigator.of(context).pop(recipe);
      } else {
        setState(() {
          _savedSlugs.add(slug);
          _editedCandidates.remove(candidate.id);
          _lastSaved = recipe;
          _savedText = _text.text;
          _saveMessage = message;
          _selected = null;
          _editing = false;
        });
        _scrollToTop();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.recipeEditSaveFailed);
        _scrollToTop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving || _askingToDiscard) return;
    if (_hasUserChanges) {
      _askingToDiscard = true;
      final discard = await showEatovaDialog<bool>(
        context: context,
        builder: (dialogContext) => EatovaConfirmDialog(
          title: context.l10n.foodDiscardChangesTitle,
          body: context.l10n.recipesDiscardChangesBody,
          confirmLabel: context.l10n.foodDiscardChangesConfirm,
          cancelLabel: context.l10n.foodDiscardChangesKeepEditing,
          destructive: true,
          confirmKey: const ValueKey('recipe-import-discard'),
          onConfirm: () => Navigator.of(dialogContext).pop(true),
          onCancel: () => Navigator.of(dialogContext).pop(false),
        ),
      );
      _askingToDiscard = false;
      if (!mounted || discard != true) return;
    }
    if (mounted) Navigator.of(context).pop(_lastSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final compactTitle =
        MediaQuery.sizeOf(context).width < 360 &&
        MediaQuery.textScalerOf(context).scale(24) > 32;
    return PopScope<FitnessRecipe?>(
      canPop: !_saving && !_hasUserChanges && _lastSaved == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-import-sheet'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: HeadingSemantics(
                      level: 1,
                      child: Text(
                        l10n.recipeImportTitle,
                        style: AppType.display(
                          compactTitle ? 20 : 24,
                          color: t.ink,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('recipe-import-close'),
                    tooltip: l10n.commonClose,
                    onPressed: _saving ? null : _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        _intro(context),
                        const SizedBox(height: 28),
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          l10n.recipeImportLoading,
                          textAlign: TextAlign.center,
                          style: AppType.ui(16, color: t.ink),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.recipeImportReviewHint,
                          textAlign: TextAlign.center,
                          style: AppType.ui(14, color: t.ink2, height: 1.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.recipeImportPrivacyHint,
                          textAlign: TextAlign.center,
                          style: AppType.ui(12, color: t.ink2, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      key: const ValueKey('recipe-import-error'),
                      style: AppType.ui(14, color: t.danger, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_showInput)
                  _input(context)
                else if (_selected != null)
                  _preview(context)
                else
                  _choices(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: t.brandSurface,
        borderRadius: BorderRadius.circular(rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bookmark_add_outlined,
                size: 22,
                color: t.onBrandSurface,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.recipeImportEyebrow,
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w700,
                    color: t.onBrandSurface,
                    letterSpacing: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            l10n.recipeImportIntroTitle,
            style: AppType.display(30, color: t.onBrandSurface, height: 1.12),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.recipeImportIntroBody,
            style: AppType.ui(14, color: t.onBrandSurface, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _input(BuildContext context) {
    final l10n = context.l10n;
    final status = _result?.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _intro(context),
        const SizedBox(height: 24),
        Text(
          _result?.sourceUnavailable == true
              ? l10n.recipeImportSourceUnavailable
              : status == RecipeImportStatus.needsText
              ? l10n.recipeImportNeedsText
              : status == RecipeImportStatus.noRecipe
              ? l10n.recipeImportNoRecipe
              : l10n.recipeImportInputHint,
          style: AppType.ui(15, color: context.t.ink2, height: 1.5),
        ),
        const SizedBox(height: 16),
        SheetField(
          fieldKey: const ValueKey('recipe-import-input'),
          label: l10n.recipeImportInputLabel,
          hint: l10n.recipeImportInputPlaceholder,
          controller: _text,
          maxLines: 6,
          maxLength: 20000,
          enabled: !_busy,
          keyboardType: TextInputType.multiline,
        ),
        Text(
          l10n.recipeImportPrivacyHint,
          style: AppType.ui(12, color: context.t.ink2, height: 1.5),
        ),
        const SizedBox(height: 20),
        PrimaryActionButton(
          key: const ValueKey('recipe-import-analyze'),
          label: _error == null
              ? l10n.recipeImportAnalyze
              : l10n.recipeImportRetry,
          icon: Icons.auto_awesome_outlined,
          onTap: _busy || _text.text.trim().isEmpty ? null : _extract,
        ),
      ],
    );
  }

  Widget _source(BuildContext context) {
    final result = _result;
    final source = result?.sourceUrl;
    final title = result?.sourceTitle;
    final author = result?.sourceAuthor;
    if (source == null && title == null && author == null) {
      return const SizedBox.shrink();
    }
    final details = [
      if (title?.isNotEmpty ?? false) title!,
      if (author?.isNotEmpty ?? false) author!,
      if (source != null) source,
    ].join('\n');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        key: const ValueKey('recipe-import-source'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          source == null
              ? context.l10n.recipeImportSourceLabel
              : '${context.l10n.recipeImportSourceLabel}: ${Uri.tryParse(source)?.host ?? ''}',
          style: AppType.ui(13, color: context.t.ink2),
        ),
        subtitle: author == null
            ? null
            : Text(author, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          SelectableText(
            details,
            style: AppType.ui(13, color: context.t.ink2, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _choices(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_saveMessage != null) ...[
          Semantics(
            liveRegion: true,
            child: Text(
              _saveMessage!,
              key: const ValueKey('recipe-import-saved-message'),
              style: AppType.ui(14, color: context.t.accent, height: 1.5),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          l10n.recipeImportChoose,
          style: AppType.ui(16, color: context.t.ink, weight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.recipeImportChooseHint,
          style: AppType.ui(14, color: context.t.ink2, height: 1.5),
        ),
        const SizedBox(height: 16),
        _source(context),
        for (final candidate in _result!.candidates)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: context.t.surf,
              borderRadius: BorderRadius.circular(rCard),
              child: ListTile(
                key: ValueKey('recipe-import-candidate-${candidate.id}'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rCard),
                ),
                title: Text(
                  (_drafts[candidate.id] ?? candidate).title,
                  style: AppType.ui(
                    16,
                    color: context.t.ink,
                    weight: FontWeight.w600,
                  ),
                ),
                subtitle: _candidateSaved(candidate)
                    ? Text(
                        l10n.recipeImportAdded,
                        style: AppType.ui(14, color: context.t.ink2),
                      )
                    : candidate.variantLabel.isEmpty
                    ? null
                    : Text(candidate.variantLabel),
                trailing: Icon(
                  _candidateSaved(candidate)
                      ? Icons.check_circle_outline_rounded
                      : Icons.chevron_right_rounded,
                  color: _candidateSaved(candidate) ? context.t.accent : null,
                ),
                enabled: !_busy && !_candidateSaved(candidate),
                onTap: _busy || _candidateSaved(candidate)
                    ? null
                    : () => _select(candidate),
              ),
            ),
          ),
        TextButton(
          onPressed: () {
            setState(() => _showInput = true);
            _scrollToTop();
          },
          child: Text(l10n.recipeImportChangeText),
        ),
        if (_lastSaved != null) ...[
          const SizedBox(height: 12),
          PrimaryActionButton(
            key: const ValueKey('recipe-import-done'),
            label: l10n.recipeImportDone,
            onTap: _busy ? null : _close,
          ),
        ],
      ],
    );
  }

  Widget _preview(BuildContext context) {
    final l10n = context.l10n;
    final candidate = _selected!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_editing && _result!.candidates.length > 1)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('recipe-import-back'),
              onPressed: _saving
                  ? null
                  : () {
                      setState(() {
                        _selected = null;
                        _error = null;
                      });
                      _scrollToTop();
                    },
              icon: const Icon(Icons.arrow_back_rounded),
              label: Text(l10n.recipeImportOtherRecipe),
            ),
          ),
        if (_editing) ...[
          SheetField(
            fieldKey: const ValueKey('recipe-import-edit-title'),
            label: l10n.recipeImportNameLabel,
            hint: l10n.recipesNameHint,
            controller: _title,
            maxLength: 160,
            enabled: !_saving,
          ),
          SheetField(
            fieldKey: const ValueKey('recipe-import-edit-portion'),
            label: l10n.recipesSectionPortion,
            hint: l10n.recipesPortionHint,
            controller: _portion,
            maxLength: 200,
            enabled: !_saving,
          ),
          SheetField(
            fieldKey: const ValueKey('recipe-import-edit-ingredients'),
            label: l10n.recipesSectionIngredients,
            hint: l10n.recipesIngredientsHint,
            controller: _ingredients,
            maxLines: 6,
            maxLength: 8000,
            enabled: !_saving,
          ),
          SheetField(
            fieldKey: const ValueKey('recipe-import-edit-preparation'),
            label: l10n.recipesSectionPreparation,
            hint: l10n.recipeImportPreparationHint,
            controller: _preparation,
            maxLines: 6,
            maxLength: 10000,
            enabled: !_saving,
          ),
          if (_editError != null)
            Text(_editError!, style: AppType.ui(14, color: context.t.danger)),
          TextButton(
            onPressed: _saving ? null : _applyEdits,
            child: Text(l10n.recipeImportFinishEditing),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: context.t.brandSurface,
              borderRadius: BorderRadius.circular(rCard),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.recipeImportPreviewLabel,
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w700,
                    color: context.t.onBrandSurface,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  candidate.title,
                  style: AppType.display(
                    28,
                    color: context.t.onBrandSurface,
                    height: 1.16,
                  ),
                ),
                if (candidate.variantLabel.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    candidate.variantLabel,
                    style: AppType.ui(
                      14,
                      color: context.t.onBrandSurface,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
                if (candidate.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    candidate.description,
                    style: AppType.ui(
                      14,
                      color: context.t.onBrandSurface,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          RecipeImportNutrition(candidate: candidate),
          _section(
            context,
            l10n.recipesSectionPortion,
            candidate.portion.isNotEmpty
                ? candidate.portion
                : candidate.servings != null
                ? '${l10n.recipeEditBatchServings}: ${candidate.servings == candidate.servings!.roundToDouble() ? candidate.servings!.round() : candidate.servings}'
                : '',
          ),
          _section(
            context,
            l10n.recipesSectionIngredients,
            candidate.ingredients,
          ),
          _section(
            context,
            l10n.recipesSectionPreparation,
            candidate.preparation,
          ),
          TextButton.icon(
            key: const ValueKey('recipe-import-edit'),
            onPressed: _saving || _attemptedRecipes.containsKey(candidate.id)
                ? null
                : _edit,
            icon: const Icon(Icons.edit_outlined),
            label: Text(l10n.recipeImportEdit),
          ),
        ],
        for (final warning in _result!.warnings.where(
          (warning) => warning != 'nutrition_missing',
        ))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _warningText(warning, l10n),
              style: AppType.ui(13, color: context.t.ink2, height: 1.5),
            ),
          ),
        const SizedBox(height: 16),
        _source(context),
        Text(
          l10n.recipeImportReviewHint,
          style: AppType.ui(12, color: context.t.ink2, height: 1.5),
        ),
        const SizedBox(height: 16),
        PrimaryActionButton(
          key: const ValueKey('recipe-import-save'),
          label: _saving ? l10n.recipeImportSaving : l10n.recipeImportSave,
          icon: Icons.bookmark_add_outlined,
          onTap: _saving ? null : _save,
        ),
      ],
    );
  }

  String _warningText(String warning, AppLocalizations l10n) =>
      switch (warning) {
        'source_incomplete' => l10n.recipeImportIncompleteHint,
        'truncated' => l10n.recipeImportTruncatedHint,
        _ => l10n.recipeImportReviewHint,
      };

  Widget _section(BuildContext context, String title, String body) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: context.t.line, height: 20),
        const SizedBox(height: 8),
        Text(
          title,
          style: AppType.ui(16, color: context.t.ink, weight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          body.isEmpty
              ? title == context.l10n.recipesSectionPreparation
                    ? context.l10n.recipeImportPreparationMissing
                    : context.l10n.recipesNoDataProvided
              : body,
          style: AppType.ui(15, color: context.t.ink, height: 1.6),
        ),
      ],
    ),
  );
}
