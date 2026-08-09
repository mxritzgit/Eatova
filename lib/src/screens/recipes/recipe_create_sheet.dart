part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// „Eigenes Rezept"-Formular: Bottom-Sheet zum Anlegen eines eigenen Rezepts
// (Name, Portion, Makros, Zutaten) inkl. des rahmenlosen Eingabefelds.
// ---------------------------------------------------------------------------

/// Grenzen aus `LoggedMealLimits` bzw. `PlausibilityLimits`
/// (lib/src/models/model_limits.dart) — hier **gespiegelt statt importiert**:
/// diese Datei ist ein `part of 'recipes_screen.dart'` und kann keine eigenen
/// Import-Direktiven tragen; der Import muesste in die Elterndatei.
///
/// Die Kopplung ist per Test gesichert: test/recipe_create_sheet_test.dart
/// leitet jede Grenze und jeden Fehlertext aus `LoggedMealLimits.*` ab. Laufen
/// die Werte auseinander, wird der Test rot. Wer den Import spaeter nach
/// recipes_screen.dart hebt, loescht diesen Block ersatzlos.
const int _kcalMax = 10000; // LoggedMealLimits.caloriesKcalMax
const int _gramsMax = 10000; // LoggedMealLimits.estimatedGMax
const int _macroMax = 1000; // LoggedMealLimits.macroGMax
const int _nameMaxChars = 160; // LoggedMealLimits.mealNameMaxChars

/// Untergrenzen. `logged_meals` liesse 0 zu, aber eine Mahlzeit mit 0 kcal
/// oder 0 g ist keine — und 0 g fuehrt in `MealAnalysisResult.adjustedToGrams`
/// zur Division durch die Ursprungsportion sowie zu `kcalPer100G == 0`
/// (`PlausibilityLimits.portionGramsMin`).
const int _kcalMin = 1;
const int _gramsMin = 1;
const int _macroMin = 0;

/// Ein Feld des Formulars samt seinem Ausgangswert.
///
/// Das Paar entsteht ausschliesslich in [_CreateRecipeSheetState._feld] —
/// siehe die Begruendung dort.
class _RecipeField {
  _RecipeField(this.controller, this.start);

  final TextEditingController controller;
  final String start;

  bool get veraendert => controller.text != start;
}

/// D5: „Aenderungen verwerfen?" — die gemeinsame Bestaetigung fuer jeden Weg,
/// ein ausgefuelltes Sheet zu schliessen.
///
/// `barrierDismissible` bleibt auf dem Default `true`: ein Tap neben den
/// Dialog ist „Abbrechen", also die harmlose Antwort. Der Dialog liegt auf dem
/// Root-Navigator und damit UEBER der Sheet-Route — sein eigener Barrier
/// schluckt den Tap, das Sheet darunter bekommt ihn nie zu sehen. Der Dialog
/// kann sich also nicht selbst mitsamt dem Sheet wegklicken.
///
/// Zwilling von `_confirmDiscardChanges` in
/// lib/src/widgets/kcal/edit_meal_sheet.dart. Die Dopplung ist der Preis
/// dafuer, dass diese Datei ein `part` ohne eigene Imports ist; beide Fassungen
/// gehoeren zusammen nach lib/src/widgets/common/, sobald jemand den Import in
/// recipes_screen.dart setzen darf.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final t = context.t;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        'Änderungen verwerfen?',
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(
        'Dein Rezept ist noch nicht gespeichert.',
        style: AppType.ui(13, color: t.ink2, height: 1.4),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          style: TextButton.styleFrom(foregroundColor: t.ink2),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Weiter bearbeiten'),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Verwerfen'),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// D5: faengt das Nach-unten-Ziehen eines modalen Bottom-Sheets ab.
///
/// **Warum ein `PopScope` allein nicht reicht:** die beiden Dismiss-Wege
/// laufen im Framework verschieden.
///
///  * Barriere-Tap → `ModalBarrier.handleDismiss` → `Navigator.maybePop`
///    (`modal_barrier.dart:225-230`) — fragt die Pop-Disposition, also
///    `PopScope`.
///  * Ziehen → `BottomSheet._handleDragEnd` → `onClosing` → **`Navigator.pop`**
///    (`bottom_sheet.dart:769-771`) — fragt sie **nicht**. Ein `PopScope` sieht
///    diesen Weg nie.
///
/// Von innerhalb des Sheets gibt es dafuer genau einen Hebel: die Gesten-Arena.
/// Der `_BottomSheetGestureDetector` sitzt ueber dem `builder`-Kind; ein
/// eigener Vertikal-Drag-Erkenner IM Kind liegt tiefer und gewinnt die Arena —
/// dasselbe Prinzip, aus dem eine ScrollView im Sheet das Ziehen schluckt.
/// Scrollbare Bereiche liegen wiederum tiefer als dieser Guard und bleiben
/// unberuehrt.
///
/// Ist [active] false (nichts ausgefuellt), wird gar kein Erkenner registriert
/// — das Sheet laesst sich dann wie gewohnt wegziehen. Ein Sheet, das man ohne
/// Dialog nicht mehr zubekommt, waere schlimmer als der Bug.
///
/// Zwilling von `_DiscardDragGuard` in
/// lib/src/widgets/kcal/edit_meal_sheet.dart.
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
  /// Mindeststrecke nach unten, ab der ein Zug als „zumachen" gilt. Bewusst
  /// klein: der Guard schluckt die Geste ohnehin, die Frage ist nur, ob der
  /// Nutzer dazu eine Antwort bekommt.
  static const double _closeIntentPx = 32;

  /// Flick-Schwelle, gespiegelt an `_kMinFlingVelocity` aus bottom_sheet.dart.
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
      // Ohne translucent bleiben Luecken zwischen den Kindern unbedeckt.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

/// Bottom-Sheet zum Anlegen eines eigenen Rezepts (Name, Portion, Makros,
/// Zutaten). Gibt beim Speichern ein [FitnessRecipe] via Navigator.pop zurück.
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet();

  @override
  State<_CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<_CreateRecipeSheet> {
  /// Registry ALLER Eingabefelder — die einzige Liste, die es hier gibt.
  ///
  /// D5 verlangt ein `_dirty`, das ein neuntes Feld nicht vergisst. Deshalb
  /// gibt es keinen zweiten Ort, an dem Felder aufgezaehlt werden: [_feld] ist
  /// die einzige Quelle eines Controllers, und wer sie benutzt, bekommt
  /// automatisch alle drei Dinge, die man sonst einzeln vergisst —
  ///
  ///   1. den Ausgangswert fuer den [_dirty]-Vergleich,
  ///   2. den Listener, der Speichern-Freigabe UND `PopScope.canPop`
  ///      nachfuehrt (ohne ihn bliebe `canPop` bei einem Feld ohne
  ///      `onChanged` stehen — genau die Luecke, die eine Handliste reisst),
  ///   3. das `dispose()`.
  ///
  /// Ein direkt gebauter `TextEditingController` haette keins davon und faellt
  /// sofort auf. Der Vergleich laeuft gegen den Startzustand, nicht gegen
  /// „wurde mal getippt": wer eine Eingabe wieder zuruecknimmt, bekommt keinen
  /// Dialog mehr.
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
    _portion = _feld('1 Portion');
    _grams = _feld('300');
    _kcal = _feld();
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
    _ingredients = _feld();
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

  /// D5: irgendein Feld weicht vom Ausgangszustand ab.
  bool get _dirty => _felder.any((feld) => feld.veraendert);

  // ── Feldvalidierung ─────────────────────────────────────────────────────
  //
  // `user_recipes` kennt laut Constraint-Inventur nur `>= 0`; faktische Grenze
  // ist der `integer`-Typ. Die deutlich strengeren `logged_meals`-Grenzen
  // greifen erst beim Konvertieren (`FitnessRecipe.toMealResult`) — ein Rezept
  // mit 50 000 kcal liess sich also anlegen und danach nie loggen. Deshalb
  // gelten sie hier bereits beim Anlegen.
  //
  // ABGELEHNT, nicht geklemmt (Regel aus Welle 1): 50 000 auf 10 000 zu
  // klemmen schriebe eine Zahl ins Rezept, die der Nutzer nie gemeint hat, und
  // zwar unbemerkt. Nur der Name wird gekuerzt — Texte sind die dokumentierte
  // Ausnahme, und das Kuerzen passiert sichtbar schon bei der Eingabe
  // (`maxLength`).

  /// Fehlertext fuer ein Ganzzahlfeld oder null.
  ///
  /// Ein leeres Feld bekommt bewusst KEINEN Fehler: „noch nichts eingegeben"
  /// ist kein Eingabefehler. Das Fehlen eines Pflichtwerts sperrt allein
  /// [_isValid] — sonst begruesst das frisch geoeffnete Sheet den Nutzer mit
  /// zwei roten Feldern.
  String? _zahlFehler(
    TextEditingController controller, {
    required int min,
    required int max,
    required String einheit,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final wert = int.tryParse(text);
    if (wert == null || wert < min || wert > max) return '$min–$max $einheit';
    return null;
  }

  String? get _kcalFehler =>
      _zahlFehler(_kcal, min: _kcalMin, max: _kcalMax, einheit: 'kcal');

  String? get _gramsFehler =>
      _zahlFehler(_grams, min: _gramsMin, max: _gramsMax, einheit: 'g');

  String? _makroFehler(TextEditingController controller) =>
      _zahlFehler(controller, min: _macroMin, max: _macroMax, einheit: 'g');

  /// Speichern ist frei, wenn die Pflichtfelder gefuellt und ALLE Felder
  /// innerhalb ihrer Grenzen sind.
  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    // Pflichtfelder: leer ist hier kein „optional", sondern fehlend.
    if (_kcal.text.trim().isEmpty || _grams.text.trim().isEmpty) return false;
    return _kcalFehler == null &&
        _gramsFehler == null &&
        _makroFehler(_protein) == null &&
        _makroFehler(_carbs) == null &&
        _makroFehler(_fat) == null;
  }

  int _zahl(TextEditingController controller) =>
      int.tryParse(controller.text.trim()) ?? 0;

  void _save() {
    if (!_isValid) return;
    // Der Name ist durch `maxLength` bereits auf <= 160 UTF-16-Einheiten
    // begrenzt; `char_length` in Postgres zaehlt Code Points und ist damit nie
    // groesser. Bleibt das Trimmen.
    final name = _name.text.trim();
    final ingredients = _ingredients.text.trim();
    final portion =
        _portion.text.trim().isEmpty ? '1 Portion' : _portion.text.trim();

    Navigator.of(context).pop(
      FitnessRecipe(
        slug: FitnessRecipe.userRecipeSlug(),
        title: name,
        description: 'Eigenes Rezept',
        portion: portion,
        ingredients: ingredients.isEmpty ? 'Keine Angabe' : ingredients,
        preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
        professionalHint: 'Selbst angelegt. Werte beruhen auf deinen Angaben.',
        imageAsset: '',
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

  /// D5: laeuft fuer jeden abgefangenen Dismiss-Versuch — Barriere-Tap und
  /// System-Zurueck kommen ueber [PopScope], das Ziehen ueber
  /// [_DiscardDragGuard]. Mehrfach-Versuche stapeln keine Dialoge.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Der Dialog ist hier bereits gepoppt — oberste Route ist wieder das
    // Sheet. Ohne Ergebnis: verworfen ist nicht gespeichert.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope<FitnessRecipe?>(
      // Nur solange wirklich etwas drinsteht. Ein leeres Sheet schliesst wie
      // bisher sofort.
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
    // Der Rumpf ist der SheetScaffold-Optik nachgebaut statt sie zu benutzen:
    // `SheetScaffold` kennt keinen Key an der Fussaktion, und der
    // Speichern-Knopf muss ein `FilledButton` mit `recipe-create-save` bleiben.
    return Container(
      key: const ValueKey('recipe-create-sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(rSheet)),
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
                  color: t.line,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Eigenes Rezept',
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
            const SizedBox(height: 6),
            Text(
              'Name, Kalorien und Gewicht genügen — Makros sind optional.',
              style: AppType.ui(12.5, color: t.ink2, height: 1.45),
            ),
            const SizedBox(height: 18),
            _RecipeSheetField(
              fieldKey: const ValueKey('recipe-create-name'),
              controller: _name,
              label: 'Name',
              hint: 'z. B. Protein-Bowl',
              maxChars: _nameMaxChars,
            ),
            const SizedBox(height: 12),
            _RecipeSheetField(
              fieldKey: const ValueKey('recipe-create-portion'),
              controller: _portion,
              label: 'Portion',
              hint: '1 Teller',
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-kcal'),
                    controller: _kcal,
                    label: 'Kalorien',
                    suffix: 'kcal',
                    numeric: true,
                    errorText: _kcalFehler,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-grams'),
                    controller: _grams,
                    label: 'Gewicht',
                    suffix: 'g',
                    numeric: true,
                    errorText: _gramsFehler,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-protein'),
                    controller: _protein,
                    label: 'Protein',
                    suffix: 'g',
                    numeric: true,
                    errorText: _makroFehler(_protein),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-carbs'),
                    controller: _carbs,
                    label: 'KH',
                    suffix: 'g',
                    numeric: true,
                    errorText: _makroFehler(_carbs),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _RecipeSheetField(
                    fieldKey: const ValueKey('recipe-create-fat'),
                    controller: _fat,
                    label: 'Fett',
                    suffix: 'g',
                    numeric: true,
                    errorText: _makroFehler(_fat),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _RecipeSheetField(
              fieldKey: const ValueKey('recipe-create-ingredients'),
              controller: _ingredients,
              label: 'Zutaten',
              hint: 'Eine Zutat pro Zeile',
              maxLines: 4,
            ),
            const SizedBox(height: 18),
            // Bleibt ein `FilledButton` mit `onPressed: _isValid ? _save : null`
            // — recipe_create_sheet_test castet darauf und liest
            // `onPressed == null` als Sperrsignal. Nur der Stil wandert auf die
            // Fussaktion der neuen Sheet-Sprache.
            FilledButton.icon(
              key: const ValueKey('recipe-create-save'),
              onPressed: _isValid ? _save : null,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(
                'Rezept speichern',
                style: AppType.ui(14.5, weight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: t.forest,
                foregroundColor: t.onForest,
                disabledBackgroundColor: t.surf2,
                disabledForegroundColor: t.ink2,
                // `minimumSize` statt fester Hoehe: bei doppelter Schrift waere
                // die Beschriftung sonst hoeher als der Knopf.
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Beschriftetes Eingabefeld in der Optik von `SheetField`, hier lokal
/// nachgebaut: das Bibliotheks-Widget kennt (noch) weder einen Key auf dem
/// inneren [TextField] noch `maxLines`/`maxLength`/`inputFormatters` — und der
/// [ValueKey] muss zwingend direkt am [TextField] sitzen, weil
/// recipe_create_sheet_test darauf castet.
class _RecipeSheetField extends StatelessWidget {
  const _RecipeSheetField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.hint,
    this.suffix,
    this.numeric = false,
    this.maxLines = 1,
    this.maxChars,
    this.errorText,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? suffix;
  final bool numeric;
  final int maxLines;

  /// Harte Laengenbegrenzung waehrend der Eingabe. Zaehlt UTF-16-Einheiten und
  /// ist damit nie grosszuegiger als Postgres' `char_length` (Code Points) —
  /// die Constraint kann also nicht mehr verletzt werden.
  final int? maxChars;

  /// Feldfehler statt stiller Klemmung. Sperrt zusammen mit [_isValid] das
  /// Speichern und sagt dem Nutzer, welcher Bereich gilt.
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 9.5)),
        const SizedBox(height: 7),
        Container(
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: hasError ? t.danger : t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                // Die Beschriftung steht als eigene Versalien-Zeile UEBER dem
                // Feld statt als `InputDecoration.labelText` darin. Optisch ist
                // das die neue Sprache — fuer den Screenreader waere das Feld
                // damit aber unbeschriftet („Textfeld, leer"), waehrend es
                // vorher „Kalorien" ansagte. Die Annotation holt den Bezug
                // zurueck, ohne die Optik anzufassen.
                child: Semantics(
                  label: label,
                  child: TextField(
                    key: fieldKey,
                    cursorOpacityAnimates: false,
                    controller: controller,
                    maxLines: maxLines,
                    maxLength: maxChars,
                    keyboardType:
                        numeric ? TextInputType.number : TextInputType.text,
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
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      hintText: hint,
                      hintStyle: AppType.ui(14, color: t.ink2),
                      // Der Zeichenzaehler waere hier nur Rauschen — gekuerzt
                      // wird ohnehin sichtbar, weil die Eingabe an der Grenze
                      // stehen bleibt.
                      counterText: '',
                    ),
                  ),
                ),
              ),
              if (suffix != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    suffix!,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: t.ink2,
                    ),
                  ),
                ),
            ],
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
