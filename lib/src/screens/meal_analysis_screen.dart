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
import '../services/kcal_format.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/meal_totals.dart';
import '../services/meilisearch_product_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../services/trend_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/motion.dart';
import '../widgets/design/design.dart';
import '../widgets/kcal/add_meal_sheet.dart';
import '../widgets/kcal/diary_meal_card.dart';
import '../widgets/kcal/meal_analysis_sheet.dart';
import 'barcode_scanner_sheet.dart';
import 'trends_screen.dart';

/// The Food tab: header, date strip, search launcher with barcode/AI scan and
/// the diary with its four slot cards.
///
/// No calorie card: the `DailySummaryCard` repeated what the Heute tab already
/// shows and pushed the diary — this tab's actual job — below the fold on an
/// 852 px screen. The consumed kcal of the shown day stay visible as a small
/// forest tile in the header ([_KcalTile]).
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
    // 30 days reachable via chips, older ones via the calendar. Stays under
    // MealsSync's 35-day boot window, so chips always hit loaded days.
    this.visiblePastDays = 30,
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
    this.addSlotRequest,
  }) : analyzer = analyzer ?? const EdgeFunctionMealAnalyzer(),
       productService = productService ?? _defaultProductService(),
       photoInput = photoInput ?? DeviceMealPhotoInput(),
       cameraLauncher = cameraLauncher ?? const InAppMealCameraLauncher(),
       selectedDate = DateUtils.dateOnly(selectedDate ?? DateTime.now()),
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
  final int visiblePastDays;

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

  /// Entry to settings sheet and profile screen; the Food header is the only
  /// way in. Null (preview/test) hides the icons.
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onProfilePressed;
  final String? profileInitial;

  /// Data loader for the trends view (test injection). Null builds a
  /// TrendService on Supabase.instance lazily when opened; the constructor
  /// never touches Supabase.
  final TrendTotalsLoader? trendTotalsLoader;

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
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      onRemoveFavorite: onRemoveFavorite,
      onRemoveMeal: onRemoveMeal,
    );
  }

  // Slot heuristic for the sheet openers; matches LoggedMeal.slot so a new
  // entry lands in the right slot.
  MealSlot _heuristicSlot() {
    final h = DateTime.now().hour;
    if (h < 11) return MealSlot.breakfast;
    if (h < 15) return MealSlot.lunch;
    if (h < 21) return MealSlot.dinner;
    return MealSlot.snack;
  }

  // AI scan: in-app camera with slot picker -> photo -> analysis -> result
  // sheet in the chosen slot.
  Future<void> _scanWithCamera(BuildContext context) async {
    final capture = await cameraLauncher.launch(
      context,
      initialSlot: _heuristicSlot(),
    );
    if (capture == null || !context.mounted) return;
    await showMealAnalysisSheet(
      context,
      slot: capture.slot,
      resultFuture: analyzer.analyze(
        capture.request.withLanguage(context.l10n.localeName),
      ),
      previewImage: capture.previewBytes,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      failureMessage: context.l10n.foodAnalysisFailedMessage,
    );
  }

  // Barcode: in-app scanner as a bottom panel -> OFF lookup -> result sheet.
  Future<void> _scanBarcode(BuildContext context) async {
    // The clock slot only preselects the scanner's chips; the choice there
    // decides where the product goes (finding 2026-08-22: the slot was not
    // selectable from this button before).
    final scan = await showBarcodeScannerSheet(
      context,
      initialSlot: _heuristicSlot(),
    );
    if (scan == null || !context.mounted) return;
    await showMealAnalysisSheet(
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
  }

  // Trends as a full page. The kcal goal comes from the already passed profile
  // (no store access); the loader is injected or built lazily on open, so
  // construction and preview work without an initialized Supabase.
  void _openTrends(BuildContext context) {
    final loader = trendTotalsLoader ?? _supabaseTrendLoader;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TrendsScreen(kcalGoal: profile.dailyKcalGoal, loadTotals: loader),
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final l10n = context.l10n;
        final boundedHeight = constraints.hasBoundedHeight;
        final bySlot = _entriesBySlot();
        final tagLeer = bySlot.values.every((e) => e.isEmpty);

        final children = <Widget>[
          _KcalHeader(
            selectedDate: selectedDate,
            consumedKcal: dailyConsumedKcal,
            onTrendsPressed: () => _openTrends(context),
            onSettingsPressed: onSettingsPressed,
            onProfilePressed: onProfilePressed,
            profileInitial: profileInitial,
          ),
          const SizedBox(height: 14),
          _FoodDateStrip(
            selectedDate: selectedDate,
            pastDays: visiblePastDays,
            onSelected: onDateSelected,
          ),
          const SizedBox(height: 12),
          // Search launcher + quick chips. No entrance animation, so they stay
          // reliably hit-testable in widget tests.
          _FoodAddBlock(
            onSearch: () =>
                _openAddSheet(context, _heuristicSlot(), searchMode: true),
            onBarcode: () => _scanBarcode(context),
            onAiScan: () => _scanWithCamera(context),
          ),
          // The DailySummaryCard used to sit here; the day balance now lives
          // in the Heute tab (see class comment).
          const SizedBox(height: 14),
          if (dayLoading)
            const _DayLoadingCard()
          else
            // Built eagerly (Column, not ListView): finders walk the element
            // tree, and in a lazy list the lower slot cards would not exist.
            SlidableAutoCloseBehavior(
              child: Column(
                key: const ValueKey('kcal-meals-today-card'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // The section keeps its name: DESIGN_REFACTOR §6 pins the
                  // wording, a redesign is not a rename.
                  SectionHeading(title: l10n.foodSectionHistoryTitle),
                  const SizedBox(height: 12),
                  Column(
                    key: const ValueKey('food-history'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final slot in MealSlot.values) ...<Widget>[
                        DiaryMealCard(
                          slot: slot,
                          entries: bySlot[slot]!,
                          onAddToSlot: (s) => _openAddSheet(context, s),
                          onMealTap: (s) => _openAddSheet(context, s),
                          onRemoveMeal: onRemoveMeal,
                        ),
                        if (slot != MealSlot.values.last)
                          const SizedBox(height: 12),
                      ],
                    ],
                  ),
                  if (tagLeer) ...<Widget>[
                    const SizedBox(height: 14),
                    const _DiaryDayHint(),
                  ],
                ],
              ),
            ),
        ];

        final column = Column(
          key: const ValueKey('screen-kcal-tracker'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );

        return SizedBox(
          key: const ValueKey('kcal-page-fill'),
          height: boundedHeight ? constraints.maxHeight : null,
          // Without a bounded height a scroll view would grow forever; the
          // same Column then renders unscrolled.
          child: _SlotRequestListener(
            request: addSlotRequest,
            onSlot: (listenerContext, slot) =>
                _openAddSheet(listenerContext, slot),
            child: boundedHeight
                ? SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: column,
                  )
                : column,
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

/// Hint for a day without any entry, shown once below the four slot cards.
class _DiaryDayHint extends StatelessWidget {
  const _DiaryDayHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        context.l10n.foodDiaryEmptyHint,
        textAlign: TextAlign.center,
        style: AppType.ui(12, color: context.t.ink2, height: 1.3),
      ),
    );
  }
}

/// Add block: read-only search launcher plus two quick chips. No entrance
/// opacity/transform, so it stays hit-testable.
class _FoodAddBlock extends StatelessWidget {
  const _FoodAddBlock({
    required this.onSearch,
    required this.onBarcode,
    required this.onAiScan,
  });

  final VoidCallback onSearch;
  final VoidCallback onBarcode;
  final VoidCallback onAiScan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FoodSearchBar(onTap: onSearch),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _FoodQuickChip(
                key: const ValueKey('food-action-barcode'),
                icon: Icons.qr_code_scanner_rounded,
                label: l10n.foodActionBarcode,
                filled: false,
                onTap: onBarcode,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FoodQuickChip(
                key: const ValueKey('food-action-ai'),
                icon: Icons.auto_awesome_rounded,
                label: l10n.foodActionAiScan,
                filled: true,
                onTap: onAiScan,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Read-only search launcher (NOT a real TextField) that opens the add sheet.
/// A real field here would open the keyboard instead; the actual input stays
/// `kcal-product-search-input`.
class _FoodSearchBar extends StatelessWidget {
  const _FoodSearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: it looks like a text field but is a button, so mark it as one;
    // the visible placeholder provides the label.
    return Semantics(
      button: true,
      child: Material(
        color: t.surf,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const ValueKey('food-search'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: t.line),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 18, color: t.ink2),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // Wording unchanged: search finds products AND own meals,
                    // and a redesign is not a rename (§6).
                    context.l10n.foodSearchPlaceholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(14, color: t.ink2),
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

/// Quick chip for barcode and AI scan.
///
/// Deliberately not [FilterChipPill]: the shared chip sets no `maxLines`, and
/// `food_tab_layout_test` expects exactly one text descendant with
/// `maxLines == 1`.
class _FoodQuickChip extends StatelessWidget {
  const _FoodQuickChip({
    super.key,
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fg = filled ? t.onForest : t.ink2;
    return Semantics(
      button: true,
      child: Material(
        color: filled ? t.forest : t.surf,
        borderRadius: BorderRadius.circular(rChip),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rChip),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rChip),
              border: Border.all(
                color: filled ? Colors.transparent : t.line,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: filled ? t.lime : t.ink2),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      13,
                      weight: filled ? FontWeight.w700 : FontWeight.w600,
                      color: fg,
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

/// One-time init of the `intl` date symbols. The screen rebuilds on every
/// HomeStore change, so without this guard `initializeDateFormatting()` would
/// rebuild its large CLDR table each time.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// Spelled-out date as the page subtitle, via `intl`'s `MMMMEEEEd` skeleton.
///
/// Deliberately not the relative label: `food-date-selected-label` already
/// carries that, and tests count it exactly once.
@visibleForTesting
String foodHeaderDateLabel(DateTime date, AppLocalizations l10n) {
  _ensureDateSymbols();
  return DateFormat.MMMMEEEEd(l10n.localeName).format(date);
}

class _KcalHeader extends StatelessWidget {
  const _KcalHeader({
    required this.selectedDate,
    required this.consumedKcal,
    required this.onTrendsPressed,
    this.onSettingsPressed,
    this.onProfilePressed,
    this.profileInitial,
  });

  final DateTime selectedDate;
  final int consumedKcal;

  /// Entry to the trends view. Always visible: that page does not depend on
  /// the store, it loads on its own.
  final VoidCallback onTrendsPressed;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onProfilePressed;
  final String? profileInitial;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SquareIconButton(
              key: const ValueKey('topbar-trends'),
              icon: Icons.insights_rounded,
              onTap: onTrendsPressed,
              semanticLabel: l10n.foodSemanticsTrends,
            ),
            if (onSettingsPressed != null) ...[
              const SizedBox(width: 8),
              SquareIconButton(
                key: const ValueKey('topbar-settings'),
                // Gear, not slider: this button leads to settings (account,
                // display, data), not to the goal input.
                icon: Icons.settings_outlined,
                onTap: onSettingsPressed,
                semanticLabel: l10n.foodSemanticsSettings,
              ),
            ],
            if (onProfilePressed != null) ...[
              const SizedBox(width: 8),
              _ProfileBadge(initial: profileInitial, onTap: onProfilePressed!),
            ],
          ],
        ),
        const SizedBox(height: 10),
        ScreenTitle(
          title: l10n.foodTitle,
          subtitle: foodHeaderDateLabel(selectedDate, l10n),
          trailing: _KcalTile(
            kcal: consumedKcal,
            isToday: DateUtils.isSameDay(selectedDate, DateTime.now()),
          ),
        ),
      ],
    );
  }
}

/// The forest tile on the right of the header. Number and label are two
/// separate texts, because `flows/food_scan_flow_test` counts a combined
/// "N kcal" exactly once.
class _KcalTile extends StatelessWidget {
  const _KcalTile({required this.kcal, required this.isToday});

  final int kcal;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      decoration: BoxDecoration(
        color: t.forest,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatThousands(kcal, l10n.localeName),
            style: AppType.display(
              20,
              weight: FontWeight.w700,
              color: t.onForest,
              height: 1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            // The tab shows any of the last 30 days, so a "today" label would
            // be wrong on an archived day.
            isToday ? l10n.foodKcalTodayLabel : l10n.foodKcalOnDayLabel,
            style: AppType.ui(
              9.5,
              weight: FontWeight.w500,
              color: t.lime,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact profile entry: soft brand capsule with an initial.
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.onTap, this.initial});

  final VoidCallback onTap;
  final String? initial;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final showInitial = initial != null && initial!.isNotEmpty;
    // A11y: the capsule shows only an initial/icon, so it needs a label.
    return Semantics(
      button: true,
      // Shares `todaySemanticsOpenProfile`: both tabs open the same profile,
      // an own key would duplicate the string in the ARB.
      label: context.l10n.todaySemanticsOpenProfile,
      child: Material(
        key: const ValueKey('topbar-profile'),
        color: t.forest,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            child: showInitial
                ? Text(
                    initial!,
                    style: AppType.display(
                      13,
                      weight: FontWeight.w700,
                      color: t.lime,
                    ),
                  )
                : Icon(Icons.person_rounded, color: t.lime, size: 17),
          ),
        ),
      ),
    );
  }
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
// against an arbitrary anchor instead of only `DateTime.now()`.

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

class _FoodDateStrip extends StatefulWidget {
  const _FoodDateStrip({
    required this.selectedDate,
    required this.pastDays,
    required this.onSelected,
  });

  final DateTime selectedDate;
  final int pastDays;
  final ValueChanged<DateTime> onSelected;

  @override
  State<_FoodDateStrip> createState() => _FoodDateStripState();
}

class _FoodDateStripState extends State<_FoodDateStrip> {
  static const double _chipWidth = 66;
  static const double _chipGap = 6;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Make the selection visible on build (e.g. restore on an older day).
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(covariant _FoodDateStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!DateUtils.isSameDay(oldWidget.selectedDate, widget.selectedDate)) {
      // The selected day scrolls itself into view; otherwise focus jumped
      // back to the calendar button and the selection stayed invisible.
      _scrollToSelected();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!mounted || !_scroll.hasClients) return;
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = DateUtils.dateOnly(widget.selectedDate);
    final index = daysBetween(today, selected);
    // Beyond the chips the archive chip sits at the start of the list.
    final ziel = (index < 0 || index > widget.pastDays)
        ? 0.0
        : (index * (_chipWidth + _chipGap) - 2 * _chipWidth)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    final dauer = motionDuration(context, const Duration(milliseconds: 260));
    // No `animateTo(..., Duration.zero)`: DrivenScrollActivity asserts on it
    // in debug builds. With reduced motion the strip jumps instead.
    if (dauer == Duration.zero) {
      _scroll.jumpTo(ziel);
      return;
    }
    _scroll.animateTo(ziel, duration: dauer, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = DateUtils.dateOnly(widget.selectedDate);
    // Descending (today first): with 31 scrollable chips the relevant edge
    // must lead. Chip index == day offset (chip-0 = today).
    final days = foodDateStripDays(today: today, pastDays: widget.pastDays)
        .reversed
        .toList(growable: false);
    final imStreifen = days.any((d) => DateUtils.isSameDay(d, selected));

    // No enclosing card: the chips carry their own shape. The headline names
    // the selected day and the calendar button stays fixed, so the selection
    // is always visible.
    return Column(
      key: const ValueKey('food-date-strip'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Row(
            children: [
              Icon(
                Icons.calendar_today_rounded,
                size: 12,
                color: context.t.ink2,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  foodDateSelectedLabel(today, selected, l10n),
                  key: const ValueKey('food-date-selected-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w600,
                    color: context.t.ink2,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          // Grow with the system font size (a11y up to 200 %): a fixed
          // ListView height would overflow at textScale 2.0.
          height: 52 *
              (MediaQuery.textScalerOf(context).scale(12) / 12)
                  .clamp(1.0, 2.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  // A selection beyond the 30 days appears as a full-width
                  // chip at the start, not as a wide pill next to the
                  // calendar button that stole space from the other chips.
                  itemCount: days.length + (imStreifen ? 0 : 1),
                  separatorBuilder: (_, __) => const SizedBox(width: _chipGap),
                  itemBuilder: (context, index) {
                    if (!imStreifen && index == 0) {
                      return SizedBox(
                        width: _chipWidth,
                        child: _FoodDateChip(
                          key: const ValueKey('food-date-chip-archive'),
                          date: selected,
                          // Headline: the year if it is not the current one,
                          // otherwise the weekday like any chip.
                          label: selected.year == today.year
                              ? foodDateChipLabel(today, selected, l10n)
                              : '${selected.year}',
                          selected: true,
                          onTap: () => _pickFromCalendar(context),
                        ),
                      );
                    }
                    final tagIndex = imStreifen ? index : index - 1;
                    return SizedBox(
                      width: _chipWidth,
                      child: _FoodDateChip(
                        key: ValueKey('food-date-chip-$tagIndex'),
                        date: days[tagIndex],
                        label: foodDateChipLabel(today, days[tagIndex], l10n),
                        selected:
                            DateUtils.isSameDay(days[tagIndex], selected),
                        onTap: () => widget.onSelected(days[tagIndex]),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: _chipGap),
              _CalendarDayButton(
                key: const ValueKey('food-date-calendar'),
                selected: !imStreifen,
                onTap: () => _pickFromCalendar(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Calendar access to days beyond the chips. The dialog renders in the
  /// active app language, and the selection runs through the same [onSelected]
  /// path as the chips, including on-demand loading in the store.
  Future<void> _pickFromCalendar(BuildContext context) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = DateTime(today.year - 2, today.month, today.day);
    final selectedDay = DateUtils.dateOnly(widget.selectedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDay.isBefore(firstDate) ? firstDate : selectedDay,
      firstDate: firstDate,
      lastDate: today,
      helpText: context.l10n.foodDatePickerHelpText,
    );
    if (picked != null) widget.onSelected(picked);
  }
}

class _FoodDateChip extends StatelessWidget {
  const _FoodDateChip({
    super.key,
    required this.date,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final DateTime date;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: announce the chip as a button carrying a selection state.
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rChip),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          curve: Curves.easeOut,
          // Tight vertical padding: the 1 px border costs 2 px and the strip
          // is pinned to 52 px (chip geometry 66/6 feeds _scrollToSelected).
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? t.forest : t.surf,
            borderRadius: BorderRadius.circular(rChip),
            border: Border.all(color: selected ? Colors.transparent : t.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The weekday recedes and the date leads; on the selected chip
              // it is the other way round, because context matters there.
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  10.5,
                  weight: FontWeight.w700,
                  color: selected ? t.lime : t.ink2,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${date.day}.${date.month}.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.display(
                  11.5,
                  weight: FontWeight.w700,
                  color: selected ? t.onForest : t.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Square calendar button at the end of the date chips: opens showDatePicker
/// for days beyond the strip. Same shape language as the chips; [selected]
/// fills it like an active chip.
class _CalendarDayButton extends StatelessWidget {
  const _CalendarDayButton({
    super.key,
    required this.selected,
    required this.onTap,
  });

  /// True when the selection lies beyond the chips; the button then colors
  /// like an active chip while the archive chip shows the date itself.
  final bool selected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: icon-only button, silent for screen readers without a label.
    return Semantics(
      button: true,
      selected: selected,
      label: context.l10n.foodCalendarButtonSemantics,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rChip),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          curve: Curves.easeOut,
          width: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.forest : t.surf,
            borderRadius: BorderRadius.circular(rChip),
            border: Border.all(color: selected ? Colors.transparent : t.line),
          ),
          child: Icon(
            Icons.calendar_month_rounded,
            size: 18,
            color: selected ? t.lime : t.ink2,
          ),
        ),
      ),
    );
  }
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
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: t.accent,
            ),
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
