import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../screens/barcode_scanner_sheet.dart';
import '../../services/meal_analyzer.dart';
import '../../services/meal_photo_input.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'edit_meal_sheet.dart';
import 'existing_meals_list.dart';
import 'manual_meal_sheet.dart';
import 'meal_analysis_sheet.dart';
import 'meal_suggestion_item.dart';
import 'slot_selector.dart';

/// Meldung, wenn eine Zeile aus Suche, Favoriten oder Recents ohne
/// Kalorienangabe geloggt werden soll — `l10n.foodSuggestionWithoutCaloriesMessage`.
///
/// Bewusst **nicht** [kMealWithoutCaloriesMessage] (`foodMealWithoutCaloriesMessage`)
/// aus dem Analyse-Sheet: der dortige Wortlaut verweist auf „Anpassen" →
/// Bestandteile eintragen, und genau diesen Weg gibt es hier nicht. Das
/// aufgeklappte Kaertchen hat nur einen Portionsregler, und 0 kcal bleiben bei
/// jeder Portion 0. Der einzige Ausweg ist, den Bestandseintrag zu ersetzen —
/// das steht hier deshalb auch so drin. Zwei eigene ARB-Keys mit
/// verschiedenem Inhalt statt einer gespiegelten Konstante.

Future<void> showAddMealSheet(
  BuildContext context, {
  required MealSlot slot,
  bool searchMode = false,
  required MealAnalyzer analyzer,
  required ProductLookupService productService,
  required MealPhotoInput photoInput,
  required List<FavoriteMeal> favorites,
  required String Function(MealAnalysisResult, MealSlot) onAdd,
  required void Function(String id, MealAnalysisResult scaled) onUpdateMeal,
  required ValueChanged<String> onRemoveFavorite,
  bool Function(MealAnalysisResult)? isFavorite,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
  List<LoggedMeal> existingMeals = const <LoggedMeal>[],
  ValueChanged<String>? onRemoveMeal,
  UpdateMealDetails? onUpdateMealDetails,
}) {
  // Bearbeiten-Callback VOR dem Route-Wechsel aus dem Scope aufloesen: der
  // Builder-Context des Bottom-Sheets haengt am Navigator und sieht den
  // MealEditScope der Home-Seite nicht mehr. Ohne Scope (Preview/Tests)
  // bleibt die „Schon hinzugefuegt"-Liste wie bisher ohne Tap-Bearbeitung.
  final resolvedUpdateDetails =
      onUpdateMealDetails ?? MealEditScope.maybeOf(context)?.onUpdateMeal;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Bewusst kein Token: der Scrim hinter einem Sheet dunkelt in beiden
    // Anzeige-Modi ab — ein heller Scrim wuerde nichts daempfen.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) {
      return AddMealSheet(
        slot: slot,
        searchMode: searchMode,
        analyzer: analyzer,
        productService: productService,
        photoInput: photoInput,
        favorites: favorites,
        existingMeals: existingMeals,
        onAdd: onAdd,
        onUpdateMeal: onUpdateMeal,
        onRemoveFavorite: onRemoveFavorite,
        isFavorite: isFavorite,
        onToggleFavorite: onToggleFavorite,
        onRemoveMeal: onRemoveMeal,
        onUpdateMealDetails: resolvedUpdateDetails,
      );
    },
  );
}

class AddMealSheet extends StatefulWidget {
  const AddMealSheet({
    super.key,
    required this.slot,
    this.searchMode = false,
    required this.analyzer,
    required this.productService,
    required this.photoInput,
    required this.favorites,
    required this.onAdd,
    required this.onUpdateMeal,
    required this.onRemoveFavorite,
    this.isFavorite,
    this.onToggleFavorite,
    this.existingMeals = const <LoggedMeal>[],
    this.onRemoveMeal,
    this.onUpdateMealDetails,
  });

  final MealSlot slot;
  final bool searchMode;
  final MealAnalyzer analyzer;
  final ProductLookupService productService;
  final MealPhotoInput photoInput;
  final List<FavoriteMeal> favorites;

  /// Loggt das Ergebnis und liefert die Client-UUID zurueck (siehe
  /// MealAnalysisSheet) — fuer die gezielte spaetere Um-Portionierung.
  final String Function(MealAnalysisResult, MealSlot) onAdd;

  /// Ersetzt das Ergebnis einer geloggten Zeile per id (kcal + Makros).
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;
  final ValueChanged<String> onRemoveFavorite;

  /// Ist die Mahlzeit aktuell angeheftet? Null -> kein Herz.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favoriten-Toggle (anheften/loesen). Null -> kein Herz.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final List<LoggedMeal> existingMeals;
  final ValueChanged<String>? onRemoveMeal;

  /// Details-Update fuer das Bearbeiten-Sheet (Portion/Slot/Tag). Null ->
  /// „Schon hinzugefuegt"-Zeilen sind nicht tippbar (bisheriges Verhalten).
  final UpdateMealDetails? onUpdateMealDetails;

  @override
  State<AddMealSheet> createState() => _AddMealSheetState();
}

/// **Bewusst OHNE Verwerfen-Schutz (D5).** Das wurde geprueft, nicht vergessen.
///
/// Drei Sheets haben seit Welle 3 `PopScope` + `_DiscardDragGuard`
/// (`recipe_create_sheet`, `edit_meal_sheet`, `settings_sheet`), ein viertes
/// seit Welle 6 (`meal_widgets_adjust`). Das Kriterium dafuer ist **nicht**
/// „haelt einen TextEditingController", sondern **selbst verfasster Inhalt,
/// der Muehe gekostet hat**: acht Rezeptfelder, sieben Einstellungsfelder,
/// Gramm-Korrekturen pro Bestandteil plus Makro-Dialog.
///
/// Hier liegen zwei Dinge im State: ein Suchbegriff und die Angabe, welche
/// Karte aufgeklappt ist (die Portion selbst lebt im `MealSuggestionItem`).
/// Beides ist eine *Anfrage*, keine Eingabe, und in wenigen Sekunden
/// wiederhergestellt — waehrend Suchen der Hauptzweck dieses Sheets ist, der
/// Dialog also bei praktisch jedem Schliessen kaeme.
///
/// Das hat einen Preis: ein Dialog, der staendig grundlos erscheint, wird
/// reflexhaft weggetippt und verliert genau dort an Wirkung, wo er zaehlt.
/// Aus demselben Grund traegt auch das Gewichts-Sheet
/// (`profile_widgets_body.dart`) keinen.
class _AddMealSheetState extends State<AddMealSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _productSearchDebounce;
  int _productSearchRequestId = 0;
  final Map<String, List<ProductSearchResult>> _productSearchCache =
      <String, List<ProductSearchResult>>{};
  // Sessions-Cache leerer Suchen: ein einmal erfolglos (aber ohne Fehler)
  // abgefragter Begriff liefert beim erneuten Tippen sofort "nichts gefunden",
  // ohne die Dienstkette noch einmal anzufassen.
  final Set<String> _emptyQueryCache = <String>{};
  List<ProductSearchResult> _productSuggestions = const <ProductSearchResult>[];
  bool _isSearchingProducts = false;
  String? _productSearchMessage;

  /// True NUR nach einer endgueltig leeren (fehlerfreien) Suche — der einzige
  /// Zustand, in dem der „Manuell eintragen"-CTA erscheint. Netz-Fehler und
  /// Min-Zeichen-Hinweis heissen „Suche kaputt/zu kurz", nicht „gibt es
  /// nicht", und bieten den CTA bewusst nicht an (Spec 2026-08-13).
  bool _searchCameUpEmpty = false;

  /// Hat der Nutzer die Suche SELBST ausgeloest (Lupe/Enter)? Nur dann gilt
  /// ein Fragment unterhalb von [_autoSearchMinChars] als aktive Suche. Jeder
  /// weitere Tastendruck nimmt die Freischaltung zurueck — sonst bliebe die
  /// Trefferzone offen, waehrend der Debounce laengst nichts mehr schickt.
  bool _explicitSearchRequested = false;

  String? _expandedItemKey;
  final Set<String> _justAddedKeys = <String>{};
  final Map<String, Timer> _justAddedTimers = <String, Timer>{};

  // Der Slot ist Sheet-Zustand, nicht ein fixer Input: Default ist der
  // übergebene (Uhrzeit-)Vorschlag, der User kann ihn im Selector ändern.
  late MealSlot _selectedSlot;
  late List<LoggedMeal> _existing;
  late List<FavoriteMeal> _favorites;

  // Diese drei Dauern laufen BEWUSST NICHT ueber `motionDuration`: sie takten
  // keine Bewegung, sondern Netz- und Anzeigelogik. Ein Debounce von 0 wuerde
  // pro Tastendruck eine Suchanfrage feuern, ein Retry-Delay von 0 den
  // Backoff aushebeln, und der Haken am gerade hinzugefuegten Treffer waere
  // weg, bevor ihn jemand sieht. „Bewegung reduzieren" darf das Verhalten der
  // App nicht aendern, nur ihre Animationen.
  static const Duration _productSearchDebounceDelay = Duration(
    milliseconds: 1000,
  );
  static const Duration _productSearchRetryDelay = Duration(milliseconds: 600);
  static const int _productSearchMaxAttempts = 3;
  static const Duration _justAddedFadeDelay = Duration(seconds: 2);

  /// Kuerzeste Eingabe, die ueberhaupt eine Suche wert ist — das gilt fuer den
  /// selbst ausgeloesten Weg (Lupe/Enter).
  static const int _searchMinChars = 2;

  /// Ab hier schickt der Debounce von SELBST los, bewusst HOEHER als
  /// [_searchMinChars]. Der Debounce feuert pro Tipp-Pause, und eine
  /// erfolglose Suche ist teuer: sie faechert sich ueber Mirror + OFF-de +
  /// OFF-world auf. Ein Zweibuchstaben-Fragment ist praktisch immer auf dem
  /// Weg zu einem Wort — es kostet also drei Anfragen fuer ein Ergebnis, das
  /// der naechste Buchstabe ohnehin ueberholt. Wer wirklich nur „Ei" sucht,
  /// kommt ueber die Lupe weiterhin dran.
  static const int _autoSearchMinChars = 3;

  @override
  void initState() {
    super.initState();
    _selectedSlot = widget.slot;
    _existing = List<LoggedMeal>.of(widget.existingMeals);
    _favorites = List<FavoriteMeal>.of(widget.favorites);
  }

  void _selectSlot(MealSlot slot) {
    if (slot == _selectedSlot) return;
    setState(() => _selectedSlot = slot);
  }

  // Geloggte Einträge des aktuell gewählten Slots (aus der vollen Tagesliste,
  // die das Sheet als existingMeals erhält) — der Kopfbereich bleibt so immer
  // zum Selector synchron.
  List<LoggedMeal> get _slotMeals =>
      _existing.where((m) => m.slot == _selectedSlot).toList(growable: false);

  @override
  void dispose() {
    _productSearchDebounce?.cancel();
    for (final t in _justAddedTimers.values) {
      t.cancel();
    }
    _justAddedTimers.clear();
    _searchController.dispose();
    super.dispose();
  }

  /// Trefferzone statt Favoriten. Unterhalb von [_autoSearchMinChars] bleiben
  /// Favoriten/Recents stehen, solange die Suche nicht selbst ausgeloest wurde
  /// — sonst stuende dort ein leerer Bereich, weil der Debounce fuer so kurze
  /// Eingaben absichtlich nichts schickt.
  bool get _searchActive {
    final length = _searchController.text.trim().length;
    if (length >= _autoSearchMinChars) return true;
    return _explicitSearchRequested && length >= _searchMinChars;
  }

  void _removeExisting(String id) {
    setState(() {
      _existing = _existing.where((m) => m.id != id).toList();
    });
    widget.onRemoveMeal?.call(id);
  }

  /// Tap auf eine „Schon hinzugefuegt"-Zeile: Bearbeiten-Sheet oeffnen und
  /// danach die LOKALE Tagesliste des Sheets nachziehen (das Sheet haelt eine
  /// Kopie und rebuildet nicht am Store). Ein Tag-Wechsel entfernt den
  /// Eintrag aus der Liste — sie zeigt nur den Tag dieses Sheets.
  Future<void> _editExisting(LoggedMeal meal) async {
    final update = widget.onUpdateMealDetails;
    if (update == null) return;
    final outcome = await showEditMealSheet(
      context,
      meal: meal,
      onUpdateMeal: update,
      onRemoveMeal: widget.onRemoveMeal == null ? null : _removeExisting,
    );
    if (!mounted || outcome == null) return;
    if (outcome.deleted) {
      return; // _removeExisting hat die Liste schon gepflegt.
    }
    final updated = outcome.meal;
    if (updated == null) return;
    setState(() {
      if (updated.effectiveLocalDay != meal.effectiveLocalDay) {
        _existing = _existing.where((m) => m.id != meal.id).toList();
      } else {
        _existing = [for (final m in _existing) m.id == meal.id ? updated : m];
      }
    });
  }

  void _removeFavorite(String id) {
    setState(() {
      _favorites = _favorites.where((f) => f.id != id).toList();
      _justAddedKeys.remove('favorite:$id');
    });
    widget.onRemoveFavorite(id);
  }

  // ─── Suche ────────────────────────────────────────────────────────────

  void _scheduleProductSearch(String value) {
    final query = value.trim();
    _productSearchDebounce?.cancel();

    if (query.length < _autoSearchMinChars) {
      _productSearchRequestId++;
      setState(() {
        // Eine neue Eingabe hebt die Freischaltung durch Lupe/Enter auf: die
        // Treffer davor gehoeren zu einem anderen Begriff.
        _explicitSearchRequested = false;
        _isSearchingProducts = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = null;
        _searchCameUpEmpty = false;
      });
      return;
    }

    // rebuild damit _searchActive umschaltet (Favoriten -> Treffer-Slot).
    setState(() {});
    _productSearchDebounce = Timer(
      _productSearchDebounceDelay,
      () => _searchProducts(
        queryOverride: query,
        showTransientError: false,
        explicit: false,
      ),
    );
  }

  /// [explicit] trennt Lupe/Enter vom Debounce: nur der selbst ausgeloeste Weg
  /// schaltet die Trefferzone auch fuer ein Fragment unterhalb von
  /// [_autoSearchMinChars] frei.
  Future<void> _searchProducts({
    String? queryOverride,
    bool showTransientError = true,
    bool explicit = true,
  }) async {
    _productSearchDebounce?.cancel();
    final query = (queryOverride ?? _searchController.text).trim();
    if (query.length < _searchMinChars) {
      setState(() {
        _explicitSearchRequested = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = context.l10n.foodSearchMinCharsHint;
        _searchCameUpEmpty = false;
      });
      return;
    }
    if (explicit) {
      _explicitSearchRequested = true;
    }

    final cacheKey = _normalizeQuery(query);
    final cached = _productSearchCache[cacheKey];
    if (cached != null) {
      _productSearchRequestId++;
      setState(() {
        _productSuggestions = cached;
        _isSearchingProducts = false;
        _productSearchMessage = cached.isEmpty
            ? context.l10n.foodSearchNoResultsHint
            : null;
        _searchCameUpEmpty = cached.isEmpty;
      });
      return;
    }
    // Bekannte Leersuche: sofort "nichts gefunden", kein Retry-Zyklus.
    if (_emptyQueryCache.contains(cacheKey)) {
      _productSearchRequestId++;
      setState(() {
        _productSuggestions = const <ProductSearchResult>[];
        _isSearchingProducts = false;
        _productSearchMessage = context.l10n.foodSearchNoResultsHint;
        _searchCameUpEmpty = true;
      });
      return;
    }

    final requestId = ++_productSearchRequestId;
    setState(() {
      _isSearchingProducts = true;
      _productSearchMessage = null;
    });

    try {
      final suggestions = await _searchWithRetry(query, requestId);
      if (!mounted) return;
      if (requestId != _productSearchRequestId ||
          query != _searchController.text.trim()) {
        return;
      }
      setState(() {
        _productSuggestions = suggestions;
        _isSearchingProducts = false;
        _productSearchMessage = suggestions.isEmpty
            ? context.l10n.foodSearchNoResultsHint
            : null;
        _searchCameUpEmpty = suggestions.isEmpty;
      });
    } catch (error) {
      if (!mounted) return;
      if (requestId != _productSearchRequestId ||
          query != _searchController.text.trim()) {
        return;
      }
      final gedrosselt = _istDrosselung(error);
      setState(() {
        _isSearchingProducts = false;
        // Eine Drosselung wird IMMER benannt, auch auf dem getippten Weg
        // (showTransientError == false). Ohne Satz stuende die Trefferzone
        // stumm da, und der naechste Tastendruck schickte die naechste
        // Anfrage in dasselbe Limit.
        _productSearchMessage = gedrosselt
            ? context.l10n.searchRateLimited
            : (showTransientError
                  ? context.l10n.foodSearchUnreachableHint
                  : null);
        // Kein „gibt es nicht": eine Drosselung ist keine Auskunft ueber das
        // Produkt, also auch kein Weg in den Manuell-CTA.
        _searchCameUpEmpty = false;
      });
    }
  }

  /// Grobe Klassifizierung nach dem Muster von `auth_code_screen.dart`: die
  /// Suchpfade werfen ein nacktes [Exception]/`HttpException` mit dem
  /// Statuscode im Text (`… search failed: 429`) — einen eigenen Ausnahmetyp
  /// gibt es in der Dienstschicht nicht.
  ///
  /// Warum ueberhaupt: ein 429 ist die einzige Antwort, die vom Wiederholen
  /// SCHLECHTER wird. Ohne diese Weiche lief er in denselben Sammelzweig wie
  /// ein Netzfehler, wurde auf dem getippten Weg gar nicht angezeigt und sah
  /// damit aus wie „nichts gefunden" — worauf der naechste Tastendruck
  /// nachlegte.
  static bool _istDrosselung(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('429') ||
        raw.contains('too many requests') ||
        raw.contains('rate limit');
  }

  Future<List<ProductSearchResult>> _searchWithRetry(
    String query,
    int requestId,
  ) async {
    Object? lastError;
    final cacheKey = _normalizeQuery(query);

    for (var attempt = 0; attempt < _productSearchMaxAttempts; attempt++) {
      try {
        final suggestions = await widget.productService.searchProducts(query);
        // Eine erfolgreiche Antwort ist autoritativ — auch die leere. Leer
        // ist eine Auskunft, kein Fehler.
        //
        // Frueher lief sie durch dieselbe Retry-Schleife wie ein Netzfehler,
        // in der Annahme, der Mirror sei nur kalt. Der Preis dafuer traegt
        // jede erfolglose Suche: ein Versuch faechert sich in der
        // Dienstschicht ueber Mirror + OFF-de + OFF-world auf, drei Versuche
        // machen daraus neun Anfragen fuer ein „gibt es nicht" — und ein
        // gedrosselter Dienst wurde davon nur noch weiter gedrosselt.
        // Retries bleiben dort, wo sie hingehoeren: bei echten Fehlern.
        if (suggestions.isEmpty) {
          _emptyQueryCache.add(cacheKey);
        } else {
          _productSearchCache[cacheKey] = suggestions;
        }
        return suggestions;
      } catch (error) {
        lastError = error;
      }

      final isLastAttempt = attempt == _productSearchMaxAttempts - 1;
      // Eine Drosselung wird vom Wiederholen schlimmer statt besser: sofort
      // raus, der Aufrufer benennt sie dem Nutzer.
      if (isLastAttempt ||
          _istDrosselung(lastError) ||
          requestId != _productSearchRequestId) {
        break;
      }
      await Future<void>.delayed(_productSearchRetryDelay);
    }

    throw lastError!;
  }

  static String _normalizeQuery(String query) =>
      query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  // ─── Foto / Galerie / Barcode ─────────────────────────────────────────

  Future<void> _pickAndAnalyze(ImageSource source) async {
    MealPhotoSelection? selection;
    try {
      selection = await widget.photoInput.pick(source);
    } on PlatformException catch (_) {
      if (!mounted) return;
      final l10n = context.l10n;
      showAppSnack(
        context,
        source == ImageSource.camera
            ? l10n.foodCameraPermissionError
            : l10n.foodGalleryPermissionError,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }
    if (selection == null || !mounted) return;

    await showMealAnalysisSheet(
      context,
      slot: _selectedSlot,
      resultFuture: widget.analyzer.analyze(
        selection.request.withLanguage(context.l10n.localeName),
      ),
      previewImage: selection.previewBytes,
      onAdd: widget.onAdd,
      onUpdateMeal: widget.onUpdateMeal,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage: context.l10n.foodAnalysisFailedMessage,
    );
  }

  Future<void> _scanBarcode() async {
    // Bottom-Panel (~60% Hoehe) wie beim KI-Scan statt Vollbild-Wechsel.
    // Die Chips im Scanner starten auf dem hier gewaehlten Slot.
    final scan = await showBarcodeScannerSheet(
      context,
      initialSlot: _selectedSlot,
    );
    if (scan == null || !mounted) return;
    // Eine Umwahl im Scanner gilt auch fuer dieses Sheet — sonst stuende
    // im Kopf „Abendessen", waehrend der Treffer ins Mittagessen ging.
    _selectSlot(scan.slot);

    await showMealAnalysisSheet(
      context,
      slot: scan.slot,
      resultFuture: widget.productService.lookupBarcode(scan.code),
      previewImage: null,
      onAdd: widget.onAdd,
      onUpdateMeal: widget.onUpdateMeal,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage: context.l10n.foodBarcodeNotFoundMessage(scan.code),
    );
  }

  // ─── Manueller Eintrag ────────────────────────────────────────────────

  /// Einstieg fuer eigene Naehrwerte (Spec 2026-08-13). Das Formular baut nur
  /// das Ergebnis; geloggt wird hier ueber [_handleAdd] — inklusive der
  /// 0-kcal-Bremse (eine manuelle 0 traegt explicitZeroKcal und passiert sie)
  /// und des Erfolgs-Snacks. [initialName] kommt vom Such-CTA.
  Future<void> _openManualEntry({String? initialName}) async {
    final result = await showManualMealSheet(context, initialName: initialName);
    if (result == null || !mounted) return;
    _handleAdd('manual:${FavoriteMeal.idFor(result)}', result);
  }

  // ─── Hinzufuegen ──────────────────────────────────────────────────────

  void _handleAdd(String itemKey, MealAnalysisResult result) {
    // Letzte Bremse vor dem Tagebuch (B1/B7) — dieselbe Rolle, die
    // `MealAnalysisSheet._addToDaily` fuer den Foto-Pfad spielt. Ohne sie
    // liessen sich Bestandszeilen in `favorite_meals` mit
    // `calories_kcal = 0` (die Constraint erlaubt `>= 0`, der Vor-Fix-Code
    // hat sie erzeugt) weiterhin loggen — bestaetigt mit einem Snack, der
    // woertlich „0 kcal … hinzugefügt." sagte.
    //
    // Die Zeile wird bewusst NICHT aus Favoriten/Recents herausgefiltert:
    // unsichtbar waere sie auch nicht mehr ueber das X der Zeile loeschbar,
    // und der Nutzer wuesste nicht, warum sein Favorit verschwunden ist.
    // Sichtbar, nicht loggbar, mit Begruendung ist die ehrlichere Variante.
    //
    // explicitZeroKcal: eine GEMESSENE 0 (Wasser, Zero — die Datenquelle
    // sagt ausdruecklich 0 kcal) ist loggbar; die Bremse gilt dem Sentinel
    // „0 = unbekannt" der Alt-Zeilen, nicht dem Produkt.
    if (result.caloriesKcal <= 0 && !result.explicitZeroKcal) {
      showAppSnack(
        context,
        context.l10n.foodSuggestionWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }

    widget.onAdd(result, _selectedSlot);
    if (mounted) {
      final l10n = context.l10n;
      showAppSnack(
        context,
        l10n.commonKcalAddedToSlot(
          result.caloriesKcal,
          _selectedSlot.label(l10n),
        ),
        icon: Icons.check_circle_rounded,
      );
    }
    setState(() {
      _expandedItemKey = null;
      _justAddedKeys.add(itemKey);
    });
    _justAddedTimers.remove(itemKey)?.cancel();
    _justAddedTimers[itemKey] = Timer(_justAddedFadeDelay, () {
      _justAddedTimers.remove(itemKey);
      if (!mounted) return;
      setState(() => _justAddedKeys.remove(itemKey));
    });
  }

  void _toggleExpanded(String key) {
    setState(() {
      _expandedItemKey = _expandedItemKey == key ? null : key;
    });
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final mediaQuery = MediaQuery.of(context);
    // Safe-Area- und Tastatur-bewusst statt fester 92 % (sheetMaxHeight):
    // mit offener Suchfeld-Tastatur schob der feste Anteil das Sheet bis
    // unter die Dynamic Island — der Kopf mit Kamera/Galerie/Barcode war auf
    // dem iPhone nicht mehr zu sehen. Jetzt schrumpft der Scrollbereich.
    final maxHeight = sheetMaxHeightOf(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // Kein SheetScaffold: das Sheet traegt drei fixe Zonen (Kopf, Suchleiste,
    // Slot-Wahl) ueber einem gedeckelten Scrollbereich und hat gar keine
    // Fussaktion — jede Zeile loggt selbst.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        key: const ValueKey('add-meal-sheet'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            _SheetHeader(
              slot: _selectedSlot,
              searchMode: widget.searchMode,
              onClose: () => Navigator.of(context).pop(),
              onCamera: () => _pickAndAnalyze(ImageSource.camera),
              onGallery: () => _pickAndAnalyze(ImageSource.gallery),
              onBarcode: _scanBarcode,
            ),
            _SearchBar(
              controller: _searchController,
              isSearching: _isSearchingProducts,
              onChanged: _scheduleProductSearch,
              onSubmitted: (_) => _searchProducts(),
              onSearchPressed: _searchProducts,
            ),
            Padding(
              key: const ValueKey('add-meal-slot-select'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: SlotSelector(
                selected: _selectedSlot,
                onSelected: _selectSlot,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('add-meal-sheet-scroll'),
                padding: EdgeInsets.fromLTRB(
                  20,
                  12,
                  20,
                  28 + mediaQuery.viewPadding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Stehender Eingang zum manuellen Eintrag — solange nicht
                    // aktiv gesucht wird; ab da uebernimmt der Kontext-CTA
                    // unter "nichts gefunden" (_buildSearchResults).
                    if (!_searchActive) ...[
                      _ManualEntryRow(onTap: () => _openManualEntry()),
                      const SizedBox(height: 16),
                    ],
                    if (_slotMeals.isNotEmpty) ...[
                      ExistingMealsList(
                        meals: _slotMeals,
                        slot: _selectedSlot,
                        onRemove: widget.onRemoveMeal == null
                            ? null
                            : _removeExisting,
                        onEdit: widget.onUpdateMealDetails == null
                            ? null
                            : _editExisting,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_searchActive)
                      _buildSearchResults()
                    else
                      // Beim Entfernen eines Favoriten fällt die Liste sanft
                      // zusammen statt hart zu springen.
                      AnimatedSize(
                        duration: motionDuration(
                          context,
                          const Duration(milliseconds: 220),
                        ),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: _buildFavorites(),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_isSearchingProducts && _productSuggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.t.accent,
            ),
          ),
        ),
      );
    }
    if (_productSuggestions.isEmpty && _productSearchMessage != null) {
      return Column(
        children: [
          _HintBlock(text: _productSearchMessage!),
          if (_searchCameUpEmpty)
            // Der Hofladen-Moment: endgueltig nichts gefunden -> direkt ins
            // Formular, mit dem Suchbegriff als Namens-Vorbelegung.
            TextButton.icon(
              key: const ValueKey('manual-entry-cta'),
              onPressed: () =>
                  _openManualEntry(initialName: _searchController.text.trim()),
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: Text(context.l10n.foodManualEntryCta),
            ),
        ],
      );
    }
    if (_productSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(context.l10n.foodSectionSearchResults),
        const SizedBox(height: 8),
        for (var i = 0; i < _productSuggestions.length; i++) ...[
          _suggestionItem(i),
          if (i != _productSuggestions.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _suggestionItem(int index) {
    final suggestion = _productSuggestions[index];
    final key = 'product:${suggestion.code}';
    return MealSuggestionItem(
      key: ValueKey('kcal-product-suggestion-$index'),
      result: suggestion.result,
      imageUrl: suggestion.imageUrl,
      fallbackIcon: Icons.fastfood_outlined,
      expanded: _expandedItemKey == key,
      justAdded: _justAddedKeys.contains(key),
      onTap: () => _toggleExpanded(key),
      onAdd: (result) => _handleAdd(key, result),
      addButtonKey: ValueKey('kcal-product-suggestion-add-$index'),
      isFavorite: widget.isFavorite?.call(suggestion.result) ?? false,
      onToggleFavorite: widget.onToggleFavorite == null
          ? null
          : (result) => _handleToggleFavorite(result),
      favoriteButtonKey: ValueKey('kcal-product-suggestion-fav-$index'),
    );
  }

  // Favoriten (angeheftet) zuerst, dann Auto-Recents. Beide kommen aus
  // derselben Liste, getrennt ueber das pinned-Flag.
  List<FavoriteMeal> get _pinned =>
      _favorites.where((f) => f.pinned).toList(growable: false);
  List<FavoriteMeal> get _recents =>
      _favorites.where((f) => !f.pinned).toList(growable: false);

  Widget _buildFavorites() {
    if (_favorites.isEmpty) {
      return const _EmptyState();
    }
    final pinned = _pinned;
    final recents = _recents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pinned.isNotEmpty) ...[
          _SectionLabel(context.l10n.foodSectionFavorites),
          const SizedBox(height: 8),
          for (var i = 0; i < pinned.length; i++) ...[
            _favoriteItem(pinned[i], i, pinned: true),
            if (i != pinned.length - 1) const SizedBox(height: 8),
          ],
          if (recents.isNotEmpty) const SizedBox(height: 18),
        ],
        if (recents.isNotEmpty) ...[
          _SectionLabel(context.l10n.foodSectionRecentMeals),
          const SizedBox(height: 8),
          for (var i = 0; i < recents.length; i++) ...[
            _favoriteItem(recents[i], i, pinned: false),
            if (i != recents.length - 1) const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  Widget _favoriteItem(
    FavoriteMeal favorite,
    int index, {
    required bool pinned,
  }) {
    final key = 'favorite:${favorite.id}';
    // Stabile, sektionsweise Keys: angeheftete -> favorite-pinned-*, Recents
    // behalten den bestehenden favorite-tile-* Key (Test-Pin) bei.
    final tileKey = pinned ? 'favorite-pinned-$index' : 'favorite-tile-$index';
    final addKey = pinned
        ? 'favorite-pinned-add-$index'
        : 'favorite-tile-add-$index';
    return MealSuggestionItem(
      key: ValueKey(tileKey),
      result: favorite.result,
      fallbackIcon: pinned
          ? Icons.favorite_rounded
          : Icons.bookmark_outline_rounded,
      expanded: _expandedItemKey == key,
      justAdded: _justAddedKeys.contains(key),
      onTap: () => _toggleExpanded(key),
      onAdd: (result) => _handleAdd(key, result),
      onRemove: () => _removeFavorite(favorite.id),
      addButtonKey: ValueKey(addKey),
      isFavorite: favorite.pinned,
      onToggleFavorite: widget.onToggleFavorite == null
          ? null
          : (result) => _handleToggleFavorite(result),
      favoriteButtonKey: ValueKey('$tileKey-fav'),
    );
  }

  // Toggle nach oben melden UND die lokale Sheet-Liste sofort spiegeln, damit
  // das Herz ohne Sheet-Neuaufbau umschaltet (Favoriten <-> Recents).
  void _handleToggleFavorite(MealAnalysisResult result) {
    widget.onToggleFavorite?.call(result);
    final id = FavoriteMeal.idFor(result);
    setState(() {
      final idx = _favorites.indexWhere((f) => f.id == id);
      if (idx == -1) {
        _favorites = [
          FavoriteMeal(
            id: id,
            result: result,
            addedAt: DateTime.now(),
            pinned: true,
          ),
          ..._favorites,
        ];
      } else {
        final current = _favorites[idx];
        final next = [..._favorites];
        next[idx] = current.copyWith(pinned: !current.pinned);
        _favorites = next;
      }
    });
  }
}

// ─── Header ─────────────────────────────────────────────────────────────

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.slot,
    this.searchMode = false,
    required this.onClose,
    required this.onCamera,
    required this.onGallery,
    required this.onBarcode,
  });

  final MealSlot slot;
  final bool searchMode;
  final VoidCallback onClose;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onBarcode;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = searchMode ? l10n.foodSearchModeTitle : slot.label(l10n);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 6, 10),
      child: Row(
        children: [
          if (searchMode)
            IconTile(icon: Icons.search_rounded, color: t.accent, size: 36)
          else
            MealAvatar(
              letter: slot.initial(l10n),
              color: slot.accentIn(context),
              size: 36,
            ),
          const SizedBox(width: 12),
          Expanded(
            // Einzeilig, immer (Nutzer-Feedback 2026-08-13): ein viertes
            // Header-Icon hatte "Breakfast" umbrechen lassen. Das Icon ist
            // raus (der manuelle Eintrag hat jetzt seine beschriftete Zeile
            // unter der Slot-Wahl), und der Titel bleibt auch bei langen
            // Slot-Namen/grosser Schrift auf einer Zeile.
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.display(18, color: t.ink),
            ),
          ),
          // Foto/Galerie/Barcode nur im normalen Add-Modus. Im Such-Modus
          // bleibt der Kopf schlank — die Suche hat ihre eigenen Aktions-
          // Buttons im Food-Tab, hier wird nur gesucht.
          //
          // Die drei tragen jetzt denselben gedaempften Ton: sie sind
          // gleichrangige Eingaenge, und die frueheren drei Farben waren
          // Makro-/Wellness-Toene aus einer fremden Bedeutungsebene.
          if (!searchMode) ...[
            _HeaderIconButton(
              keyValue: const ValueKey('analyse-camera-button'),
              icon: Icons.photo_camera_rounded,
              tooltip: l10n.foodTakePhotoTooltip,
              onPressed: onCamera,
            ),
            _HeaderIconButton(
              keyValue: const ValueKey('analyse-gallery-button'),
              icon: Icons.photo_library_outlined,
              tooltip: l10n.foodFromGalleryTooltip,
              onPressed: onGallery,
            ),
            _HeaderIconButton(
              keyValue: const ValueKey('analyse-barcode-button'),
              icon: Icons.qr_code_scanner_rounded,
              tooltip: l10n.foodScanBarcodeTooltip,
              onPressed: onBarcode,
            ),
            const SizedBox(width: 2),
          ],
          IconButton(
            key: const ValueKey('add-meal-sheet-close'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.keyValue,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key keyValue;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: keyValue,
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: IconTile(icon: icon),
    );
  }
}

// ─── Search bar ─────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.isSearching,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSearchPressed,
  });

  final TextEditingController controller;
  final bool isSearching;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSearchPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      key: const ValueKey('kcal-product-search-card'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: t.line),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search_rounded, size: 18, color: t.ink2),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('kcal-product-search-input'),
                controller: controller,
                autofocus: true,
                // iOS-Default ist ein Dauer-Fade des Cursors -> haelt die App
                // bei offenem Sheet auf ~60fps Dauer-Rendering. Diskretes
                // Blinken repaintet nur ~2x/s (gilt app-weit fuer alle Felder).
                cursorOpacityAnimates: false,
                cursorColor: t.accent,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                textInputAction: TextInputAction.search,
                style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                decoration: InputDecoration(
                  hintText: context.l10n.foodSearchInputHint,
                  hintStyle: AppType.ui(
                    14,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('kcal-product-search-button'),
              tooltip: context.l10n.foodSearchButtonTooltip,
              onPressed: isSearching ? null : onSearchPressed,
              icon: isSearching
                  ? SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: t.accent,
                      ),
                    )
                  : Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: t.accent,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty / hint / labels ──────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: AppType.eyebrow(context.t.ink2, size: 11),
    );
  }
}

/// Stehender Eingang zum manuellen Eintrag (Nutzer-Feedback 2026-08-13):
/// das vierte Header-Icon quetschte den Slot-Titel zweizeilig und war als
/// nackter Stift kaum zu entdecken. Jetzt eine BESCHRIFTETE Zeile in voller
/// Breite direkt unter der Slot-Wahl — Text schlaegt Icon bei der
/// Auffindbarkeit. Optik der Suchleisten-Kapsel (46 px, surf, line-Rand),
/// damit die beiden Eingaenge dieselbe Formsprache sprechen.
class _ManualEntryRow extends StatelessWidget {
  const _ManualEntryRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      borderRadius: BorderRadius.circular(rControl),
      child: InkWell(
        key: const ValueKey('manual-entry-button'),
        borderRadius: BorderRadius.circular(rControl),
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: t.line),
          ),
          child: Row(
            children: [
              Icon(Icons.edit_rounded, size: 18, color: t.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.l10n.foodManualEntryCta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: t.ink2),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintBlock extends StatelessWidget {
  const _HintBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppType.ui(
          13,
          weight: FontWeight.w500,
          color: context.t.ink2,
          height: 1.4,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Volle Breite erzwingen: die Inhalts-Spalte des Sheets richtet ihre
    // Kinder links aus und ist seit der Manuell-Zeile (PR #38) immer
    // viewport-breit — ohne eigene Breite hing dieser Block deshalb an der
    // linken Kante, statt sich zu zentrieren (Nutzer-Befund 2026-08-14).
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            IconTile(
              icon: Icons.restaurant_outlined,
              color: t.accent,
              size: 56,
            ),
            const SizedBox(height: 14),
            Text(
              context.l10n.foodEmptyStateTitle,
              textAlign: TextAlign.center,
              style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.foodEmptyStateSubtitle,
              textAlign: TextAlign.center,
              style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
            ),
          ],
        ),
      ),
    );
  }
}
