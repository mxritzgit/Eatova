import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../services/sync_error_messages.dart';
import '../../services/user_recipe_reads.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';

typedef RecipeHistoryLoader =
    Future<RecipeHistoryPage> Function({String? slug, int? beforeRevision});
typedef RecipeVersionRestorer =
    Future<SyncDelivery> Function(
      FitnessRecipe recipe, {
      required int expectedRevision,
    });

/// The account timeline also exposes deleted recipes, which have no detail page.
class RecipeHistoryScreen extends StatefulWidget {
  const RecipeHistoryScreen({
    super.key,
    required this.loadHistory,
    required this.restoreVersion,
    required this.isSessionCurrent,
    this.slug,
  });

  final RecipeHistoryLoader loadHistory;
  final RecipeVersionRestorer restoreVersion;
  final bool Function() isSessionCurrent;
  final String? slug;

  @override
  State<RecipeHistoryScreen> createState() => _RecipeHistoryScreenState();
}

class _RecipeHistoryScreenState extends State<RecipeHistoryScreen> {
  final _versions = <RecipeVersion>[];
  bool _loading = false;
  bool _answered = false;
  Object? _error;
  int? _next;
  int? _restoring;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _current => mounted && widget.isSessionCurrent();

  Future<void> _load() async {
    if (!_current || _loading || (_answered && _next == null)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.loadHistory(
        slug: widget.slug,
        beforeRevision: _next,
      );
      if (!mounted || !widget.isSessionCurrent()) return;
      setState(() {
        _versions.addAll(page.versions);
        _next = page.nextBefore;
        _answered = true;
      });
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore(RecipeVersion version) async {
    if (!_current || _restoring != null || !version.hasRecipeContent) return;
    setState(() => _restoring = version.revision);
    try {
      // A timeline cursor is historical. Confirmation binds to a fresh head;
      // a later concurrent edit is handled by the store's CAS conflict policy.
      final head = await widget.loadHistory(slug: version.recipe.slug);
      if (!mounted || !widget.isSessionCurrent()) return;
      final expected = head.currentRevision;
      if (expected == null) throw StateError('Recipe head is unavailable');
      final l10n = context.l10n;
      final confirm = await showEatovaDialog<bool>(
        context: context,
        builder: (context) => EatovaConfirmDialog(
          title: l10n.recipeHistoryRestore,
          body: l10n.recipeHistoryRestoreConfirm(
            version.recipe.displayTitle(l10n),
          ),
          icon: Icons.restore_rounded,
          confirmLabel: l10n.recipeHistoryRestore,
          cancelLabel: l10n.commonCancel,
          confirmKey: const ValueKey('recipe-history-confirm'),
          onConfirm: () => Navigator.pop(context, true),
          onCancel: () => Navigator.pop(context, false),
        ),
      );
      if (confirm != true || !mounted || !widget.isSessionCurrent()) return;
      final delivery = await widget.restoreVersion(
        version.recipe,
        expectedRevision: expected,
      );
      if (!mounted || !widget.isSessionCurrent()) return;
      Navigator.pop(context, delivery);
    } catch (error) {
      if (mounted && widget.isSessionCurrent()) {
        showAppSnack(
          context,
          directSyncErrorMessage(error, context.l10n),
          tone: SnackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: ListView(
          key: const ValueKey('recipe-history-list'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            PageHeader(
              title: l10n.recipeHistoryTitle,
              onBack: () => Navigator.pop(context),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.recipeHistoryExplanation,
              style: AppType.ui(14, color: t.ink2, height: 1.5),
            ),
            const SizedBox(height: 20),
            for (final version in _versions) ...[
              _VersionCard(
                key: ValueKey('recipe-history-version-${version.revision}'),
                version: version,
                restoreEnabled: _restoring == null,
                onRestore: () => _restore(version),
              ),
              const SizedBox(height: 12),
            ],
            if (_answered && _versions.isEmpty)
              Text(
                l10n.recipeHistoryEmpty,
                style: AppType.ui(14, color: t.ink2),
              ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                directSyncErrorMessage(_error!, l10n),
                style: AppType.ui(14, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SoftPillButton(
                  key: const ValueKey('recipe-history-retry'),
                  label: l10n.commonBootUnansweredRetry,
                  icon: Icons.refresh_rounded,
                  onTap: _load,
                ),
              ),
            ] else if (!_loading && _next != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Center(
                  child: SoftPillButton(
                    key: const ValueKey('recipe-history-load-more'),
                    label: l10n.recipeHistoryLoadMore,
                    icon: Icons.expand_more_rounded,
                    tone: SoftPillTone.neutral,
                    onTap: _load,
                  ),
                ),
              ),
            if (_loading || _restoring != null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One timeline entry as a card: title and when, tap to read the version's
/// content and restore it.
class _VersionCard extends StatefulWidget {
  const _VersionCard({
    super.key,
    required this.version,
    required this.restoreEnabled,
    required this.onRestore,
  });

  final RecipeVersion version;

  /// False while any restore is in flight.
  final bool restoreEnabled;
  final VoidCallback onRestore;

  @override
  State<_VersionCard> createState() => _VersionCardState();
}

class _VersionCardState extends State<_VersionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final material = MaterialLocalizations.of(context);
    final t = context.t;
    final version = widget.version;
    final recipe = version.recipe;
    final when = version.recordedAt.toLocal();
    final meta = [
      material.formatFullDate(when),
      material.formatTimeOfDay(TimeOfDay.fromDateTime(when)),
      l10n.recipeHistoryVersion(version.revision),
      if (version.deleted) l10n.recipeHistoryDeleted,
    ].join(' · ');
    // From 1.5x text the title gets the tile's width.
    final large = MediaQuery.textScalerOf(context).scale(16) > 24;
    final header = Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!large) ...[
                IconTile(
                  icon: version.deleted
                      ? Icons.delete_outline_rounded
                      : Icons.history_rounded,
                  color: version.deleted ? t.danger : t.accent,
                  size: 36,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      version.hasRecipeContent
                          ? recipe.displayTitle(l10n)
                          : l10n.recipeHistoryDeletionOnlyTitle,
                      style: AppType.display(16, color: t.ink, height: 1.25),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: AppType.ui(13, color: t.ink2, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: motionDuration(context, kMotionEnter),
                curve: kMotionCurve,
                child: Icon(Icons.expand_more_rounded, color: t.ink2),
              ),
            ],
          ),
        ),
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (version.hasRecipeContent) ...[
            if (recipe.hasImportedIngredientContext) ...[
              Text(
                recipe.ingredientQuantityHint(l10n),
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              recipe.displayIngredients(l10n),
              style: AppType.ui(14, color: t.ink, height: 1.5),
            ),
            const SizedBox(height: 12),
            Text(
              recipe.displayPreparation(l10n),
              style: AppType.ui(14, color: t.ink2, height: 1.5),
            ),
            const SizedBox(height: 16),
            SoftPillButton(
              key: ValueKey('recipe-history-restore-${version.revision}'),
              label: l10n.recipeHistoryRestore,
              icon: Icons.restore_rounded,
              onTap: widget.restoreEnabled ? widget.onRestore : null,
            ),
          ] else
            Text(
              l10n.recipeHistoryDeletionOnlyDetail,
              style: AppType.ui(14, color: t.ink2, height: 1.5),
            ),
        ],
      ),
    );
    return Material(
      color: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rCard),
        side: BorderSide(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: maybeAnimatedSize(
        context,
        duration: kMotionEnter,
        curve: kMotionCurve,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, if (_expanded) body],
        ),
      ),
    );
  }
}
