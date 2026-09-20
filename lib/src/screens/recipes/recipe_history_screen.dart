import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../services/sync_error_messages.dart';
import '../../services/user_recipe_reads.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
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
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.recipeHistoryRestore),
          content: Text(l10n.recipeHistoryRestoreConfirm(version.recipe.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              key: const ValueKey('recipe-history-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.recipeHistoryRestore),
            ),
          ],
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
    final material = MaterialLocalizations.of(context);
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
            const SizedBox(height: 16),
            for (final version in _versions)
              ExpansionTile(
                key: ValueKey('recipe-history-version-${version.revision}'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  version.hasRecipeContent
                      ? version.recipe.title
                      : l10n.recipeHistoryDeletionOnlyTitle,
                ),
                subtitle: Text(
                  [
                    material.formatFullDate(version.recordedAt.toLocal()),
                    material.formatTimeOfDay(
                      TimeOfDay.fromDateTime(version.recordedAt.toLocal()),
                    ),
                    l10n.recipeHistoryVersion(version.revision),
                    if (version.deleted) l10n.recipeHistoryDeleted,
                  ].join(' · '),
                ),
                childrenPadding: const EdgeInsets.only(bottom: 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (version.hasRecipeContent) ...[
                    Text(version.recipe.displayIngredients(l10n)),
                    const SizedBox(height: 12),
                    Text(version.recipe.displayPreparation(l10n)),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: ValueKey(
                        'recipe-history-restore-${version.revision}',
                      ),
                      onPressed: _restoring != null
                          ? null
                          : () => _restore(version),
                      icon: const Icon(Icons.restore_rounded),
                      label: Text(l10n.recipeHistoryRestore),
                    ),
                  ] else
                    Text(l10n.recipeHistoryDeletionOnlyDetail),
                ],
              ),
            if (_answered && _versions.isEmpty)
              Text(
                l10n.recipeHistoryEmpty,
                style: AppType.ui(14, color: t.ink2),
              ),
            if (_error != null) ...[
              Text(directSyncErrorMessage(_error!, l10n)),
              TextButton(
                onPressed: _load,
                child: Text(l10n.commonBootUnansweredRetry),
              ),
            ] else if (!_loading && _next != null)
              TextButton(
                onPressed: _load,
                child: Text(l10n.recipeHistoryLoadMore),
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
