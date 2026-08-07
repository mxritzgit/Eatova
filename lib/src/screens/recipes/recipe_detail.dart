part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Detail-Ansicht eines Rezepts (eigener Route-Push): Bild, Makro-Grid,
// „Zum Tracker hinzufügen"-Karte und die Info-Sektionen (Portion, Zutaten,
// Zubereitung, Profi-Hinweis). [RecipeDetailScreen] ist bewusst öffentlich.
// ---------------------------------------------------------------------------
class RecipeDetailScreen extends StatelessWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    required this.onAddMeal,
    this.onDelete,
  });

  final FitnessRecipe recipe;
  final void Function(MealAnalysisResult result, MealSlot slot) onAddMeal;

  /// Optionaler Loeschen-Hook (nur fuer Eigen-Rezepte gesetzt). Schliesst den
  /// Detail-Screen und meldet die Loeschung an den Aufrufer.
  final VoidCallback? onDelete;

  Future<void> _showMealPicker(BuildContext context) async {
    final slot = await showModalBottomSheet<MealSlot>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      isScrollControlled: true,
      builder: (sheetContext) => _MealSlotPickerSheet(recipe: recipe),
    );
    if (!context.mounted || slot == null) return;
    _add(context, slot);
  }

  void _add(BuildContext context, MealSlot slot) {
    onAddMeal(recipe.toMealResult(), slot);
    showAppSnack(
      context,
      '${recipe.caloriesKcal} kcal zu ${slot.label} hinzugefügt.',
      icon: Icons.check_circle_rounded,
      accent: lime,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _RoundIconButton(
                    key: const ValueKey('recipe-detail-back'),
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  if (onDelete != null) ...[
                    _RoundIconButton(
                      key: const ValueKey('recipe-detail-delete'),
                      icon: Icons.delete_outline_rounded,
                      iconColor: danger,
                      onTap: () {
                        Navigator.of(context).pop();
                        onDelete!();
                      },
                    ),
                    const SizedBox(width: 10),
                  ],
                  _GlassBadge(
                    text: recipe.userCreated ? 'Eigenes Rezept' : 'Eatova Rezept',
                    dark: true,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(rSheet),
                child: SizedBox(
                  height: 258,
                  width: double.infinity,
                  child: _RecipeImage(recipe: recipe),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                recipe.title,
                key: ValueKey('recipe-detail-${recipe.slug}'),
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 28,
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                recipe.description,
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 14,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (recipe.categories.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final category in recipe.categories)
                      _CategoryPill(label: category),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              _NutritionGrid(recipe: recipe),
              const SizedBox(height: 18),
              _AddToMealCard(
                recipe: recipe,
                onTap: () => _showMealPicker(context),
              ),
              const SizedBox(height: 18),
              _RecipeInfoSection(title: 'Portion', body: recipe.portion),
              _RecipeInfoSection(title: 'Zutaten', body: recipe.ingredients),
              _RecipeInfoSection(title: 'Zubereitung', body: recipe.preparation),
              _RecipeInfoSection(
                title: 'Profi-Hinweis',
                body: recipe.professionalHint,
                accent: lime,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddToMealCard extends StatelessWidget {
  const _AddToMealCard({required this.recipe, required this.onTap});

  final FitnessRecipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('recipe-add-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rSheet),
        border: Border.all(color: lime.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: lime.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: const Icon(Icons.add_rounded, color: lime, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Zum Tracker hinzufügen',
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${recipe.caloriesKcal} kcal · ${recipe.proteinG} g Protein',
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              key: const ValueKey('recipe-add-button'),
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: lime,
                foregroundColor: bg,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rCard),
                ),
              ),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
              label: const Text(
                'Hinzufügen',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            'Danach wählst du Frühstück, Mittagessen, Abendessen oder Snack.',
            style: TextStyle(color: textMuted, fontSize: 11.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _NutritionGrid extends StatelessWidget {
  const _NutritionGrid({required this.recipe});

  final FitnessRecipe recipe;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _NutritionTile(label: 'Kcal', value: '${recipe.caloriesKcal}', color: lime)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'Protein', value: '${recipe.proteinG} g', color: orange)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'KH', value: '${recipe.carbsG} g', color: cyan)),
        const SizedBox(width: 8),
        Expanded(child: _NutritionTile(label: 'Fett', value: '${recipe.fatG} g', color: macroFat)),
      ],
    );
  }
}

class _NutritionTile extends StatelessWidget {
  const _NutritionTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeInfoSection extends StatelessWidget {
  const _RecipeInfoSection({
    required this.title,
    required this.body,
    this.accent = cyan,
  });

  final String title;
  final String body;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rSheet),
          border: Border.all(color: hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: const TextStyle(
                color: textMuted,
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconColor = textPrimary,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}
