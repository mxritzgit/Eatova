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

/// Message when a search/favorite/recent row without calories is logged —
/// `l10n.foodSuggestionWithoutCaloriesMessage`.
///
/// Deliberately not [kMealWithoutCaloriesMessage] from the analysis sheet: its
/// wording points at "adjust" → enter components, a path that does not exist
/// here (the expanded card only has a portion slider, and 0 kcal stays 0 at
/// any portion). Two separate ARB keys instead of one mirrored constant.

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
  // Resolve the edit callback from the scope BEFORE the route change: the
  // sheet's builder context hangs off the navigator and no longer sees the
  // home page's MealEditScope. Without a scope the list stays non-editable.
  final resolvedUpdateDetails =
      onUpdateMealDetails ?? MealEditScope.maybeOf(context)?.onUpdateMeal;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // No token on purpose: the scrim darkens in both display modes, a light
    // scrim would dim nothing.
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

  /// Logs the result and returns the client UUID (see MealAnalysisSheet) for
  /// later re-portioning.
  final String Function(MealAnalysisResult, MealSlot) onAdd;

  /// Replaces a logged row's result by id (kcal + macros).
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;
  final ValueChanged<String> onRemoveFavorite;

  /// Is the meal currently pinned? Null -> no heart.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favorite toggle (pin/unpin). Null -> no heart.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final List<LoggedMeal> existingMeals;
  final ValueChanged<String>? onRemoveMeal;

  /// Details update for the edit sheet (portion/slot/day). Null -> already
  /// added rows are not tappable.
  final UpdateMealDetails? onUpdateMealDetails;

  @override
  State<AddMealSheet> createState() => _AddMealSheetState();
}

/// Deliberately WITHOUT a discard guard (D5) — checked, not forgotten.
///
/// The criterion for `PopScope` + `_DiscardDragGuard` is authored content that
/// cost effort, not "holds a TextEditingController". This sheet holds a search
/// term and which card is expanded: a query, not input, restored in seconds.
/// Searching is the sheet's purpose, so the dialog would fire on nearly every
/// close and be dismissed reflexively — losing its effect where it counts.
class _AddMealSheetState extends State<AddMealSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _productSearchDebounce;
  int _productSearchRequestId = 0;
  final Map<String, List<ProductSearchResult>> _productSearchCache =
      <String, List<ProductSearchResult>>{};
  // Session cache of empty searches: a term that came back empty (without
  // error) answers "nothing found" instantly, without hitting the services.
  final Set<String> _emptyQueryCache = <String>{};
  List<ProductSearchResult> _productSuggestions = const <ProductSearchResult>[];
  bool _isSearchingProducts = false;
  String? _productSearchMessage;

  /// True only after a definitively empty (error-free) search — the one state
  /// that shows the manual-entry CTA. Network errors and the min-chars hint
  /// mean "search broken/too short", not "does not exist" (spec 2026-08-13).
  bool _searchCameUpEmpty = false;

  /// Did the user trigger the search explicitly (magnifier/enter)? Only then
  /// does a fragment below [_autoSearchMinChars] count as an active search.
  /// Any further keystroke revokes it, otherwise the result zone would stay
  /// open while the debounce no longer sends anything.
  bool _explicitSearchRequested = false;

  String? _expandedItemKey;
  final Set<String> _justAddedKeys = <String>{};
  final Map<String, Timer> _justAddedTimers = <String, Timer>{};

  // The slot is sheet state, not a fixed input: it defaults to the passed
  // (time-of-day) suggestion and can be changed in the selector.
  late MealSlot _selectedSlot;
  late List<LoggedMeal> _existing;
  late List<FavoriteMeal> _favorites;

  // These durations deliberately bypass `motionDuration`: they time network
  // and display logic, not motion. At 0 the debounce would fire per keystroke,
  // the retry delay would defeat the backoff, and the just-added check would
  // vanish before anyone sees it. "Reduce motion" must not change behavior.
  static const Duration _productSearchDebounceDelay = Duration(
    milliseconds: 1000,
  );
  static const Duration _productSearchRetryDelay = Duration(milliseconds: 600);
  static const int _productSearchMaxAttempts = 3;
  static const Duration _justAddedFadeDelay = Duration(seconds: 2);

  /// Shortest input worth a search at all — applies to the explicit path
  /// (magnifier/enter).
  static const int _searchMinChars = 2;

  /// Threshold for the debounce to fire on its own, deliberately higher than
  /// [_searchMinChars]: a failed search fans out over mirror + OFF-de +
  /// OFF-world, and a two-letter fragment is almost always on its way to a
  /// word. The magnifier still reaches short terms.
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

  // Logged entries of the selected slot, filtered from the full day list, so
  // the header stays in sync with the selector.
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

  /// Results zone instead of favorites. Below [_autoSearchMinChars] favorites
  /// and recents stay unless the search was triggered explicitly, otherwise
  /// the area would be empty — the debounce sends nothing for short input.
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

  /// Tap on an already-added row: open the edit sheet, then bring the sheet's
  /// LOCAL day list in line (it holds a copy and does not rebuild from the
  /// store). A day change removes the entry — the list shows one day only.
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
      return; // _removeExisting already updated the list.
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

  // ─── Search ───────────────────────────────────────────────────────────

  void _scheduleProductSearch(String value) {
    final query = value.trim();
    _productSearchDebounce?.cancel();

    if (query.length < _autoSearchMinChars) {
      _productSearchRequestId++;
      setState(() {
        // New input revokes the magnifier/enter unlock: the previous hits
        // belong to a different term.
        _explicitSearchRequested = false;
        _isSearchingProducts = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = null;
        _searchCameUpEmpty = false;
      });
      return;
    }

    // Rebuild so _searchActive flips (favorites -> results zone).
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

  /// [explicit] separates magnifier/enter from the debounce: only the explicit
  /// path unlocks the results zone for a fragment below
  /// [_autoSearchMinChars].
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
    // Known empty search: answer immediately, no retry cycle.
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
        // Rate limiting is always named, even on the typed path
        // (showTransientError == false): otherwise the zone stays silent and
        // the next keystroke runs into the same limit.
        _productSearchMessage = gedrosselt
            ? context.l10n.searchRateLimited
            : (showTransientError
                  ? context.l10n.foodSearchUnreachableHint
                  : null);
        // Not "does not exist": rate limiting says nothing about the product,
        // so it must not open the manual CTA.
        _searchCameUpEmpty = false;
      });
    }
  }

  /// Coarse classification like `auth_code_screen.dart`: the search paths
  /// throw a bare [Exception]/`HttpException` with the status code in the text
  /// — the service layer has no dedicated exception type.
  ///
  /// A 429 is the one answer that gets worse from retrying, so it needs its
  /// own branch instead of looking like "nothing found".
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
        // A successful answer is authoritative, the empty one included: empty
        // is information, not an error. Retrying it would fan one search out
        // over mirror + OFF-de + OFF-world three times over. Retries stay
        // where they belong: real errors.
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
      // Rate limiting gets worse from retrying: bail out, the caller names it.
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

  // ─── Photo / gallery / barcode ────────────────────────────────────────

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
    // Bottom panel like the AI scan instead of a full-screen switch. The
    // scanner's chips start on the slot selected here.
    final scan = await showBarcodeScannerSheet(
      context,
      initialSlot: _selectedSlot,
    );
    if (scan == null || !mounted) return;
    // A slot change in the scanner applies to this sheet too, otherwise the
    // header would show one slot while the hit went to another.
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

  // ─── Manual entry ─────────────────────────────────────────────────────

  /// Entry point for own nutrition values (spec 2026-08-13). The form only
  /// builds the result; logging happens here via [_handleAdd], including the
  /// 0-kcal guard (a manual 0 carries explicitZeroKcal and passes it) and the
  /// success snack. [initialName] comes from the search CTA.
  Future<void> _openManualEntry({String? initialName}) async {
    final result = await showManualMealSheet(context, initialName: initialName);
    if (result == null || !mounted) return;
    _handleAdd('manual:${FavoriteMeal.idFor(result)}', result);
  }

  // ─── Adding ───────────────────────────────────────────────────────────

  void _handleAdd(String itemKey, MealAnalysisResult result) {
    // Last guard before the diary (B1/B7), the role
    // `MealAnalysisSheet._addToDaily` plays for the photo path: legacy
    // `favorite_meals` rows with `calories_kcal = 0` must not be loggable.
    //
    // Such rows are deliberately NOT filtered out of favorites/recents —
    // invisible rows could not be deleted via their X either. Visible, not
    // loggable, with a reason is the honest variant.
    //
    // explicitZeroKcal: a MEASURED 0 (water, zero drinks) is loggable; the
    // guard targets the "0 = unknown" sentinel of old rows, not the product.
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
    // Safe-area and keyboard aware instead of a fixed 92 % (sheetMaxHeight):
    // with the search keyboard open the fixed share pushed the header under
    // the Dynamic Island. Now the scroll area shrinks instead.
    final maxHeight = sheetMaxHeightOf(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // No SheetScaffold: three fixed zones (header, search bar, slot picker)
    // over a capped scroll area, and no footer action — every row logs itself.
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
                    // Standing entry point for manual entry while no search is
                    // active; after that the contextual CTA under "nothing
                    // found" takes over (_buildSearchResults).
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
                      // Removing a favorite collapses the list smoothly
                      // instead of jumping.
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
            // Definitively nothing found -> straight into the form, with the
            // query prefilled as the name.
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

  // Pinned favorites first, then auto recents — one list, split by the
  // pinned flag.
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
    // Stable per-section keys: pinned -> favorite-pinned-*, recents keep the
    // existing favorite-tile-* key (tests pin it).
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

  // Report the toggle upwards AND mirror it in the local list, so the heart
  // flips without rebuilding the sheet (favorites <-> recents).
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
            // Always single line (user feedback 2026-08-13): a fourth header
            // icon made the slot title wrap. The title now stays on one line
            // even with long slot names or large text.
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.display(18, color: t.ink),
            ),
          ),
          // Photo/gallery/barcode only in normal add mode; search mode keeps a
          // slim header. All three share the same muted tone because they are
          // equal-rank entry points.
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
                // The iOS default fades the cursor continuously, keeping the
                // app at ~60fps while the sheet is open. Discrete blinking
                // repaints ~2x/s (app-wide rule for all fields).
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

/// Standing entry point for manual entry (user feedback 2026-08-13): a bare
/// pencil icon in the header was hard to find and wrapped the slot title. Now
/// a labeled full-width row below the slot picker, styled like the search bar
/// capsule so both entry points share one shape.
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
    // Force full width: the sheet's content column aligns children left, so
    // without an own width this block hugged the left edge instead of
    // centering (user finding 2026-08-14).
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
