import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/fitness_recipe.dart';
import '../../services/recipe_image_store.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

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
///  3. Everything else gets the striped [ImagePlaceholder].
class RecipePhoto extends StatelessWidget {
  const RecipePhoto({
    super.key,
    required this.recipe,
    this.placeholderRadius = 0,
  });

  final FitnessRecipe recipe;

  // Meal-plan snapshots deserialize as user recipes. Only an exact catalog
  // slug/path pair may reuse a bundled photo; arbitrary persisted paths cannot.
  static final _catalogPhotos = {
    for (final recipe in recipeCatalogDe) recipe.slug: recipe.imageAsset,
  };

  /// The placeholder draws its own corner; real assets are clipped by the
  /// calling card.
  final double placeholderRadius;

  @override
  Widget build(BuildContext context) {
    if (RecipeImageStore.isLocalReference(recipe.imageAsset)) {
      return _LocalRecipeImage(
        reference: recipe.imageAsset,
        placeholderRadius: placeholderRadius,
      );
    }
    if (recipe.imageAsset.isEmpty ||
        (recipe.userCreated &&
            _catalogPhotos[recipe.slug] != recipe.imageAsset)) {
      return ImagePlaceholder(
        radius: placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
      );
    }
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
    required this.placeholderRadius,
  });

  final String reference;
  final double placeholderRadius;

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
    if (datei == null) {
      return ImagePlaceholder(
        radius: widget.placeholderRadius,
        label: context.l10n.recipesImagePlaceholderLabel,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 400.0;
        return Image.file(
          datei,
          fit: BoxFit.cover,
          cacheWidth: (logicalWidth * dpr).round().clamp(1, 1600),
          // The file can vanish between the existence check and decoding.
          errorBuilder: (context, error, stack) => ImagePlaceholder(
            radius: widget.placeholderRadius,
            label: context.l10n.recipesImagePlaceholderLabel,
          ),
        );
      },
    );
  }
}
