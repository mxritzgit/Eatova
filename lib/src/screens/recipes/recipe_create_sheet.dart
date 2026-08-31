part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// "Own recipe" form: bottom sheet for creating a recipe (photo, name, portion,
// nutrition, ingredients), incl. field, photo picker and discard guard.
// ---------------------------------------------------------------------------

/// Limits mirrored from `LoggedMealLimits` / `PlausibilityLimits` instead of
/// imported: this file is a `part of 'recipes_screen.dart'` and cannot carry
/// import directives. test/recipe_create_sheet_test.dart derives every limit
/// and error text from `LoggedMealLimits.*`, so drift turns the test red.
const int _kcalMax = 10000; // LoggedMealLimits.caloriesKcalMax
const int _gramsMax = 10000; // LoggedMealLimits.estimatedGMax
const int _macroMax = 1000; // LoggedMealLimits.macroGMax
const int _nameMaxChars = 160; // LoggedMealLimits.mealNameMaxChars

/// Client caps for the free-text fields, well under the DB clamps
/// (`user_recipes.portion` 1000, `ingredients` 20000, migration
/// 20260819140000) so a 23514 can never turn a recipe into a local-only one.
const int _portionMaxChars = 200;
const int _ingredientsMaxChars = 4000;

/// `user_recipes.title` is `char_length(title) <= 300`, i.e. CODE POINTS.
/// Flutter's `maxLength` counts grapheme clusters, so 160 ZWJ family emoji
/// (7 code points each) pass the field cap and still overshoot the server.
const int _nameMaxCodePoints = 300;

/// Floors. `logged_meals` would allow 0, but 0 g breaks
/// `MealAnalysisResult.adjustedToGrams` (division by the source portion,
/// `kcalPer100G == 0`).
const int _kcalMin = 1;
const int _gramsMin = 1;
const int _macroMin = 0;

/// One form field plus its initial value. Only [_CreateRecipeSheetState._feld]
/// creates the pair — see the rationale there.
class _RecipeField {
  _RecipeField(this.controller, this.start);

  final TextEditingController controller;

  /// Not `final`: the portion default is only known in
  /// `didChangeDependencies` (l10n needs a built `BuildContext`) and is
  /// backfilled there, otherwise the field would count itself as changed.
  String start;

  bool get veraendert => controller.text != start;
}

/// D5: shared "discard changes?" confirmation for every way of closing a
/// filled sheet. `barrierDismissible` stays `true`: a tap outside means
/// cancel, and the dialog's own barrier swallows it, so the sheet below never
/// sees it. Twin of `_confirmDiscardChanges` in
/// lib/src/widgets/kcal/edit_meal_sheet.dart — duplicated because this file is
/// a `part` without imports.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final t = context.t;
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.foodDiscardChangesTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(
        l10n.recipesDiscardChangesBody,
        style: AppType.ui(13, color: t.ink2, height: 1.4),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          // Destructive red is the one colour the theme may not decide.
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// D5: intercepts the drag-down dismiss of a modal bottom sheet.
///
/// A `PopScope` is not enough: a barrier tap goes through `Navigator.maybePop`
/// (asks the pop disposition), but dragging goes `BottomSheet._handleDragEnd`
/// → `onClosing` → `Navigator.pop`, which does not. The only lever from inside
/// is the gesture arena: a vertical drag recognizer in the builder child sits
/// below `_BottomSheetGestureDetector` and wins. Scrollables sit below this
/// guard and stay unaffected. With [active] false no recognizer is registered
/// at all, so an empty sheet still drags away.
///
/// Twin of `_DiscardDragGuard` in lib/src/widgets/kcal/edit_meal_sheet.dart.
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Minimum downward distance counted as "close". Deliberately small: the
  /// guard swallows the gesture anyway, the only question is whether the user
  /// gets an answer.
  static const double _closeIntentPx = 32;

  /// Fling threshold, mirroring `_kMinFlingVelocity` from bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Without translucent, gaps between children stay uncovered.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

/// Bottom sheet for creating an own recipe (photo, name, portion, nutrition,
/// ingredients). Returns a [FitnessRecipe] via Navigator.pop on save.
///
/// Four named groups ([_SheetGroup]) instead of one field column; the four
/// nutrition fields sit side by side, four columns at normal text scale and
/// two above ~1.25x (see [_FieldGrid]). Height is a functional constraint
/// here, not cosmetics — see [_SheetGroup].
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet({required this.photoInput});

  /// Camera/gallery picker. Returns EXIF-free bytes already
  /// (`DeviceMealPhotoInput` runs them through `compressMealPhoto`) — the same
  /// pipeline the AI scan uses.
  final MealPhotoInput photoInput;

  @override
  State<_CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<_CreateRecipeSheet> {
  /// Registry of ALL input fields — the only such list here.
  ///
  /// [_feld] is the single source of a controller, so every field
  /// automatically gets its start value for [_dirty], the listener that keeps
  /// save-enablement and `PopScope.canPop` current, and its `dispose()`. A
  /// hand-built `TextEditingController` would have none of them. The
  /// comparison runs against the start state, so undoing an edit clears
  /// dirty again.
  final List<_RecipeField> _felder = <_RecipeField>[];

  late final TextEditingController _name;
  late final TextEditingController _portion;
  late final TextEditingController _grams;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _ingredients;

  @override
  void initState() {
    super.initState();
    _name = _feld();
    // The portion default lands in didChangeDependencies — l10n needs a built
    // BuildContext, which initState does not have yet.
    _portion = _feld();
    _grams = _feld('300');
    _kcal = _feld();
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
    _ingredients = _feld();
  }

  /// Applies the l10n-dependent portion default exactly once: not in
  /// [initState] (no localized BuildContext yet), and not on every
  /// [didChangeDependencies] (a locale switch must not overwrite typed text).
  /// [_RecipeField.start] moves with it, or the fresh field counts as changed.
  bool _defaultsVorbelegt = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_defaultsVorbelegt) return;
    _defaultsVorbelegt = true;
    final fallbackPortion = context.l10n.foodPortionFallback;
    _portion.text = fallbackPortion;
    _felder
        .firstWhere((feld) => feld.controller == _portion)
        .start = fallbackPortion;
  }

  TextEditingController _feld([String start = '']) {
    final controller = TextEditingController(text: start);
    controller.addListener(_onFeldChanged);
    _felder.add(_RecipeField(controller, start));
    return controller;
  }

  void _onFeldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final feld in _felder) {
      feld.controller
        ..removeListener(_onFeldChanged)
        ..dispose();
    }
    super.dispose();
  }

  // ── Photo ───────────────────────────────────────────────────────────────
  //
  // Bytes stay in memory until [_save] writes them, so discarding the sheet
  // leaves no orphaned file.

  Uint8List? _photoBytes;

  /// True while the system picker is open or the bytes are being scrubbed.
  bool _photoBusy = false;

  bool get _hasPhoto => _photoBytes != null;

  Future<void> _pickPhoto(ImageSource source) async {
    if (_photoBusy) return;
    setState(() => _photoBusy = true);
    Uint8List? bytes;
    try {
      final auswahl = await widget.photoInput.pick(source);
      // `previewBytes` is the already scrubbed state; null means undecodable —
      // fail closed and keep no image (same rule as the upload path).
      bytes = auswahl?.previewBytes;
      if (auswahl != null && bytes == null && mounted) {
        _melde(context.l10n.recipesPhotoUnreadableError);
      }
    } catch (_) {
      if (mounted) _melde(context.l10n.recipesPhotoLoadFailedError);
    }
    if (!mounted) return;
    setState(() {
      _photoBusy = false;
      if (bytes != null) _photoBytes = bytes;
    });
  }

  void _removePhoto() => setState(() => _photoBytes = null);

  void _melde(String text) {
    if (!mounted) return;
    showAppSnack(
      context,
      text,
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
    );
  }

  /// D5: any field differs from its start value, or an unsaved photo sits in
  /// the sheet. Without the second half a fresh photo would be the one content
  /// a barrier tap discards silently.
  bool get _dirty => _felder.any((feld) => feld.veraendert) || _hasPhoto;

  // ── Field validation ────────────────────────────────────────────────────
  //
  // `user_recipes` only constrains `>= 0`; the much stricter `logged_meals`
  // limits apply on conversion (`FitnessRecipe.toMealResult`), so a 50 000 kcal
  // recipe could be created and never logged. They are enforced here already.
  //
  // Rejected, not clamped: clamping would silently store a number the user
  // never meant. Only the name is truncated, visibly, during input
  // (`maxLength`).

  /// Error text for an integer field, or null.
  ///
  /// An empty field gets no error — "nothing typed yet" is not an input error.
  /// A missing required value is blocked by [_isValid] alone, so a freshly
  /// opened sheet does not greet the user with red fields.
  String? _zahlFehler(
    TextEditingController controller, {
    required int min,
    required int max,
    required String Function(int min, int max) bereichstext,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final wert = int.tryParse(text);
    if (wert == null || wert < min || wert > max) return bereichstext(min, max);
    return null;
  }

  String? get _kcalFehler => _zahlFehler(
        _kcal,
        min: _kcalMin,
        max: _kcalMax,
        bereichstext: context.l10n.recipesRangeErrorKcal,
      );

  String? get _gramsFehler => _zahlFehler(
        _grams,
        min: _gramsMin,
        max: _gramsMax,
        bereichstext: context.l10n.recipesRangeErrorGrams,
      );

  String? _makroFehler(TextEditingController controller) => _zahlFehler(
        controller,
        min: _macroMin,
        max: _macroMax,
        bereichstext: context.l10n.recipesRangeErrorGrams,
      );

  /// Code-point cap on the name (see [_nameMaxCodePoints]); `maxLength` alone
  /// cannot enforce it.
  String? get _nameFehler => _name.text.trim().runes.length > _nameMaxCodePoints
      ? context.l10n.recipesNameTooLongError
      : null;

  /// Save is enabled when the required fields are filled and all fields are
  /// within their limits.
  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    // Required fields: empty means missing, not optional.
    if (_kcal.text.trim().isEmpty || _grams.text.trim().isEmpty) return false;
    return _nameFehler == null &&
        _kcalFehler == null &&
        _gramsFehler == null &&
        _makroFehler(_protein) == null &&
        _makroFehler(_carbs) == null &&
        _makroFehler(_fat) == null;
  }

  int _zahl(TextEditingController controller) =>
      int.tryParse(controller.text.trim()) ?? 0;

  /// Runs fully synchronously without a photo (no `await` before the `pop`);
  /// only the image branch waits on the store. Returns `Future<void>` but
  /// stays readable as a `VoidCallback` on the [FilledButton] (`null` =
  /// disabled), which recipe_create_sheet_test relies on.
  Future<void> _save() async {
    if (!_isValid || _saving) return;
    final l10n = context.l10n;
    // `maxLength` caps the name at 160 GRAPHEMES, which can still be more
    // than the 300 code points Postgres' `char_length` allows; `_isValid`
    // (via `_nameFehler`) has already rejected that case. Only trim left.
    final name = _name.text.trim();
    if (name.runes.length > _nameMaxCodePoints) return;
    final ingredients = _ingredients.text.trim();
    // description/preparation/professionalHint have no field here and are
    // stored empty (neutral marker); display resolves them into the CURRENT
    // locale via `FitnessRecipe.display*`. Persisting the localized ARB text
    // would freeze the language the recipe was created in. Same for the
    // portion: its default is l10n-dependent, so an untouched or emptied
    // suggestion is "no real value". `_RecipeField.veraendert` decides — more
    // robust than comparing against the current ARB wording.
    final portionField =
        _felder.firstWhere((feld) => feld.controller == _portion);
    final portion = portionField.veraendert ? _portion.text.trim() : '';
    final slug = FitnessRecipe.userRecipeSlug();

    // The store names the image cryptographically at random, not from the slug
    // (Security review 2026-08-11, finding 5: `user_<ms>` was guessable). If
    // the write fails, the recipe is saved without an image — a dangling
    // reference would be worse than none.
    var imageAsset = '';
    final bytes = _photoBytes;
    if (bytes != null) {
      setState(() => _saving = true);
      final referenz = await RecipeImageStore.instance.save(bytes: bytes);
      if (!mounted) return;
      setState(() => _saving = false);
      if (referenz == null) {
        _melde(l10n.recipesPhotoSaveFailedError);
      } else {
        imageAsset = referenz;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(
      FitnessRecipe(
        slug: slug,
        title: name,
        description: '',
        portion: portion,
        ingredients: ingredients,
        preparation: '',
        professionalHint: '',
        imageAsset: imageAsset,
        caloriesKcal: _zahl(_kcal),
        proteinG: _zahl(_protein),
        carbsG: _zahl(_carbs),
        fatG: _zahl(_fat),
        estimatedGrams: _zahl(_grams),
        categories: const <String>['Eigene'],
        userCreated: true,
      ),
    );
  }

  /// Blocks the save button while the bytes are being written.
  bool _saving = false;

  /// D5: guards every intercepted dismiss attempt (barrier tap and system back
  /// via [PopScope], drag via [_DiscardDragGuard]) so retries do not stack
  /// dialogs.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // The dialog is already popped, so the sheet is topmost again. No result:
    // discarded is not saved.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope<FitnessRecipe?>(
      // Only while something is actually filled in; an empty sheet closes
      // immediately.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: Padding(
          padding: EdgeInsets.only(bottom: viewInsets),
          child: _buildSheet(context),
        ),
      ),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Rebuilt in the SheetScaffold look instead of using it: `SheetScaffold`
    // has no key on its footer action, and the save button must stay a
    // `FilledButton` keyed `recipe-create-save`.
    return Container(
      key: const ValueKey('recipe-create-sheet'),
      // Safe-area and keyboard aware instead of a fixed 92 % (sheetMaxHeight):
      // with eight text fields and the keyboard open, the fixed share pushed
      // the top edge under the status bar / Dynamic Island.
      constraints: BoxConstraints(maxHeight: sheetMaxHeightOf(context)),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: t.line,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.recipesOwnTitle,
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
            const SizedBox(height: 4),
            // Deliberately short: the groups themselves mark what is optional
            // (trailing label in their header).
            Text(
              l10n.recipesNameAndCaloriesSuffice,
              style: AppType.ui(12.5, color: t.ink2, height: 1.4),
            ),
            const SizedBox(height: 12),
            _SheetGroup(
              label: l10n.foodPhotoCardTitle,
              child: _RecipePhotoPicker(
                bytes: _photoBytes,
                busy: _photoBusy,
                onCamera: () => _pickPhoto(ImageSource.camera),
                onGallery: () => _pickPhoto(ImageSource.gallery),
                onRemove: _removePhoto,
              ),
            ),
            const SizedBox(height: 10),
            _SheetGroup(
              label: l10n.recipesGroupWhatIsIt,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-name'),
                    controller: _name,
                    label: l10n.foodAddItemNameLabel,
                    hint: l10n.recipesNameHint,
                    maxChars: _nameMaxChars,
                    errorText: _nameFehler,
                  ),
                  const SizedBox(height: 12),
                  _FieldGrid(
                    // Portion and weight describe the same thing, so they sit
                    // together and the nutrition group stays purely numeric.
                    columns: 2,
                    children: [
                      _RecipeSheetField(
                        fieldKey: const ValueKey('recipe-create-portion'),
                        controller: _portion,
                        label: l10n.recipesSectionPortion,
                        hint: l10n.recipesPortionHint,
                        maxChars: _portionMaxChars,
                      ),
                      _RecipeSheetField(
                        fieldKey: const ValueKey('recipe-create-grams'),
                        controller: _grams,
                        label: l10n.foodAddItemWeightLabel,
                        unit: 'g',
                        numeric: true,
                        errorText: _gramsFehler,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _SheetGroup(
              label: l10n.recipesGroupNutrition,
              trailing: l10n.recipesPerPortion,
              // Four numbers side by side instead of four full rows. The macro
              // fields carry their token color as a dot, same encoding as the
              // nutrition grid in the detail view.
              child: _FieldGrid(
                columns: 4,
                children: [
                  _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-kcal'),
                    controller: _kcal,
                    label: l10n.foodAddItemCaloriesLabel,
                    unit: 'kcal',
                    numeric: true,
                    dot: t.accent,
                    errorText: _kcalFehler,
                  ),
                  _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-protein'),
                    controller: _protein,
                    label: l10n.todayMacroProtein,
                    unit: 'g',
                    numeric: true,
                    dot: t.protein,
                    errorText: _makroFehler(_protein),
                  ),
                  _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-carbs'),
                    controller: _carbs,
                    label: l10n.recipesNutritionCarbsLabel,
                    unit: 'g',
                    numeric: true,
                    dot: t.carbs,
                    errorText: _makroFehler(_carbs),
                  ),
                  _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-fat'),
                    controller: _fat,
                    label: l10n.todayMacroFat,
                    unit: 'g',
                    numeric: true,
                    dot: t.fat,
                    errorText: _makroFehler(_fat),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _SheetGroup(
              label: l10n.recipesSectionIngredients,
              trailing: l10n.recipesOptionalLabel,
              child: _RecipeSheetField(
                fieldKey: const ValueKey('recipe-create-ingredients'),
                controller: _ingredients,
                label: l10n.recipesSectionIngredients,
                hint: l10n.recipesIngredientsHint,
                maxLines: 3,
                maxChars: _ingredientsMaxChars,
                // The group header already carries the label; a second one
                // would duplicate it. Screen-reader label stays (Semantics).
                showLabel: false,
              ),
            ),
            const SizedBox(height: 14),
            // Must stay a `FilledButton` with `onPressed: _isValid ? _save :
            // null` — recipe_create_sheet_test casts to it and reads
            // `onPressed == null` as the disabled signal. Colours and shape
            // come from the button theme (F8-10); only the stature is local,
            // as a MINIMUM so a 2x label never outgrows the button.
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: double.infinity,
                minHeight: 52,
              ),
              child: FilledButton.icon(
                key: const ValueKey('recipe-create-save'),
                onPressed: _isValid && !_saving ? _save : null,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(
                  l10n.recipesSaveButtonLabel,
                  style: AppType.ui(14.5, weight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A named group of the create sheet: all-caps header above its content.
///
/// Deliberately without a wrapping card: an [AppCard] per group cost 4 x 24 px
/// of padding and pushed the sheet over its height cap, which made it
/// scrollable — and a scrollable wins the gesture arena against
/// [_DiscardDragGuard], killing the discard guard's drag path.
class _SheetGroup extends StatelessWidget {
  const _SheetGroup({
    required this.label,
    required this.child,
    this.trailing,
  });

  final String label;
  final Widget child;

  /// Muted trailing note on the right ("per portion", "optional").
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: AppType.eyebrow(t.ink2, size: 10),
              ),
            ),
            if (trailing != null)
              // `Flexible`, not fixed: at 2x text scale the note overflows the
              // row otherwise.
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    trailing!,
                    textAlign: TextAlign.right,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Equal-width cells side by side, with an escape hatch for large text.
///
/// Four number fields per row are right at normal scale and unusable at 2.0
/// (~75 px per cell). Above 1.25x the column count halves and the `Wrap`
/// breaks cleanly instead of overflowing.
class _FieldGrid extends StatelessWidget {
  const _FieldGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  static const double _spacing = 9;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final spalten = scale <= 1.25 ? columns : (columns > 2 ? 2 : 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final breite =
            (constraints.maxWidth - _spacing * (spalten - 1)) / spalten;
        return Wrap(
          spacing: _spacing,
          runSpacing: 12,
          children: [
            for (final child in children)
              SizedBox(width: breite > 0 ? breite : null, child: child),
          ],
        );
      },
    );
  }
}

/// Photo group: preview and explanation side by side, actions below.
///
/// The "stays on this device" note is prominent on purpose — the bytes never
/// reach the cloud, so a second device sees the recipe with a placeholder.
class _RecipePhotoPicker extends StatelessWidget {
  const _RecipePhotoPicker({
    required this.bytes,
    required this.busy,
    required this.onCamera,
    required this.onGallery,
    required this.onRemove,
  });

  final Uint8List? bytes;
  final bool busy;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final vorhanden = bytes != null;
    return AppCard(
      radius: rCard,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 60,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(rControl),
                  child: vorhanden
                      ? Image.memory(
                          bytes!,
                          key: const ValueKey('recipe-create-photo-preview'),
                          fit: BoxFit.cover,
                          width: 60,
                          height: 60,
                          // Fixed 60-px slot: decode there instead of the
                          // full 1600-px scrub (worst decode/display ratio in
                          // the app before the perf round 2026-08-31).
                          cacheWidth:
                              (60 * MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                        )
                      : ImagePlaceholder(
                          radius: rControl,
                          label: l10n.recipesPhotoPlaceholderLabel,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vorhanden ? l10n.recipesYourPhoto : l10n.recipesPhotoOfDish,
                      style:
                          AppType.ui(13, weight: FontWeight.w600, color: t.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      busy
                          ? l10n.recipesPhotoPreparing
                          : l10n.recipesPhotoStaysOnDevice,
                      style: AppType.ui(11.5, color: t.ink2, height: 1.3),
                    ),
                    if (vorhanden) ...[
                      const SizedBox(height: 3),
                      Text(
                        l10n.recipesPhotoNoLocationData,
                        style: AppType.ui(11.5, color: t.ink2, height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Fixed row of equal-width chips instead of a `Wrap`: there the
          // third chip wrapped to a second line and cost ~37 px of height,
          // which this sheet cannot spare (see `_SheetGroup`).
          Row(
            children: [
              Expanded(
                child: _PhotoAction(
                  actionKey: const ValueKey('recipe-create-photo-camera'),
                  icon: Icons.photo_camera_outlined,
                  label: l10n.recipesCameraAction,
                  onTap: busy ? null : onCamera,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PhotoAction(
                  actionKey: const ValueKey('recipe-create-photo-gallery'),
                  icon: Icons.photo_library_outlined,
                  label: l10n.recipesGalleryAction,
                  onTap: busy ? null : onGallery,
                ),
              ),
              if (vorhanden) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _PhotoAction(
                    actionKey: const ValueKey('recipe-create-photo-remove'),
                    icon: Icons.close_rounded,
                    label: l10n.foodRemoveTooltip,
                    onTap: busy ? null : onRemove,
                    destructive: true,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Small chip action of the photo group.
class _PhotoAction extends StatelessWidget {
  const _PhotoAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = destructive ? t.danger : t.ink;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: t.surf2,
          borderRadius: BorderRadius.circular(rChip),
          child: InkWell(
            key: actionKey,
            onTap: onTap,
            borderRadius: BorderRadius.circular(rChip),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 15, color: ton),
                  const SizedBox(width: 6),
                  // `Flexible` is load-bearing: at 2x text scale the label is
                  // wider than its column, and a `Wrap` cannot break a single
                  // child — it overflowed by ~27 px.
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          AppType.ui(12, weight: FontWeight.w600, color: ton),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Labeled input on a [FieldCapsule] (field / fieldFocus / fieldError plus
/// the text line below). Stays local because of the header: macro dot, unit
/// suffix and a fixed one-line height that `SheetField.label` does not offer.
/// The [ValueKey] sits directly on the [TextField] because
/// recipe_create_sheet_test casts to it.
class _RecipeSheetField extends StatelessWidget {
  const _RecipeSheetField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.unit,
    this.numeric = false,
    this.maxLines = 1,
    this.maxChars,
    this.errorText,
    this.showLabel = true,
    this.dot,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;

  /// Unit — shown as a suffix in the all-caps header.
  final String? unit;

  final bool numeric;
  final int maxLines;

  /// Hides the header when the group already carries the label. The
  /// screen-reader label is unaffected ([Semantics] below).
  final bool showLabel;

  /// Category dot before the label (macro token). Encoding, not decoration —
  /// same colors as the detail view's nutrition grid.
  final Color? dot;

  /// Hard length limit during input. Flutter counts GRAPHEME clusters here,
  /// which can be more generous than Postgres' `char_length` (code points) —
  /// a ZWJ emoji is one grapheme but up to seven code points. Server-bound
  /// caps therefore get a separate code-point check ([_nameMaxCodePoints]).
  final int? maxChars;

  /// Field error instead of silent clamping. Blocks saving together with
  /// [_isValid] and names the valid range.
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    final kopfzeile = unit == null
        ? label.toUpperCase()
        : '${label.toUpperCase()} · ${unit!.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          // Fixed header height, exactly one line: a wrapping long header made
          // the neighbouring fields start visibly higher (user finding
          // 2026-08-10). The FittedBox shrinks long headers instead, so all
          // four fields align at any text size.
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(9.5) * 1.35,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (dot != null) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      kopfzeile,
                      maxLines: 1,
                      softWrap: false,
                      style: AppType.eyebrow(t.ink2, size: 9.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
        ],
        // The `Focus` ancestor only observes: `Focus.of` rebuilds the builder
        // whenever the inner field gains or loses focus.
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          child: Builder(
            builder: (context) {
              return FieldCapsule(
                focused: Focus.of(context).hasFocus,
                error: hasError,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      // The label is a separate all-caps line above the
                      // field, not `InputDecoration.labelText`, which would
                      // leave the field unlabeled for screen readers. This
                      // annotation restores it.
                      child: Semantics(
                        label: label,
                        child: TextField(
                          key: fieldKey,
                          cursorOpacityAnimates: false,
                          controller: controller,
                          maxLines: maxLines,
                          maxLength: maxChars,
                          keyboardType: numeric
                              ? TextInputType.number
                              : TextInputType.text,
                          inputFormatters: numeric
                              ? [FilteringTextInputFormatter.digitsOnly]
                              : null,
                          textCapitalization: numeric
                              ? TextCapitalization.none
                              : TextCapitalization.sentences,
                          style: AppType.ui(14, color: t.ink),
                          cursorColor: t.accent,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                            hintText: hint,
                            hintStyle: AppType.ui(14, color: t.ink2),
                            // The character counter is noise here; input
                            // visibly stops at the limit anyway.
                            counterText: '',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }
}
