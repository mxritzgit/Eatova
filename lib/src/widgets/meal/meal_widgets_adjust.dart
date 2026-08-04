part of 'meal_widgets.dart';

Future<Object?> showWeightAdjustmentSheet(
  BuildContext context,
  MealAnalysisResult result,
) {
  return showModalBottomSheet<Object>(
    context: context,
    backgroundColor: surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _MealItemAdjustmentSheet(result: result),
  );
}

class _MealWeightAdjustmentSheet extends StatefulWidget {
  const _MealWeightAdjustmentSheet({required this.result});

  final MealAnalysisResult result;

  @override
  State<_MealWeightAdjustmentSheet> createState() =>
      _MealWeightAdjustmentSheetState();
}

class _MealWeightAdjustmentSheetState extends State<_MealWeightAdjustmentSheet> {
  late final TextEditingController _controller;
  late int _grams;

  @override
  void initState() {
    super.initState();
    _grams = widget.result.estimatedGrams;
    _controller = TextEditingController(text: _grams.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final kcal = (result.kcalPer100G * _grams / 100).round();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Portion anpassen',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${result.mealName} · ${result.kcalPer100Label}',
            style: const TextStyle(
              color: textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            key: const ValueKey('analyse-weight-input'),
            cursorOpacityAnimates: false,
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Gewicht in Gramm',
              suffixText: 'g',
            ),
            onChanged: (value) {
              setState(() {
                _grams = int.tryParse(value) ?? widget.result.estimatedGrams;
              });
            },
          ),
          const SizedBox(height: 14),
          Container(
            key: const ValueKey('analyse-adjusted-kcal-preview'),
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: surfaceSoft,
              borderRadius: BorderRadius.circular(rControl),
              border: Border.all(color: orange.withValues(alpha: 0.18)),
            ),
            child: Text(
              '$_grams g ≈ $kcal kcal',
              style: const TextStyle(
                color: orange,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('analyse-save-weight-button'),
              onPressed: _grams <= 0 ? null : () => Navigator.pop(context, _grams),
              icon: const Icon(Icons.check_rounded, size: 17),
              label: const Text(
                'Übernehmen',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: orange,
                foregroundColor: bg,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MealItemAdjustmentSheet extends StatefulWidget {
  const _MealItemAdjustmentSheet({required this.result});

  final MealAnalysisResult result;

  @override
  State<_MealItemAdjustmentSheet> createState() => _MealItemAdjustmentSheetState();
}

class _MealItemAdjustmentSheetState extends State<_MealItemAdjustmentSheet> {
  late final List<MealComponent> _items;
  late final List<TextEditingController> _controllers;
  late final List<int> _grams;
  Set<int> _removed = const <int>{};

  @override
  void initState() {
    super.initState();
    // Fall back to a single synthesized item when the AI didn't return any
    // itemized breakdown (or for OpenFoodFacts barcode lookups). The user can
    // then still edit the weight, remove it, or split it into multiple items
    // via "Bestandteil hinzufügen".
    if (widget.result.items.isNotEmpty) {
      _items = [...widget.result.items];
    } else {
      _items = [
        MealComponent(
          name: widget.result.mealName,
          grams: widget.result.estimatedGrams,
          caloriesKcal: widget.result.caloriesKcal,
          kcalPer100G: widget.result.kcalPer100G,
        ),
      ];
    }
    _grams = _items.map((item) => item.grams).toList(growable: true);
    _controllers = _grams
        .map((grams) => TextEditingController(text: grams.toString()))
        .toList(growable: true);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _remove(int index) {
    setState(() => _removed = {..._removed, index});
  }

  void _undoRemove(int index) {
    setState(() => _removed = {..._removed}..remove(index));
  }

  void _appendItem(MealComponent item) {
    setState(() {
      _items.add(item);
      _grams.add(item.grams);
      _controllers.add(TextEditingController(text: item.grams.toString()));
    });
  }

  Future<void> _addItemDialog() async {
    final newItem = await showDialog<MealComponent>(
      context: context,
      builder: (context) => const _AddItemDialog(),
    );
    if (newItem != null) {
      _appendItem(newItem);
    }
  }

  int _itemKcalFor(int index) {
    final item = _items[index];
    final grams = _grams[index];
    final per100 = item.kcalPer100G;
    if (per100 != null && per100 > 0) {
      return (per100 * grams / 100).round();
    }
    if (item.grams > 0) {
      return (item.caloriesKcal * grams / item.grams).round();
    }
    return item.caloriesKcal;
  }

  String _statusLine(int addedCount) {
    final parts = <String>[];
    if (_removed.isNotEmpty) parts.add('${_removed.length} entfernt');
    if (addedCount > 0) parts.add('$addedCount manuell ergänzt');
    if (parts.isEmpty) {
      return 'Pro Lebensmittel das Gewicht anpassen oder mit X entfernen.';
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final adjustedItems = <MealComponent>[
      for (var index = 0; index < _items.length; index++)
        if (!_removed.contains(index))
          _items[index].adjustedToGrams(_grams[index]),
    ];
    final totalGrams = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.grams,
    );
    final totalKcal = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.caloriesKcal,
    );
    final invalidGrams = [
      for (var index = 0; index < _items.length; index++)
        if (!_removed.contains(index) && _grams[index] <= 0) index,
    ];
    final canSave = adjustedItems.isNotEmpty && invalidGrams.isEmpty;
    final addedCount = _items.length - widget.result.items.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Bestandteile anpassen',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _statusLine(addedCount),
              style: const TextStyle(
                color: textMuted,
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 18),
            for (var index = 0; index < _items.length; index++) ...[
              if (_removed.contains(index))
                _RemovedItemCard(
                  name: _items[index].name,
                  onUndo: () => _undoRemove(index),
                )
              else
                _ItemEditCard(
                  index: index,
                  item: _items[index],
                  controller: _controllers[index],
                  liveKcal: _itemKcalFor(index),
                  liveGrams: _grams[index],
                  onGramsChanged: (g) =>
                      setState(() => _grams[index] = g),
                  onRemove: () => _remove(index),
                ),
              const SizedBox(height: 10),
            ],
            OutlinedButton.icon(
              key: const ValueKey('analyse-item-add-button'),
              onPressed: _addItemDialog,
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text(
                'Bestandteil hinzufügen',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: cyan,
                side: BorderSide(color: cyan.withValues(alpha: 0.45)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              key: const ValueKey('analyse-adjusted-kcal-preview'),
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: surfaceSoft,
                borderRadius: BorderRadius.circular(rControl),
                border: Border.all(color: orange.withValues(alpha: 0.18)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calculate_outlined,
                    color: orange,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$totalGrams g ≈ $totalKcal kcal',
                      style: const TextStyle(
                        color: orange,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (adjustedItems.isNotEmpty)
                    Text(
                      '${adjustedItems.length} Posten',
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
            if (adjustedItems.isEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Mindestens ein Bestandteil muss übrig bleiben.',
                style: TextStyle(
                  color: warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('analyse-save-weight-button'),
                onPressed: canSave
                    ? () => Navigator.pop(context, adjustedItems)
                    : null,
                icon: const Icon(Icons.check_rounded, size: 17),
                label: const Text(
                  'Übernehmen',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: orange,
                  foregroundColor: bg,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
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

class _ItemEditCard extends StatelessWidget {
  const _ItemEditCard({
    required this.index,
    required this.item,
    required this.controller,
    required this.liveKcal,
    required this.liveGrams,
    required this.onGramsChanged,
    required this.onRemove,
  });

  final int index;
  final MealComponent item;
  final TextEditingController controller;
  final int liveKcal;
  final int liveGrams;
  final ValueChanged<int> onGramsChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('analyse-item-card-$index'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('analyse-item-remove-$index'),
                onPressed: onRemove,
                tooltip: 'Entfernen',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: textMuted,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: TextField(
              key: ValueKey('analyse-item-weight-input-$index'),
              cursorOpacityAnimates: false,
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Gewicht',
                suffixText: 'g',
                helperText:
                    'Ursprünglich ${item.gramsLabel} · ${item.caloriesLabel}',
                helperStyle: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value) ?? 0;
                onGramsChanged(parsed);
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.local_fire_department_outlined,
                  size: 14,
                  color: orange,
                ),
                const SizedBox(width: 6),
                Text(
                  '$liveGrams g · $liveKcal kcal',
                  style: const TextStyle(
                    color: orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (item.kcalPer100G != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ${item.kcalPer100G!.round()} kcal/100g',
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RemovedItemCard extends StatelessWidget {
  const _RemovedItemCard({required this.name, required this.onUndo});

  final String name;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: surfaceSoft.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textMuted,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              foregroundColor: cyan,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: const Text(
              'Wiederherstellen',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final _name = TextEditingController();
  final _grams = TextEditingController();
  final _kcal = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _grams.dispose();
    _kcal.dispose();
    super.dispose();
  }

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    final g = int.tryParse(_grams.text.trim());
    final k = int.tryParse(_kcal.text.trim());
    return g != null && g > 0 && k != null && k >= 0;
  }

  void _submit() {
    final name = _name.text.trim();
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    if (name.isEmpty || grams <= 0) return;
    final per100 = grams > 0 ? kcal * 100 / grams : null;
    Navigator.pop(
      context,
      MealComponent(
        name: name,
        grams: grams,
        caloriesKcal: kcal,
        kcalPer100G: per100,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSheet)),
      title: const Text(
        'Bestandteil hinzufügen',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Manuell — wenn die KI etwas übersehen hat.',
              style: TextStyle(
                color: textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('analyse-add-item-name'),
              cursorOpacityAnimates: false,
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'z. B. Tomate',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analyse-add-item-grams'),
                    cursorOpacityAnimates: false,
                    controller: _grams,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Gewicht',
                      suffixText: 'g',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey('analyse-add-item-kcal'),
                    cursorOpacityAnimates: false,
                    controller: _kcal,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Kalorien',
                      suffixText: 'kcal',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: textMuted),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          key: const ValueKey('analyse-add-item-save'),
          onPressed: _isValid ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: cyan,
            foregroundColor: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rControl),
            ),
          ),
          child: const Text(
            'Hinzufügen',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
