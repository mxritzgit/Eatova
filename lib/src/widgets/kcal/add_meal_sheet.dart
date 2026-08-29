import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_request.dart';
import '../../models/meal_analysis_result.dart';
import '../../screens/barcode_scanner_sheet.dart';
import '../../services/favorites_view.dart';
import '../../services/eatova_http.dart';
import '../../services/local_day.dart';
import '../../services/meal_analyzer.dart';
import '../../services/meal_photo_input.dart';
import '../../services/meals_sync.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'edit_meal_sheet.dart';
import 'existing_meals_list.dart';
import 'favorites_sheet.dart';
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

/// Live access to the two store lists the add-meal sheet renders.
///
/// The sheet lives in a modal route, and a `showModalBottomSheet` builder is
/// never rebuilt by a store notify. So the sheet used to open with a COPY of
/// "already added" and the favorites and only ever wrote INTO that copy:
/// everything the store did on its own never arrived. The undo of a deleted
/// meal was the worst case — the store put the row back, the sheet did not,
/// the user re-entered the meal and had it twice in the diary (review P8-01,
/// with P8-05/-06/-07 on the same root).
///
/// The scope is the active channel: [showAddMealSheet] resolves it from the
/// OPENING context (like [MealEditScope]; the sheet's own context hangs off
/// the navigator and no longer sees the food tab) and re-feeds the sheet the
/// current lists on every notify. Without a scope — previews, standalone
/// widget tests — the sheet keeps its opening snapshot and its own optimistic
/// mirror, exactly as before.
class FoodStoreScope extends InheritedWidget {
  const FoodStoreScope({
    super.key,
    required this.store,
    required this.mealsOfSelectedDay,
    required this.favorites,
    required super.child,
  });

  /// The store as a plain [Listenable]. The sheet only listens on it; every
  /// read goes through the two suppliers below, so this widget layer never
  /// learns the store's type.
  final Listenable store;

  /// Logged meals of the day the food tab shows, bucketed the DATA-6 way
  /// (`mealsForFoodDate`) — the same list the opener passes as a value.
  final List<LoggedMeal> Function() mealsOfSelectedDay;

  /// The full favorites list (pinned + auto recents) in store order.
  ///
  /// Must return the store's own list instance while nothing changed: the
  /// sheet uses its identity as the O(1) "did anything move" fingerprint.
  final List<FavoriteMeal> Function() favorites;

  /// Deliberately without dependency registration (like [MealEditScope]): the
  /// lookup happens in the sheet opener, outside build.
  static FoodStoreScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FoodStoreScope>();

  @override
  bool updateShouldNotify(FoodStoreScope oldWidget) =>
      !identical(store, oldWidget.store);
}

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
  DateTime? foodDate,
  ValueChanged<String>? onRemoveMeal,
  UpdateMealDetails? onUpdateMealDetails,
}) {
  // Resolve the edit callback from the scope BEFORE the route change: the
  // sheet's builder context hangs off the navigator and no longer sees the
  // home page's MealEditScope. Without a scope the list stays non-editable.
  final resolvedUpdateDetails =
      onUpdateMealDetails ?? MealEditScope.maybeOf(context)?.onUpdateMeal;
  // Same reason, same moment: the live source of both lists (P8-01/-05).
  final live = FoodStoreScope.maybeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
    builder: (sheetContext) {
      AddMealSheet sheet(
        List<LoggedMeal> meals,
        List<FavoriteMeal> favoriteMeals,
      ) {
        return AddMealSheet(
          slot: slot,
          searchMode: searchMode,
          analyzer: analyzer,
          productService: productService,
          photoInput: photoInput,
          favorites: favoriteMeals,
          existingMeals: meals,
          foodDate: foodDate,
          onAdd: onAdd,
          onUpdateMeal: onUpdateMeal,
          onRemoveFavorite: onRemoveFavorite,
          isFavorite: isFavorite,
          onToggleFavorite: onToggleFavorite,
          onRemoveMeal: onRemoveMeal,
          onUpdateMealDetails: resolvedUpdateDetails,
        );
      }

      if (live == null) return sheet(existingMeals, favorites);
      // The channel: every store notify rebuilds here and hands the sheet the
      // CURRENT lists, which its state adopts (see `didUpdateWidget`). Plain
      // ListenableBuilder, no slice selector — the sheet is one modal at a
      // time and both suppliers are O(1) reads plus one day filter.
      return ListenableBuilder(
        listenable: live.store,
        builder: (_, __) => sheet(live.mealsOfSelectedDay(), live.favorites()),
      );
    },
  );
}

/// Adopts an incoming favorites list but keeps every entry the sheet already
/// holds whose content did not change (P8-07b).
///
/// [MealSuggestionItem] resets a typed portion as soon as its `result` instance
/// changes — the guard against index-keyed rows handing a State the NEXT row's
/// meal (review B, 2026-08-27). It rests on callers handing out stable
/// instances; the boot load hands out new ones for unchanged rows and so turned
/// that guard into data loss. Reusing the old instance restores the contract
/// without weakening the reset: an entry that really moved (the store rewriting
/// a recent with the logged result, P8-07) arrives as a new instance and still
/// resets its row.
///
/// The fingerprint is [mealResultToJson] — the projection the persistence layer
/// already keeps complete and round-trip-safe, so this cannot fall behind a new
/// model field and hand a stale result to `onAdd`.
List<FavoriteMeal> _uebernommeneFavoriten(
  List<FavoriteMeal> bisher,
  List<FavoriteMeal> neu,
) {
  final vorhanden = <String, FavoriteMeal>{for (final f in bisher) f.id: f};
  return <FavoriteMeal>[
    for (final f in neu)
      if (_favoritUnveraendert(vorhanden[f.id], f)) vorhanden[f.id]! else f,
  ];
}

bool _favoritUnveraendert(FavoriteMeal? bisher, FavoriteMeal neu) {
  if (bisher == null) return false;
  if (identical(bisher, neu)) return true;
  return bisher.pinned == neu.pinned &&
      bisher.addedAt.isAtSameMomentAs(neu.addedAt) &&
      _gleicherJsonWert(
        mealResultToJson(bisher.result),
        mealResultToJson(neu.result),
      );
}

/// Deep equality over the JSON shapes [mealResultToJson] produces (scalars,
/// lists, string-keyed maps). Hand-rolled: `package:collection` is not a
/// declared dependency here, and `jsonEncode` would throw on a non-finite
/// double — `kcalPer100G` can be one. Unequal is the safe answer, so NaN
/// simply falls through to "changed".
bool _gleicherJsonWert(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final eintrag in a.entries) {
      if (!b.containsKey(eintrag.key)) return false;
      if (!_gleicherJsonWert(eintrag.value, b[eintrag.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_gleicherJsonWert(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
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
    this.foodDate,
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

  /// The diary day the sheet logs into (null = today). Only the mirror rows
  /// need it: the store books an archive-day log on that day, and the sheet's
  /// copy must say the same or an edit would drop the row as "moved".
  final DateTime? foodDate;
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

  /// True only after a definitively empty (error-free) search — one of the two
  /// states that show the manual-entry CTA. Network errors and the min-chars
  /// hint mean "search broken/too short", not "does not exist" (spec
  /// 2026-08-13).
  bool _searchCameUpEmpty = false;

  /// True after the search RAN OUT — the total deadline expired, or the user
  /// hit cancel (review P10-02).
  ///
  /// Deliberately not folded into [_searchCameUpEmpty]: giving up says nothing
  /// about whether the product exists, and that distinction still drives the
  /// message. It shares only the CTA — someone who waited 18 s wants to log
  /// their meal, not diagnose a network.
  bool _searchGaveUp = false;

  /// Definitively nothing found OR the search gave up: both hand the user the
  /// manual form. A 429 and the min-chars hint deliberately do not.
  bool get _offerManualEntry => _searchCameUpEmpty || _searchGaveUp;

  /// True once [_productSearchSlowAfter] passed with the search still running
  /// — shows the "taking longer" line plus the cancel button.
  bool _searchIsSlow = false;
  Timer? _searchSlowTimer;

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

  // Seeded from the opener and RE-seeded from it on every store notify
  // (`didUpdateWidget`). The local writes below ("mirror") only lead by a
  // frame; with a FoodStoreScope attached the store always has the last word,
  // without one they are all the sheet has.
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

  /// THE ceiling on one search cycle — every attempt, every retry pause, every
  /// leg inside them (review P10-02).
  ///
  /// Each stage used to carry its own timeout and nothing carried the chain:
  /// mirror 16 s + rotation 3 s + mirror retry 16 s + OFF-de 32 s + OFF-world
  /// 32 s = 99 s per attempt, times three attempts plus two 600 ms pauses =
  /// 298.2 s of bare spinner. The service layer now caps each chain too, but
  /// this is the number the USER is promised.
  ///
  /// Tighter than the service caps on purpose: a fast failure still gets its
  /// three attempts (≈1.2 s), while a chain that hangs is over long before its
  /// legs would have finished arguing.
  static const Duration _productSearchCycleBudget = Duration(seconds: 18);

  /// After this long the loading state gets the "taking longer" line plus a
  /// cancel button — the same gesture (and the same wording,
  /// `foodAnalysisSlowHint`) the photo scan uses at
  /// [MealAnalysisSheet.slowAfter], scaled to the shorter ceiling here.
  static const Duration _productSearchSlowAfter = Duration(seconds: 6);

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

  /// Adopts the lists the opener re-feeds on every store notify (see
  /// [FoodStoreScope]) — this is what makes the store, not the copy, the
  /// truth. Everything the sheet writes locally (see "mirror" below) is only
  /// the optimistic leading edge of its OWN action and is overwritten here, in
  /// the same frame, by what the store really did.
  ///
  /// Identity, not content: both lists are reassigned by the store on every
  /// mutation, so identity is an O(1) fingerprint.
  ///
  /// For [_favorites] the entries themselves matter too — [MealSuggestionItem]
  /// throws away a typed portion as soon as its `result` INSTANCE differs
  /// (review B, 2026-08-27), and that contract says callers hand out stable
  /// instances across rebuilds. The boot load breaks it: it replaces the whole
  /// favorites list with freshly parsed server rows, same content, new objects
  /// (P8-07b). A user whose shell is already up from the cache can be typing
  /// 175 g into an open sheet when that answer lands, and the field snapped
  /// back to 100. [_uebernommeneFavoriten] keeps the promise instead of
  /// weakening the reset: an entry that really changed still arrives as a new
  /// instance and still resets the row.
  @override
  void didUpdateWidget(AddMealSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.existingMeals, widget.existingMeals)) {
      _existing = List<LoggedMeal>.of(widget.existingMeals);
    }
    if (!identical(oldWidget.favorites, widget.favorites)) {
      _favorites = _uebernommeneFavoriten(_favorites, widget.favorites);
    }
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
    _searchSlowTimer?.cancel();
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

  /// Drops the row here and reports it upwards. The store answers with an undo
  /// snack that lands in THIS sheet's SnackHost; tapping it restores the row in
  /// the store, and the restored list reaches [didUpdateWidget] from there
  /// (P8-01 — the local removal used to be a one-way street).
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

  /// Same shape as [_removeExisting], second list: the store's undo snack
  /// restores the favorite and [didUpdateWidget] brings it back here (P8-05).
  void _removeFavorite(String id) {
    setState(() {
      _favorites = _favorites.where((f) => f.id != id).toList();
      _justAddedKeys.remove('favorite:$id');
    });
    widget.onRemoveFavorite(id);
  }

  /// The one logging path of this sheet (review F3-01): logs via
  /// [AddMealSheet.onAdd] and mirrors the new row into the local day copy, so
  /// "already added" and the slot total change on the spot instead of on the
  /// next open. Also bumps the favorite's recency like the store does.
  String _logAndMirror(MealAnalysisResult result, MealSlot slot) {
    final id = widget.onAdd(result, slot);
    if (!mounted) return id;
    final day = widget.foodDate;
    final mirrored = LoggedMeal(
      id: id,
      result: result,
      loggedAt: clock.now(),
      forcedSlot: slot,
      localDay: day == null ? null : localDayKey(DateUtils.dateOnly(day)),
    );
    setState(() => _existing = [mirrored, ..._existing]);
    _touchFavorite(result);
    return id;
  }

  /// Re-portioning from the analysis sheet ("adjust" after adding): forwards
  /// to the store AND updates the mirror row, so "already added" and the slot
  /// total show the new kcal at once.
  void _updateAndMirror(String id, MealAnalysisResult scaled) {
    widget.onUpdateMeal(id, scaled);
    if (!mounted) return;
    setState(() {
      _existing = [
        for (final m in _existing) m.id == id ? m.copyWith(result: scaled) : m,
      ];
    });
  }

  // ─── Search ───────────────────────────────────────────────────────────

  void _scheduleProductSearch(String value) {
    final query = value.trim();
    _productSearchDebounce?.cancel();

    if (query.length < _autoSearchMinChars) {
      _productSearchRequestId++;
      _searchSlowTimer?.cancel();
      setState(() {
        // New input revokes the magnifier/enter unlock: the previous hits
        // belong to a different term.
        _explicitSearchRequested = false;
        _isSearchingProducts = false;
        _searchIsSlow = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = null;
        _searchCameUpEmpty = false;
        _searchGaveUp = false;
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
        _searchGaveUp = false;
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
      _searchSlowTimer?.cancel();
      setState(() {
        _productSuggestions = cached;
        _isSearchingProducts = false;
        _searchIsSlow = false;
        _productSearchMessage = cached.isEmpty
            ? context.l10n.foodSearchNoResultsHint
            : null;
        _searchCameUpEmpty = cached.isEmpty;
        _searchGaveUp = false;
      });
      return;
    }
    // Known empty search: answer immediately, no retry cycle.
    if (_emptyQueryCache.contains(cacheKey)) {
      _productSearchRequestId++;
      _searchSlowTimer?.cancel();
      setState(() {
        _productSuggestions = const <ProductSearchResult>[];
        _isSearchingProducts = false;
        _searchIsSlow = false;
        _productSearchMessage = context.l10n.foodSearchNoResultsHint;
        _searchCameUpEmpty = true;
        _searchGaveUp = false;
      });
      return;
    }

    final requestId = ++_productSearchRequestId;
    setState(() {
      _isSearchingProducts = true;
      _searchIsSlow = false;
      _searchGaveUp = false;
      _productSearchMessage = null;
    });
    _armSlowHint(requestId);

    try {
      final suggestions = await _searchWithRetry(query, requestId);
      if (!mounted) return;
      if (requestId != _productSearchRequestId ||
          query != _searchController.text.trim()) {
        return;
      }
      _searchSlowTimer?.cancel();
      setState(() {
        _productSuggestions = suggestions;
        _isSearchingProducts = false;
        _searchIsSlow = false;
        _productSearchMessage = suggestions.isEmpty
            ? context.l10n.foodSearchNoResultsHint
            : null;
        _searchCameUpEmpty = suggestions.isEmpty;
        _searchGaveUp = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (requestId != _productSearchRequestId ||
          query != _searchController.text.trim()) {
        return;
      }
      final gedrosselt = _istDrosselung(error);
      // The total deadline (or a chain deadline below it) ran out. Named on
      // BOTH paths, typed one included: after 18 s of spinner an empty result
      // zone is the one answer the user cannot act on.
      final abgelaufen = error is TimeoutException;
      _searchSlowTimer?.cancel();
      setState(() {
        _isSearchingProducts = false;
        _searchIsSlow = false;
        // Rate limiting is always named, even on the typed path
        // (showTransientError == false): otherwise the zone stays silent and
        // the next keystroke runs into the same limit.
        _productSearchMessage = gedrosselt
            ? context.l10n.searchRateLimited
            : abgelaufen
            ? context.l10n.foodSearchTimeoutHint
            : (showTransientError
                  ? context.l10n.foodSearchUnreachableHint
                  : null);
        // Not "does not exist": neither rate limiting nor a deadline says
        // anything about the product.
        _searchCameUpEmpty = false;
        _searchGaveUp = abgelaufen;
      });
    }
  }

  /// Arms the "taking longer" line for [requestId]. Fires only while THAT
  /// search is still the current one and still running.
  void _armSlowHint(int requestId) {
    _searchSlowTimer?.cancel();
    _searchSlowTimer = Timer(_productSearchSlowAfter, () {
      if (!mounted ||
          requestId != _productSearchRequestId ||
          !_isSearchingProducts) {
        return;
      }
      setState(() => _searchIsSlow = true);
    });
  }

  /// The user's handle on a search that is taking too long — the counterpart
  /// to the photo scan's cancel button.
  ///
  /// Bumping the request id is what actually ends it: the running chain has no
  /// cancel token, so its answer is dropped on arrival (and its own deadlines
  /// stop the sockets). The zone drops straight to the manual form, which is
  /// what someone who just gave up on the search wants.
  void _cancelProductSearch() {
    _productSearchDebounce?.cancel();
    _searchSlowTimer?.cancel();
    _productSearchRequestId++;
    setState(() {
      _isSearchingProducts = false;
      _searchIsSlow = false;
      _productSuggestions = const <ProductSearchResult>[];
      _productSearchMessage = context.l10n.foodSearchCanceledHint;
      _searchCameUpEmpty = false;
      _searchGaveUp = true;
    });
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
    // THE ceiling (P10-02): attempts, retry pauses and every leg inside them
    // race against this one budget, so the cycle ends after
    // [_productSearchCycleBudget] no matter how many stages still wanted a
    // timeout of their own.
    final deadline = ChainDeadline(
      _productSearchCycleBudget,
      operation: 'product.search.cycle',
    );

    try {
      for (var attempt = 0; attempt < _productSearchMaxAttempts; attempt++) {
        try {
          final suggestions = await deadline.guard(
            widget.productService.searchProducts(query),
          );
          // A successful answer is authoritative, the empty one included:
          // empty is information, not an error. Retrying it would fan one
          // search out over mirror + OFF-de + OFF-world three times over.
          // Retries stay where they belong: real errors.
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
        // Rate limiting gets worse from retrying: bail out, the caller names
        // it. An expired budget bails for the same reason — the next attempt
        // would only be cut off again.
        if (isLastAttempt ||
            deadline.isExpired ||
            _istDrosselung(lastError) ||
            requestId != _productSearchRequestId) {
          break;
        }
        // The pause counts against the budget too, or the ceiling would be
        // the budget plus 600 ms per retry.
        try {
          await deadline.guard(Future<void>.delayed(_productSearchRetryDelay));
        } on TimeoutException catch (error) {
          lastError = error;
          break;
        }
      }

      throw lastError!;
    } finally {
      deadline.dispose();
    }
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

    // One request for first try and retries: the sheet re-runs it from the
    // same bytes, and the shared cancel handle lets a swiped-away sheet abort
    // whichever attempt is in flight (review F4-02).
    final request = _cancellable(
      selection.request.withLanguage(context.l10n.localeName),
    );
    // An attempt that fails before the sheet listens (validation, already
    // cancelled) must not surface as an unhandled zone error; the sheet's
    // error card reports it once it is up. `ignore` only marks it handled.
    final first = widget.analyzer.analyze(request)..ignore();
    final outcome = await showMealAnalysisSheet(
      context,
      slot: _selectedSlot,
      resultFuture: first,
      retry: () => widget.analyzer.analyze(request),
      cancellation: request.cancellation,
      previewImage: selection.previewBytes,
      onAdd: _logAndMirror,
      onUpdateMeal: _updateAndMirror,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage: context.l10n.foodAnalysisFailedMessage,
    );
    if (outcome == MealAnalysisSheetOutcome.manualEntry && mounted) {
      await _openManualEntry();
    }
  }

  /// The picker's request carries no cancel handle; attach one so the result
  /// sheet can abort. A request that already has one is left alone.
  static MealAnalysisRequest _cancellable(MealAnalysisRequest request) {
    if (request.cancellation != null) return request;
    return MealAnalysisRequest(
      imageId: request.imageId,
      imageBytes: request.imageBytes,
      portionHint: request.portionHint,
      freeTextHint: request.freeTextHint,
      language: request.language,
      cancellation: MealAnalysisCancellation(),
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

    // No retry/cancel: a lookup is cheap and its "not found" is final.
    final outcome = await showMealAnalysisSheet(
      context,
      slot: scan.slot,
      resultFuture: widget.productService.lookupBarcode(scan.code),
      previewImage: null,
      onAdd: _logAndMirror,
      onUpdateMeal: _updateAndMirror,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage: context.l10n.foodBarcodeNotFoundMessage(scan.code),
    );
    if (outcome == MealAnalysisSheetOutcome.manualEntry && mounted) {
      await _openManualEntry();
    }
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

    _logAndMirror(result, _selectedSlot);
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
    final body = Column(
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
                  maybeAnimatedSize(
                    context,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _buildFavorites(),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    // SnackHost INSIDE the ground color: the sheet stays open after adds and
    // deletes, so its toasts (and the store's undo) render above the scrim,
    // in a strip the host reserves below the content.
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
        child: SnackHost(child: body),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_isSearchingProducts && _productSuggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            SizedBox(
              key: const ValueKey('product-search-spinner'),
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.t.accent,
              ),
            ),
            // Same gesture as the photo scan: after
            // [_productSearchSlowAfter] the wait gets a name and a way out.
            if (_searchIsSlow) ...[
              const SizedBox(height: 12),
              _SearchSlowHint(onCancel: _cancelProductSearch),
            ],
          ],
        ),
      );
    }
    if (_productSuggestions.isEmpty && _productSearchMessage != null) {
      return Column(
        children: [
          _HintBlock(text: _productSearchMessage!),
          if (_offerManualEntry)
            // Definitively nothing found, or the search gave up -> straight
            // into the form, with the query prefilled as the name.
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

  // Pinned favorites first (by recency, see favorites_view.dart), then auto
  // recents in store order — one list, split by the pinned flag.
  List<FavoriteMeal> get _pinned => pinnedFavoritesByRecency(_favorites);
  List<FavoriteMeal> get _recents =>
      _favorites.where((f) => !f.pinned).toList(growable: false);

  /// Favorites section (feature 2026-08-27): only the top
  /// [kInlineFavoritesCount] pinned by recency sit inline, the rest live in
  /// the favorites sheet behind the "All (N)" button. A long pinned list used
  /// to push search results and recents off screen; the button shows from the
  /// first pinned favorite on so unpinning stays reachable.
  Widget _buildFavorites() {
    if (_favorites.isEmpty) {
      return const _EmptyState();
    }
    // One sort for both count and slice (inlineFavorites would sort again).
    final pinned = _pinned;
    final pinnedCount = pinned.length;
    final inline = pinned.take(kInlineFavoritesCount).toList(growable: false);
    final recents = _recents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inline.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: _SectionLabel(context.l10n.foodSectionFavorites),
              ),
              _FavoritesAllButton(
                count: pinnedCount,
                onTap: _openFavoritesSheet,
              ),
            ],
          ),
          const SizedBox(height: 2),
          for (var i = 0; i < inline.length; i++) ...[
            _favoriteItem(inline[i], i, pinned: true),
            if (i != inline.length - 1) const SizedBox(height: 8),
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

  // Report the toggle upwards AND flip the heart locally, so it reacts on the
  // spot (favorites <-> recents).
  //
  // Only the flip is mirrored, never the store's rules: an unpin runs through
  // the recents cap there and can DELETE the row instead of demoting it. That
  // outcome arrives via [FoodStoreScope]; the sheet used to keep showing a row
  // the store had dropped (P8-06).
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
            addedAt: clock.now(),
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

  /// Unpin-only path for the favorites sheet: the heart there never re-pins,
  /// so a row that is already unpinned locally (or unknown) is left alone
  /// instead of being toggled back on.
  void _unpinFavorite(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final idx = _favorites.indexWhere((f) => f.id == id);
    if (idx == -1 || !_favorites[idx].pinned) return;
    _handleToggleFavorite(result);
  }

  /// Opens the favorites sheet on top of this one. Adds go through
  /// [_logAndMirror] with the slot chosen here; the tile check lives in the
  /// favorites sheet itself. The rebuild after closing refreshes count and
  /// top 3 after unpins and after adds.
  Future<void> _openFavoritesSheet() async {
    await showFavoritesSheet(
      context,
      favorites: _favorites,
      slot: _selectedSlot,
      onAdd: _logAndMirror,
      onUnpin: _unpinFavorite,
    );
    if (!mounted) return;
    setState(() {});
  }

  /// Mirrors the store's "last used" bump (`_rememberRecent`) into the local
  /// copy, so the inline top 3 follow "most recently used first" within this
  /// sheet session too (review A, 2026-08-27).
  ///
  /// Like the store: the entry is REBUILT from the logged result and moves to
  /// the front. `copyWith(addedAt:)` only moved the timestamp and left the old
  /// result behind, so a re-logged meal kept showing the old density in its
  /// tile header (P8-07). What stays the store's alone is the recents cap —
  /// its outcome (including a dropped entry) arrives via [FoodStoreScope].
  /// Unknown results (fresh search hits) are left alone here for the same
  /// reason: the store creates that recent and hands it over.
  void _touchFavorite(MealAnalysisResult result) {
    final id = FavoriteMeal.idFor(result);
    final idx = _favorites.indexWhere((f) => f.id == id);
    if (idx == -1) return;
    final refreshed = FavoriteMeal(
      id: id,
      result: result,
      addedAt: clock.now(),
      pinned: _favorites[idx].pinned,
    );
    setState(() {
      _favorites = [refreshed, ..._favorites.where((f) => f.id != id)];
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

/// Borderless soft capsule ([FieldCapsule]): rest `field`, focus `fieldFocus`,
/// no hairline, no focus ring.
class _SearchBar extends StatefulWidget {
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
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      key: const ValueKey('kcal-product-search-card'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: FieldCapsule(
        focusNode: _focus,
        // Minimum, not fixed: at large system text the hint needs more than
        // 46 pt and would hang out of a fixed capsule (review F3-05).
        constraints: const BoxConstraints(minHeight: 46),
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search_rounded, size: 18, color: t.ink2),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('kcal-product-search-input'),
                controller: widget.controller,
                focusNode: _focus,
                autofocus: true,
                // The iOS default fades the cursor continuously, keeping the
                // app at ~60fps while the sheet is open. Discrete blinking
                // repaints ~2x/s (app-wide rule for all fields).
                cursorOpacityAnimates: false,
                cursorColor: t.accent,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
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
              onPressed: widget.isSearching ? null : widget.onSearchPressed,
              icon: widget.isSearching
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

/// "All (N)" link on the favorites section head (feature 2026-08-27). Bare
/// accent text plus chevron, no capsule: it sits beside an eyebrow label and
/// must not compete with the tiles. The 44 pt minimum keeps the tap target.
class _FavoritesAllButton extends StatelessWidget {
  const _FavoritesAllButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final label = context.l10n.foodFavoritesAllButton(count);
    return Semantics(
      button: true,
      label: label,
      // excludeSemantics drops InkWell's own tap action, so a screen reader
      // needs it re-declared here (review B, 2026-08-27).
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('add-meal-favorites-all'),
        borderRadius: BorderRadius.circular(rPill),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.only(left: 10, right: 2),
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppType.ui(
                  12.5,
                  weight: FontWeight.w600,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 18, color: t.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standing entry point for manual entry (user feedback 2026-08-13): a bare
/// pencil icon in the header was hard to find and wrapped the slot title. Now
/// a labeled full-width row below the slot picker, styled like the search bar
/// capsule (borderless, same radius) so both entry points share one shape.
class _ManualEntryRow extends StatelessWidget {
  const _ManualEntryRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      // Same fill as the search capsule at rest (`field`), not a card.
      color: t.field,
      borderRadius: BorderRadius.circular(rControl),
      child: InkWell(
        key: const ValueKey('manual-entry-button'),
        borderRadius: BorderRadius.circular(rControl),
        onTap: onTap,
        child: Container(
          // Grows with the label at large system text (review F3-05).
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
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

/// "Taking longer" line plus cancel, shown under the search spinner once
/// `_AddMealSheetState._productSearchSlowAfter` passed.
///
/// Deliberately the same shape and the same ARB key as `_SlowHint` in
/// `meal_analysis_sheet.dart`: one wording for "this is taking a while", so
/// the photo scan and the product search speak with one voice. Its own widget
/// rather than a shared one — the analysis sheet's version sits under a
/// loading CARD and carries that card's insets.
class _SearchSlowHint extends StatelessWidget {
  const _SearchSlowHint({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      key: const ValueKey('product-search-slow-hint'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            l10n.foodAnalysisSlowHint,
            style: AppType.ui(12.5, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
        TextButton(
          key: const ValueKey('product-search-cancel'),
          onPressed: onCancel,
          child: Text(l10n.commonCancel),
        ),
      ],
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
