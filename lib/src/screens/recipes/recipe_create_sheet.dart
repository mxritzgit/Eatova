part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// „Eigenes Rezept"-Formular: Bottom-Sheet zum Anlegen eines eigenen Rezepts
// (Name, Portion, Makros, Zutaten) inkl. des rahmenlosen Eingabefelds.
// ---------------------------------------------------------------------------

/// Bottom-Sheet zum Anlegen eines eigenen Rezepts (Name, Portion, Makros,
/// Zutaten). Gibt beim Speichern ein [FitnessRecipe] via Navigator.pop zurück.
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet();

  @override
  State<_CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<_CreateRecipeSheet> {
  final _name = TextEditingController();
  final _portion = TextEditingController(text: '1 Portion');
  final _grams = TextEditingController(text: '300');
  final _kcal = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _ingredients = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _portion.dispose();
    _grams.dispose();
    _kcal.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _ingredients.dispose();
    super.dispose();
  }

  bool get _isValid {
    final kcal = int.tryParse(_kcal.text.trim());
    return _name.text.trim().isNotEmpty && kcal != null && kcal > 0;
  }

  void _save() {
    final name = _name.text.trim();
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    if (name.isEmpty || kcal <= 0) return;
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final ingredients = _ingredients.text.trim();
    final portion = _portion.text.trim().isEmpty
        ? '1 Portion'
        : _portion.text.trim();
    final slug = 'user_${DateTime.now().millisecondsSinceEpoch}';

    Navigator.of(context).pop(
      FitnessRecipe(
        slug: slug,
        title: name,
        description: 'Eigenes Rezept',
        portion: portion,
        ingredients: ingredients.isEmpty ? 'Keine Angabe' : ingredients,
        preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
        professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
        imageAsset: '',
        caloriesKcal: kcal,
        proteinG: int.tryParse(_protein.text.trim()) ?? 0,
        carbsG: int.tryParse(_carbs.text.trim()) ?? 0,
        fatG: int.tryParse(_fat.text.trim()) ?? 0,
        estimatedGrams: grams > 0 ? grams : 100,
        categories: const <String>['Eigene'],
        userCreated: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        key: const ValueKey('recipe-create-sheet'),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: hairline,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Eigenes Rezept',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Name und Kalorien genügen — Makros sind optional.',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 12.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 18),
              _Field(
                fieldKey: const ValueKey('recipe-create-name'),
                controller: _name,
                label: 'Name',
                hint: 'z. B. Protein-Bowl',
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 12),
              _Field(
                fieldKey: const ValueKey('recipe-create-portion'),
                controller: _portion,
                label: 'Portion',
                hint: '1 Teller',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-kcal'),
                      controller: _kcal,
                      label: 'Kalorien',
                      suffix: 'kcal',
                      numeric: true,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-grams'),
                      controller: _grams,
                      label: 'Gewicht',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-protein'),
                      controller: _protein,
                      label: 'Protein',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-carbs'),
                      controller: _carbs,
                      label: 'KH',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Field(
                      fieldKey: const ValueKey('recipe-create-fat'),
                      controller: _fat,
                      label: 'Fett',
                      suffix: 'g',
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Field(
                fieldKey: const ValueKey('recipe-create-ingredients'),
                controller: _ingredients,
                label: 'Zutaten',
                hint: 'Eine Zutat pro Zeile',
                maxLines: 4,
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  key: const ValueKey('recipe-create-save'),
                  onPressed: _isValid ? _save : null,
                  icon: const Icon(Icons.check_rounded, size: 19),
                  label: const Text(
                    'Rezept speichern',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: lime,
                    foregroundColor: bg,
                    disabledBackgroundColor: surfaceSoft,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.suffix,
    this.numeric = false,
    this.maxLines = 1,
    this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? suffix;
  final bool numeric;
  final int maxLines;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      cursorOpacityAnimates: false,
      controller: controller,
      maxLines: maxLines,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters:
          numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
      textCapitalization: numeric
          ? TextCapitalization.none
          : TextCapitalization.sentences,
      style: const TextStyle(color: textPrimary, fontSize: 14),
      cursorColor: lime,
      onChanged: onChanged == null ? null : (_) => onChanged!(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
      ),
    );
  }
}
