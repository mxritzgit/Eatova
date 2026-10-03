import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';
import '../../models/recipe_ingredient.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../common/decimal_text.dart';
import '../design/design.dart';
import '../kcal/saved_meal_presentation.dart';

/// Controlled list editor. Only confirmed, valid ingredient snapshots escape.
class RecipeIngredientEditor extends StatelessWidget {
  const RecipeIngredientEditor({
    super.key,
    required this.ingredients,
    required this.onChanged,
    this.productService,
  });

  final List<RecipeIngredient> ingredients;
  final ValueChanged<List<RecipeIngredient>> onChanged;
  final ProductLookupService? productService;

  Future<void> _edit(BuildContext context, [int? index]) async {
    final ingredient = await showEatovaSheet<RecipeIngredient>(
      context,
      _IngredientSheet(
        initial: index == null ? null : ingredients[index],
        productService: productService ?? const OpenFoodFactsProductService(),
      ),
    );
    if (!context.mounted || ingredient == null) return;
    final updated = [...ingredients];
    if (index == null) {
      if (updated.length >= RecipeIngredient.maxIngredients) return;
      updated.add(ingredient);
    } else {
      updated[index] = ingredient;
    }
    onChanged(List.unmodifiable(updated));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ingredients.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t.ingredientEmpty,
              style: AppType.ui(14, color: context.t.ink2, height: 1.4),
            ),
          ),
        // One soft card per ingredient, spaced instead of divided.
        for (var i = 0; i < ingredients.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _IngredientRow(
              ingredient: ingredients[i],
              editKey: ValueKey('ingredient-edit-$i'),
              removeKey: ValueKey('ingredient-remove-$i'),
              onEdit: () => _edit(context, i),
              onRemove: () => onChanged(
                List.unmodifiable([...ingredients]..removeAt(i)),
              ),
            ),
          ),
        if (ingredients.isNotEmpty) const SizedBox(height: 4),
        SoftPillButton(
          key: const ValueKey('ingredient-add'),
          label: t.ingredientAdd,
          icon: Icons.add_rounded,
          expand: true,
          onTap: ingredients.length < RecipeIngredient.maxIngredients
              ? () => _edit(context)
              : null,
        ),
        if (ingredients.length >= RecipeIngredient.maxIngredients) ...[
          const SizedBox(height: 8),
          Text(t.ingredientLimit, style: AppType.ui(12, color: context.t.ink2)),
        ],
      ],
    );
  }
}

/// One weighed ingredient in the meal-row language: name, the weight as the
/// muted line, its kcal share on the right, then edit and remove.
class _IngredientRow extends StatelessWidget {
  const _IngredientRow({
    required this.ingredient,
    required this.editKey,
    required this.removeKey,
    required this.onEdit,
    required this.onRemove,
  });

  final RecipeIngredient ingredient;
  final Key editKey, removeKey;
  final VoidCallback onEdit, onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final kcal100 = ingredient.per100g.caloriesKcal;
    final kcal = kcal100 == null
        ? null
        : (kcal100 * ingredient.grams / 100).round();
    // Large text: the kcal moves under the name so the name keeps its width.
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
    final value = kcal == null
        ? null
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$kcal',
                  style: AppType.ui(15, weight: FontWeight.w700, color: t.ink)
                      .copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
                TextSpan(
                  text: ' kcal',
                  style: AppType.ui(12, weight: FontWeight.w500, color: t.ink3),
                ),
              ],
            ),
          );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: t.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ingredient.displayName(l10n),
                  style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_numberText(ingredient.grams, l10n)} g',
                  style: AppType.ui(
                    12.5,
                    weight: FontWeight.w500,
                    color: t.ink3,
                  ),
                ),
                if (!ingredient.per100g.isComplete) ...[
                  const SizedBox(height: 2),
                  Text(
                    l10n.ingredientIncomplete,
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w600,
                      color: t.warning,
                    ),
                  ),
                ],
                if (stacked && value != null) ...[
                  const SizedBox(height: 4),
                  value,
                ],
              ],
            ),
          ),
          if (!stacked && value != null) ...[
            const SizedBox(width: 10),
            value,
          ],
          const SizedBox(width: 6),
          _RoundIconButton(
            buttonKey: editKey,
            tooltip: l10n.ingredientEdit,
            icon: Icons.edit_rounded,
            onPressed: onEdit,
          ),
          _RoundIconButton(
            buttonKey: removeKey,
            tooltip: l10n.ingredientRemove,
            icon: Icons.close_rounded,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// The round surf2 icon button of the sheets (close, edit, remove).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(backgroundColor: t.surf2),
      icon: Icon(icon, size: 18, color: t.ink2),
    );
  }
}

/// A product hit in the meal-row language: packshot (or letter) tile, name,
/// brand, and the kcal per 100 g on the right.
class _ProductResultRow extends StatelessWidget {
  const _ProductResultRow({
    required this.product,
    required this.onTap,
    super.key,
  });

  final ProductSearchResult product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final (title, brand) = mealTitleAndBrand(product.result, l10n);
    // The value [_IngredientSheetState._select] will carry over.
    final per100 = product.ingredientNutritionPer100g;
    final kcal = per100 != null
        ? per100.caloriesKcal
        : isLoggableKcalPer100G(product.kcalPer100G) ||
              product.result.explicitZeroKcal
        ? product.kcalPer100G
        : null;
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
    final value = kcal == null
        ? Text(
            l10n.ingredientUnknown,
            style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink3),
          )
        : Column(
            crossAxisAlignment: stacked
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              MealKcalValue(number: '${kcal.round()}'),
              Text(
                l10n.foodManualPer100GSuffix,
                style: AppType.ui(11.5, color: t.ink3),
              ),
            ],
          );
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(
              children: [
                MealItemTile(
                  name: title,
                  imageUrl: product.imageUrl,
                  justAdded: false,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: stacked ? null : 2,
                        overflow: stacked ? null : TextOverflow.ellipsis,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      if (brand != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          brand,
                          style: AppType.ui(
                            12.5,
                            weight: FontWeight.w500,
                            color: t.ink3,
                          ),
                        ),
                      ],
                      if (stacked) ...[const SizedBox(height: 4), value],
                    ],
                  ),
                ),
                if (!stacked) ...[const SizedBox(width: 10), value],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IngredientSheet extends StatefulWidget {
  const _IngredientSheet({required this.productService, this.initial});
  final ProductLookupService productService;
  final RecipeIngredient? initial;

  @override
  State<_IngredientSheet> createState() => _IngredientSheetState();
}

class _IngredientSheetState extends State<_IngredientSheet> {
  final _query = TextEditingController();
  late final List<TextEditingController> _fields;
  RecipeIngredient? _original;
  bool _form = false,
      _searching = false,
      _searched = false,
      _searchError = false;
  bool _nutritionEdited = false;
  int _searchEpoch = 0;
  List<ProductSearchResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _original = widget.initial;
    _form = widget.initial != null;
    _fields = List.generate(6, (_) => TextEditingController());
  }

  bool _filled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The prefill uses the locale's decimal separator, unreadable in
    // initState. Runs once, before the first build.
    if (!_filled) {
      _filled = true;
      _fill(widget.initial);
    }
  }

  void _fill(RecipeIngredient? ingredient) {
    final n = ingredient?.per100g;
    final l10n = context.l10n;
    final values = [
      ingredient?.name ?? _query.text.trim(),
      _inputText(ingredient?.grams ?? 100, l10n),
      _inputText(n?.caloriesKcal, l10n),
      _inputText(n?.proteinG, l10n),
      _inputText(n?.carbsG, l10n),
      _inputText(n?.fatG, l10n),
    ];
    for (var i = 0; i < _fields.length; i++) {
      _fields[i].text = values[i];
    }
    _original = ingredient;
    _nutritionEdited = false;
  }

  @override
  void dispose() {
    _query.dispose();
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  NumberInput _input(int index) => NumberInput.parse(_fields[index].text);

  double? _value(int index) => _input(index).value;

  RecipeIngredient? get _draft {
    try {
      for (var i = 2; i < 6; i++) {
        if (_fields[i].text.trim().isNotEmpty && _value(i) == null) return null;
      }
      return RecipeIngredient(
        name: _fields[0].text,
        grams: _value(1) ?? 0,
        per100g: RecipeNutrition(
          caloriesKcal: _value(2),
          proteinG: _value(3),
          carbsG: _value(4),
          fatG: _value(5),
        ),
        source: _nutritionEdited
            ? IngredientSource.manual
            : _original?.source ?? IngredientSource.manual,
        productCode: _nutritionEdited ? null : _original?.productCode,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.length < 2 || _searching) return;
    final epoch = ++_searchEpoch;
    setState(() {
      _searching = true;
      _searchError = false;
      _results = const [];
    });
    try {
      final results = await widget.productService.searchProducts(query);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _results = results.take(20).toList();
        _searched = true;
      });
    } catch (_) {
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchError = true;
      });
    } finally {
      if (mounted && epoch == _searchEpoch) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  void _select(ProductSearchResult product) {
    final code = RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(product.code)
        ? product.code
        : null;
    try {
      final ingredient = RecipeIngredient(
        name: product.title,
        grams: 100,
        per100g:
            product.ingredientNutritionPer100g ??
            RecipeNutrition(
              caloriesKcal:
                  isLoggableKcalPer100G(product.kcalPer100G) ||
                      product.result.explicitZeroKcal
                  ? product.kcalPer100G
                  : null,
            ),
        source: IngredientSource.openFoodFacts,
        productCode: code,
      );
      setState(() {
        _fill(ingredient);
        _form = true;
      });
    } on FormatException {
      setState(() {
        _searchError = true;
      });
    }
  }

  String? _error(int index) {
    final text = _fields[index].text.trim();
    if (text.isEmpty) return null;
    if (index == 0) {
      return text.runes.length > 160 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)
          ? context.l10n.ingredientNameError
          : null;
    }
    final hint = numberInputHint(_input(index), context.l10n);
    if (hint != null) return hint;
    final value = _value(index);
    final min = index == 1 ? 0.001 : 0.0;
    final max = index == 1
        ? 10000.0
        : index == 2
        ? 900.0
        : 100.0;
    return value == null || !value.isFinite || value < min || value > max
        ? context.l10n.ingredientNumberError(
            _numberText(min, context.l10n),
            _numberText(max, context.l10n),
          )
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    if (!_form) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.ingredientAdd,
              style: AppType.display(24, color: context.t.ink),
            ),
            const SizedBox(height: 12),
            SheetField(
              label: t.ingredientSearch,
              hint: t.ingredientSearchHint,
              controller: _query,
              fieldKey: const ValueKey('ingredient-query'),
              maxLength: 100,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              onChanged: (_) => setState(() {
                _searchEpoch++;
                _searching = false;
                _searched = false;
                _searchError = false;
                _results = const [];
              }),
            ),
            PrimaryActionButton(
              key: const ValueKey('ingredient-search-submit'),
              label: t.ingredientSearch,
              icon: Icons.search_rounded,
              onTap: _searching || _query.text.trim().length < 2
                  ? null
                  : _search,
            ),
            const SizedBox(height: 10),
            SoftPillButton(
              key: const ValueKey('ingredient-manual'),
              label: t.ingredientManual,
              icon: Icons.edit_rounded,
              expand: true,
              onTap: () => setState(() {
                _fill(null);
                _form = true;
              }),
            ),
            if (_searching) ...[
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                label: t.ingredientSearching,
                child: Center(
                  child: CircularProgressIndicator(color: context.t.accent),
                ),
              ),
            ],
            if (_searchError) ...[
              const SizedBox(height: 16),
              Text(
                t.ingredientSearchError,
                style: AppType.ui(14, color: context.t.danger, height: 1.4),
              ),
            ],
            if (_searched &&
                !_searching &&
                _results.isEmpty &&
                !_searchError) ...[
              const SizedBox(height: 16),
              Text(
                t.ingredientNoResults,
                style: AppType.ui(14, color: context.t.ink2, height: 1.4),
              ),
            ],
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 16),
              SavedMealCollection(
                children: [
                  for (var i = 0; i < _results.length; i++)
                    _ProductResultRow(
                      key: ValueKey('ingredient-result-$i'),
                      product: _results[i],
                      onTap: () => _select(_results[i]),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            SoftPillButton(
              label: t.commonCancel,
              tone: SoftPillTone.neutral,
              expand: true,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }
    final labels = [
      t.ingredientName,
      t.ingredientGrams,
      t.ingredientKcal,
      t.ingredientProtein,
      t.ingredientCarbs,
      t.ingredientFat,
    ];
    return SheetScaffold(
      title: widget.initial == null ? t.ingredientAdd : t.ingredientEdit,
      subtitle: t.ingredientPer100Help,
      actionLabel: t.ingredientSave,
      actionEnabled: _draft != null,
      onAction: () {
        final draft = _draft;
        if (draft != null) Navigator.of(context).pop(draft);
      },
      children: [
        for (var i = 0; i < _fields.length; i++)
          SheetField(
            label: labels[i],
            hint: i == 0
                ? t.ingredientNameHint
                : i == 1
                ? '100'
                : t.ingredientUnknown,
            fieldKey: ValueKey('ingredient-field-$i'),
            controller: _fields[i],
            keyboardType: i == 0
                ? TextInputType.text
                : const TextInputType.numberWithOptions(decimal: true),
            maxLength: i == 0 ? 160 : 24,
            errorText: _error(i),
            onChanged: (_) => setState(() {
              if (i != 1) _nutritionEdited = true;
            }),
          ),
        if (_draft != null && !_draft!.per100g.isComplete)
          Text(
            t.ingredientIncompleteHelp,
            style: AppType.ui(13, color: context.t.ink2, height: 1.4),
          ),
        const SizedBox(height: 12),
        SoftPillButton(
          label: t.commonCancel,
          tone: SoftPillTone.neutral,
          expand: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Six fraction digits keep imported per-100 g values intact in the fields.
String _numberText(double? n, AppLocalizations l10n) =>
    n == null ? '' : formatDecimal(n, l10n, maxFractionDigits: 6);

/// [_numberText] for a field prefill: reads back as the same number.
String _inputText(double? n, AppLocalizations l10n) =>
    n == null ? '' : formatDecimalInput(n, l10n, maxFractionDigits: 6);
