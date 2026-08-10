part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// Detail-Ansicht eines Rezepts (eigener Route-Push): Bild, Nährwert-Grid,
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
    final slot = await showEatovaSheet<MealSlot>(
      context,
      _MealSlotPickerSheet(recipe: recipe),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          key: const ValueKey('recipe-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title: recipe.userCreated ? 'Eigenes Rezept' : 'Eatova Rezept',
                backKey: const ValueKey('recipe-detail-back'),
                onBack: () => Navigator.of(context).pop(),
                trailing: onDelete == null
                    // Gegengewicht zum Zurueck-Knopf: ohne es waere der mittige
                    // Titel bei Bestandsrezepten aus der Mitte verschoben.
                    ? const SizedBox(width: 34)
                    : SquareIconButton(
                        key: const ValueKey('recipe-detail-delete'),
                        icon: Icons.delete_outline_rounded,
                        semanticLabel: 'Rezept löschen',
                        onTap: () {
                          // Erst zurueck, dann melden: der Toast soll auf der
                          // Rezeptliste landen, nicht auf dem sterbenden Detail.
                          Navigator.of(context).pop();
                          onDelete!();
                        },
                      ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(rSheet),
                child: SizedBox(
                  height: 258,
                  width: double.infinity,
                  child: _RecipeImage(
                    recipe: recipe,
                    placeholderRadius: rSheet,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                recipe.title,
                key: ValueKey('recipe-detail-${recipe.slug}'),
                style: AppType.display(28, color: t.ink, height: 1.1),
              ),
              const SizedBox(height: 10),
              Text(
                recipe.description,
                style: AppType.ui(14, color: t.ink2, height: 1.45),
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
                highlight: true,
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
    final t = context.t;
    return AppCard(
      key: const ValueKey('recipe-add-card'),
      radius: rSheet,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: Icons.add_rounded, color: t.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Zum Tracker hinzufügen',
                      style: AppType.display(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${recipe.caloriesKcal} kcal · ${recipe.proteinG} g Protein',
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          PrimaryActionButton(
            key: const ValueKey('recipe-add-button'),
            label: 'Hinzufügen',
            icon: Icons.add_rounded,
            onTap: onTap,
          ),
          const SizedBox(height: 10),
          Text(
            'Danach wählst du Frühstück, Mittagessen, Abendessen oder Snack.',
            style: AppType.ui(11.5, color: t.ink2, height: 1.35),
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
    final t = context.t;
    // Korrektur gegenueber dem Altstand: dort trug „Protein" `orange` und
    // „Fett" `macroFat` — derselbe Farbwert (app_colors.dart:50/62), beide
    // Kacheln waren also farbgleich. Jetzt je ein eigener Makro-Token.
    return Row(
      children: [
        Expanded(
          child: _NutritionTile(
            label: 'Kcal',
            value: '${recipe.caloriesKcal}',
            color: t.accent,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: 'Protein',
            value: '${recipe.proteinG} g',
            color: t.protein,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: 'KH',
            value: '${recipe.carbsG} g',
            color: t.carbs,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _NutritionTile(
            label: 'Fett',
            value: '${recipe.fatG} g',
            color: t.fat,
          ),
        ),
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
    final t = context.t;
    return AppCard(
      radius: rCard,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.display(16, weight: FontWeight.w700, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow(t.ink2, size: 9.5),
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
    this.highlight = false,
  });

  final String title;
  final String body;

  /// Hebt den Punkt vor der Überschrift in den Akzent (Profi-Hinweis).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: highlight ? t.accent : t.ink2,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: SectionHeading(title: title)),
            ],
          ),
          const SizedBox(height: 10),
          AppCard(
            radius: rSheet,
            child: SizedBox(
              width: double.infinity,
              child: Text(
                body,
                style: AppType.ui(13, color: t.ink2, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
