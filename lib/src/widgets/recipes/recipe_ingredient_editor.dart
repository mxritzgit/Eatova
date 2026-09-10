import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/recipe_ingredient.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../design/design.dart';

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
              style: AppType.ui(14, color: context.t.ink2),
            ),
          ),
        for (var i = 0; i < ingredients.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ingredients[i].name,
                        style: AppType.ui(15, color: context.t.ink),
                      ),
                      Text(
                        '${_numberText(ingredients[i].grams)} g',
                        style: AppType.ui(14, color: context.t.ink2),
                      ),
                      if (!ingredients[i].per100g.isComplete)
                        Text(
                          t.ingredientIncomplete,
                          style: AppType.ui(12, color: context.t.warning),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('ingredient-edit-$i'),
                  tooltip: t.ingredientEdit,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _edit(context, i),
                ),
                IconButton(
                  key: ValueKey('ingredient-remove-$i'),
                  tooltip: t.ingredientRemove,
                  icon: const Icon(Icons.close),
                  onPressed: () => onChanged(
                    List.unmodifiable([...ingredients]..removeAt(i)),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: context.t.line),
        ],
        TextButton.icon(
          key: const ValueKey('ingredient-add'),
          onPressed: ingredients.length < RecipeIngredient.maxIngredients
              ? () => _edit(context)
              : null,
          icon: const Icon(Icons.add),
          label: Text(t.ingredientAdd),
        ),
        if (ingredients.length >= RecipeIngredient.maxIngredients)
          Text(t.ingredientLimit, style: AppType.ui(12, color: context.t.ink2)),
      ],
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
    _fill(widget.initial);
  }

  void _fill(RecipeIngredient? ingredient) {
    final n = ingredient?.per100g;
    final values = [
      ingredient?.name ?? _query.text.trim(),
      _numberText(ingredient?.grams ?? 100),
      _numberText(n?.caloriesKcal),
      _numberText(n?.proteinG),
      _numberText(n?.carbsG),
      _numberText(n?.fatG),
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

  double? _value(int index) =>
      double.tryParse(_fields[index].text.trim().replaceAll(',', '.'));

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
    final value = _value(index);
    final min = index == 1 ? 0.001 : 0.0;
    final max = index == 1
        ? 10000.0
        : index == 2
        ? 900.0
        : 100.0;
    return value == null || !value.isFinite || value < min || value > max
        ? context.l10n.ingredientNumberError(_numberText(min), _numberText(max))
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
              onTap: _searching || _query.text.trim().length < 2
                  ? null
                  : _search,
            ),
            TextButton(
              key: const ValueKey('ingredient-manual'),
              onPressed: () => setState(() {
                _fill(null);
                _form = true;
              }),
              child: Text(t.ingredientManual),
            ),
            if (_searching) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                label: t.ingredientSearching,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ],
            if (_searchError)
              Text(
                t.ingredientSearchError,
                style: AppType.ui(14, color: context.t.danger),
              ),
            if (_searched && !_searching && _results.isEmpty && !_searchError)
              Text(
                t.ingredientNoResults,
                style: AppType.ui(14, color: context.t.ink2),
              ),
            for (var i = 0; i < _results.length; i++)
              ListTile(
                key: ValueKey('ingredient-result-$i'),
                contentPadding: EdgeInsets.zero,
                title: Text(_results[i].title),
                subtitle: Text(_results[i].subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _select(_results[i]),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.commonCancel),
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
            style: AppType.ui(13, color: context.t.ink2),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.commonCancel),
        ),
      ],
    );
  }
}

String _numberText(double? n) => n == null
    ? ''
    : n == n.roundToDouble()
    ? '${n.round()}'
    : '$n';
