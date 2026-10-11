import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/fitness_recipe.dart';
import '../../services/recipe_image_store.dart';
import '../../theme/app_tokens.dart';
import 'recipe_glyphs.dart';

/// Gives large text the full width instead of squeezing it beside a photo.
class RecipePhotoRow extends StatelessWidget {
  const RecipePhotoRow({
    super.key,
    required this.recipe,
    required this.child,
    this.photoWidth = 82,
    this.photoHeight = 92,
  });

  final FitnessRecipe recipe;
  final Widget child;
  final double photoWidth, photoHeight;

  @override
  Widget build(BuildContext context) {
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 24;
    final photo = ClipRRect(
      borderRadius: BorderRadius.circular(rControl),
      child: SizedBox(
        width: stacked ? double.infinity : photoWidth,
        height: stacked ? 140 : photoHeight,
        child: RecipePhoto(recipe: recipe),
      ),
    );
    return stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [photo, const SizedBox(height: 14), child],
          )
        : Row(
            children: [
              photo,
              const SizedBox(width: 14),
              Expanded(child: child),
            ],
          );
  }
}

/// Image of a recipe card. Three cases, in this order:
///  1. `local:<slug>.jpg` from [RecipeImageStore]; a missing file (other
///     device, cleared cache) falls back to the placeholder, never a broken
///     icon.
///  2. Catalog recipes show their bundle asset.
///  3. Everything else gets the glowing [RecipeArt].
class RecipePhoto extends StatelessWidget {
  const RecipePhoto({
    super.key,
    required this.recipe,
    this.placeholderRadius = 0,
    this.alignment = Alignment.center,
    this.placeholder,
  });

  final FitnessRecipe recipe;

  // Meal-plan snapshots deserialize as user recipes. Only an exact catalog
  // slug/path pair may reuse a bundled photo; arbitrary persisted paths cannot.
  static final _catalogPhotos = {
    for (final recipe in recipeCatalogDe) recipe.slug: recipe.imageAsset,
  };

  /// Whether [build] shows a bundled catalog photo for [recipe] (case 2).
  static bool showsCatalogPhoto(FitnessRecipe recipe) =>
      recipe.imageAsset.isNotEmpty &&
      !RecipeImageStore.isLocalReference(recipe.imageAsset) &&
      (!recipe.userCreated ||
          _catalogPhotos[recipe.slug] == recipe.imageAsset);

  /// Whether the photo shown for [recipe] is known to be AI-generated: the
  /// bundled catalog photos are (their pixels carry an "AI Generated" mark).
  /// A `local:` photo may be the user's own shot — a coach recipe's photo can
  /// be replaced in the editor — so it is never claimed as AI.
  static bool isAiGenerated(FitnessRecipe recipe) => showsCatalogPhoto(recipe);

  /// Corner of the placeholder art when the caller does not clip; real
  /// assets are clipped by the calling card.
  final double placeholderRadius;

  /// Crop anchor of the cover-fitted photo.
  final Alignment alignment;

  /// Replaces the default [RecipeArt] (no photo, or a local file that is
  /// missing on this device).
  final WidgetBuilder? placeholder;

  Widget _placeholder(BuildContext context) {
    final custom = placeholder?.call(context);
    if (custom != null) return custom;
    final art = RecipeArt.of(recipe);
    return placeholderRadius <= 0
        ? art
        : ClipRRect(
            borderRadius: BorderRadius.circular(placeholderRadius),
            child: art,
          );
  }

  @override
  Widget build(BuildContext context) {
    if (RecipeImageStore.isLocalReference(recipe.imageAsset)) {
      return _LocalRecipeImage(
        reference: recipe.imageAsset,
        alignment: alignment,
        placeholder: _placeholder,
      );
    }
    if (!showsCatalogPhoto(recipe)) return _placeholder(context);
    // Tie decode resolution to the actual slot width: the recipe PNGs are
    // ~1800px/2.4MB and would otherwise decode in full for every size.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 400.0;
        return Image.asset(
          recipe.imageAsset,
          fit: BoxFit.cover,
          alignment: alignment,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
        );
      },
    );
  }
}

/// A user-taken recipe photo from the app documents directory.
///
/// Stateful rather than a [FutureBuilder]: once the base is resolved,
/// [RecipeImageStore.resolveSync] answers without a frame delay, so scrolling
/// never flashes a placeholder. Only the first access per session is async.
class _LocalRecipeImage extends StatefulWidget {
  const _LocalRecipeImage({
    required this.reference,
    required this.alignment,
    required this.placeholder,
  });

  final String reference;
  final Alignment alignment;
  final WidgetBuilder placeholder;

  @override
  State<_LocalRecipeImage> createState() => _LocalRecipeImageState();
}

class _LocalRecipeImageState extends State<_LocalRecipeImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _LocalRecipeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference) {
      _file = null;
      _resolve();
    }
  }

  void _resolve() {
    final store = RecipeImageStore.instance;
    if (store.baseResolved) {
      _file = store.resolveSync(widget.reference);
      return;
    }
    final gesucht = widget.reference;
    store.resolve(gesucht).then((datei) {
      // Disposed meanwhile, or switched to another recipe.
      if (!mounted || gesucht != widget.reference) return;
      setState(() => _file = datei);
    });
  }

  @override
  Widget build(BuildContext context) {
    final datei = _file;
    if (datei == null) return widget.placeholder(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 400.0;
        return Image.file(
          datei,
          fit: BoxFit.cover,
          alignment: widget.alignment,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
          // The file can vanish between the existence check and decoding.
          errorBuilder: (context, error, stack) => widget.placeholder(context),
        );
      },
    );
  }
}

/// The motif of a [RecipeArt], from the recipe's categories: fish dishes get
/// the fish, vegetarian and vegan ones the leaf, the rest the bowl.
enum RecipeArtKind {
  bowl,
  fish,
  leaf;

  static RecipeArtKind of(FitnessRecipe recipe) {
    // Double-quoted: category identities are matching data, not UI text.
    if (recipe.categories.contains("Fisch")) return RecipeArtKind.fish;
    if (recipe.categories.contains("Vegetarisch") ||
        recipe.categories.contains("Vegan")) {
      return RecipeArtKind.leaf;
    }
    return RecipeArtKind.bowl;
  }
}

/// The design's glowing icon for a recipe without a photo: a radial glow on
/// the quiet well, the glyph in the matching ink. Fills its slot, from a
/// 56 px thumbnail to the detail hero.
///
/// The design's three hues are the macro fills and inks (blue, orange, green);
/// they are reused here as decoration because the art carries no data and has
/// no tokens of its own. Decorative: the row or card around it names the
/// recipe.
class RecipeArt extends StatelessWidget {
  const RecipeArt({super.key, this.kind = RecipeArtKind.bowl, this.iconSize});

  /// The art for [recipe]'s categories.
  RecipeArt.of(FitnessRecipe recipe, {super.key, this.iconSize})
    : kind = RecipeArtKind.of(recipe);

  final RecipeArtKind kind;

  /// Glyph size; null derives it from the slot (40 % of its shorter side,
  /// 18 to 56 px).
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (glow, alpha, ink, glyph) = switch (kind) {
      RecipeArtKind.bowl => (t.carbs, 0.32, t.carbsInk, RecipeGlyph.bowl),
      RecipeArtKind.fish => (t.fat, 0.34, t.fatInk, RecipeGlyph.fish),
      RecipeArtKind.leaf => (t.protein, 0.32, t.proteinInk, RecipeGlyph.leaf),
    };
    return ColoredBox(
      key: ValueKey('recipe-art-${kind.name}'),
      color: t.surfWell,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth, h = constraints.maxHeight;
          // CSS `radial-gradient(circle at 50% 55%, c 0%, transparent 65%)`
          // runs to the farthest corner; Flutter's radius is a fraction of
          // the shortest side.
          final dx = w / 2, dy = h * 0.55 > h * 0.45 ? h * 0.55 : h * 0.45;
          final shortest = w < h ? w : h;
          final radius = shortest <= 0 || !shortest.isFinite
              ? 1.0
              : math.sqrt(dx * dx + dy * dy) / shortest;
          final size =
              iconSize ??
              (shortest.isFinite ? (shortest * 0.4).clamp(18.0, 56.0) : 44.0);
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, 0.1),
                radius: radius,
                colors: [
                  glow.withValues(alpha: alpha),
                  glow.withValues(alpha: 0),
                ],
                stops: const [0, 0.65],
              ),
            ),
            child: Center(
              child: RecipeGlyphIcon(
                glyph,
                size: size,
                // Thumbnails get a firmer line; at 1.4 a 22 px glyph drew
                // hairlines.
                strokeWidth: size < 36 ? 1.8 : 1.4,
                color: ink,
              ),
            ),
          );
        },
      ),
    );
  }
}
