part of 'recipes_screen.dart';

/// Resolve complete caption values before opening the diary slot picker.
class _RecipeNutritionBasisSheet extends StatefulWidget {
  const _RecipeNutritionBasisSheet({
    required this.recipe,
    required this.onSave,
    required this.isSessionCurrent,
  });

  final FitnessRecipe recipe;
  final Future<RecipeSaveResult> Function(FitnessRecipe) onSave;
  final bool Function() isSessionCurrent;

  @override
  State<_RecipeNutritionBasisSheet> createState() =>
      _RecipeNutritionBasisSheetState();
}

class _RecipeNutritionBasisSheetState
    extends State<_RecipeNutritionBasisSheet> {
  double? _sourceServings = 1;
  bool _saving = false;
  bool _committed = false;
  String? _error;

  FitnessRecipe? get _confirmed {
    if (_sourceServings == null) return null;
    try {
      return widget.recipe.withConfirmedNutritionBasis(_sourceServings!);
    } on FormatException {
      return null;
    }
  }

  Future<void> _save() async {
    final draft = _confirmed;
    if (_saving || _committed || draft == null) return;
    if (!widget.isSessionCurrent()) {
      setState(() => _error = context.l10n.recipeEditSessionChanged);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    RecipeSaveResult saved;
    try {
      saved = await widget.onSave(draft);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = context.l10n.recipeEditSaveFailed;
        });
      }
      return;
    }
    if (!mounted || !widget.isSessionCurrent()) {
      saved.handle.dispose();
      if (mounted) {
        setState(() {
          _saving = false;
          _error = context.l10n.recipeEditSessionChanged;
        });
      }
      return;
    }
    // Lift the pop guard in the widget tree before closing the committed draft.
    setState(() {
      _saving = false;
      _committed = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop(saved);
      } else {
        saved.handle.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final confirmed = _confirmed;
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-nutrition-basis-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              HeadingSemantics(
                level: 1,
                child: Text(
                  l10n.recipeNutritionBasisCheck,
                  style: AppType.display(24, color: t.ink, height: 1.15),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.recipeNutritionBasisExplanation,
                style: AppType.ui(14, color: t.ink2, height: 1.5),
              ),
              const SizedBox(height: 20),
              Text(
                widget.recipe.title,
                style: AppType.display(20, color: t.ink),
              ),
              const SizedBox(height: 12),
              _NutritionGrid(recipe: widget.recipe),
              const SizedBox(height: 24),
              IgnorePointer(
                ignoring: _saving,
                child: RecipePortionSelector(
                  label: l10n.recipeNutritionBasisServings,
                  showPresets: false,
                  onChanged: (value) => setState(() => _sourceServings = value),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                confirmed == null
                    ? l10n.recipeNutritionBasisInvalid
                    : '${l10n.recipesPerPortion}: ${_recipeSummary(confirmed, l10n)}',
                key: const ValueKey('recipe-nutrition-basis-preview'),
                style: AppType.ui(
                  14,
                  color: confirmed == null ? t.danger : t.ink,
                  height: 1.5,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const ValueKey('recipe-nutrition-basis-error'),
                  style: AppType.ui(14, color: t.danger, height: 1.5),
                ),
              ],
              const SizedBox(height: 24),
              PrimaryActionButton(
                key: const ValueKey('recipe-nutrition-basis-confirm'),
                label: _saving
                    ? l10n.recipeImportSaving
                    : l10n.recipeNutritionBasisContinue,
                onTap: _saving || confirmed == null ? null : _save,
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('recipe-nutrition-basis-cancel'),
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.commonCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
