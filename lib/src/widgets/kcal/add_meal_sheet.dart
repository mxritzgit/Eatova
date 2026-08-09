import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

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
import 'meal_analysis_sheet.dart';
import 'meal_suggestion_item.dart';
import 'slot_selector.dart';

/// Meldung, wenn eine Zeile aus Suche, Favoriten oder Recents ohne
/// Kalorienangabe geloggt werden soll.
///
/// Bewusst **nicht** [kMealWithoutCaloriesMessage] aus dem Analyse-Sheet: der
/// dortige Wortlaut verweist auf „Anpassen" → Bestandteile eintragen, und
/// genau diesen Weg gibt es hier nicht. Das aufgeklappte Kaertchen hat nur
/// einen Portionsregler, und 0 kcal bleiben bei jeder Portion 0. Der einzige
/// Ausweg ist, den Bestandseintrag zu ersetzen — das steht hier deshalb auch
/// so drin. Zwei Saetze mit verschiedenem Inhalt sind keine gespiegelte
/// Konstante; als Konstante steht der Text hier nur, damit Tests denselben
/// Wortlaut pruefen wie die Oberflaeche.
const String kSuggestionWithoutCaloriesMessage =
    'Ohne Kalorienangabe lässt sich nichts loggen. Der Eintrag stammt noch '
    'aus einer älteren Version — entferne ihn und leg ihn über Suche oder '
    'Barcode neu an.';

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
  // statt wieder den vollen Retry-Zyklus zu durchlaufen.
  final Set<String> _emptyQueryCache = <String>{};
  List<ProductSearchResult> _productSuggestions = const <ProductSearchResult>[];
  bool _isSearchingProducts = false;
  String? _productSearchMessage;

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

  bool get _searchActive => _searchController.text.trim().length >= 2;

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

    if (query.length < 2) {
      _productSearchRequestId++;
      setState(() {
        _isSearchingProducts = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = null;
      });
      return;
    }

    // rebuild damit _searchActive umschaltet (Favoriten -> Treffer-Slot).
    setState(() {});
    _productSearchDebounce = Timer(
      _productSearchDebounceDelay,
      () => _searchProducts(queryOverride: query, showTransientError: false),
    );
  }

  Future<void> _searchProducts({
    String? queryOverride,
    bool showTransientError = true,
  }) async {
    _productSearchDebounce?.cancel();
    final query = (queryOverride ?? _searchController.text).trim();
    if (query.length < 2) {
      setState(() {
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = 'Mindestens 2 Zeichen, z.B. Dr Oetker Salami.';
      });
      return;
    }

    final cacheKey = _normalizeQuery(query);
    final cached = _productSearchCache[cacheKey];
    if (cached != null) {
      _productSearchRequestId++;
      setState(() {
        _productSuggestions = cached;
        _isSearchingProducts = false;
        _productSearchMessage = cached.isEmpty
            ? 'Keine passenden Produkte gefunden. Versuche Marke + Produktname.'
            : null;
      });
      return;
    }
    // Bekannte Leersuche: sofort "nichts gefunden", kein Retry-Zyklus.
    if (_emptyQueryCache.contains(cacheKey)) {
      _productSearchRequestId++;
      setState(() {
        _productSuggestions = const <ProductSearchResult>[];
        _isSearchingProducts = false;
        _productSearchMessage =
            'Keine passenden Produkte gefunden. Versuche Marke + Produktname.';
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
            ? 'Keine passenden Produkte gefunden. Versuche Marke + Produktname.'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      if (requestId != _productSearchRequestId ||
          query != _searchController.text.trim()) {
        return;
      }
      setState(() {
        _isSearchingProducts = false;
        _productSearchMessage = showTransientError
            ? 'OpenFoodFacts gerade nicht erreichbar.'
            : null;
      });
    }
  }

  Future<List<ProductSearchResult>> _searchWithRetry(
    String query,
    int requestId,
  ) async {
    Object? lastError;
    final cacheKey = _normalizeQuery(query);

    for (var attempt = 0; attempt < _productSearchMaxAttempts; attempt++) {
      List<ProductSearchResult>? suggestions;
      try {
        suggestions = await widget.productService.searchProducts(query);
        lastError = null;
        // Treffer sind sofort autoritativ und werden gecached.
        if (suggestions.isNotEmpty) {
          _productSearchCache[cacheKey] = suggestions;
          return suggestions;
        }
        // Eine leere Antwort kann transient sein (Mirror gerade kalt, Index
        // noch nicht warm). Sie wird wie ein Fehler über die *begrenzte*
        // Retry-Schleife (max 3 Versuche, je 600 ms) erneut versucht – nicht
        // über den langen ~30-s-Zyklus. Erst wenn alle Versuche leer bleiben,
        // gilt "nichts gefunden" als final und wird gecached.
      } catch (error) {
        lastError = error;
      }

      final isLastAttempt = attempt == _productSearchMaxAttempts - 1;
      if (isLastAttempt || requestId != _productSearchRequestId) {
        // Nach erschöpften Versuchen: leere (aber fehlerfreie) Antwort ist
        // jetzt autoritativ -> als Leersuche cachen und zurückgeben.
        if (lastError == null) {
          _emptyQueryCache.add(cacheKey);
          return suggestions ?? const <ProductSearchResult>[];
        }
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
      showAppSnack(
        context,
        source == ImageSource.camera
            ? 'Kamera konnte nicht geöffnet werden. Prüfe die Berechtigung.'
            : 'Galerie konnte nicht geöffnet werden. Prüfe die Berechtigung.',
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
      resultFuture: widget.analyzer.analyze(selection.request),
      previewImage: selection.previewBytes,
      onAdd: widget.onAdd,
      onUpdateMeal: widget.onUpdateMeal,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage:
          'Analyse fehlgeschlagen. Prüfe Internet, Supabase und OpenRouter.',
    );
  }

  Future<void> _scanBarcode() async {
    // Bottom-Panel (~60% Hoehe) wie beim KI-Scan statt Vollbild-Wechsel.
    final barcode = await showBarcodeScannerSheet(context);
    final trimmed = barcode?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;

    await showMealAnalysisSheet(
      context,
      slot: _selectedSlot,
      resultFuture: widget.productService.lookupBarcode(trimmed),
      previewImage: null,
      onAdd: widget.onAdd,
      onUpdateMeal: widget.onUpdateMeal,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage:
          'Barcode $trimmed nicht gefunden oder OpenFoodFacts nicht erreichbar.',
    );
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
        kSuggestionWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }

    widget.onAdd(result, _selectedSlot);
    if (mounted) {
      showAppSnack(
        context,
        '${result.caloriesKcal} kcal zu ${_selectedSlot.label} hinzugefügt.',
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
    final maxHeight = mediaQuery.size.height * 0.92;
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // Kein SheetScaffold: das Sheet traegt drei fixe Zonen (Kopf, Suchleiste,
    // Slot-Wahl) ueber einem gedeckelten Scrollbereich und hat gar keine
    // Fussaktion — jede Zeile loggt selbst.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
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
      return _HintBlock(text: _productSearchMessage!);
    }
    if (_productSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Suchtreffer'),
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
          const _SectionLabel('Favoriten'),
          const SizedBox(height: 8),
          for (var i = 0; i < pinned.length; i++) ...[
            _favoriteItem(pinned[i], i, pinned: true),
            if (i != pinned.length - 1) const SizedBox(height: 8),
          ],
          if (recents.isNotEmpty) const SizedBox(height: 18),
        ],
        if (recents.isNotEmpty) ...[
          const _SectionLabel('Letzte Mahlzeiten'),
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
    final title = searchMode ? 'Lebensmittel suchen' : slot.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 6, 10),
      child: Row(
        children: [
          if (searchMode)
            IconTile(icon: Icons.search_rounded, color: t.accent, size: 36)
          else
            MealAvatar(
              letter: slot.initial,
              color: slot.accentIn(context),
              size: 36,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
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
              tooltip: 'Foto aufnehmen',
              onPressed: onCamera,
            ),
            _HeaderIconButton(
              keyValue: const ValueKey('analyse-gallery-button'),
              icon: Icons.photo_library_outlined,
              tooltip: 'Aus Galerie',
              onPressed: onGallery,
            ),
            _HeaderIconButton(
              keyValue: const ValueKey('analyse-barcode-button'),
              icon: Icons.qr_code_scanner_rounded,
              tooltip: 'Barcode scannen',
              onPressed: onBarcode,
            ),
            const SizedBox(width: 2),
          ],
          IconButton(
            key: const ValueKey('add-meal-sheet-close'),
            onPressed: onClose,
            tooltip: 'Schließen',
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
                  hintText: 'Was hast du gegessen?',
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
              tooltip: 'Suchen',
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
    return Padding(
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
            'Suche oben oder scanne einen Barcode',
            textAlign: TextAlign.center,
            style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
          ),
          const SizedBox(height: 4),
          Text(
            'Eingaben erscheinen direkt in der Liste oben.',
            textAlign: TextAlign.center,
            style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
