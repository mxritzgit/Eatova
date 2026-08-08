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

  /// Tragen ALLE Posten, die uebrig bleiben, vollstaendige Makros?
  ///
  /// Genau diese Bedingung entscheidet in
  /// [MealAnalysisResult.adjustedToItems], ob die Makros der Mahlzeit exakt
  /// aufsummiert werden oder als "unbekannt" gelten. Der Dialog braucht sie,
  /// um dem Nutzer die Folge seiner Eingabe **vorher** sagen zu koennen.
  /// Leere Auswahl ergibt bewusst `true` — genau wie `every` auf einer leeren
  /// Liste. Wer alle Posten entfernt und einen neuen mit Makros anlegt, hat
  /// danach eine Mahlzeit, deren einziger Posten Makros traegt; die Summe
  /// greift dann sehr wohl.
  bool get _restTraegtMakros {
    for (var index = 0; index < _items.length; index++) {
      if (_removed.contains(index)) continue;
      if (!_items[index].hasMacros) return false;
    }
    return true;
  }

  Future<void> _addItemDialog() async {
    final newItem = await showDialog<MealComponent>(
      context: context,
      builder: (context) =>
          _AddItemDialog(restTraegtMakros: _restTraegtMakros),
    );
    if (newItem != null) {
      _appendItem(newItem);
    }
  }

  /// Der Posten [index], umgerechnet auf das aktuell eingetippte Gewicht.
  ///
  /// **Eine** Rechnung fuer Vorschau, Gesamtzeile und Speicherpfad. Genau die
  /// Doppelung war B1: `_itemKcalFor` bevorzugte `kcalPer100G`, waehrend
  /// [MealComponent.adjustedToGrams] seit Welle 2 `caloriesKcal` als
  /// autoritativ behandelt und die Dichte nur als Rueckfallebene nimmt. Bei
  /// einem Posten, dessen Dichte nicht zu Gramm und Kalorien passt
  /// ({100 g, 521 kcal, 2180 kcal/100 g}), zeigte die Zeile auf 30 g deshalb
  /// 654 kcal, gespeichert wurden 156.
  ///
  /// Delegieren statt die Formel abzuschreiben: eine Kopie kann wieder
  /// auseinanderlaufen, und `adjustedToGrams` bringt zusaetzlich die Clamps
  /// (1..10000 g, 0..10000 kcal) mit — ohne sie zeigte die Zeile bei einer
  /// abwegigen Eingabe erneut etwas anderes als die Summe darunter.
  MealComponent _adjustedItem(int index) =>
      _items[index].adjustedToGrams(_grams[index]);

  int _itemKcalFor(int index) {
    // 0 g ist ein ungueltiger Zwischenstand (das Uebernehmen ist dann
    // gesperrt). `adjustedToGrams` wuerde auf die Mindestportion 1 g klemmen
    // und damit neben der getippten 0 eine Kalorienzahl zeigen.
    if (_grams[index] <= 0) return 0;
    return _adjustedItem(index).caloriesKcal;
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
        if (!_removed.contains(index)) _adjustedItem(index),
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

/// Obergrenze fuer ein Makro eines einzelnen Postens, in Gramm.
///
/// Spiegelt `LoggedMealLimits.macroGMax` aus `models/model_limits.dart`.
/// Bewusst als lokale Konstante: diese Datei ist ein `part of
/// 'meal_widgets.dart'` und kann selbst nichts importieren, und die
/// Bibliotheks-Datei mit den Importen gehoert einem anderen Arbeitsstrang.
/// Getippte Werte werden hier **abgelehnt statt geklemmt** — so will es die
/// Doku in `model_limits.dart` fuer alles, was der Nutzer selbst eingibt.
const double _makroMaxG = 1000;

/// Ein Makro-Eingabefeld: optional, Gramm, Dezimaltrennung per Komma ODER
/// Punkt. Bewusst nicht `digitsOnly` — 0,5 g Fett muss eingebbar sein.
class _MacroField extends StatelessWidget {
  const _MacroField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      cursorOpacityAnimates: false,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      decoration: InputDecoration(labelText: label, suffixText: 'g'),
      onChanged: (_) => onChanged(),
    );
  }
}

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog({required this.restTraegtMakros});

  /// Tragen die uebrigen Posten der Mahlzeit bereits vollstaendige Makros?
  /// Nur dann kann die Mahlzeit ihre Makros ueberhaupt behalten, wenn dieser
  /// Posten welche mitbringt — sonst waere jedes Versprechen hier gelogen.
  final bool restTraegtMakros;

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final _name = TextEditingController();
  final _grams = TextEditingController();
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();

  /// Die Makro-Felder sind eingeklappt. Der haeufige Fall ("ich hab noch Brot
  /// dazu") bleibt damit drei Felder lang; wer genauer sein will, klappt auf.
  bool _makrosOffen = false;

  @override
  void dispose() {
    _name.dispose();
    _grams.dispose();
    _kcal.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  /// Liest ein Makro-Feld: leer -> `null` ("unbekannt"), sonst die Zahl.
  ///
  /// `null` und `0` sind ausdruecklich **nicht** dasselbe. Wer das Feld leer
  /// laesst, sagt "weiss ich nicht"; wer 0 eintippt, sagt "davon ist nichts
  /// drin". [MealComponent.hasMacros] unterscheidet genau daran.
  static double? _makro(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  /// `true`, wenn das Feld leer ist ODER eine Zahl im erlaubten Bereich traegt.
  static bool _makroFeldOk(TextEditingController controller) {
    if (controller.text.trim().isEmpty) return true;
    final wert = _makro(controller);
    return wert != null && wert.isFinite && wert >= 0 && wert <= _makroMaxG;
  }

  bool get _alleMakrosGesetzt =>
      _makro(_protein) != null &&
      _makro(_carbs) != null &&
      _makro(_fat) != null;

  bool get _makrosGueltig =>
      _makroFeldOk(_protein) && _makroFeldOk(_carbs) && _makroFeldOk(_fat);

  /// Was die Eingabe fuer die Makros der GANZEN Mahlzeit bedeutet — sichtbar,
  /// bevor der Nutzer auf "Hinzufügen" tippt (B8). Der Wortlaut deckt sich mit
  /// dem, was danach in `portionNotes` steht.
  String get _makroHinweis {
    if (!_alleMakrosGesetzt) {
      return 'Ohne alle drei Angaben werden Protein, Kohlenhydrate und Fett '
          'für die ganze Mahlzeit als „–" ausgewiesen.';
    }
    if (!widget.restTraegtMakros) {
      return 'Andere Bestandteile tragen keine Makros — die Mahlzeit weist '
          'Protein, Kohlenhydrate und Fett weiterhin als „–" aus.';
    }
    return 'Protein, Kohlenhydrate und Fett werden für die Mahlzeit exakt '
        'aufsummiert.';
  }

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    final g = int.tryParse(_grams.text.trim());
    final k = int.tryParse(_kcal.text.trim());
    return g != null && g > 0 && k != null && k >= 0 && _makrosGueltig;
  }

  void _submit() {
    final name = _name.text.trim();
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    if (name.isEmpty || grams <= 0 || !_makrosGueltig) return;
    final per100 = grams > 0 ? kcal * 100 / grams : null;
    Navigator.pop(
      context,
      MealComponent(
        name: name,
        grams: grams,
        caloriesKcal: kcal,
        kcalPer100G: per100,
        proteinG: _makro(_protein),
        carbsG: _makro(_carbs),
        fatG: _makro(_fat),
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
            const SizedBox(height: 4),
            // Aufklappbar statt drei weiterer Pflichtfelder: der schnelle Pfad
            // bleibt Name + Gramm + Kalorien.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('analyse-add-item-macros-toggle'),
                onPressed: () =>
                    setState(() => _makrosOffen = !_makrosOffen),
                style: TextButton.styleFrom(
                  foregroundColor: cyan,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  _makrosOffen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                ),
                label: const Text(
                  'Makros ergänzen (optional)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (_makrosOffen) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _MacroField(
                      fieldKey: const ValueKey('analyse-add-item-protein'),
                      controller: _protein,
                      label: 'Protein',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MacroField(
                      fieldKey: const ValueKey('analyse-add-item-carbs'),
                      controller: _carbs,
                      label: 'Carbs',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MacroField(
                      fieldKey: const ValueKey('analyse-add-item-fat'),
                      controller: _fat,
                      label: 'Fett',
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
              if (!_makrosGueltig) ...[
                const SizedBox(height: 6),
                const Text(
                  'Makros in Gramm, jeweils zwischen 0 und 1000.',
                  style: TextStyle(
                    color: warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 10),
            Text(
              _makroHinweis,
              key: const ValueKey('analyse-add-item-macro-hint'),
              style: const TextStyle(
                color: textMuted,
                fontSize: 11,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
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
