import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/l10n.dart';
import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_result.dart';
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
import '../widgets/design/design.dart';
import '../widgets/kcal/add_meal_sheet.dart';
import '../widgets/kcal/diary_meal_card.dart';
import '../widgets/kcal/food_page_chrome.dart';
import '../widgets/kcal/manual_meal_sheet.dart';
import '../widgets/kcal/meal_analysis_sheet.dart';
import '../widgets/kcal/meal_scan_preview_sheet.dart';
import 'barcode_scanner_sheet.dart';
import 'trends_screen.dart';

/// The Food diary: day navigation, expandable meal sections and a capture dock.
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
    String Function(MealAnalysisResult, MealSlot)? onAddMeal,
    void Function(String id, MealAnalysisResult scaled)? onUpdateMeal,
    this.isFavorite,
    this.onToggleFavorite,
    ValueChanged<String>? onRemoveFavorite,
    ValueChanged<String>? onRemoveMeal,
    this.onSettingsPressed,
    this.onProfilePressed,
    this.profileInitial,
    this.trendTotalsLoader,
    this.trendBurnedKcalFor,
    this.addSlotRequest,
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
  final String Function(MealAnalysisResult, MealSlot) onAddMeal;
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;

  /// Is the meal pinned as a favorite? Null -> no heart.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favorite toggle. Null -> no heart.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final ValueChanged<String> onRemoveFavorite;
  final ValueChanged<String> onRemoveMeal;

  /// Entries in the Food header's overflow menu; null hides the respective item.
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onProfilePressed;
  final String? profileInitial;

  /// Data loader for the trends view (test injection). Null builds a
  /// TrendService on Supabase.instance lazily when opened; the constructor
  /// never touches Supabase.
  final TrendTotalsLoader? trendTotalsLoader;

  /// Step bonus per day for the trends corridor (F7-05), the store's
  /// `burnedKcalForFoodDate`. Null keeps Trends on the base goal.
  final int Function(DateTime day)? trendBurnedKcalFor;

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
    onAddMeal(result, selectedSlot);
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
    // No retry/cancel: a lookup is cheap and its "not found" is final.
    final outcome = await showMealAnalysisSheet(
      context,
      slot: scan.slot,
      resultFuture: productService.lookupBarcode(scan.code),
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

  /// Entries of the shown day, newest first, each with its index in THIS list.
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
    final sorted = mealsForFoodDate(loggedMeals, selectedDate).toList()
      ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    final map = <MealSlot, List<DiaryEntry>>{
      for (final slot in MealSlot.values) slot: <DiaryEntry>[],
    };
    for (var i = 0; i < sorted.length; i++) {
      map[sorted[i].slot]!.add(DiaryEntry(sorted[i], i));
    }
    return map;
  }

  Future<void> _selectDate(BuildContext context) async {
    // This screen context survives relocation of the visible date controls.
    final today = DateUtils.dateOnly(clock.now());
    final first = DateTime(today.year - 2, today.month, today.day);
    final initial = selectedDate.isBefore(first)
        ? first
        : (selectedDate.isAfter(today) ? today : selectedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: today,
      helpText: context.l10n.foodDatePickerHelpText,
    );
    if (picked != null && context.mounted) onDateSelected(picked);
  }

  Future<void> _openOptions(BuildContext context, BuildContext anchor) async {
    final box = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final l10n = context.l10n;
    // Complete from the screen, even if resizing relocates the menu anchor.
    final action = await showMenu<VoidCallback>(
      context: context,
      position: position,
      items: [
        if (onProfilePressed != null)
          PopupMenuItem(
            key: const ValueKey('topbar-profile'),
            value: onProfilePressed,
            child: Text(l10n.todaySemanticsOpenProfile),
          ),
        if (onSettingsPressed != null)
          PopupMenuItem(
            key: const ValueKey('topbar-settings'),
            value: onSettingsPressed,
            child: Text(l10n.foodSemanticsSettings),
          ),
      ],
    );
    if (context.mounted) action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final bySlot = _entriesBySlot();
    final pageHeader = Column(
      children: [
        FoodPageHeader(
          consumedKcal: dailyConsumedKcal,
          loading: dayLoading,
          onTrends: () => _openTrends(context),
          onOptions: onSettingsPressed == null && onProfilePressed == null
              ? null
              : (anchor) => _openOptions(context, anchor),
        ),
        FoodDayNavigation(
          day: selectedDate,
          label: foodHeaderDateLabel(selectedDate, context.l10n),
          onSelected: onDateSelected,
          onCalendar: () => _selectDate(context),
        ),
      ],
    );
    final diary = dayLoading
        ? const _DayLoadingCard()
        : SlidableAutoCloseBehavior(
            child: Column(
              key: const ValueKey('kcal-meals-today-card'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  key: const ValueKey('food-history'),
                  children: [
                    for (final slot in MealSlot.values)
                      DiaryMealCard(
                        key: ValueKey(
                          'food-slot-${selectedDate.toIso8601String()}-${slot.name}',
                        ),
                        slot: slot,
                        entries: bySlot[slot]!,
                        onAddToSlot: (s) => _openAddSheet(context, s),
                        onMealTap: (s) => _openAddSheet(context, s),
                        onRemoveMeal: onRemoveMeal,
                      ),
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
        // Large text and short landscape windows need the whole page to scroll.
        final pinned =
            constraints.hasBoundedHeight &&
            constraints.maxWidth >= 340 &&
            constraints.maxHeight >= 560 &&
            MediaQuery.textScalerOf(context).scale(14) <= 20;
        final content = Padding(
          key: const ValueKey('food-diary-content'),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: diary,
        );
        // Keep the scrollable and diary at the same element paths when the
        // keyboard or rotation changes available space, even in a hidden tab.
        final body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            pinned ? pageHeader : const SizedBox.shrink(),
            Flexible(
              key: const ValueKey('food-scroll-region'),
              fit: pinned ? FlexFit.tight : FlexFit.loose,
              child: ColoredBox(
                color: context.t.surf,
                child: SingleChildScrollView(
                  key: const ValueKey('food-diary-scroll'),
                  child: Column(
                    children: [
                      pinned ? const SizedBox.shrink() : pageHeader,
                      content,
                      const SizedBox(height: 20),
                      pinned ? const SizedBox.shrink() : dock,
                    ],
                  ),
                ),
              ),
            ),
            pinned ? dock : const SizedBox.shrink(),
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
              // A new date starts at the first meal, not at the old scroll offset.
              child: KeyedSubtree(key: ValueKey(selectedDate), child: body),
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

/// The selected diary date; archived years stay unambiguous.
@visibleForTesting
String foodHeaderDateLabel(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  if (date.year != clock.now().year) {
    return DateFormat.yMMMMEEEEd(l10n.localeName).format(date);
  }
  return DateFormat.MMMMEEEEd(l10n.localeName).format(date);
}

// ---------------------------------------------------------------------------
// B5: calendar arithmetic of the date strip
// ---------------------------------------------------------------------------
//
// `Duration` is absolute time, not a calendar. Across a DST change
// `today.subtract(Duration(days: 1))` skipped a day, so the "yesterday" chip
// carried the wrong date and meals logged from it got the wrong `local_day`;
// `.difference(...).inDays` was off by the same 23-hour day.
//
// Both now go through `day_math.dart`, as free functions so they can be tested
// against an arbitrary anchor instead of only `clock.now()`.

/// The strip's days: [pastDays] past days plus [today], ascending.
@visibleForTesting
List<DateTime> foodDateStripDays({
  required DateTime today,
  required int pastDays,
}) {
  return dayStrip(today: today, pastDays: pastDays);
}

/// A chip's headline: for older days the weekday, since the date already
/// stands below it. Uses `intl`'s `EE` skeleton; the trailing dot of the
/// German CLDR abbreviations is stripped so `de` stays byte-identical.
@visibleForTesting
String foodDateChipLabel(DateTime today, DateTime date, AppLocalizations l10n) {
  final offset = daysBetween(today, date);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  _ensureDateSymbols();
  return DateFormat('EE', l10n.localeName).format(date).replaceAll('.', '');
}

/// A chip's date line, locale-aware via `intl`'s `Md` skeleton ("27.8." in
/// `de`, "8/27" in `en`) — the same format the store's move snack uses.
@visibleForTesting
String foodDateChipDate({
  required DateTime date,
  required AppLocalizations l10n,
}) {
  _ensureDateSymbols();
  return DateFormat.Md(l10n.localeName).format(date);
}

/// The line above the chips naming the selected day. Reads the same ARB keys
/// as `today_texts.dart:todayDateLabel` so the two copies cannot drift.
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
