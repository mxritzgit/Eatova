import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../models/recipe_import_result.dart';
import '../../services/recipe_import_service.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'recipe_import_nutrition.dart';
import 'recipes_screen.dart' show showRecipeNutritionDraftEditor;

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
  bool _reviewingNutrition = false;
  bool _askingToDiscard = false;
  bool _showInput = true;
  bool _sourceOpen = false;
  String? _error;
  String? _editError;

  bool get _busy => _loading || _saving || _reviewingNutrition;
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
        _sourceOpen = false;
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

  /// Fills the empty input from the clipboard. Platforms without a readable
  /// clipboard throw; the field then simply stays empty.
  Future<void> _paste() async {
    if (_busy || _text.text.trim().isNotEmpty) return;
    String? pasted;
    try {
      pasted = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (!mounted || _busy || pasted == null || pasted.trim().isEmpty) return;
    // Same cap as the field's maxLength, which only limits typed input.
    final text = pasted.characters.take(20000).toString();
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
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

  Future<void> _correctNutrition() async {
    if (_busy || _selected == null || !_checkSession()) return;
    final candidate = _selected!;
    if (_attemptedRecipes.containsKey(candidate.id)) return;
    setState(() => _reviewingNutrition = true);
    final reviewed = await showRecipeNutritionDraftEditor(
      context: context,
      recipe: candidate.toRecipe(slug: candidate.stableSlug(_result?.sourceUrl),
          sourceUrl: _result?.sourceUrl, sourceLabel: context.l10n.recipeImportSourceLabel),
      isSessionCurrent: () => mounted && widget.sessionIsCurrent(),
    );
    if (!mounted) return;
    setState(() => _reviewingNutrition = false);
    if (reviewed == null || !_checkSession() || !identical(_selected, candidate)) return;
    final updated = candidate.withReviewedNutrition(reviewed);
    setState(() {
      _selected = updated;
      _drafts[candidate.id] = updated;
      _editedCandidates.add(candidate.id);
    });
    _scrollToTop();
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
    final String view;
    final Widget body;
    if (_loading) {
      view = 'loading';
      body = _reading(context);
    } else {
      final Widget content;
      if (_showInput) {
        view = 'input';
        content = _input(context);
      } else if (_selected != null) {
        view = _editing ? 'edit' : 'preview-${_selected!.id}';
        content = _preview(context);
      } else {
        view = 'choices';
        content = _choices(context);
      }
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            _Notice(
              icon: Icons.error_outline_rounded,
              iconColor: t.danger,
              fill: t.danger.withValues(alpha: 0.12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: const ValueKey('recipe-import-error'),
                  style: AppType.ui(14, color: t.ink, height: 1.45),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          content,
        ],
      );
    }
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                        // Capped like a tab title: at 2x on 320 px the
                        // uncapped "importieren" broke mid-word.
                        textScaler: AppType.pageTitleScaler(context),
                        style: AppType.display(
                          compactTitle ? 20 : 24,
                          color: t.ink,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('recipe-import-close'),
                    tooltip: l10n.commonClose,
                    onPressed: _saving ? null : _close,
                    style: IconButton.styleFrom(
                      backgroundColor: t.surf2,
                      foregroundColor: t.ink2,
                      disabledBackgroundColor: t.surf2,
                      disabledForegroundColor: t.inkDisabled,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 21),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Each state arrives with the shared soft entrance; a state that
              // only changes inside (an error, a correction) does not replay.
              LivelyEntrance(
                key: ValueKey('recipe-import-view-$view'),
                offsetY: 8,
                duration: const Duration(milliseconds: 260),
                child: body,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasSource {
    final result = _result;
    return result != null &&
        (result.sourceUrl != null ||
            result.sourceTitle != null ||
            result.sourceAuthor != null);
  }

  Widget _reading(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    return Semantics(
      key: const ValueKey('recipe-import-loading'),
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ImportSteps(active: 1),
          const SizedBox(height: 22),
          Text(
            l10n.recipeImportLoading,
            textAlign: TextAlign.center,
            style: AppType.ui(16, weight: FontWeight.w700, color: t.ink),
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
    );
  }

  Widget _input(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final status = _result?.status;
    final notice = _result?.sourceUnavailable == true
        ? l10n.recipeImportSourceUnavailable
        : status == RecipeImportStatus.needsText
        ? l10n.recipeImportNeedsText
        : status == RecipeImportStatus.noRecipe
        ? l10n.recipeImportNoRecipe
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ImportSteps(),
        const SizedBox(height: 20),
        if (notice != null) ...[
          _Notice(
            icon: Icons.info_outline_rounded,
            iconColor: t.accentText,
            fill: t.accentTint,
            child: Text(
              notice,
              style: AppType.ui(14, color: t.ink, height: 1.45),
            ),
          ),
          const SizedBox(height: 16),
        ],
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
        if (_text.text.trim().isEmpty) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('recipe-import-paste'),
              label: l10n.recipeImportPaste,
              icon: Icons.content_paste_rounded,
              onTap: _busy ? null : _paste,
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          l10n.recipeImportPrivacyHint,
          style: AppType.ui(12, color: t.ink2, height: 1.5),
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

  /// The source as a quiet pill (host name); a tap shows the full source
  /// text below it.
  Widget _source(BuildContext context, {bool onBrand = false}) {
    final result = _result!;
    final l10n = context.l10n;
    final t = context.t;
    final source = result.sourceUrl;
    final title = result.sourceTitle;
    final author = result.sourceAuthor;
    final details = [
      if (title?.isNotEmpty ?? false) title!,
      if (author?.isNotEmpty ?? false) author!,
      if (source != null) source,
    ].join('\n');
    var host = source == null ? '' : Uri.tryParse(source)?.host ?? '';
    if (host.startsWith('www.')) host = host.substring(4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SourcePill(
          key: const ValueKey('recipe-import-source'),
          label: host.isEmpty ? l10n.recipeImportSourceLabel : host,
          semanticLabel: host.isEmpty
              ? l10n.recipeImportSourceLabel
              : '${l10n.recipeImportSourceLabel}: $host',
          onTap: () => setState(() => _sourceOpen = !_sourceOpen),
        ),
        maybeAnimatedSize(
          context,
          duration: const Duration(milliseconds: 200),
          curve: kMotionCurve,
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: double.infinity,
            child: _sourceOpen
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SelectableText(
                      details,
                      key: const ValueKey('recipe-import-source-details'),
                      style: AppType.ui(
                        13,
                        color: onBrand ? t.onBrandSurface : t.ink2,
                        height: 1.5,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _choices(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_saveMessage != null) ...[
          _Notice(
            icon: Icons.bookmark_added_rounded,
            iconColor: t.accentText,
            fill: t.accentTint,
            child: Semantics(
              liveRegion: true,
              child: Text(
                _saveMessage!,
                key: const ValueKey('recipe-import-saved-message'),
                style: AppType.ui(14, color: t.ink, height: 1.45),
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        Text(
          l10n.recipeImportChoose,
          style: AppType.display(
            19,
            weight: FontWeight.w700,
            color: t.ink,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.recipeImportChooseHint,
          style: AppType.ui(14, color: t.ink2, height: 1.45),
        ),
        if (_hasSource) ...[const SizedBox(height: 14), _source(context)],
        const SizedBox(height: 18),
        for (final (index, candidate) in _result!.candidates.indexed) ...[
          if (index > 0) const SizedBox(height: 10),
          _candidate(context, index, candidate),
        ],
        const SizedBox(height: 18),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SoftPillButton(
            key: const ValueKey('recipe-import-change-text'),
            label: l10n.recipeImportChangeText,
            icon: Icons.edit_note_rounded,
            tone: SoftPillTone.neutral,
            onTap: () {
              setState(() => _showInput = true);
              _scrollToTop();
            },
          ),
        ),
        if (_lastSaved != null) ...[
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('recipe-import-done'),
            label: l10n.recipeImportDone,
            onTap: _busy ? null : _close,
          ),
        ],
      ],
    );
  }

  Widget _candidate(
    BuildContext context,
    int index,
    RecipeImportCandidate candidate,
  ) {
    final l10n = context.l10n;
    final t = context.t;
    final saved = _candidateSaved(candidate);
    final enabled = !_busy && !saved;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        child: PressScale(
          enabled: enabled,
          scale: kPressScaleCard,
          child: Material(
            color: t.surf,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rTile),
              side: BorderSide(color: t.cardBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('recipe-import-candidate-${candidate.id}'),
              onTap: enabled ? () => _select(candidate) : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 68),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: _NumberBadge(number: index + 1, size: 34),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              (_drafts[candidate.id] ?? candidate).title,
                              style: AppType.ui(
                                15.5,
                                weight: FontWeight.w700,
                                color: saved ? t.ink2 : t.ink,
                                height: 1.3,
                              ),
                            ),
                            if (saved || candidate.variantLabel.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  if (candidate.variantLabel.isNotEmpty)
                                    _TintChip(label: candidate.variantLabel),
                                  if (saved)
                                    _TintChip(
                                      label: l10n.recipeImportAdded,
                                      icon: Icons.check_rounded,
                                      done: true,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ExcludeSemantics(
                        child: Icon(
                          saved
                              ? Icons.check_circle_rounded
                              : Icons.chevron_right_rounded,
                          size: 22,
                          color: saved ? t.accent : t.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final candidate = _selected!;
    final previewRecipe = candidate.toRecipe(slug: candidate.stableSlug(), sourceLabel: l10n.recipeImportSourceLabel);
    final portion = candidate.portion.isNotEmpty
        ? candidate.portion
        : candidate.servings != null
        ? '${l10n.recipeEditBatchServings}: ${candidate.servings == candidate.servings!.roundToDouble() ? candidate.servings!.round() : candidate.servings}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_editing && _result!.candidates.length > 1) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('recipe-import-back'),
              label: l10n.recipeImportOtherRecipe,
              icon: Icons.arrow_back_rounded,
              tone: SoftPillTone.neutral,
              onTap: _saving
                  ? null
                  : () {
                      setState(() {
                        _selected = null;
                        _error = null;
                      });
                      _scrollToTop();
                    },
            ),
          ),
          const SizedBox(height: 14),
        ],
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
            label: previewRecipe.sourceIngredientQuantityHint(l10n),
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
          if (_editError != null) ...[
            Text(_editError!, style: AppType.ui(14, color: t.danger)),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('recipe-import-finish-editing'),
              label: l10n.recipeImportFinishEditing,
              icon: Icons.visibility_outlined,
              onTap: _saving ? null : _applyEdits,
            ),
          ),
        ] else ...[
          _hero(context, candidate),
          const SizedBox(height: 22),
          RecipeImportNutrition(
            candidate: candidate,
            action: !candidate.hasNutrition || candidate.nutritionBasisUnclear
                ? SoftPillButton(
                    key: const ValueKey('recipe-import-correct-nutrition'),
                    label: l10n.recipeNutritionCorrect,
                    icon: Icons.tune_rounded,
                    onTap: _busy || _attemptedRecipes.containsKey(candidate.id)
                        ? null
                        : _correctNutrition,
                  )
                : null,
          ),
          const SizedBox(height: 22),
          _SectionCard(
            icon: Icons.restaurant_rounded,
            title: l10n.recipesSectionPortion,
            child: _Paragraph(text: portion, empty: l10n.recipesNoDataProvided),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            icon: Icons.shopping_basket_outlined,
            title: l10n.recipesSectionIngredients,
            child: _Ingredients(
              hint: previewRecipe.ingredientQuantityHint(l10n),
              text: previewRecipe.displayIngredients(l10n),
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            icon: Icons.soup_kitchen_outlined,
            title: l10n.recipesSectionPreparation,
            child: _Preparation(text: candidate.preparation),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SoftPillButton(
              key: const ValueKey('recipe-import-edit'),
              label: l10n.recipeImportEdit,
              icon: Icons.edit_outlined,
              onTap: _saving || _attemptedRecipes.containsKey(candidate.id)
                  ? null
                  : _edit,
            ),
          ),
        ],
        for (final warning in _result!.warnings.where(
          (warning) => warning != 'nutrition_missing',
        ))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _Notice(
              icon: Icons.info_outline_rounded,
              iconColor: t.ink2,
              fill: t.surf2,
              child: Text(
                _warningText(warning, l10n),
                style: AppType.ui(13, color: t.ink, height: 1.45),
              ),
            ),
          ),
        const SizedBox(height: 18),
        if (_editing && _hasSource) ...[
          _source(context),
          const SizedBox(height: 14),
        ],
        Text(
          l10n.recipeImportReviewHint,
          style: AppType.ui(12, color: t.ink2, height: 1.5),
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

  Widget _hero(BuildContext context, RecipeImportCandidate candidate) {
    final l10n = context.l10n;
    final t = context.t;
    return Container(
      key: const ValueKey('recipe-import-hero'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: t.brandSurface,
        borderRadius: BorderRadius.circular(rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.recipeImportPreviewLabel,
            style: AppType.sectionEyebrow(t.accentText, size: 11),
          ),
          const SizedBox(height: 10),
          Text(
            candidate.title,
            textScaler: AppType.pageTitleScaler(context),
            style: AppType.display(26, color: t.onBrandSurface, height: 1.15),
          ),
          if (candidate.variantLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            _TintChip(label: candidate.variantLabel),
          ],
          if (candidate.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              candidate.description,
              style: AppType.ui(14, color: t.onBrandSurface, height: 1.5),
            ),
          ],
          if (_hasSource) ...[
            const SizedBox(height: 16),
            _source(context, onBrand: true),
          ],
        ],
      ),
    );
  }

  String _warningText(String warning, AppLocalizations l10n) =>
      switch (warning) {
        'source_incomplete' => l10n.recipeImportIncompleteHint,
        'truncated' => l10n.recipeImportTruncatedHint,
        _ => l10n.recipeImportReviewHint,
      };
}

/// The import in three steps. Without [active] it explains the flow; with it
/// (the loading state) earlier steps read as done, the active one is filled
/// and pulses softly, later ones wait. The pulse stops under reduced motion.
class _ImportSteps extends StatefulWidget {
  const _ImportSteps({this.active});

  final int? active;

  @override
  State<_ImportSteps> createState() => _ImportStepsState();
}

class _ImportStepsState extends State<_ImportSteps>
    with SingleTickerProviderStateMixin {
  static const double _tile = 36;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(_ImportSteps oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final run = widget.active != null && !reducedMotion(context);
    if (run && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!run && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    final steps = [
      (Icons.ios_share_rounded, l10n.recipeImportStepShare),
      (Icons.auto_awesome_rounded, l10n.recipeImportStepRead),
      (Icons.bookmark_add_rounded, l10n.recipeImportStepSave),
    ];
    return Container(
      key: const ValueKey('recipe-import-steps'),
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (icon, label)) in steps.indexed)
            _step(context, i, icon, label, last: i == steps.length - 1),
        ],
      ),
    );
  }

  Widget _step(
    BuildContext context,
    int index,
    IconData icon,
    String label, {
    required bool last,
  }) {
    final t = context.t;
    final active = widget.active;
    final done = active != null && index < active;
    final current = active == index;
    final waiting = active != null && index > active;
    final (fill, glyph) = current
        ? (t.accentFill, t.onAccentFill)
        : waiting
        ? (t.tile, t.ink3)
        : (t.accentTint, t.accentText);
    Widget tile = Container(
      width: _tile,
      height: _tile,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(rChip),
      ),
      child: Icon(done ? Icons.check_rounded : icon, size: 18, color: glyph),
    );
    if (current && !reducedMotion(context)) {
      // A halo that grows and fades from the tile: calm "working" feedback.
      tile = AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final v = Curves.easeOut.transform(_pulse.value);
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Transform.scale(
                scale: 1 + 0.5 * v,
                child: Container(
                  width: _tile,
                  height: _tile,
                  decoration: BoxDecoration(
                    color: t.accent.withValues(alpha: 0.4 * (1 - v)),
                    borderRadius: BorderRadius.circular(rChip),
                  ),
                ),
              ),
              child!,
            ],
          );
        },
        child: tile,
      );
    }
    // The rail under each tile runs to the next tile however tall the label
    // grows, so the three rows read as one flow at any text scale.
    return MergeSemantics(
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Column(
                children: [
                  tile,
                  if (!last)
                    Expanded(
                      child: Container(
                        width: 2,
                        decoration: BoxDecoration(
                          color: done || current ? t.accentTint : t.line,
                          borderRadius: BorderRadius.circular(rPill),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: last ? 0 : 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _tile),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${index + 1}  ',
                            style: AppType.display(
                              13,
                              color: waiting ? t.ink3 : t.accentText,
                            ),
                          ),
                          TextSpan(text: label),
                        ],
                      ),
                      style: AppType.ui(
                        14,
                        weight: current ? FontWeight.w700 : FontWeight.w600,
                        color: waiting
                            ? t.ink3
                            : done
                            ? t.ink2
                            : t.ink,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A calm one-line notice: tinted ground, a leading glyph, the message.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.iconColor,
    required this.fill,
    required this.child,
  });

  final IconData icon;
  final Color iconColor;
  final Color fill;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(rTile),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: ExcludeSemantics(
              child: Icon(icon, size: 18, color: iconColor),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Accent-tinted round number (a candidate's position, a preparation step).
/// The digit follows text scale only up to 1.3x, so it never bursts the
/// circle.
class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.number, required this.size});

  final int number;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.accentTint, shape: BoxShape.circle),
      child: Text(
        '$number',
        textScaler: MediaQuery.textScalerOf(
          context,
        ).clamp(maxScaleFactor: 1.3),
        style: AppType.display(size * 0.46, color: t.accentText),
      ),
    );
  }
}

/// A small tinted label chip (variant, "Added").
class _TintChip extends StatelessWidget {
  const _TintChip({required this.label, this.icon, this.done = false});

  final String label;
  final IconData? icon;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (fill, ink) = done
        ? (t.surf2, t.inkSoft)
        : (t.accentTint, t.accentText);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: done ? t.success : ink),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              style: AppType.ui(12, weight: FontWeight.w700, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A preview section: small icon tile, title, content on a calm card.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: rTile,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: IconTile(icon: icon, color: t.accent, size: 30),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HeadingSemantics(
                  level: 2,
                  child: Text(
                    title,
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

const double _bodySize = 15;
const double _bodyHeight = 1.5;

TextStyle _bodyStyle(AppTokens t, {bool muted = false}) =>
    AppType.ui(_bodySize, color: muted ? t.ink2 : t.ink, height: _bodyHeight);

/// Non-empty, trimmed lines of a free text.
List<String> _lines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

class _Paragraph extends StatelessWidget {
  const _Paragraph({required this.text, required this.empty});

  final String text;

  /// Shown muted when [text] is empty.
  final String empty;

  @override
  Widget build(BuildContext context) {
    final value = text.trim();
    return Text(
      value.isEmpty ? empty : value,
      style: _bodyStyle(context.t, muted: value.isEmpty),
    );
  }
}

/// Ingredients as bullet lines (accent dot + text) under the quantity hint.
class _Ingredients extends StatelessWidget {
  const _Ingredients({required this.hint, required this.text});

  final String hint;
  final String text;

  // A leading list marker from the caption; the dot replaces it.
  static final RegExp _marker = RegExp(r'^(?:[•*·–]\s*|-\s+)');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = [
      for (final line in _lines(text))
        if (line.replaceFirst(_marker, '').isNotEmpty)
          line.replaceFirst(_marker, ''),
    ];
    // Centre the dot on the first line at any text scale.
    final dotTop =
        (MediaQuery.textScalerOf(context).scale(_bodySize) * _bodyHeight - 6) /
        2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hint.isNotEmpty) ...[
          Text(hint, style: AppType.ui(13, color: t.ink2, height: 1.45)),
          const SizedBox(height: 12),
        ],
        if (lines.isEmpty)
          Text(
            context.l10n.recipesNoDataProvided,
            style: _bodyStyle(t, muted: true),
          ),
        for (final (i, line) in lines.indexed) ...[
          if (i > 0) const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: dotTop),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(line, style: _bodyStyle(t))),
            ],
          ),
        ],
      ],
    );
  }
}

/// Preparation as numbered steps when the text has several lines; a single
/// paragraph stays a paragraph.
class _Preparation extends StatelessWidget {
  const _Preparation({required this.text});

  final String text;

  // "1." / "2)" or a list marker the caption already numbered with; not the
  // "1" of "1.5 l".
  static final RegExp _marker = RegExp(r'^(?:\d+[.)](?!\d)|[•*·–]|-(?=\s))\s*');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final steps = _lines(text);
    if (steps.length < 2) {
      return _Paragraph(
        text: text,
        empty: context.l10n.recipeImportPreparationMissing,
      );
    }
    const badge = 26.0;
    // Badge and first text line share one centre at any text scale.
    final line =
        MediaQuery.textScalerOf(context).scale(_bodySize) * _bodyHeight;
    final badgeTop = line > badge ? (line - badge) / 2 : 0.0;
    final textTop = line < badge ? (badge - line) / 2 : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, step) in steps.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: badgeTop),
                child: _NumberBadge(number: i + 1, size: badge),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: textTop),
                  child: Text(
                    step.replaceFirst(_marker, ''),
                    style: _bodyStyle(t),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
