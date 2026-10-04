import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../widgets/common/persistence_action.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/l10n.dart';
import '../models/day_nutrition.dart';
import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/recipe_pick.dart';
import '../models/user_profile.dart';
import '../config/search_config.dart';
import '../services/day_math.dart';
import '../services/fallback_product_service.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/meal_scan_identity.dart';
import '../services/meal_totals.dart';
import '../services/meilisearch_product_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../services/trend_service.dart';
import '../theme/app_tokens.dart';
import '../theme/meal_slot_style.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/lively.dart';
import '../widgets/design/design.dart';
import '../widgets/kcal/add_meal_sheet.dart';
import '../widgets/kcal/diary_meal_card.dart';
import '../widgets/kcal/food_page_chrome.dart';
import '../widgets/kcal/food_date_picker.dart';
import '../widgets/kcal/manual_meal_sheet.dart';
import '../widgets/kcal/meal_analysis_sheet.dart';
import '../widgets/kcal/meal_scan_preview_sheet.dart';
import 'barcode_scanner_sheet.dart';
import '../widgets/recipes/recipe_pick_actions.dart';
import 'trends_screen.dart';

/// The Food diary (dark redesign): title with calendar, day switcher, day
/// summary, one card per meal slot and a floating capture dock above the tab
/// bar that the diary scrolls under.
class MealAnalysisScreen extends StatelessWidget {
  MealAnalysisScreen({
    super.key,
    MealAnalyzer? analyzer,
    ProductLookupService? productService,
    MealPhotoInput? photoInput,
    MealCameraLauncher? cameraLauncher,
    required this.dailyConsumedKcal,
    this.profile = const UserProfile(),
    this.favorites = const <FavoriteMeal>[],
    this.loggedMeals = const <LoggedMeal>[],
    DateTime? selectedDate,
    ValueChanged<DateTime>? onDateSelected,
    this.dayLoading = false,
    FutureOr<String> Function(MealAnalysisResult, MealSlot)? onAddMeal,
    FutureOr<void> Function(String id, MealAnalysisResult scaled)? onUpdateMeal,
    this.isFavorite,
    this.onToggleFavorite,
    ValueChanged<String>? onRemoveFavorite,
    PersistValueChanged<String>? onRemoveMeal,
    this.trendTotalsLoader,
    this.trendBurnedKcalFor,
    this.addSlotRequest,
    this.nutrition,
    this.recipePick,
    this.onOpenMealPlan,
  }) : analyzer = analyzer ?? const EdgeFunctionMealAnalyzer(),
       productService = productService ?? _defaultProductService(),
       photoInput = photoInput ?? DeviceMealPhotoInput(),
       cameraLauncher = cameraLauncher ?? const InAppMealCameraLauncher(),
       selectedDate = DateUtils.dateOnly(selectedDate ?? clock.now()),
       onDateSelected = onDateSelected ?? _noopDate,
       onAddMeal = onAddMeal ?? _noopAdd,
       onUpdateMeal = onUpdateMeal ?? _noopUpdate,
       onRemoveFavorite = onRemoveFavorite ?? _noopString,
       onRemoveMeal = onRemoveMeal ?? _noopString;

  // Own search index (Meilisearch) with live OFF as fallback for new products,
  // barcode lookups and mirror outages.
  //
  // Runs on EVERY rebuild, so it stays strictly synchronous and
  // allocation-free: no `await`, no SharedPreferences, no `Supabase.instance`.
  // Credentials are decided by the search request itself; only the hard local
  // kill switch `--dart-define=OFF_MIRROR_URL=` lives here.
  static ProductLookupService _defaultProductService() {
    const off = OpenFoodFactsProductService();
    if (SearchConfig.mirrorHardDisabled) return off;
    return const FallbackProductService(MeilisearchProductService(), off);
  }

  // Default onAddMeal returns an empty id (preview/test without persistence);
  // a later re-portioning then hits the no-op update.
  static String _noopAdd(MealAnalysisResult _, MealSlot __) => '';
  static void _noopDate(DateTime _) {}
  static void _noopUpdate(String _, MealAnalysisResult __) {}
  static void _noopString(String _) {}

  final MealAnalyzer analyzer;
  final ProductLookupService productService;
  final MealPhotoInput photoInput;
  final MealCameraLauncher cameraLauncher;
  final int dailyConsumedKcal;
  final UserProfile profile;
  final List<FavoriteMeal> favorites;
  final List<LoggedMeal> loggedMeals;

  /// External request to open the add sheet for a slot, set by the Heute tab.
  ///
  /// A [ValueNotifier], not a plain parameter: the shell caches tab widgets by
  /// identity (`_tabViews`), so a changed parameter would never reach the built
  /// tab. The receiver resets the value to null after handling it, otherwise
  /// the next visit would open a ghost sheet.
  final ValueNotifier<MealSlot?>? addSlotRequest;

  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;

  /// True while a calendar-picked day outside the 35-day window loads; the
  /// diary then shows a spinner instead of a falsely empty day.
  final bool dayLoading;
  final FutureOr<String> Function(MealAnalysisResult, MealSlot) onAddMeal;
  final FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal;

  /// Is the meal pinned as a favorite? Null -> no heart.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favorite toggle. Null -> no heart.
  final PersistValueChanged<MealAnalysisResult>? onToggleFavorite;
  final PersistValueChanged<String> onRemoveFavorite;
  final PersistValueChanged<String> onRemoveMeal;

  /// Data loader for the trends view (test injection). Null builds a
  /// TrendService on Supabase.instance lazily when opened; the constructor
  /// never touches Supabase.
  final TrendTotalsLoader? trendTotalsLoader;

  /// Step bonus per day for the trends corridor (F7-05), the store's
  /// `burnedKcalForFoodDate`. Null keeps Trends on the base goal.
  final int Function(DateTime day)? trendBurnedKcalFor;

  /// The shown day's numbers (the store's `nutritionSummaryForFoodDate`:
  /// budget incl. activity credit). Null (tests, previews) derives them from
  /// [profile], [loggedMeals] and [dailyConsumedKcal] without a credit.
  final DayNutritionSummary? nutrition;

  /// Today's recipe pick (`nextMealPick`); shown in its empty slot only
  /// while today is on screen.
  final RecipePick? recipePick;

  /// Opens the meal plan: where a planned pick is eaten.
  final VoidCallback? onOpenMealPlan;

  void _openAddSheet(
    BuildContext context,
    MealSlot slot, {
    bool searchMode = false,
  }) {
    // All entries of the shown day; the sheet filters by the selected slot
    // itself, so it stays in sync when the user switches slots. `slot` is only
    // the default. DATA-6: bucketed via `mealsForFoodDate`, not
    // `isSameDay(loggedAt)` — see [_entriesBySlot].
    final existingForDay = mealsForFoodDate(loggedMeals, selectedDate);
    showAddMealSheet(
      context,
      slot: slot,
      searchMode: searchMode,
      analyzer: analyzer,
      productService: productService,
      photoInput: photoInput,
      favorites: favorites,
      existingMeals: existingForDay,
      // The sheet mirrors its own adds; on an archive day the mirror must
      // carry THAT day, like the store does.
      foodDate: selectedDate,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      onRemoveFavorite: onRemoveFavorite,
      onRemoveMeal: onRemoveMeal,
    );
  }

  // AI scan: in-app camera with slot picker -> photo -> analysis -> result
  // sheet in the chosen slot.
  Future<void> _scanWithCamera(BuildContext context) async {
    final identity = MealScanIdentity();
    final capture = await cameraLauncher.launch(
      context,
      initialSlot: currentMealSlot(),
    );
    if (capture == null || !context.mounted || !identity.isCurrent) return;
    // One request for first try and retries (same bytes); the camera sheet's
    // cancel handle lets a swiped-away result sheet abort the attempt in
    // flight (review F4-02).
    final request = await showMealScanPreviewSheet(
      context,
      request: capture.request.withLanguage(context.l10n.localeName),
      previewBytes: capture.previewBytes,
    );
    if (request == null || !context.mounted || !identity.isCurrent) return;
    // An attempt that fails before the sheet listens (validation, already
    // cancelled) must not surface as an unhandled zone error; the sheet's
    // error card reports it once it is up. `ignore` only marks it handled.
    final first = analyzer.analyze(request)..ignore();
    final outcome = await showMealAnalysisSheet(
      context,
      slot: capture.slot,
      resultFuture: first,
      retry: () => identity.isCurrent
          ? analyzer.analyze(request)
          : Future.error(const MealAnalysisCancelled()),
      cancellation: request.cancellation,
      previewImage: capture.previewBytes,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      failureMessage: context.l10n.foodAnalysisFailedMessage,
    );
    if (outcome == MealAnalysisSheetOutcome.manualEntry && context.mounted) {
      await _manualEntryFor(context, capture.slot);
    }
  }

  /// Manual capture or scan fallback. The dock offers a slot choice; both
  /// paths preserve the explicit-confirmation and zero-calorie guards.
  Future<void> _manualEntryFor(
    BuildContext context,
    MealSlot slot, {
    bool chooseSlot = false,
  }) async {
    final identity = MealScanIdentity();
    var selectedSlot = slot;
    final result = await showManualMealSheet(
      context,
      initialSlot: chooseSlot ? slot : null,
      onSlotChanged: (slot) => selectedSlot = slot,
      onSave: (result) async {
        if (!identity.isCurrent) throw StateError('Meal owner changed');
        await onAddMeal(result, selectedSlot);
      },
      contextLabel: foodHeaderDateLabel(selectedDate, context.l10n),
    );
    if (result == null || !context.mounted || !identity.isCurrent) return;
    final l10n = context.l10n;
    if (result.caloriesKcal <= 0 && !result.explicitZeroKcal) {
      showAppSnack(
        context,
        l10n.foodSuggestionWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, selectedSlot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
  }

  // Barcode: in-app scanner as a bottom panel -> OFF lookup -> result sheet.
  Future<void> _scanBarcode(BuildContext context) async {
    // The clock slot only preselects the scanner's chips; the choice there
    // decides where the product goes (finding 2026-08-22: the slot was not
    // selectable from this button before).
    final scan = await showBarcodeScannerSheet(
      context,
      initialSlot: currentMealSlot(),
    );
    if (scan == null || !context.mounted) return;
    // As for the photo scan: offline the lookup fails before the sheet
    // listens, which must not surface as an unhandled zone error.
    final lookup = productService.lookupBarcode(scan.code)..ignore();
    // No retry/cancel: a lookup is cheap and its "not found" is final.
    final outcome = await showMealAnalysisSheet(
      context,
      slot: scan.slot,
      resultFuture: lookup,
      previewImage: null,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      failureMessage: context.l10n.foodBarcodeNotFoundMessage(scan.code),
    );
    if (outcome == MealAnalysisSheetOutcome.manualEntry && context.mounted) {
      await _manualEntryFor(context, scan.slot);
    }
  }

  // Trends as a full page. The kcal goal comes from the already passed profile
  // (no store access); the loader is injected or built lazily on open, so
  // construction and preview work without an initialized Supabase.
  void _openTrends(BuildContext context) {
    final loader = trendTotalsLoader ?? _supabaseTrendLoader;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrendsScreen(
          kcalGoal: profile.dailyKcalGoal,
          loadTotals: loader,
          burnedKcalFor: trendBurnedKcalFor ?? noTrendStepBonus,
        ),
      ),
    );
  }

  static Future<List<TrendDayTotals>> _supabaseTrendLoader() {
    // Throws synchronously without init/session; TrendsScreen turns that into
    // its error/retry state rather than a crash.
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Kein angemeldeter Nutzer für die Trend-Ansicht.');
    }
    return TrendService(client, userId).loadDailyTotals();
  }

  /// Entries of the shown day per slot, oldest first (the diary order of
  /// `mealSlotSummariesForFoodDate`), each with its index in the DAY list
  /// sorted newest first.
  ///
  /// Indices are assigned once per day, not per slot card, so
  /// `food-history-entry-0` stays the day's newest entry, which several flows
  /// rely on.
  ///
  /// Filtering uses `mealsForFoodDate`, the canonical DATA-6 key that also
  /// feeds [dailyConsumedKcal]. A local `isSameDay(loggedAt, selectedDate)`
  /// would let a meal with a persisted `local_day` count in the header but
  /// drop out of the diary.
  Map<MealSlot, List<DiaryEntry>> _entriesBySlot() {
    final newestFirst = mealsForFoodDate(loggedMeals, selectedDate).toList()
      ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    final dayIndex = Map<LoggedMeal, int>.identity();
    for (var i = 0; i < newestFirst.length; i++) {
      dayIndex[newestFirst[i]] = i;
    }
    return {
      for (final summary in mealSlotSummariesForFoodDate(
        loggedMeals,
        selectedDate,
      ))
        summary.slot: [
          for (final meal in summary.meals) DiaryEntry(meal, dayIndex[meal]!),
        ],
    };
  }

  /// [nutrition], or the same numbers from the screen's own inputs.
  DayNutritionSummary _summary() {
    final given = nutrition;
    if (given != null) return given;
    final macros = mealsForFoodDate(loggedMeals, selectedDate).fold(
      MacroProgress.empty,
      (sum, meal) => sum.add(meal.result),
    );
    return DayNutritionSummary(
      profile: profile,
      burnedKcal: 0,
      consumed: MacroProgress(
        proteinG: macros.proteinG,
        carbsG: macros.carbsG,
        fatG: macros.fatG,
        kcal: dailyConsumedKcal,
      ),
    );
  }

  /// The pick row: a suggestion opens its recipe (adding there logs through
  /// [onAddMeal]); a planned meal opens the meal plan ([onOpenMealPlan]),
  /// whose "Eat" is the plan conversion. See [openRecipePick].
  void _openPick(BuildContext context, RecipePick pick) {
    final identity = MealScanIdentity();
    openRecipePick(
      context,
      pick,
      addMeal: onAddMeal,
      openMealPlan: onOpenMealPlan ?? () {},
      isSessionCurrent: () => identity.isCurrent,
      photoInput: photoInput,
      productService: productService,
    );
  }

  /// A planned pick needs the meal plan; without it the row stays inert.
  bool _canOpenPick(RecipePick pick) =>
      pick.source != RecipePickSource.planned || onOpenMealPlan != null;

  Future<void> _selectDate(BuildContext context) async {
    // This screen context survives relocation of the visible date controls.
    final today = DateUtils.dateOnly(clock.now());
    final first = DateTime(today.year - 2, today.month, today.day);
    final initial = selectedDate.isBefore(first)
        ? first
        : (selectedDate.isAfter(today) ? today : selectedDate);
    final picked = await showFoodDatePicker(
      context,
      initialDate: initial,
      firstDate: first,
      today: today,
    );
    if (picked != null && context.mounted) onDateSelected(picked);
  }

  /// Gap between the page's blocks (design: 14).
  static const double _gap = 14;

  /// Space the design keeps between the dock and the diary's end.
  static const double _dockClearance = 44;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bySlot = _entriesBySlot();
    final summary = _summary();
    final today = DateUtils.dateOnly(clock.now());
    final showsToday = DateUtils.isSameDay(selectedDate, today);
    final pick = showsToday ? recipePick : null;
    final chrome = <Widget>[
      FoodPageHeader(
        key: TabChrome.headerKey,
        onCalendar: () => _selectDate(context),
      ),
      const SizedBox(height: _gap),
      FoodDayNavigation(
        day: selectedDate,
        headline: foodDateSelectedLabel(today, selectedDate, l10n),
        dateLabel: foodHeaderDateLabel(selectedDate, l10n),
        onSelected: onDateSelected,
      ),
      const SizedBox(height: _gap),
      FoodDaySummaryCard(
        summary: summary,
        loading: dayLoading,
        onTap: () => _openTrends(context),
      ),
      const SizedBox(height: _gap),
    ];
    final diary = dayLoading
        ? const _DayLoadingCard()
        : SlidableAutoCloseBehavior(
            child: Column(
              key: const ValueKey('kcal-meals-today-card'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  key: const ValueKey('food-history'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final slot in MealSlot.values) ...[
                      if (slot != MealSlot.values.first)
                        const SizedBox(height: _gap),
                      DiaryMealCard(
                        key: ValueKey(
                          'food-slot-${selectedDate.toIso8601String()}-${slot.name}',
                        ),
                        slot: slot,
                        entries: bySlot[slot]!,
                        // A guide for today's open slots, sized by what is
                        // left; past days just say nothing was logged.
                        suggestedRange: showsToday
                            ? summary.suggestedKcalRange(
                                slot,
                                emptySlots: [
                                  for (final s in MealSlot.values)
                                    if (bySlot[s]!.isEmpty) s,
                                ],
                              )
                            : null,
                        pick:
                            pick != null &&
                                pick.slot == slot &&
                                bySlot[slot]!.isEmpty
                            ? pick
                            : null,
                        onOpenPick: pick == null || !_canOpenPick(pick)
                            ? null
                            : () => _openPick(context, pick),
                        onAddToSlot: (s) => _openAddSheet(context, s),
                        onMealTap: (s) => _openAddSheet(context, s),
                        onRemoveMeal: onRemoveMeal,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          );
    final dock = FoodEntryDock(
      enabled: !dayLoading,
      onSearch: () =>
          _openAddSheet(context, currentMealSlot(), searchMode: true),
      onCamera: () => _scanWithCamera(context),
      onBarcode: () => _scanBarcode(context),
      onManual: () =>
          _manualEntryFor(context, currentMealSlot(), chooseSlot: true),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // The floating tab bar's band (from the shell): the dock floats on
        // it and the diary scrolls under both.
        final navInset = MediaQuery.paddingOf(context).bottom;
        // Very short windows (landscape) keep the dock at the diary's end
        // instead of letting it cover most of the view.
        final floating =
            constraints.hasBoundedHeight &&
            constraints.maxHeight - navInset >= 380;
        final t = context.t;
        // Keep the scrollable and diary at the same element paths when the
        // keyboard or rotation changes available space, even in a hidden tab.
        final body = Stack(
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                key: const ValueKey('food-diary-scroll'),
                padding: EdgeInsets.fromLTRB(
                  20,
                  TabChrome.topInset(context),
                  20,
                  navInset +
                      (floating ? FoodEntryDock.height + _dockClearance : 20),
                ),
                // Own layer: scrolling moves the recorded diary instead of
                // re-recording it every frame.
                child: RepaintBoundary(
                  child: Column(
                    key: const ValueKey('food-diary-content'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: livelyStagger([
                      ...chrome,
                      diary,
                      floating
                          ? const SizedBox.shrink()
                          : const SizedBox(height: 20),
                      floating ? const SizedBox.shrink() : dock,
                  ]),
                  ),
                ),
              ),
            ),
            // The design's fade behind the dock: the diary dissolves into
            // the page before it reaches the dock and the bar.
            if (floating)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: navInset + FoodEntryDock.height + _dockClearance,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('food-dock-fade'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.4, 1],
                        colors: [t.bg.withValues(alpha: 0), t.bg, t.bg],
                      ),
                    ),
                  ),
                ),
              ),
            if (floating)
              Positioned(
                left: 14,
                right: 14,
                bottom: navInset,
                child: LivelyStaggerItem(
                  index: LivelyStaggerScope.maxIndex,
                child: ReadableWidth(child: dock),
              ),
              ),
          ],
        );
        return SizedBox(
          key: const ValueKey('kcal-page-fill'),
          height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
          child: _SlotRequestListener(
            request: addSlotRequest,
            onSlot: (listenerContext, slot) =>
                _openAddSheet(listenerContext, slot),
            child: KeyedSubtree(
              key: const ValueKey('screen-kcal-tracker'),
              // A new date starts at the first meal, not at the old scroll
              // offset. The first-view entrance sits above that key: it
              // plays once, not again for every day.
              child: LivelyStaggerScope(
              child: KeyedSubtree(key: ValueKey(selectedDate), child: body),
            ),
          ),
          ),
        );
      },
    );
  }
}

/// Opens the add sheet when a slot is requested from outside.
///
/// Lives inside the Food tab's tree because the sheet needs a context below
/// the navigator. Both triggers are required: the tab is built lazily, so a
/// request that already exists at mount time would miss a plain listener.
class _SlotRequestListener extends StatefulWidget {
  const _SlotRequestListener({
    required this.request,
    required this.onSlot,
    required this.child,
  });

  final ValueNotifier<MealSlot?>? request;
  final void Function(BuildContext context, MealSlot slot) onSlot;
  final Widget child;

  @override
  State<_SlotRequestListener> createState() => _SlotRequestListenerState();
}

class _SlotRequestListenerState extends State<_SlotRequestListener> {
  @override
  void initState() {
    super.initState();
    widget.request?.addListener(_pruefe);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pruefe());
  }

  @override
  void didUpdateWidget(covariant _SlotRequestListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      oldWidget.request?.removeListener(_pruefe);
      widget.request?.addListener(_pruefe);
    }
  }

  @override
  void dispose() {
    widget.request?.removeListener(_pruefe);
    super.dispose();
  }

  void _pruefe() {
    final anfrage = widget.request;
    final slot = anfrage?.value;
    if (slot == null || !mounted) return;
    // Reset first, then open: the sheet is async, and a second notify in
    // between would otherwise open it twice.
    anfrage!.value = null;
    widget.onSlot(context, slot);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One-time init of the `intl` date symbols. The screen rebuilds on every
/// HomeStore change, so without this guard `initializeDateFormatting()` would
/// rebuild its large CLDR table each time.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// The selected diary date, "Monday, Sep 28" ("Montag, 28. Sept."); archived
/// years stay unambiguous.
@visibleForTesting
String foodHeaderDateLabel(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  final locale = l10n.localeName;
  final weekday = DateFormat.EEEE(locale).format(date);
  final day = date.year != clock.now().year
      ? DateFormat.yMMMd(locale).format(date)
      : DateFormat.MMMd(locale).format(date);
  return '$weekday, $day';
}

/// The headline of the day navigation naming the selected day. Reads the same
/// ARB keys as `today_texts.dart:todayDateLabel` so the two copies cannot
/// drift. Counts calendar days via [daysBetween], never `Duration` (B5).
@visibleForTesting
String foodDateSelectedLabel(
  DateTime today,
  DateTime selected,
  AppLocalizations l10n,
) {
  final offset = daysBetween(today, selected);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  return l10n.todayDateDaysAgo(offset);
}

/// Loading state of the diary while an older day loads on demand: exactly one
/// spinner replacing the whole diary block, not individual cards.
class _DayLoadingCard extends StatelessWidget {
  const _DayLoadingCard();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('food-day-loading'),
      radius: rCard,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: t.accent),
          ),
          const SizedBox(height: 10),
          Text(
            // Shares `todayDayLoading`: both tabs show the same interim state.
            context.l10n.todayDayLoading,
            style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
