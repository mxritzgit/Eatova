part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// "Own recipe" form: bottom sheet for creating a recipe (photo, name, portion,
// nutrition, ingredients), incl. field, photo picker and discard guard.
// ---------------------------------------------------------------------------

/// Ergebnis des Anlege-Sheets: das Rezept plus die Frage, ob sein Foto
/// unterwegs verloren ging.
///
/// Ohne dieses Flag konnte der Aufrufer ein leeres `imageAsset` nicht von
/// "kein Foto gewaehlt" unterscheiden — und das Sheet selbst kann die Meldung
/// nicht zeigen, weil es unmittelbar danach schliesst und der Erfolgs-Toast
/// sich darueberlegt (Mutationslauf 2026-09-01, T6).
class RezeptEntwurfErgebnis {
  const RezeptEntwurfErgebnis({
    required this.rezept,
    required this.fotoFehlgeschlagen,
    this.delivery,
  });

  final FitnessRecipe rezept;
  final SyncDelivery? delivery;

  /// Es lag ein Foto vor, aber die Ablage auf dem Geraet schlug fehl. Das
  /// Rezept wurde trotzdem gespeichert — ohne Bild, weil eine baumelnde
  /// Referenz schlimmer waere als keine.
  final bool fotoFehlgeschlagen;
}

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
const int _portionMaxCodePoints = 1000;
const int _ingredientsMaxCodePoints = 20000;

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
  final l10n = context.l10n;
  final verwerfen = await showEatovaDialog<bool>(
    context: context,
    builder: (dialogContext) => EatovaConfirmDialog(
      key: const ValueKey('discard-changes-dialog'),
      title: l10n.foodDiscardChangesTitle,
      body: l10n.recipesDiscardChangesBody,
      icon: Icons.edit_off_rounded,
      destructive: true,
      cancelKey: const ValueKey('discard-changes-cancel'),
      cancelLabel: l10n.foodDiscardChangesKeepEditing,
      onCancel: () => Navigator.of(dialogContext).pop(false),
      confirmKey: const ValueKey('discard-changes-confirm'),
      confirmLabel: l10n.foodDiscardChangesConfirm,
      onConfirm: () => Navigator.of(dialogContext).pop(true),
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
    return GestureDetector(
      // Without translucent, gaps between children stay uncovered.
      behavior: HitTestBehavior.translucent,
      // Keep the child's element (and focused field) when dirty changes.
      onVerticalDragStart: widget.active ? _onStart : null,
      onVerticalDragUpdate: widget.active ? _onUpdate : null,
      onVerticalDragEnd: widget.active ? _onEnd : null,
      child: widget.child,
    );
  }
}

/// Bottom sheet for creating an own recipe (photo, name, portion, nutrition,
/// ingredients). Returns a [FitnessRecipe] via Navigator.pop on save.
///
/// Numbered sections scroll between the close control and the save action.
/// Related values reflow to a single column on narrow or enlarged layouts.
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet({
    required this.photoInput,
    this.initialRecipe,
    this.onSave,
    this.isSessionCurrent,
    this.productService,
  });

  /// Camera/gallery picker. Returns EXIF-free bytes already
  /// (`DeviceMealPhotoInput` runs them through `compressMealPhoto`) — the same
  /// pipeline the AI scan uses.
  final MealPhotoInput photoInput;
  final FitnessRecipe? initialRecipe;
  final Future<SyncDelivery> Function(FitnessRecipe)? onSave;
  final bool Function()? isSessionCurrent;
  final ProductLookupService? productService;

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

  late final String _draftSlug;
  late final TextEditingController _name;
  late final TextEditingController _portion;
  late final TextEditingController _grams;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _ingredients;
  late final TextEditingController _preparation;
  late final TextEditingController _description;
  late List<RecipeIngredient> _structuredIngredients;
  late bool _structured;
  late double? _batchServings;
  bool _ingredientsChanged = false;

  @override
  void initState() {
    super.initState();
    final recipe = widget.initialRecipe;
    _draftSlug = recipe?.slug ?? FitnessRecipe.userRecipeSlug();
    _structuredIngredients = List.of(recipe?.structuredIngredients ?? []);
    _structured = recipe?.hasStructuredIngredients ?? false;
    _batchServings = recipe?.batchServings ?? 1;
    _name = _feld(recipe?.title ?? '');
    // The portion default lands in didChangeDependencies — l10n needs a built
    // BuildContext, which initState does not have yet.
    _portion = _feld(recipe?.portion ?? '');
    _grams = _feld(recipe?.estimatedGrams.toString() ?? '300');
    _kcal = _feld(recipe?.caloriesKcal.toString() ?? '');
    _protein = _feld(recipe?.proteinG.toString() ?? '');
    _carbs = _feld(recipe?.carbsG.toString() ?? '');
    _fat = _feld(recipe?.fatG.toString() ?? '');
    _ingredients = _feld(recipe?.ingredients ?? '');
    _preparation = _feld(recipe?.preparation ?? '');
    _description = _feld(recipe?.description ?? '');
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
    if (widget.initialRecipe != null) return;
    final fallbackPortion = context.l10n.foodPortionFallback;
    _portion.text = fallbackPortion;
    _felder.firstWhere((feld) => feld.controller == _portion).start =
        fallbackPortion;
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
  bool _photoRemoved = false;
  String? _saveError;

  /// True while the system picker is open or the bytes are being scrubbed.
  bool _photoBusy = false;

  bool get _sessionCurrent => widget.isSessionCurrent?.call() ?? true;

  Future<void> _pickPhoto(ImageSource source) async {
    if (_photoBusy || _saving || !_sessionCurrent) return;
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
      if (bytes != null && _sessionCurrent) {
        _photoBytes = bytes;
        _photoRemoved = false;
      }
    });
  }

  void _removePhoto() => setState(() {
    _photoBytes = null;
    _photoRemoved = widget.initialRecipe?.imageAsset.isNotEmpty ?? false;
  });

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
  bool get _dirty =>
      _ingredientsChanged ||
      _structured !=
          (widget.initialRecipe?.hasStructuredIngredients ?? false) ||
      _batchServings != (widget.initialRecipe?.batchServings ?? 1) ||
      _felder.any((feld) => feld.veraendert) ||
      _photoBytes != null ||
      _photoRemoved;

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

  String? _textFehler(TextEditingController controller, int maxCodePoints) =>
      controller.text.trim().runes.length > maxCodePoints
      ? context.l10n.recipesTextTooLongError
      : null;

  /// Save is enabled when the required fields are filled and all fields are
  /// within their limits.
  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    if (_structured) {
      return _structuredIngredients.isNotEmpty &&
          _batchServings != null &&
          _calculation?.fitsStorageLimits == true &&
          _nameFehler == null &&
          _textFehler(_portion, _portionMaxCodePoints) == null &&
          _textFehler(_ingredients, _ingredientsMaxCodePoints) == null &&
          _textFehler(_preparation, _ingredientsMaxCodePoints) == null &&
          _textFehler(_description, 2000) == null;
    }
    // Required fields: empty means missing, not optional.
    if (_kcal.text.trim().isEmpty || _grams.text.trim().isEmpty) return false;
    return _nameFehler == null &&
        _textFehler(_portion, _portionMaxCodePoints) == null &&
        _textFehler(_ingredients, _ingredientsMaxCodePoints) == null &&
        _textFehler(_preparation, _ingredientsMaxCodePoints) == null &&
        _textFehler(_description, 2000) == null &&
        _kcalFehler == null &&
        _gramsFehler == null &&
        _makroFehler(_protein) == null &&
        _makroFehler(_carbs) == null &&
        _makroFehler(_fat) == null;
  }

  int _zahl(TextEditingController controller) =>
      int.tryParse(controller.text.trim()) ?? 0;

  RecipeCalculation? get _calculation =>
      !_structured || _structuredIngredients.isEmpty || _batchServings == null
      ? null
      : RecipeCalculation.calculate(
          _structuredIngredients,
          batchServings: _batchServings!,
        );

  /// Freeze the validated draft before IO and close only after persistence.
  Future<void> _save() async {
    if (!_isValid || _saving || _photoBusy) return;
    if (!_sessionCurrent) {
      setState(() => _saveError = context.l10n.recipeEditSessionChanged);
      return;
    }
    // `maxLength` caps the name at 160 GRAPHEMES, which can still be more
    // than the 300 code points Postgres' `char_length` allows; `_isValid`
    // (via `_nameFehler`) has already rejected that case. Only trim left.
    final name = _name.text.trim();
    if (name.runes.length > _nameMaxCodePoints) return;
    final ingredients = _ingredients.text.trim();
    final preparation = _preparation.text.trim();
    final description = _description.text.trim();
    // Keep an untouched creation placeholder locale-neutral. Editing preserves
    // the stored portion, including empty text.
    final portionField = _felder.firstWhere(
      (feld) => feld.controller == _portion,
    );
    final portion = widget.initialRecipe != null || portionField.veraendert
        ? _portion.text.trim()
        : '';
    final original = widget.initialRecipe;
    final slug = _draftSlug;
    // Capture every validated value before the asynchronous photo write.
    final known = _calculation?.knownNutrition;
    final caloriesKcal = known?.caloriesKcal?.round() ?? _zahl(_kcal);
    final proteinG = known?.proteinG?.round() ?? _zahl(_protein);
    final carbsG = known?.carbsG?.round() ?? _zahl(_carbs);
    final fatG = known?.fatG?.round() ?? _zahl(_fat);
    final estimatedGrams = _structured ? 0 : _zahl(_grams);
    final structuredIngredients = List<RecipeIngredient>.unmodifiable(
      _structured ? _structuredIngredients : <RecipeIngredient>[],
    );
    final batchServings = _structured ? _batchServings! : 1.0;

    // The store names the image cryptographically at random, not from the slug
    // (Security review 2026-08-11, finding 5: `user_<ms>` was guessable). If
    // the write fails, the recipe is saved without an image — a dangling
    // reference would be worse than none.
    var imageAsset = _photoRemoved ? '' : original?.imageAsset ?? '';
    // Reist mit dem Ergebnis nach draussen: das Sheet darf das Scheitern NICHT
    // selbst melden. Es poppt unmittelbar danach, und der Erfolgs-Toast des
    // Aufrufers legt sich sofort darueber — die Meldung erreichte den Nutzer
    // nie, er las "gespeichert", waehrend sein Foto fehlte (Mutationslauf
    // 2026-09-01, T6). Der Aufrufer entscheidet jetzt, was er sagt.
    var fotoFehlgeschlagen = false;
    final bytes = _photoBytes;
    if (bytes != null) {
      setState(() => _saving = true);
      FocusScope.of(context).unfocus();
      final referenz = await RecipeImageStore.instance.save(bytes: bytes);
      if (!mounted) return;
      if (referenz == null) {
        fotoFehlgeschlagen = true;
      } else {
        imageAsset = referenz;
      }
    }

    if (!mounted) return;
    if (!_sessionCurrent) {
      setState(() {
        _saving = false;
        _saveError = context.l10n.recipeEditSessionChanged;
      });
      return;
    }
    final recipe = FitnessRecipe(
      slug: slug,
      title: name,
      description: description,
      portion: portion,
      ingredients: ingredients,
      preparation: preparation,
      professionalHint: original?.professionalHint ?? '',
      imageAsset: imageAsset,
      caloriesKcal: caloriesKcal,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      estimatedGrams: estimatedGrams,
      categories: original?.categories ?? const <String>['Eigene'],
      userCreated: true,
      structuredIngredients: structuredIngredients,
      batchServings: batchServings,
    );
    SyncDelivery? delivery;
    if (widget.onSave != null) {
      setState(() {
        _saving = true;
        _saveError = null;
      });
      FocusScope.of(context).unfocus();
      try {
        delivery = await widget.onSave!(recipe);
      } catch (_) {
        if (mounted) {
          setState(() {
            _saving = false;
            _saveError = context.l10n.recipeEditSaveFailed;
          });
        }
        return;
      }
      if (!mounted) return;
      if (!_sessionCurrent) {
        setState(() {
          _saving = false;
          _saveError = context.l10n.recipeEditSessionChanged;
        });
        return;
      }
    }
    Navigator.of(context).pop(
      RezeptEntwurfErgebnis(
        rezept: recipe,
        fotoFehlgeschlagen: fotoFehlgeschlagen,
        delivery: delivery,
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
    if (_discardDialogOpen || _saving) return;
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
    return PopScope<RezeptEntwurfErgebnis?>(
      // Only while something is actually filled in; an empty sheet closes
      // immediately.
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty || _saving,
        onDismissAttempt: _askDiscard,
        child: Padding(
          padding: EdgeInsets.only(bottom: viewInsets),
          child: ExcludeFocus(
            excluding: _saving,
            child: AbsorbPointer(
              absorbing: _saving,
              child: _buildSheet(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final compact = sheetMaxHeightOf(context) < 400;
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
            child: Row(
              children: [
                if (!compact &&
                    MediaQuery.textScalerOf(context).scale(14) <= 18) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.forest,
                      borderRadius: BorderRadius.circular(rControl),
                    ),
                    child: Icon(
                      Icons.menu_book_rounded,
                      color: t.lime,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: HeadingSemantics(
                    level: 1,
                    child: Text(
                      widget.initialRecipe != null
                          ? l10n.recipeEditTitle
                          : compact
                          ? l10n.navRecipes
                          : l10n.recipesOwnTitle,
                      style: compact
                          ? AppType.ui(
                              15,
                              color: t.ink,
                              weight: FontWeight.w600,
                            )
                          : AppType.display(24, color: t.ink, height: 1.15),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('recipe-create-close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: _saving
                      ? null
                      : () {
                          if (_dirty) {
                            _askDiscard();
                          } else {
                            Navigator.pop(context);
                          }
                        },
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('recipe-create-scroll'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.initialRecipe != null
                        ? l10n.recipeEditIntro
                        : l10n.recipesCreateIntro,
                    style: AppType.ui(14, color: t.ink2, height: 1.45),
                  ),
                  if (compact) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.recipesNameAndCaloriesSuffice,
                      style: AppType.ui(12, color: t.ink2, height: 1.4),
                    ),
                  ],
                  const SizedBox(height: 22),
                  _SheetGroup(
                    number: 1,
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
                        if (widget.initialRecipe != null) ...[
                          const SizedBox(height: 12),
                          _RecipeSheetField(
                            fieldKey: const ValueKey(
                              'recipe-create-description',
                            ),
                            controller: _description,
                            label: l10n.recipeEditDescription,
                            maxLines: 3,
                            maxChars: 2000,
                            errorText: _textFehler(_description, 2000),
                          ),
                        ],
                        const SizedBox(height: 12),
                        _RecipeFieldGrid(
                          // Portion and weight describe the same thing, so they sit
                          // together and the nutrition group stays purely numeric.
                          children: [
                            _RecipeSheetField(
                              fieldKey: const ValueKey('recipe-create-portion'),
                              controller: _portion,
                              label: l10n.recipesSectionPortion,
                              hint: l10n.recipesPortionHint,
                              maxChars: _portionMaxChars,
                              errorText: _textFehler(
                                _portion,
                                _portionMaxCodePoints,
                              ),
                            ),
                            if (!_structured)
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
                  _RecipePhotoPicker(
                    bytes: _photoBytes,
                    existingRecipe: !_photoRemoved
                        ? widget.initialRecipe
                        : null,
                    busy: _photoBusy || _saving,
                    onCamera: () => _pickPhoto(ImageSource.camera),
                    onGallery: () => _pickPhoto(ImageSource.gallery),
                    onRemove: _removePhoto,
                  ),
                  const SizedBox(height: 24),
                  Material(
                    color: Colors.transparent,
                    child: SwitchListTile.adaptive(
                      key: const ValueKey('recipe-create-structured'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        l10n.recipeEditCalculateIngredients,
                        style: AppType.ui(
                          15,
                          color: t.ink,
                          weight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        l10n.recipeEditCalculateHint,
                        style: AppType.ui(14, color: t.ink2, height: 1.4),
                      ),
                      value: _structured,
                      onChanged: (value) => setState(() => _structured = value),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_structured) ...[
                    RecipeIngredientEditor(
                      ingredients: _structuredIngredients,
                      productService: widget.productService,
                      onChanged: (value) => setState(() {
                        _structuredIngredients = List.unmodifiable(value);
                        _ingredientsChanged = true;
                      }),
                    ),
                    const SizedBox(height: 16),
                    RecipePortionSelector(
                      initialServings: _batchServings ?? 1,
                      label: l10n.recipeEditBatchServings,
                      onChanged: (value) =>
                          setState(() => _batchServings = value),
                    ),
                    if (_calculation != null) ...[
                      const SizedBox(height: 16),
                      _CalculatedNutrition(calculation: _calculation!),
                    ],
                  ] else
                    _SheetGroup(
                      number: 2,
                      label: l10n.recipesGroupNutrition,
                      trailing: l10n.recipesPerPortion,
                      // Nutrient colors match the recipe detail view.
                      child: _RecipeFieldGrid(
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
                            label: l10n.todayMacroCarbs,
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
                  const SizedBox(height: 24),
                  _SheetGroup(
                    number: 3,
                    label: l10n.recipesSectionIngredients,
                    trailing: l10n.recipesOptionalLabel,
                    child: _RecipeSheetField(
                      fieldKey: const ValueKey('recipe-create-ingredients'),
                      controller: _ingredients,
                      label: l10n.recipesSectionIngredients,
                      hint: l10n.recipesIngredientsHint,
                      maxLines: 3,
                      maxChars: _ingredientsMaxChars,
                      errorText: _textFehler(
                        _ingredients,
                        _ingredientsMaxCodePoints,
                      ),
                      // The group header already carries the label; a second one
                      // would duplicate it. Screen-reader label stays (Semantics).
                      showLabel: false,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SheetGroup(
                    number: 4,
                    label: l10n.recipesSectionPreparation,
                    trailing: l10n.recipesOptionalLabel,
                    child: _RecipeSheetField(
                      fieldKey: const ValueKey('recipe-create-preparation'),
                      controller: _preparation,
                      label: l10n.recipesSectionPreparation,
                      hint: l10n.recipeEditPreparationHint,
                      maxLines: 5,
                      maxChars: _ingredientsMaxChars,
                      errorText: _textFehler(
                        _preparation,
                        _ingredientsMaxCodePoints,
                      ),
                      showLabel: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              constraints: const BoxConstraints(minHeight: kButtonMinHeight),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_saveError != null) ...[
                    Text(
                      _saveError!,
                      key: const ValueKey('recipe-edit-save-error'),
                      style: AppType.ui(14, color: t.danger, height: 1.4),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (!compact) ...[
                    Text(
                      _structured
                          ? l10n.recipeEditCalculatedHint
                          : l10n.recipesNameAndCaloriesSuffice,
                      style: AppType.ui(12, color: t.ink2),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                  ],
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
                      onPressed: _isValid && !_saving && !_photoBusy
                          ? _save
                          : null,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_rounded, size: 18),
                      label: Text(
                        widget.initialRecipe != null
                            ? l10n.recipeEditSave
                            : l10n.recipesSaveButtonLabel,
                        style: AppType.ui(14.5, weight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The same numbered sections as the Training editor.
class _SheetGroup extends StatelessWidget {
  const _SheetGroup({
    required this.number,
    required this.label,
    required this.child,
    this.trailing,
  });

  final int number;
  final String label;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CreationSectionHeading(number: number, title: label, note: trailing),
      child,
    ],
  );
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
    this.existingRecipe,
  });

  final Uint8List? bytes;
  final FitnessRecipe? existingRecipe;
  final bool busy;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final vorhanden =
        bytes != null || (existingRecipe?.imageAsset.isNotEmpty ?? false);
    return AppCard(
      radius: rCard,
      padding: const EdgeInsets.all(16),
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
                  child: bytes != null
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
                      : vorhanden
                      ? RecipePhoto(
                          recipe: existingRecipe!,
                          placeholderRadius: rControl,
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
                      vorhanden
                          ? l10n.recipesYourPhoto
                          : l10n.recipesPhotoOfDish,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      busy
                          ? l10n.recipesPhotoPreparing
                          : l10n.recipesPhotoStaysOnDevice,
                      style: AppType.ui(13, color: t.ink2, height: 1.4),
                    ),
                    if (vorhanden) ...[
                      const SizedBox(height: 3),
                      Text(
                        l10n.recipesPhotoNoLocationData,
                        style: AppType.ui(13, color: t.ink2, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Keep the full action labels and touch targets at larger text sizes.
          CreationFieldGrid(
            children: [
              _PhotoAction(
                actionKey: const ValueKey('recipe-create-photo-camera'),
                icon: Icons.photo_camera_outlined,
                label: l10n.recipesCameraAction,
                onTap: busy ? null : onCamera,
              ),
              _PhotoAction(
                actionKey: const ValueKey('recipe-create-photo-gallery'),
                icon: Icons.photo_library_outlined,
                label: l10n.recipesGalleryAction,
                onTap: busy ? null : onGallery,
              ),
              if (vorhanden) ...[
                _PhotoAction(
                  actionKey: const ValueKey('recipe-create-photo-remove'),
                  icon: Icons.close_rounded,
                  label: l10n.foodRemoveTooltip,
                  onTap: busy ? null : onRemove,
                  destructive: true,
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
            child: Container(
              constraints: const BoxConstraints(minHeight: kButtonMinHeight),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 18, color: ton),
                  const SizedBox(width: 6),
                  // `Flexible` is load-bearing: at 2x text scale the label is
                  // wider than its column, and a `Wrap` cannot break a single
                  // child — it overflowed by ~27 px.
                  Flexible(
                    child: Text(
                      label,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w600,
                        color: ton,
                      ),
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

/// Labeled input with nutrient encoding and a readable unit in the header.
class _RecipeFieldGrid extends StatelessWidget {
  const _RecipeFieldGrid({required this.children});

  final List<_RecipeSheetField> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context);
      final columns = constraints.maxWidth >= 300 * scale.scale(14) / 14
          ? 2
          : 1;
      final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
      var labelHeight = 0.0;
      for (final field in children) {
        final measure = TextPainter(
          text: TextSpan(
            text: field.heading,
            style: _RecipeSheetField.labelStyle(context),
          ),
          textDirection: Directionality.of(context),
          textScaler: scale,
        )..layout(maxWidth: width - (field.dot == null ? 0 : 12));
        if (measure.height > labelHeight) labelHeight = measure.height;
        measure.dispose();
      }
      return _RecipeLabelHeight(
        height: labelHeight,
        child: CreationFieldGrid(children: children),
      );
    },
  );
}

/// Reserve the measured label height without shrinking or clipping any text.
class _RecipeLabelHeight extends InheritedWidget {
  const _RecipeLabelHeight({required this.height, required super.child});

  final double height;

  @override
  bool updateShouldNotify(_RecipeLabelHeight oldWidget) =>
      height != oldWidget.height;
}

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

  /// Unit shown next to the label.
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

  String get heading => unit == null ? label : '$label · $unit';

  static TextStyle labelStyle(BuildContext context) => AppType.ui(
    13,
    color: context.t.ink2,
    weight: FontWeight.w500,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    final labelHeight = context
        .dependOnInheritedWidgetOfExactType<_RecipeLabelHeight>()
        ?.height;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          SizedBox(
            height: labelHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (dot != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(child: Text(heading, style: labelStyle(context))),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
                      // The label is a separate line above the
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
                              : maxLines > 1
                              ? TextInputType.multiline
                              : TextInputType.text,
                          inputFormatters: numeric
                              ? [FilteringTextInputFormatter.digitsOnly]
                              : null,
                          textCapitalization: numeric
                              ? TextCapitalization.none
                              : TextCapitalization.sentences,
                          style: AppType.ui(15, color: t.ink),
                          cursorColor: t.accent,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 15,
                            ),
                            hintText: hint,
                            hintStyle: AppType.ui(15, color: t.ink2),
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
