part of 'meal_describe_sheet.dart';

// The draft step: one row per food with its origin, the totals with Edit and
// Add, and the line editor (candidates, grams, remove).

String _originLabel(DraftItemOrigin origin, AppLocalizations l10n) =>
    switch (origin) {
      DraftItemOrigin.favorite => l10n.foodDescribeOriginFavorite,
      DraftItemOrigin.product => l10n.foodDescribeOriginProduct,
      DraftItemOrigin.estimate => l10n.foodDescribeOriginEstimate,
    };

/// A candidate's name and brand, each shown once: product and favorite
/// titles carry the brand ("Nutella · Ferrero"), which moves to the detail
/// line like in the add sheet's search hits. Estimates have no brand; an
/// empty title falls back to the described name.
(String title, String? brand) _candidateName(
  DraftCandidate candidate,
  DraftFoodItem item,
) {
  var title = candidate.title.trim();
  if (title.isEmpty) title = item.described.name;
  final brand = candidate.brand?.trim();
  if (brand == null || brand.isEmpty) return (title, null);
  final suffix = ' · $brand';
  if (title.endsWith(suffix) && title.length > suffix.length) {
    return (title.substring(0, title.length - suffix.length), brand);
  }
  return title.toLowerCase().contains(brand.toLowerCase())
      ? (title, null)
      : (title, brand);
}

/// "Ferrero · 15 g", or just [tail] without a brand.
String _withBrand(String? brand, String tail) =>
    brand == null ? tail : '$brand · $tail';

class _DraftView extends StatelessWidget {
  const _DraftView({
    required this.draft,
    required this.description,
    required this.onEditText,
    required this.onEditLine,
  });

  final MealDescriptionDraft draft;
  final String description;
  final VoidCallback onEditText;
  final ValueChanged<int> onEditLine;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final items = draft.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _DescriptionText(text: description)),
            const SizedBox(width: 4),
            IconButton(
              key: const ValueKey('meal-describe-edit-description'),
              tooltip: l10n.foodDescribeEditText,
              onPressed: onEditText,
              icon: Icon(Icons.edit_outlined, color: t.accentText, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Align(
            alignment: Alignment.centerLeft,
            child: HeadingSemantics(
              level: 2,
              child: Text(
                '${l10n.foodDescribeRecognized} · ${items.length}'
                    .toUpperCase(),
                semanticsLabel:
                    '${l10n.foodDescribeRecognized} ${items.length}',
                style: AppType.sectionEyebrow(t.ink2),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          _EmptyDraft(onEditText: onEditText)
        else
          SavedMealCollection(
            children: [
              for (var i = 0; i < items.length; i++)
                _DraftLineRow(
                  key: ValueKey('meal-describe-line-$i'),
                  item: items[i],
                  onTap: () => onEditLine(i),
                ),
            ],
          ),
      ],
    );
  }
}

/// A Food diary row: letter tile, name, origin and amount, kcal, chevron.
/// The whole row opens the line editor.
class _DraftLineRow extends StatelessWidget {
  const _DraftLineRow({super.key, required this.item, required this.onTap});

  final DraftFoodItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final (title, brand) = _candidateName(item.selected, item);
    final detail = _withBrand(brand, '${item.grams} g');
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 21;
    final kcal = MealKcalValue(number: '${item.caloriesKcal}');
    return Semantics(
      button: true,
      label: l10n.foodDescribeLineSemantics(
        title,
        item.grams,
        item.caloriesKcal,
        _originLabel(item.selected.origin, l10n),
      ),
      hint: l10n.foodDescribeLineHint,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 11, 8, 11),
            child: Row(
              children: [
                MealItemTile(name: title, justAdded: false),
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
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _OriginBadge(origin: item.selected.origin),
                          Text(
                            detail,
                            style: AppType.ui(
                              12.5,
                              weight: FontWeight.w500,
                              color: t.ink3,
                            ),
                          ),
                        ],
                      ),
                      if (stacked) ...[const SizedBox(height: 6), kcal],
                    ],
                  ),
                ),
                if (!stacked) ...[const SizedBox(width: 10), kcal],
                const SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded, size: 20, color: t.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a line's numbers come from, said plainly and quietly: a small tag
/// with a dot (violet for a favorite, green for the database, amber for the
/// AI's estimate).
class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.origin});

  final DraftItemOrigin origin;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final dot = switch (origin) {
      DraftItemOrigin.favorite => t.accent,
      DraftItemOrigin.product => t.success,
      DraftItemOrigin.estimate => t.warning,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 2, 8, 2),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              _originLabel(origin, context.l10n),
              style: AppType.ui(11.5, weight: FontWeight.w600, color: t.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every line removed: the way back to the text.
class _EmptyDraft extends StatelessWidget {
  const _EmptyDraft({required this.onEditText});

  final VoidCallback onEditText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('meal-describe-empty'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.playlist_remove_rounded, size: 26, color: t.ink3),
          const SizedBox(height: 10),
          Text(
            l10n.foodDescribeEmpty,
            textAlign: TextAlign.center,
            style: AppType.ui(13.5, color: t.ink2, height: 1.4),
          ),
          const SizedBox(height: 14),
          SoftPillButton(
            label: l10n.foodDescribeEditText,
            icon: Icons.edit_outlined,
            onTap: onEditText,
            expand: true,
          ),
        ],
      ),
    );
  }
}

/// Totals of exactly what Add logs (the draft's result), then Edit and Add.
class _DraftFooter extends StatelessWidget {
  const _DraftFooter({
    required this.draft,
    required this.adding,
    required this.onEdit,
    required this.onAdd,
  });

  final MealDescriptionDraft draft;
  final bool adding;
  final VoidCallback onEdit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final result = draft.toResult();
    final empty = draft.items.isEmpty;
    final loggable = draft.isLoggable;
    final large = MediaQuery.textScalerOf(context).scale(14) > 18;
    final kcal = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${empty ? 0 : result.caloriesKcal}',
            style: AppType.display(28, color: t.onBrandSurface, height: 1.1),
          ),
          TextSpan(
            text: ' kcal',
            style: AppType.ui(14, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
      key: const ValueKey('meal-describe-total-kcal'),
    );
    final macros = empty
        ? const SizedBox.shrink()
        : SavedMealNutrients(result: result);
    final totals = Container(
      key: const ValueKey('meal-describe-totals'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: t.brandSurface,
        borderRadius: BorderRadius.circular(rTile),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.foodDescribeTotal,
            style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
          ),
          const SizedBox(height: 2),
          if (large) ...[
            kcal,
            const SizedBox(height: 6),
            macros,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                kcal,
                const SizedBox(width: 14),
                Expanded(
                  child: Align(alignment: Alignment.centerRight, child: macros),
                ),
              ],
            ),
        ],
      ),
    );
    final edit = SoftPillButton(
      key: const ValueKey('meal-describe-edit'),
      label: l10n.foodDescribeEdit,
      icon: Icons.tune_rounded,
      onTap: empty || adding ? null : onEdit,
      expand: large,
    );
    final add = PrimaryActionButton(
      key: const ValueKey('meal-describe-add'),
      label: l10n.commonAdd,
      icon: Icons.add_rounded,
      onTap: loggable && !adding ? onAdd : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        totals,
        const SizedBox(height: 12),
        if (large) ...[
          edit,
          const SizedBox(height: 10),
          add,
        ] else
          SizedBox(
            height: kPrimaryButtonHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                edit,
                const SizedBox(width: 10),
                Expanded(child: add),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── Line editor ────────────────────────────────────────────────────────────

/// What the line editor closed with; null means unchanged.
class _LineEdit {
  const _LineEdit.update(DraftFoodItem this.item) : removed = false;
  const _LineEdit.remove() : item = null, removed = true;

  final DraftFoodItem? item;
  final bool removed;
}

/// One line: its portion (stepper and typed grams), the candidates it can
/// use, and remove. Applies on "Apply"; closing keeps the line as it was.
class _DraftLineEditor extends StatefulWidget {
  const _DraftLineEditor({required this.item});

  final DraftFoodItem item;

  @override
  State<_DraftLineEditor> createState() => _DraftLineEditorState();
}

class _DraftLineEditorState extends State<_DraftLineEditor> {
  late DraftFoodItem _item = widget.item;
  late final TextEditingController _grams = TextEditingController(
    text: '${widget.item.grams}',
  );

  /// The typed grams are not a plausible portion: Apply locks, a hint says
  /// why. Rejected, never bent into range.
  bool _gramsInvalid = false;

  int get _step => _item.grams < 100 ? 5 : 10;

  @override
  void dispose() {
    _grams.dispose();
    super.dispose();
  }

  void _syncGrams() {
    final text = '${_item.grams}';
    if (_grams.text == text) return;
    _grams.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Stepper ends assert no number, so clamping is right here.
  void _bump(int delta) {
    setState(() {
      _item = _item.withGrams(_item.grams + delta);
      _gramsInvalid = false;
    });
    _syncGrams();
  }

  void _typed(String value) {
    final parsed = NumberInput.parse(value).wholeValue;
    final valid = parsed != null && isPlausiblePortionGrams(parsed);
    setState(() {
      _gramsInvalid = !valid;
      if (valid) _item = _item.withGrams(parsed);
    });
  }

  void _choose(DraftCandidate candidate) {
    if (identical(candidate, _item.selected)) return;
    HapticFeedback.selectionClick();
    setState(() {
      _item = _item.withCandidate(candidate);
      _gramsInvalid = false;
    });
    _syncGrams();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final mediaQuery = MediaQuery.of(context);
    final item = _item;
    final selected = item.selected;
    final (title, brand) = _candidateName(selected, item);
    final said = item.described.amountText?.trim();
    final preview = MealAnalysisResult(
      mealName: title,
      caloriesKcal: item.caloriesKcal,
      estimatedGrams: item.grams,
      kcalPer100G: selected.kcalPer100G,
      protein: MealAnalysisResult.macroForGrams(
        selected.proteinPer100G,
        item.grams,
      ),
      carbs: MealAnalysisResult.macroForGrams(
        selected.carbsPer100G,
        item.grams,
      ),
      fat: MealAnalysisResult.macroForGrams(selected.fatPer100G, item.grams),
      confidence: '',
      portionNotes: '',
    );
    final subtitle = [
      ?brand,
      if (said != null && said.isNotEmpty) l10n.foodDescribeLineSaid(said),
    ].join(' · ');
    return SingleChildScrollView(
      key: const ValueKey('describe-line-editor'),
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + mediaQuery.viewPadding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HeadingSemantics(
                      level: 1,
                      child: Text(
                        title,
                        textScaler: MediaQuery.textScalerOf(
                          context,
                        ).clamp(maxScaleFactor: 1.5),
                        style: AppType.display(22, color: t.ink, height: 1.15),
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: AppType.ui(12.5, color: t.ink2, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l10n.commonClose,
                onPressed: () => Navigator.of(context).pop(),
                style: IconButton.styleFrom(backgroundColor: t.surf2),
                icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            key: const ValueKey('describe-line-portion'),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: t.brandSurface,
              borderRadius: BorderRadius.circular(rCard),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.foodManualGroupPortion,
                  style: AppType.display(18, color: t.onBrandSurface),
                ),
                const SizedBox(height: 14),
                _GramStepper(
                  controller: _grams,
                  invalid: _gramsInvalid,
                  step: _step,
                  onBump: _bump,
                  onChanged: _typed,
                ),
                if (_gramsInvalid) ...[
                  const SizedBox(height: 8),
                  Text(
                    numberInputHint(
                          NumberInput.parse(_grams.text),
                          l10n,
                          wholeNumber: true,
                        ) ??
                        l10n.foodPortionRangeHint(
                          PlausibilityLimits.portionGramsMin,
                          PlausibilityLimits.portionGramsMax,
                        ),
                    key: const ValueKey('describe-grams-hint'),
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w600,
                      color: t.warning,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${item.caloriesKcal}',
                        style: AppType.display(36, color: t.onBrandSurface),
                      ),
                      TextSpan(
                        text: ' kcal',
                        style: AppType.ui(15, color: t.onBrandSurface),
                      ),
                    ],
                  ),
                  key: const ValueKey('describe-line-kcal'),
                ),
                const SizedBox(height: 6),
                SavedMealNutrients(result: preview),
              ],
            ),
          ),
          const SizedBox(height: 22),
          HeadingSemantics(
            level: 2,
            child: Text(
              l10n.foodDescribeLineChoose.toUpperCase(),
              semanticsLabel: l10n.foodDescribeLineChoose,
              style: AppType.sectionEyebrow(t.ink2),
            ),
          ),
          const SizedBox(height: 10),
          SavedMealCollection(
            dividerInset: 14 + 24 + 12,
            children: [
              for (var i = 0; i < item.candidates.length; i++)
                _CandidateRow(
                  key: ValueKey('describe-candidate-$i'),
                  item: item,
                  candidate: item.candidates[i],
                  selected: identical(item.candidates[i], selected),
                  onTap: () => _choose(item.candidates[i]),
                ),
            ],
          ),
          const SizedBox(height: 22),
          PrimaryActionButton(
            key: const ValueKey('describe-line-apply'),
            label: l10n.foodApplyButton,
            icon: Icons.check_rounded,
            onTap: _gramsInvalid
                ? null
                : () => Navigator.of(context).pop(_LineEdit.update(_item)),
          ),
          const SizedBox(height: 10),
          SoftPillButton(
            key: const ValueKey('describe-line-remove'),
            label: l10n.foodRemoveTooltip,
            icon: Icons.delete_outline_rounded,
            tone: SoftPillTone.danger,
            expand: true,
            onTap: () => Navigator.of(context).pop(const _LineEdit.remove()),
          ),
        ],
      ),
    );
  }
}

/// A candidate: radio, name, origin, density.
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    super.key,
    required this.item,
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final DraftFoodItem item;
  final DraftCandidate candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final (title, brand) = _candidateName(candidate, item);
    final kcal100 = candidate.kcalPer100G.round();
    final origin = _originLabel(candidate.origin, l10n);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: l10n.foodDescribeCandidateSemantics(
        brand == null ? title : '$title, $brand',
        kcal100,
        origin,
      ),
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                OptionRadio(selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _OriginBadge(origin: candidate.origin),
                          Text(
                            _withBrand(brand, '$kcal100 kcal / 100 g'),
                            style: AppType.ui(
                              12.5,
                              weight: FontWeight.w500,
                              color: t.ink3,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Minus, the typed grams, plus on one soft capsule, like the add sheet's
/// portion stepper. Long press steps five times.
class _GramStepper extends StatefulWidget {
  const _GramStepper({
    required this.controller,
    required this.invalid,
    required this.step,
    required this.onBump,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool invalid;
  final int step;
  final ValueChanged<int> onBump;
  final ValueChanged<String> onChanged;

  @override
  State<_GramStepper> createState() => _GramStepperState();
}

class _GramStepperState extends State<_GramStepper> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return FieldCapsule(
      focusNode: _focus,
      error: widget.invalid,
      shape: SheetFieldShape.pill,
      shadow: false,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _StepButton(
            key: const ValueKey('describe-grams-minus'),
            icon: Icons.remove_rounded,
            semanticLabel: l10n.foodDecreaseAmountSemantics,
            onTap: () => widget.onBump(-widget.step),
            onLongPress: () => widget.onBump(-widget.step * 5),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Semantics(
                    label: l10n.foodAddItemWeightLabel,
                    child: TextField(
                      key: const ValueKey('describe-grams-input'),
                      controller: widget.controller,
                      focusNode: _focus,
                      onChanged: widget.onChanged,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [DigitBudgetFormatter(5)],
                      textAlign: TextAlign.right,
                      cursorColor: t.accent,
                      cursorOpacityAnimates: false,
                      style: AppType.display(22, color: t.ink),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'g',
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w600,
                      color: t.ink2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _StepButton(
            key: const ValueKey('describe-grams-plus'),
            icon: Icons.add_rounded,
            semanticLabel: l10n.foodIncreaseAmountSemantics,
            onTap: () => widget.onBump(widget.step),
            onLongPress: () => widget.onBump(widget.step * 5),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: PressScale(
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox.square(
              dimension: 48,
              child: Icon(icon, size: 22, color: t.accentText),
            ),
          ),
        ),
      ),
    );
  }
}
