import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../common/persistence_action.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../screens/barcode_scanner_sheet.dart';
import '../../services/favorites_view.dart';
import '../../services/eatova_http.dart';
import '../../services/local_day.dart';
import '../../services/meal_analyzer.dart';
import '../../services/meal_photo_input.dart';
import '../../services/meal_scan_identity.dart';
import '../../services/meals_sync.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'edit_meal_sheet.dart';
import 'existing_meals_list.dart';
import 'food_glyphs.dart';
import 'favorites_sheet.dart';
import 'manual_meal_sheet.dart';
import 'meal_analysis_sheet.dart';
import 'meal_entry_methods.dart';
import 'meal_scan_preview_sheet.dart';
import 'meal_slot_picker.dart';
import 'meal_suggestion_item.dart';
import 'saved_meal_presentation.dart';

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
    this.favoriteUseCounts,
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

  /// Logs per favorite id for the favorites sheet's "Frequent" order
  /// ([favoriteUseCounts]); asked when the sheet opens.
  final Map<String, int> Function()? favoriteUseCounts;

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
  required FutureOr<String> Function(MealAnalysisResult, MealSlot) onAdd,
  required FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal,
  required PersistValueChanged<String> onRemoveFavorite,
  bool Function(MealAnalysisResult)? isFavorite,
  PersistValueChanged<MealAnalysisResult>? onToggleFavorite,
  List<LoggedMeal> existingMeals = const <LoggedMeal>[],
  DateTime? foodDate,
  PersistValueChanged<String>? onRemoveMeal,
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
          favoriteUseCounts: live?.favoriteUseCounts,
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
    this.favoriteUseCounts,
  });

  final MealSlot slot;
  final bool searchMode;
  final MealAnalyzer analyzer;
  final ProductLookupService productService;
  final MealPhotoInput photoInput;
  final List<FavoriteMeal> favorites;

  /// Logs the result and returns the client UUID (see MealAnalysisSheet) for
  /// later re-portioning.
  final FutureOr<String> Function(MealAnalysisResult, MealSlot) onAdd;

  /// Replaces a logged row's result by id (kcal + macros).
  final FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal;
  final PersistValueChanged<String> onRemoveFavorite;

  /// Is the meal currently pinned? Null -> no heart.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favorite toggle (pin/unpin). Null -> no heart.
  final PersistValueChanged<MealAnalysisResult>? onToggleFavorite;
  final List<LoggedMeal> existingMeals;

  /// The diary day the sheet logs into (null = today). Only the mirror rows
  /// need it: the store books an archive-day log on that day, and the sheet's
  /// copy must say the same or an edit would drop the row as "moved".
  final DateTime? foodDate;
  final PersistValueChanged<String>? onRemoveMeal;

  /// Details update for the edit sheet (portion/slot/day). Null -> already
  /// added rows are not tappable.
  final UpdateMealDetails? onUpdateMealDetails;

  /// Logs per favorite id for the favorites sheet's "Frequent" order; null
  /// (previews, standalone tests) orders "Frequent" by recency.
  final Map<String, int> Function()? favoriteUseCounts;

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
  final ScrollController _scrollController = ScrollController();

  /// The block under the "already added" list: favorites or search hits.
  final GlobalKey _belowAddedKey = GlobalKey(debugLabel: 'below-added');
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
    _scrollController.dispose();
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

  /// The [_searchActive] value the last [build] actually painted — the gate for
  /// the keystroke path (perf audit B3, 2026-09-01).
  ///
  /// [_scheduleProductSearch] used to `setState(() {})` on EVERY keystroke to
  /// flip this zone, but the flip happens on one character in a word: the other
  /// nine rebuilt the whole sheet subtree for an identical frame.
  ///
  /// Written here rather than tracked per mutation on purpose. `onChanged`
  /// fires AFTER the controller already holds the new text, so there is no
  /// "before" left to capture inside the handler; and [_explicitSearchRequested]
  /// — the getter's second input — is written on three other paths, each of
  /// which would have to remember to update a mirrored copy. Reading it off the
  /// build itself cannot drift from what is on screen.
  bool _renderedSearchActive = false;

  /// Does the "input too short" reset in [_scheduleProductSearch] still have
  /// anything to do?
  ///
  /// Exactly the seven fields it writes. Every one of them reaches [build] —
  /// five directly, [_searchCameUpEmpty]/[_searchGaveUp] through
  /// [_offerManualEntry], [_explicitSearchRequested] through [_searchActive] —
  /// so "all seven already hold their reset value" means the rebuild would
  /// paint the identical frame (B3).
  bool get _searchStateDirty =>
      _explicitSearchRequested ||
      _isSearchingProducts ||
      _searchIsSlow ||
      _productSuggestions.isNotEmpty ||
      _productSearchMessage != null ||
      _searchCameUpEmpty ||
      _searchGaveUp;

  /// Drops the row here and reports it upwards. The store answers with an undo
  /// snack that lands in THIS sheet's SnackHost; tapping it restores the row in
  /// the store, and the restored list reaches [didUpdateWidget] from there
  /// (P8-01 — the local removal used to be a one-way street).
  Future<void> _removeExisting(String id) async {
    await widget.onRemoveMeal?.call(id);
    if (!mounted) return;
    setState(() {
      _existing = _existing.where((m) => m.id != id).toList();
    });
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
  Future<void> _removeFavorite(String id) async {
    if (!await tryPersistChange(context, () => widget.onRemoveFavorite(id)) ||
        !mounted) {
      return;
    }
    setState(() {
      _favorites = _favorites.where((f) => f.id != id).toList();
      _justAddedKeys.remove('favorite:$id');
    });
  }

  /// The one logging path of this sheet (review F3-01): logs via
  /// [AddMealSheet.onAdd] and mirrors the new row into the local day copy, so
  /// "already added" and the slot total change on the spot instead of on the
  /// next open. Also bumps the favorite's recency like the store does.
  Future<String> _logAndMirror(MealAnalysisResult result, MealSlot slot) async {
    final id = await widget.onAdd(result, slot);
    if (!mounted) return id;
    // The store publishes before its delivery attempt returns the id, so the
    // re-seed may already hold this row; a second copy doubled the row and
    // the slot total.
    if (!widget.existingMeals.any((m) => m.id == id)) {
      final day = widget.foodDate;
      final mirrored = LoggedMeal(
        id: id,
        result: result,
        loggedAt: clock.now(),
        forcedSlot: slot,
        localDay: day == null ? null : localDayKey(DateUtils.dateOnly(day)),
      );
      setState(() => _existing = [mirrored, ..._existing]);
    }
    _touchFavorite(result);
    return id;
  }

  /// Re-portioning from the analysis sheet ("adjust" after adding): forwards
  /// to the store AND updates the mirror row, so "already added" and the slot
  /// total show the new kcal at once.
  Future<void> _updateAndMirror(String id, MealAnalysisResult scaled) async {
    await widget.onUpdateMeal(id, scaled);
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
    _productSearchRequestId++;
    _searchSlowTimer?.cancel();

    // Results and errors belong to the previous query, even before the new
    // debounce fires. Clear them once; subsequent keystrokes with no state
    // or zone change still avoid rebuilding the sheet (B3).
    final hadSearchState = _searchStateDirty;
    _explicitSearchRequested = false;
    if (hadSearchState || _searchActive != _renderedSearchActive) {
      setState(() {
        _isSearchingProducts = false;
        _searchIsSlow = false;
        _productSuggestions = const <ProductSearchResult>[];
        _productSearchMessage = null;
        _searchCameUpEmpty = false;
        _searchGaveUp = false;
      });
    }
    if (query.length < _autoSearchMinChars) return;

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
      _productSuggestions = const <ProductSearchResult>[];
      _isSearchingProducts = true;
      _searchIsSlow = false;
      _searchCameUpEmpty = false;
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
    final identity = MealScanIdentity();
    final analyzer = widget.analyzer;
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
    if (selection == null || !mounted || !identity.isCurrent) return;

    // One request for first try and retries: the sheet re-runs it from the
    // same bytes, and the shared cancel handle lets a swiped-away sheet abort
    // whichever attempt is in flight (review F4-02).
    final request = await showMealScanPreviewSheet(
      context,
      request: selection.request.withLanguage(context.l10n.localeName),
      previewBytes: selection.previewBytes,
    );
    if (request == null || !mounted || !identity.isCurrent) return;
    // An attempt that fails before the sheet listens (validation, already
    // cancelled) must not surface as an unhandled zone error; the sheet's
    // error card reports it once it is up. `ignore` only marks it handled.
    final first = analyzer.analyze(request)..ignore();
    final outcome = await showMealAnalysisSheet(
      context,
      slot: _selectedSlot,
      resultFuture: first,
      // Not MealAnalysisCancelled: the sheet reads that as its own close and
      // would stay on the loading card. The photo belongs to the old session.
      retry: () => identity.isCurrent
          ? analyzer.analyze(request)
          : Future.error(const MealAnalysisReauthRequired()),
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

  Future<void> _scanBarcode() async {
    // Bottom panel like the AI scan instead of a full-screen switch. The
    // scanner's picker starts on the slot selected here.
    final scan = await showBarcodeScannerSheet(
      context,
      initialSlot: _selectedSlot,
    );
    if (scan == null || !mounted) return;
    // A slot change in the scanner applies to this sheet too, otherwise the
    // header would show one slot while the hit went to another.
    _selectSlot(scan.slot);

    // As for the photo scan: offline the lookup fails before the sheet
    // listens, which must not surface as an unhandled zone error.
    final lookup = widget.productService.lookupBarcode(scan.code)..ignore();
    // No retry/cancel: a lookup is cheap and its "not found" is final.
    final outcome = await showMealAnalysisSheet(
      context,
      slot: scan.slot,
      resultFuture: lookup,
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
  /// builds the result; logging happens here via [_logAndMirror], plus the
  /// success snack. A manual 0 kcal is measured (explicitZeroKcal), so no
  /// sentinel guard applies. [initialName] comes from the search CTA.
  Future<void> _openManualEntry({String? initialName}) async {
    var slot = _selectedSlot;
    final result = await showManualMealSheet(
      context,
      initialName: initialName,
      initialSlot: _selectedSlot,
      onSlotChanged: (value) => slot = value,
      onSave: (result) async {
        await _logAndMirror(result, slot);
      },
      contextLabel: widget.foodDate == null
          ? null
          : MaterialLocalizations.of(
              context,
            ).formatMediumDate(widget.foodDate!),
    );
    if (result == null || !mounted) return;
    _selectSlot(slot);
    showAppSnack(
      context,
      context.l10n.commonKcalAddedToSlot(
        result.caloriesKcal,
        slot.label(context.l10n),
      ),
      icon: Icons.check_circle_rounded,
    );
  }

  // ─── Adding ───────────────────────────────────────────────────────────

  final Set<String> _savingItems = {};

  Future<void> _handleAdd(String itemKey, MealAnalysisResult result) async {
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

    if (!_savingItems.add(itemKey)) return;
    final rowsTop = _belowAddedTop();
    final slot = _selectedSlot;
    final saved = await tryPersistChange(context, () async {
      await _logAndMirror(result, slot);
    });
    _savingItems.remove(itemKey);
    if (!saved || !mounted) return;
    {
      final l10n = context.l10n;
      showAppSnack(
        context,
        l10n.commonKcalAddedToSlot(result.caloriesKcal, slot.label(l10n)),
        icon: Icons.check_circle_rounded,
      );
    }
    setState(() {
      _expandedItemKey = null;
      _justAddedKeys.add(itemKey);
    });
    _keepRowsInPlace(rowsTop);
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
    // Record what this frame shows, so the keystroke path can tell a real zone
    // flip from a no-op (B3, see [_renderedSearchActive]).
    final searchActive = _searchActive;
    if (searchActive != _renderedSearchActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
    _renderedSearchActive = searchActive;

    // Keep close/search reachable above the keyboard. Everything else can
    // scroll, including entry choices and the slot picker at large text sizes.
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetHandle(padding: EdgeInsets.only(top: 10, bottom: 2)),
        _SheetHeader(
          slot: _selectedSlot,
          foodDate: widget.foodDate ?? clock.now(),
          compact: keyboardInset > 0,
          searchMode: widget.searchMode,
          onClose: () => Navigator.of(context).pop(),
        ),
        _SearchBar(
          controller: _searchController,
          autofocus: widget.searchMode,
          isSearching: _isSearchingProducts,
          onChanged: _scheduleProductSearch,
          onSubmitted: (_) => _searchProducts(),
          onSearchPressed: _searchProducts,
          onClear: () {
            _searchController.clear();
            _scheduleProductSearch('');
          },
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('add-meal-sheet-scroll'),
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              20,
              14,
              20,
              28 + mediaQuery.viewPadding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  key: const ValueKey('add-meal-slot-select'),
                  padding: const EdgeInsets.only(bottom: _kBlockGap),
                  child: MealSlotPicker(
                    selected: _selectedSlot,
                    onSelected: _selectSlot,
                  ),
                ),
                // Standing entry point for manual entry while no search is
                // active; after that the contextual CTA under "nothing
                // found" takes over (_buildSearchResults).
                if (!searchActive) ...[
                  // Manual entry joins the entry-method card; the search
                  // mode has no method card, so it keeps its own row.
                  if (widget.searchMode)
                    _ManualEntryRow(onTap: () => _openManualEntry())
                  else
                    MealEntryMethods(
                      onCamera: () => _pickAndAnalyze(ImageSource.camera),
                      onGallery: () => _pickAndAnalyze(ImageSource.gallery),
                      onBarcode: _scanBarcode,
                      onManual: () => _openManualEntry(),
                    ),
                  const SizedBox(height: _kSectionGap),
                ],
                if (_slotMeals.isNotEmpty) ...[
                  ExistingMealsList(
                    meals: _slotMeals,
                    slot: _selectedSlot,
                    onRemove: widget.onRemoveMeal == null
                        ? null
                        : (id) => tryPersistChange(
                            context,
                            () => _removeExisting(id),
                          ),
                    onEdit: widget.onUpdateMealDetails == null
                        ? null
                        : _editExisting,
                  ),
                  const SizedBox(height: _kSectionGap),
                ],
                KeyedSubtree(
                  key: _belowAddedKey,
                  child: searchActive
                      ? _buildSearchResults()
                      // Removing a favorite collapses the list smoothly
                      // instead of jumping.
                      : maybeAnimatedSize(
                          context,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeInOut,
                          alignment: Alignment.topCenter,
                          child: _buildFavorites(),
                        ),
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
    //
    // `measureToast`: the content scrolls down to the screen edge, so the
    // strip sits on the home indicator. Its Scaffold lifts a floating toast
    // above that inset; the measured reserve counts the inset too, the fixed
    // one did not and the toast was pushed off the strip ("Floating SnackBar
    // presented off screen" on every add, found 2026-10-02).
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        key: const ValueKey('add-meal-sheet'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        // The page ground plus the same 1 px edge as every Eatova sheet
        // (`showEatovaSheet`): cards inside read exactly like the Food tab's.
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
          border: Border.all(color: t.lineStrong),
        ),
        child: SnackHost(measureToast: true, child: body),
      ),
    );
  }

  Widget _buildSearchResults() {
    final l10n = context.l10n;
    if (_isSearchingProducts && _productSuggestions.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(
            l10n.ingredientSearching,
            trailing: SizedBox(
              key: const ValueKey('product-search-spinner'),
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.t.accent,
              ),
            ),
          ),
          const SizedBox(height: _kLabelGap),
          const _SkeletonGroup(),
          // Same gesture as the photo scan: after
          // [_productSearchSlowAfter] the wait gets a name and a way out.
          if (_searchIsSlow) ...[
            const SizedBox(height: 12),
            _SearchSlowHint(onCancel: _cancelProductSearch),
          ],
        ],
      );
    }
    if (_productSuggestions.isEmpty && _productSearchMessage != null) {
      final message = _productSearchMessage!;
      return _CalmState(
        icon: _searchCameUpEmpty
            ? Icons.search_off_rounded
            : _searchGaveUp
            ? Icons.hourglass_empty_rounded
            : message == l10n.foodSearchMinCharsHint
            ? Icons.keyboard_rounded
            : Icons.cloud_off_rounded,
        text: message,
        action: _offerManualEntry
            // Definitively nothing found, or the search gave up -> straight
            // into the form, with the query prefilled as the name.
            ? _TintedPillButton(
                key: const ValueKey('manual-entry-cta'),
                icon: Icons.edit_rounded,
                label: l10n.foodManualEntryCta,
                onTap: () => _openManualEntry(
                  initialName: _searchController.text.trim(),
                ),
              )
            : null,
      );
    }
    if (_productSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(l10n.foodSectionSearchResults),
        const SizedBox(height: _kLabelGap),
        SavedMealCollection(
          children: [
            for (var i = 0; i < _productSuggestions.length; i++)
              _suggestionItem(i),
          ],
        ),
      ],
    );
  }

  Widget _suggestionItem(int index) {
    final suggestion = _productSuggestions[index];
    final key = 'product:${suggestion.code}';
    return MealSuggestionItem(
      key: ValueKey('kcal-product-suggestion-$index'),
      productPresentation: true,
      result: suggestion.result,
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
  /// Top of [_belowAddedKey] on screen, or null before the first layout.
  double? _belowAddedTop() {
    final box = _belowAddedKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached
        ? box.localToGlobal(Offset.zero).dy
        : null;
  }

  /// Scroll anchoring for an add: the meal joins the "already added" list
  /// above the rows, which would push the row under the finger down by one.
  /// The sheet scrolls by the same amount, so a second tap on the same "+"
  /// lands on the same food.
  void _keepRowsInPlace(double? before) {
    if (before == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final after = _belowAddedTop();
      if (!mounted || after == null || !_scrollController.hasClients) return;
      final delta = after - before;
      if (delta.abs() < 0.5) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  List<FavoriteMeal> get _pinned => pinnedFavoritesByRecency(_favorites);

  List<FavoriteMeal> get _recents =>
      _favorites.where((f) => !f.pinned).toList(growable: false);

  /// Favorites and recents: one row opens the favorites menu (all pinned
  /// favorites, search, sorting, one-tap add); the auto recents follow.
  Widget _buildFavorites() {
    if (_favorites.isEmpty) {
      return const _EmptyState();
    }
    // Owner decision 2026-10-03: no inline top 3 any more; one row leads to
    // the favorites menu, which holds all of them.
    final pinnedCount = _pinned.length;
    final recents = _recents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pinnedCount > 0) ...[
          _FavoritesEntryRow(count: pinnedCount, onTap: _openFavoritesSheet),
          if (recents.isNotEmpty) const SizedBox(height: _kSectionGap),
        ],
        if (recents.isNotEmpty) ...[
          _SectionLabel(context.l10n.foodSectionRecentMeals),
          const SizedBox(height: _kLabelGap),
          SavedMealCollection(
            children: [
              for (var i = 0; i < recents.length; i++)
                _recentItem(recents[i], i),
            ],
          ),
        ],
      ],
    );
  }

  Widget _recentItem(FavoriteMeal favorite, int index) {
    final key = 'favorite:${favorite.id}';
    // Tests pin the favorite-tile-* keys.
    final tileKey = 'favorite-tile-$index';
    return MealSuggestionItem(
      key: ValueKey(tileKey),
      result: favorite.result,
      expanded: _expandedItemKey == key,
      justAdded: _justAddedKeys.contains(key),
      onTap: () => _toggleExpanded(key),
      onAdd: (result) => _handleAdd(key, result),
      onRemove: () => _removeFavorite(favorite.id),
      addButtonKey: ValueKey('favorite-tile-add-$index'),
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
  Future<void> _handleToggleFavorite(MealAnalysisResult result) async {
    final key = 'toggle:${FavoriteMeal.idFor(result)}';
    if (!_savingItems.add(key)) return;
    await tryPersistChange(context, () => _toggleAndMirror(result));
    _savingItems.remove(key);
  }

  Future<void> _toggleAndMirror(MealAnalysisResult result) async {
    final id = FavoriteMeal.idFor(result);
    final before = _favorites.indexWhere((f) => f.id == id);
    final pinned = before == -1 || !_favorites[before].pinned;
    final fed = widget.favorites;
    await widget.onToggleFavorite?.call(result);
    // Re-fed during the call: the list already holds the store's outcome,
    // and mirroring a dropped row would bring it back.
    if (!mounted || !identical(widget.favorites, fed)) return;
    setState(() {
      final idx = _favorites.indexWhere((f) => f.id == id);
      if (idx == -1) {
        _favorites = [
          FavoriteMeal(
            id: id,
            result: result,
            addedAt: clock.now(),
            pinned: pinned,
          ),
          ..._favorites,
        ];
      } else {
        final current = _favorites[idx];
        final next = [..._favorites];
        next[idx] = current.copyWith(
          pinned: pinned,
          result: FavoriteMeal.keepImage(current.result, result),
        );
        _favorites = next;
      }
    });
  }

  /// Unpin-only path for the favorites sheet: the heart there never re-pins,
  /// so a row that is already unpinned locally (or unknown) is left alone
  /// instead of being toggled back on.
  Future<void> _unpinFavorite(MealAnalysisResult result) async {
    final id = FavoriteMeal.idFor(result);
    final idx = _favorites.indexWhere((f) => f.id == id);
    if (idx == -1 || !_favorites[idx].pinned) return;
    await _toggleAndMirror(result);
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
      useCounts: widget.favoriteUseCounts?.call() ?? const <String, int>{},
    );
    if (!mounted) return;
    setState(() {});
  }

  /// Mirrors the store's "last used" bump (`_rememberRecent`) into the local
  /// copy, so the recents follow "most recently used first" within this
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
      result: FavoriteMeal.keepImage(result, _favorites[idx].result),
      addedAt: clock.now(),
      pinned: _favorites[idx].pinned,
    );
    setState(() {
      _favorites = [refreshed, ..._favorites.where((f) => f.id != id)];
    });
  }
}

// ─── Layout rhythm ──────────────────────────────────────────────────────

/// Gap between blocks of one group (slot picker, entry methods, manual row).
const double _kBlockGap = 12;

/// Gap before a new section (already added, favorites, recents, results).
const double _kSectionGap = 20;

/// Gap between a section label row and its card. The label row itself is
/// 48 px tall (the "All (N)" target), so the text keeps ~16 px of air.
const double _kLabelGap = 0;

// ─── Header ─────────────────────────────────────────────────────────────

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.slot,
    required this.foodDate,
    required this.compact,
    this.searchMode = false,
    required this.onClose,
  });

  final MealSlot slot;
  final DateTime foodDate;
  final bool compact;
  final bool searchMode;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final date = MaterialLocalizations.of(context).formatMediumDate(foodDate);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  HeadingSemantics(
                    level: 1,
                    child: Text(
                      searchMode ? l10n.foodSearchModeTitle : l10n.todayAddMeal,
                      style: AppType.display(28, color: t.ink, height: 1.1),
                      textScaler: AppType.pageTitleScaler(context),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                // The diary day and the target slot, with the slot's own
                // color as a dot — the same identity as the Food tab's tiles.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Centered on the FIRST line, also when the line wraps
                    // at large text.
                    SizedBox(
                      height: MediaQuery.textScalerOf(context).scale(13.5) * 1.3,
                      child: Center(
                        child: ExcludeSemantics(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: slot.accentIn(context),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '$date · ${slot.label(l10n)}',
                        key: const ValueKey('add-meal-date-context'),
                        style: AppType.ui(
                          13.5,
                          weight: FontWeight.w600,
                          color: t.ink2,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // The Food tab's round header button (card fill, strong outline),
          // drawn at 44 inside Material's 48 px touch target.
          PressScale(
            child: IconButton(
              key: const ValueKey('add-meal-sheet-close'),
              onPressed: onClose,
              tooltip: l10n.commonClose,
              style: IconButton.styleFrom(
                backgroundColor: t.surf,
                foregroundColor: t.inkMuted,
                fixedSize: const Size.square(44),
                minimumSize: const Size.square(44),
                padding: EdgeInsets.zero,
                shape: CircleBorder(side: BorderSide(color: t.lineStrong)),
              ),
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Search bar ─────────────────────────────────────────────────────────

/// The Food tab's "Search food or meals" capsule, made real: 54 px pill on a
/// [FieldCapsule] (rest `field`, focus `fieldFocus`, no hairline, no ring),
/// the dock's search glyph in front and a round accent search button at the
/// end. Focus also tints the glyph, a second cue next to the fill change.
class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.controller,
    required this.autofocus,
    required this.onClear,
    required this.isSearching,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSearchPressed,
  });

  final TextEditingController controller;
  final bool autofocus;
  final VoidCallback onClear;
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
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      key: const ValueKey('kcal-product-search-card'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: FieldCapsule(
        focusNode: _focus,
        shape: SheetFieldShape.pill,
        // Minimum, not fixed: at large system text the hint needs more than
        // the dock's 54 px and would hang out of a fixed capsule (F3-05).
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.only(left: 18, right: 7),
        child: Row(
          children: [
            FoodGlyphIcon(
              FoodGlyph.search,
              // Grows with the query text instead of shrinking beside it.
              size: scaledWidth(context, 20),
              color: _focus.hasFocus ? t.accentText : t.ink2,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                label: l10n.foodSearchModeTitle,
                child: TextField(
                  key: const ValueKey('kcal-product-search-input'),
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  // The iOS default fades the cursor continuously, keeping the
                  // app at ~60fps while the sheet is open. Discrete blinking
                  // repaints ~2x/s (app-wide rule for all fields).
                  cursorOpacityAnimates: false,
                  cursorColor: t.accent,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  textInputAction: TextInputAction.search,
                  style: AppType.ui(16, weight: FontWeight.w600, color: t.ink),
                  decoration: InputDecoration(
                    hintText: l10n.foodSearchInputHint,
                    hintStyle: AppType.ui(16, color: t.ink2),
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const ValueKey('kcal-product-search-clear'),
                      tooltip: l10n.foodSearchClear,
                      onPressed: widget.onClear,
                      icon: Icon(Icons.close_rounded, color: t.ink2, size: 19),
                    ),
            ),
            IconButton(
              key: const ValueKey('kcal-product-search-button'),
              tooltip: l10n.foodSearchButtonTooltip,
              onPressed: widget.isSearching ? null : widget.onSearchPressed,
              style: IconButton.styleFrom(
                backgroundColor: t.accentTint,
                disabledBackgroundColor: t.accentTint,
                foregroundColor: t.accentText,
                disabledForegroundColor: t.accentText.withValues(alpha: 0.45),
                fixedSize: const Size.square(40),
                minimumSize: const Size.square(40),
                padding: EdgeInsets.zero,
              ),
              // While a search runs the button rests dimmed; the one spinner
              // sits in the results zone, next to "Searching products…".
              icon: const Icon(Icons.arrow_forward_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Sections ───────────────────────────────────────────────────────────

/// The tabs' small uppercase tracked label ("LOGGED", "LEFT TODAY") as a
/// section head, with an optional action on the right. The row is 48 px
/// tall so a trailing button keeps its touch target without shifting the
/// rhythm between sections with and without one.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Expanded(
            child: HeadingSemantics(
              level: 2,
              child: Text(
                text.toUpperCase(),
                semanticsLabel: text,
                style: AppType.sectionEyebrow(context.t.ink2),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

/// "All (N)" link on the favorites section head (feature 2026-08-27). Bare
/// accent text plus chevron, no capsule: it sits beside an eyebrow label and
/// must not compete with the rows. The 48 px minimum keeps the tap target.
/// The way into the favorites menu (2026-10-03): a row in the entry-method
/// style with a heart tile, "Favorites" and how many are saved.
class _FavoritesEntryRow extends StatelessWidget {
  const _FavoritesEntryRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = l10n.foodSectionFavorites;
    final subtitle = l10n.foodFavoritesEntryCount(count);
    return Semantics(
      container: true,
      button: true,
      label: '$title, $subtitle',
      // excludeSemantics drops InkWell's own tap action, so a screen reader
      // needs it re-declared here (review B, 2026-08-27).
      onTap: onTap,
      excludeSemantics: true,
      child: PressScale(
        scale: kPressScaleCard,
        child: Material(
          color: t.surf,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rCard),
            side: BorderSide(color: t.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('add-meal-favorites-all'),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              // The geometry of the entry-method rows: 16 inset, 40 tile.
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: t.accentTint,
                      borderRadius: BorderRadius.circular(rChip),
                    ),
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 20,
                      color: t.accentText,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppType.ui(
                            15,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: AppType.ui(12.5, color: t.ink2, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, size: 22, color: t.ink3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while the first search answer is on its way: the shape
/// of the result card, so the answer replaces it without a jump. Static on
/// purpose — the spinner in the label already says "working".
class _SkeletonGroup extends StatelessWidget {
  const _SkeletonGroup();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: t.tile,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
    // The row geometry of the result rows: 64 tall, 14 inset, 40 tile.
    Widget row(double nameWidth, double metaWidth) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: t.tile,
              borderRadius: BorderRadius.circular(rChip),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(nameWidth, 12),
                const SizedBox(height: 9),
                bar(metaWidth, 10),
              ],
            ),
          ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: SavedMealCollection(
        children: [row(0.62, 0.34), row(0.48, 0.3), row(0.7, 0.38)],
      ),
    );
  }
}

/// A quiet, labeled alternative to photo and product lookup: one row card
/// with the accent icon tile, the label and what the form does.
class _ManualEntryRow extends StatelessWidget {
  const _ManualEntryRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return PressScale(
      scale: kPressScaleCard,
      child: Material(
        color: t.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(color: t.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('manual-entry-button'),
          onTap: onTap,
          child: Container(
            // Grows with the label at large system text (review F3-05).
            constraints: const BoxConstraints(minHeight: 64),
            // The row geometry of the entry-method rows right above it
            // (`meal_entry_methods.dart`): 16 inset, 40 tile, 14 gap.
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: t.tile,
                      borderRadius: BorderRadius.circular(rChip),
                    ),
                    child: Icon(
                      Icons.edit_rounded,
                      size: 20,
                      color: t.accentText,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.foodManualEntryCta,
                        style: AppType.ui(
                          15,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.foodManualEntryHint,
                        style: AppType.ui(12.5, color: t.ink2, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: t.ink3,
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

// ─── Hints and empty state ──────────────────────────────────────────────

/// "Taking longer" line plus cancel, shown under the search skeleton once
/// `_AddMealSheetState._productSearchSlowAfter` passed.
///
/// Deliberately the same ARB key as `_SlowHint` in `meal_analysis_sheet.dart`:
/// one wording for "this is taking a while", so the photo scan and the
/// product search speak with one voice. Its own widget rather than a shared
/// one — the analysis sheet's version sits under a loading CARD and carries
/// that card's insets.
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
            style: AppType.ui(13, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          key: const ValueKey('product-search-cancel'),
          onPressed: onCancel,
          style: TextButton.styleFrom(foregroundColor: t.accentText),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }
}

/// The sheet's one shape for "nothing to show here": an icon tile, one line
/// of guidance and at most one way forward.
class _CalmState extends StatelessWidget {
  const _CalmState({
    required this.icon,
    required this.text,
    this.title,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        children: [
          IconTile.custom(
            size: 48,
            child: Icon(icon, size: 22, color: t.ink2),
          ),
          const SizedBox(height: 14),
          if (title != null) ...[
            Text(
              title!,
              textAlign: TextAlign.center,
              style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            text,
            textAlign: TextAlign.center,
            style: AppType.ui(13.5, color: t.ink2, height: 1.4),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// Accent-tinted pill for the one secondary action of a [_CalmState].
class _TintedPillButton extends StatelessWidget {
  const _TintedPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return PressScale(
      child: Material(
        color: t.accentTint,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: t.accentText),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w700,
                      color: t.accentText,
                    ),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _CalmState(
      icon: Icons.history_rounded,
      title: l10n.foodEntryEmptyTitle,
      text: l10n.foodEntryEmptyHint,
    );
  }
}
