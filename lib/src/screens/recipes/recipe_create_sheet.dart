part of 'recipes_screen.dart';

// ---------------------------------------------------------------------------
// „Eigenes Rezept"-Formular: Bottom-Sheet zum Anlegen eines eigenen Rezepts
// (Foto, Name, Portion, Nährwerte, Zutaten) inkl. des Eingabefelds, der
// Foto-Auswahl und des Verwerfen-Schutzes.
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

  /// Nicht `final`: die Portion-Vorbelegung ist erst ab `didChangeDependencies`
  /// bekannt (l10n braucht einen aufgebauten `BuildContext`, `initState` hat
  /// noch keinen) und wird dort einmalig nachgetragen — sonst zaehlte das Feld
  /// sich selbst gegen seinen leeren Ausgangswert als „veraendert" (s. dort).
  String start;

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
          style: TextButton.styleFrom(foregroundColor: t.ink2),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
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

/// Bottom-Sheet zum Anlegen eines eigenen Rezepts (Foto, Name, Portion,
/// Nährwerte, Zutaten). Gibt beim Speichern ein [FitnessRecipe] via
/// Navigator.pop zurück.
///
/// **Aufbau.** Vier benannte Gruppen statt einer Feldkolonne — „Foto" ·
/// „Was ist es" · „Nährwerte" · „Zutaten", jede mit einer Versalien-Kopfzeile
/// ([_SheetGroup]) über ihrem Inhalt. Die Eingabekapseln bleiben die des
/// Design-Vertrags (`SheetField`-Optik: [AppTokens.surf] mit
/// [AppTokens.line]-Rand); rot umrandet wird, was einen Fehler trägt.
///
/// Die vier Nährwerte stehen nebeneinander statt untereinander — bei normaler
/// Schrift vierspaltig, ab ~1,25-facher Schrift zweispaltig (siehe
/// [_FieldGrid]). Zusammen mit „Portion + Gewicht" auf einer Zeile war das der
/// teuerste Höhenposten der alten Fassung.
///
/// **Höhe ist hier ein Funktionsmerkmal, keine Kosmetik** — siehe die
/// Begründung an [_SheetGroup]. Der zugehörige Test heißt
/// „bei normaler Schrift kommt es ohne Scrollen aus"
/// (test/recipe_create_photo_test.dart).
class _CreateRecipeSheet extends StatefulWidget {
  const _CreateRecipeSheet({required this.photoInput});

  /// Kamera-/Galerie-Auswahl. Liefert die Bytes bereits EXIF-frei zurück
  /// (`DeviceMealPhotoInput` schickt sie durch `compressMealPhoto`) — das ist
  /// dieselbe Pipeline wie beim KI-Scan, hier wird keine zweite gebaut.
  final MealPhotoInput photoInput;

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
    // Vorbelegung "1 Portion" kommt erst in didChangeDependencies — l10n
    // braucht einen aufgebauten BuildContext, den initState noch nicht hat.
    _portion = _feld();
    _grams = _feld('300');
    _kcal = _feld();
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
    _ingredients = _feld();
  }

  /// Setzt die l10n-abhaengige Portion-Vorbelegung genau einmal — nicht in
  /// [initState] (dort ist noch kein BuildContext fuer die Lokalisierung
  /// aufgebaut), aber auch nicht bei jedem [didChangeDependencies]-Aufruf
  /// (ein Locale-Wechsel WAEHREND das Sheet offen ist, duerfte einen bereits
  /// getippten Text nicht ueberschreiben). [_RecipeField.start] wird
  /// mitgezogen, sonst zaehlte das frische Feld sich selbst als „veraendert".
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

  // ── Foto ────────────────────────────────────────────────────────────────
  //
  // Die Bytes bleiben bis zum Speichern IM SPEICHER. Erst [_save] legt sie
  // ab — wer das Sheet verwirft, hinterlaesst keine verwaiste Datei. Der
  // Dateiname haengt am Slug, und den gibt es vor dem Speichern noch nicht.

  Uint8List? _photoBytes;

  /// Solange die Systemauswahl offen ist bzw. die Bytes gescrubbt werden.
  bool _photoBusy = false;

  bool get _hasPhoto => _photoBytes != null;

  Future<void> _pickPhoto(ImageSource source) async {
    if (_photoBusy) return;
    setState(() => _photoBusy = true);
    Uint8List? bytes;
    try {
      final auswahl = await widget.photoInput.pick(source);
      // `previewBytes` ist der bereits gescrubbte Stand. Null heisst: nicht
      // dekodierbar — fail-closed, dann lieber gar kein Bild (dieselbe Regel
      // wie im Upload-Pfad, s. compressMealPhoto).
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

  /// D5: irgendein Feld weicht vom Ausgangszustand ab — oder es liegt ein
  /// noch nicht gespeichertes Foto im Sheet. Ohne den zweiten Teil wäre ein
  /// gerade aufgenommenes Bild der einzige Inhalt, den ein Barriere-Tap
  /// kommentarlos verwirft.
  bool get _dirty => _felder.any((feld) => feld.veraendert) || _hasPhoto;

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

  /// Läuft ohne Foto vollständig synchron durch (kein `await` vor dem `pop`) —
  /// nur der Bild-Zweig wartet auf die Ablage.
  ///
  /// Der Rückgabetyp ist `Future<void>`; als `VoidCallback` am
  /// [FilledButton] bleibt `onPressed` unverändert lesbar (`null` = gesperrt),
  /// woran recipe_create_sheet_test hängt.
  Future<void> _save() async {
    if (!_isValid || _saving) return;
    final l10n = context.l10n;
    // Der Name ist durch `maxLength` bereits auf <= 160 UTF-16-Einheiten
    // begrenzt; `char_length` in Postgres zaehlt Code Points und ist damit nie
    // groesser. Bleibt das Trimmen.
    final name = _name.text.trim();
    final ingredients = _ingredients.text.trim();
    final portion = _portion.text.trim().isEmpty
        ? l10n.foodPortionFallback
        : _portion.text.trim();
    final slug = FitnessRecipe.userRecipeSlug();

    // Das Bild bekommt seinen Namen aus dem Slug. Scheitert die Ablage (kein
    // Verzeichnis, Bytes nicht dekodierbar, volle Platte), wird das Rezept OHNE
    // Bild gespeichert — eine Referenz ins Leere waere schlimmer als keine.
    var imageAsset = '';
    final bytes = _photoBytes;
    if (bytes != null) {
      setState(() => _saving = true);
      final referenz =
          await RecipeImageStore.instance.save(slug: slug, bytes: bytes);
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
        description: l10n.recipesOwnTitle,
        portion: portion,
        ingredients: ingredients.isEmpty ? l10n.recipesNoDataProvided : ingredients,
        preparation: l10n.recipesNoPreparationYet,
        professionalHint: l10n.recipesSelfCreatedHint,
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

  /// Sperrt den Speichern-Knopf, solange die Bytes geschrieben werden.
  bool _saving = false;

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
    final l10n = context.l10n;
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
            // Bewusst kurz: der Satz stand vorher zweizeilig ueber dem
            // Formular. Was optional ist, sagen jetzt die Gruppen selbst
            // („optional" rechts in der Kopfzeile).
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
                  ),
                  const SizedBox(height: 12),
                  _FieldGrid(
                    // Portion und Gewicht beschreiben dasselbe: „wie viel ist
                    // eine Portion". Sie stehen deshalb nebeneinander, und die
                    // Naehrwerte-Gruppe bleibt rein numerisch.
                    columns: 2,
                    children: [
                      _RecipeSheetField(
                        fieldKey: const ValueKey('recipe-create-portion'),
                        controller: _portion,
                        label: l10n.recipesSectionPortion,
                        hint: l10n.recipesPortionHint,
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
              // Vier Zahlen nebeneinander statt vier vollen Zeilen. Die drei
              // Makro-Felder tragen ihren Token-Ton als Punkt vor der
              // Beschriftung — dieselbe Kodierung wie im Naehrwert-Grid der
              // Detail-Ansicht, damit die Farben nicht auseinanderlaufen.
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
                // Die Gruppe traegt die Beschriftung schon in ihrer Kopfzeile;
                // eine zweite direkt darunter waere Dopplung. Der
                // Screenreader-Bezug bleibt (Semantics im Feld selbst).
                showLabel: false,
              ),
            ),
            const SizedBox(height: 14),
            // Bleibt ein `FilledButton` mit `onPressed: _isValid ? _save : null`
            // — recipe_create_sheet_test castet darauf und liest
            // `onPressed == null` als Sperrsignal. Nur der Stil wandert auf die
            // Fussaktion der neuen Sheet-Sprache.
            FilledButton.icon(
              key: const ValueKey('recipe-create-save'),
              onPressed: _isValid && !_saving ? _save : null,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(
                l10n.recipesSaveButtonLabel,
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

/// Eine benannte Gruppe des Anlege-Sheets: Versalien-Kopfzeile über ihrem
/// Inhalt.
///
/// Bewusst OHNE umschliessende Karte. Der erste Entwurf steckte jede Gruppe in
/// eine [AppCard] — das sah geordnet aus und kostete 4 x 24 px Innenpolsterung.
/// Zusammen mit dem Rest lag das Sheet bei gemessenen 889 px Inhalt auf einem
/// 852-px-Geraet, also ueber seinem 92-%-Deckel: es wurde scrollbar, der
/// Speichern-Knopf rutschte unter den Rand — und der Verwerfen-Schutz verlor
/// seinen Zug-Weg an die Scrollflaeche (ein Scroller gewinnt die Gestenarena
/// gegen den `_DiscardDragGuard` darueber). Die Kopfzeile allein gruppiert
/// genauso gut; so macht es auch das Bearbeiten-Sheet (`_SectionLabel`).
class _SheetGroup extends StatelessWidget {
  const _SheetGroup({
    required this.label,
    required this.child,
    this.trailing,
  });

  final String label;
  final Widget child;

  /// Gedämpfter Zusatz rechts („pro Portion", „optional").
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
              // `Flexible`, nicht starr: bei doppelter Schrift sprengt der
              // Zusatz die Zeile sonst.
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

/// Gleich breite Zellen nebeneinander — mit einer Notbremse für große Schrift.
///
/// Vier Zahlenfelder auf einer Zeile sind bei normaler Schrift genau richtig
/// und bei textScaler 2.0 unbenutzbar (jede Zelle bekäme ~75 px, in denen eine
/// zweistellige Zahl und ihre Beschriftung liegen müssten). Ab dem 1,25-fachen
/// halbiert sich deshalb die Spaltenzahl; ein `Wrap` bricht dann sauber um,
/// statt die Zeile zu sprengen.
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

/// Die Foto-Gruppe: Vorschau und Erklärung nebeneinander, darunter die
/// Aktionen (Kamera · Galerie · Entfernen).
///
/// Der ehrliche Hinweis („Bleibt auf diesem Gerät") steht bewusst hier und
/// nicht im Kleingedruckten: die Bytes gehen NICHT in die Cloud. Ein zweites
/// Gerät sieht das Rezept, aber den Platzhalter statt des Fotos.
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
          // Eine feste Zeile mit gleich breiten Kapseln statt eines `Wrap`:
          // im Wrap brach die dritte Kapsel in eine zweite Reihe um und kostete
          // das Sheet ~37 px Hoehe — bei einem Sheet, das seinen Deckel nicht
          // reissen darf (s. `_SheetGroup`), ist das nicht drin.
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

/// Kleine Kapsel-Aktion der Foto-Gruppe.
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
                  // `Flexible` ist hier keine Kosmetik: bei doppelter Schrift
                  // ist „Entfernen" breiter als die Spalte neben der
                  // Bildkachel, und ein `Wrap` kann ein einzelnes Kind nicht
                  // umbrechen — es lief um gemessene 27 px ueber.
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

/// Beschriftetes Eingabefeld in der Optik von `SheetField`, hier lokal
/// nachgebaut: das Bibliotheks-Widget kennt (noch) weder einen Key auf dem
/// inneren [TextField] noch `maxLines`/`maxLength`/`inputFormatters` — und der
/// [ValueKey] muss zwingend direkt am [TextField] sitzen, weil
/// recipe_create_sheet_test darauf castet.
///
/// Zwei Abweichungen von `SheetField`, beide der neuen Gruppierung geschuldet:
///
///  * **Fläche `surf2` statt `surf` ohne Rahmen.** Das Feld sitzt jetzt in
///    einer [AppCard] (die ist `surf` mit `line`-Rand) — ein Rahmen im Rahmen
///    wäre doppelt gezeichnet, und eine `surf`-Kapsel auf `surf` unsichtbar.
///    Rot umrandet wird weiterhin, was einen Fehler trägt.
///  * **Die Einheit steht in der Kopfzeile, nicht in der Kapsel.** Ein Suffix
///    NEBEN einem `Expanded`-Textfeld ist bei doppelter Schrift die klassische
///    Overflow-Quelle; in der Beschriftung bricht es einfach um. Nebenbei
///    passen dadurch vier Zahlenfelder auf eine Zeile.
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

  /// Maßeinheit — erscheint als Zusatz in der Versalien-Kopfzeile.
  final String? unit;

  final bool numeric;
  final int maxLines;

  /// Blendet die Kopfzeile aus, wenn die Gruppe sie schon trägt. Der
  /// Screenreader-Bezug bleibt davon unberührt ([Semantics] unten).
  final bool showLabel;

  /// Kategorie-Punkt vor der Beschriftung (Makro-Token). Nur Kodierung, keine
  /// Dekoration — dieselben Töne wie das Nährwert-Grid der Detail-Ansicht.
  final Color? dot;

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
    final kopfzeile = unit == null
        ? label.toUpperCase()
        : '${label.toUpperCase()} · ${unit!.toUpperCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          // Feste Kopfzeilen-Höhe, GENAU eine Zeile.
          //
          // Ohne sie brach „KALORIEN · KCAL" in einer 81-px-Spalte auf zwei
          // Zeilen um, „KH · G" blieb einzeilig — und weil die Spalten oben
          // bündig stehen, sassen die Eingabefelder von KH und Fett sichtbar
          // höher als die von Kalorien und Protein (Nutzer-Befund
          // 2026-08-10). Der FittedBox schrumpft die langen Kopfzeilen
          // stattdessen leicht; alle vier Felder beginnen damit auf
          // derselben Höhe, in jeder Schriftgrösse.
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
        Container(
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: hasError ? t.danger : t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13),
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
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
