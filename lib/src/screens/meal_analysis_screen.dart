import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/user_profile.dart';
import '../config/search_config.dart';
import '../services/day_math.dart';
import '../services/fallback_product_service.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/meilisearch_product_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../services/trend_service.dart';
import '../theme/app_colors.dart';
import '../widgets/kcal/add_meal_sheet.dart';
import '../widgets/kcal/calories_overview_card.dart';
import '../widgets/kcal/meal_analysis_sheet.dart';
import 'barcode_scanner_sheet.dart';
import 'trends_screen.dart';

class MealAnalysisScreen extends StatelessWidget {
  MealAnalysisScreen({
    super.key,
    MealAnalyzer? analyzer,
    ProductLookupService? productService,
    MealPhotoInput? photoInput,
    MealCameraLauncher? cameraLauncher,
    required this.dailyConsumedKcal,
    this.macroProgress = MacroProgress.empty,
    this.profile = const UserProfile(),
    this.favorites = const <FavoriteMeal>[],
    this.loggedMeals = const <LoggedMeal>[],
    this.burnedKcal = 0,
    DateTime? selectedDate,
    ValueChanged<DateTime>? onDateSelected,
    this.visiblePastDays = 4,
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

  // Eigener Suchindex (Meilisearch auf dem vServer) mit Live-OFF als
  // Fallback fuer neue Produkte, Barcode-Lookups und Mirror-Ausfaelle.
  //
  // Laeuft bei JEDEM Rebuild (der Screen haengt in einem ListenableBuilder am
  // HomeStore), deshalb strikt synchron und allokationsfrei: kein `await`,
  // kein SharedPreferences-Zugriff, kein `Supabase.instance`. Ob der Mirror
  // ueberhaupt Credentials hat, entscheidet erst der Such-Request selbst
  // (SearchCredentialsStore) — hier steht nur der HARTE, lokale Kill-Switch
  // `--dart-define=OFF_MIRROR_URL=` (leer), den kein Server ueberstimmen darf.
  static ProductLookupService _defaultProductService() {
    const off = OpenFoodFactsProductService();
    if (SearchConfig.mirrorHardDisabled) return off;
    return const FallbackProductService(MeilisearchProductService(), off);
  }

  // Default-onAddMeal liefert eine leere id zurueck (Preview/Test ohne echte
  // Persistenz). Eine spaetere Um-Portionierung trifft dann den No-op-Update.
  static String _noopAdd(MealAnalysisResult _, MealSlot __) => '';
  static void _noopDate(DateTime _) {}
  static void _noopUpdate(String _, MealAnalysisResult __) {}
  static void _noopString(String _) {}

  final MealAnalyzer analyzer;
  final ProductLookupService productService;
  final MealPhotoInput photoInput;
  final MealCameraLauncher cameraLauncher;
  final int dailyConsumedKcal;
  final MacroProgress macroProgress;
  final UserProfile profile;
  final List<FavoriteMeal> favorites;
  final List<LoggedMeal> loggedMeals;
  final int burnedKcal;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;
  final int visiblePastDays;

  /// True, waehrend ein per Kalender gewaehlter Alt-Tag (ausserhalb des
  /// 35-Tage-Fensters) nachgeladen wird — der Verlauf zeigt dann einen
  /// Spinner statt eines faelschlich leeren Tages.
  final bool dayLoading;
  final String Function(MealAnalysisResult, MealSlot) onAddMeal;
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;

  /// Ist die Mahlzeit als Favorit angeheftet? Null -> kein Herz.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favoriten-Toggle. Null -> kein Herz.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final ValueChanged<String> onRemoveFavorite;
  final ValueChanged<String> onRemoveMeal;

  /// Einstieg zu Settings-Sheet + Profil-Screen. Lebte frueher in der TopBar
  /// der entfernten Heute-/Training-/Trends-Tabs; seit deren Entfernen ist der
  /// Food-Header der einzige Zugang. Null (Preview/Test) -> Icons verborgen.
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onProfilePressed;
  final String? profileInitial;

  /// Daten-Lader fuer die Trend-Ansicht (Test-Injektion). Null -> beim
  /// Oeffnen wird lazily ein TrendService auf Supabase.instance gebaut;
  /// der Konstruktor selbst fasst Supabase nie an (Preview/Tests sicher).
  final TrendTotalsLoader? trendTotalsLoader;

  void _openAddSheet(
    BuildContext context,
    MealSlot slot, {
    bool searchMode = false,
  }) {
    // Alle Eintraege des angezeigten Tages - das Sheet filtert die Anzeige
    // selbst nach dem im Selector gewaehlten Slot (bleibt so synchron, wenn
    // der User den Slot im Sheet wechselt). `slot` ist nur der Default-Slot.
    final existingForDay = loggedMeals
        .where((m) => DateUtils.isSameDay(m.loggedAt, selectedDate))
        .toList(growable: false);
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

  // Slot-Heuristik fuer die Sheet-Oeffner (Suche + Action-Buttons). Deckt sich
  // mit LoggedMeal.slot, damit ein neuer Eintrag im richtigen Slot landet.
  MealSlot _heuristicSlot() {
    final h = DateTime.now().hour;
    if (h < 11) return MealSlot.breakfast;
    if (h < 15) return MealSlot.lunch;
    if (h < 21) return MealSlot.dinner;
    return MealSlot.snack;
  }

  // KI-Scan: In-App-Kamera mit Slot-Auswahl -> Foto -> KI-Analyse -> das
  // Ergebnis-Sheet im gewaehlten Slot. Kein generisches Add-Sheet mehr.
  Future<void> _scanWithCamera(BuildContext context) async {
    final capture = await cameraLauncher.launch(
      context,
      initialSlot: _heuristicSlot(),
    );
    if (capture == null || !context.mounted) return;
    await showMealAnalysisSheet(
      context,
      slot: capture.slot,
      resultFuture: analyzer.analyze(capture.request),
      previewImage: capture.previewBytes,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      failureMessage:
          'Analyse fehlgeschlagen. Prüfe Internet, Supabase und OpenRouter.',
    );
  }

  // Barcode: In-App-Scanner als Bottom-Panel (wie der KI-Scan) -> OFF-Lookup
  // -> Ergebnis-Sheet. Direkt, nicht mehr ueber das generische Add-Sheet.
  Future<void> _scanBarcode(BuildContext context) async {
    final code = await showBarcodeScannerSheet(context);
    final trimmed = code?.trim();
    if (trimmed == null || trimmed.isEmpty || !context.mounted) return;
    await showMealAnalysisSheet(
      context,
      slot: _heuristicSlot(),
      resultFuture: productService.lookupBarcode(trimmed),
      previewImage: null,
      onAdd: onAddMeal,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      failureMessage:
          'Barcode $trimmed nicht gefunden oder OpenFoodFacts nicht erreichbar.',
    );
  }

  // Trend-Ansicht als volle Seite. Das Kalorienziel wird aus dem bereits
  // durchgereichten Profil weitergegeben (KEIN Store-Zugriff); der Daten-
  // Lader kommt injiziert oder lazily aus Supabase.instance — erst beim
  // Oeffnen, damit Konstruktion/Preview ohne initialisiertes Supabase laeuft.
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
    // Wirft bei fehlender Initialisierung/Session synchron — TrendsScreen
    // faengt das in seinen Fehler-/Retry-Zustand, kein Crash.
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Kein angemeldeter Nutzer für die Trend-Ansicht.');
    }
    return TrendService(client, userId).loadDailyTotals();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedHeight = constraints.hasBoundedHeight;

        final calsCard = CaloriesOverviewCard(
          dailyConsumedKcal: dailyConsumedKcal,
          kcalGoal: profile.dailyKcalGoal,
          burnedKcal: burnedKcal,
          macroProgress: macroProgress,
          profile: profile,
        );

        final historyCard = dayLoading
            ? const _DayLoadingCard()
            : MealsTodayCard(
                meals: loggedMeals,
                onMealTap: (slot) => _openAddSheet(context, slot),
                onRemoveMeal: onRemoveMeal,
              );

        final children = <Widget>[
          _KcalHeader(
            onTrendsPressed: () => _openTrends(context),
            onSettingsPressed: onSettingsPressed,
            onProfilePressed: onProfilePressed,
            profileInitial: profileInitial,
          ),
          SizedBox(height: boundedHeight ? 10 : 8),
          _FoodDateStrip(
            selectedDate: selectedDate,
            pastDays: visiblePastDays,
            onSelected: onDateSelected,
          ),
          SizedBox(height: boundedHeight ? 12 : 14),
          // Glass-Kalorienkarte mit inline-Makros (hoehen-begrenzt im Tab).
          // Weniger Flex als der Verlauf: die Karte hat eine feste Menge an
          // Inhalt, die Liste darunter profitiert von jeder zusaetzlichen Zeile.
          if (boundedHeight) Expanded(flex: 40, child: calsCard) else calsCard,
          const SizedBox(height: 12),
          // Add-Block: FESTE Hoehe, NICHT Expanded -> sitzt klar oben,
          // damit Such-Launcher + Action-Buttons ohne Scroll hit-testbar sind.
          _FoodAddBlock(
            onSearch: () =>
                _openAddSheet(context, _heuristicSlot(), searchMode: true),
            onBarcode: () => _scanBarcode(context),
            onAiScan: () => _scanWithCamera(context),
          ),
          const SizedBox(height: 12),
          // Verlauf: einzige unten wachsende Sektion.
          if (boundedHeight)
            Expanded(flex: 46, child: historyCard)
          else
            historyCard,
        ];

        return SizedBox(
          key: const ValueKey('kcal-page-fill'),
          height: boundedHeight ? constraints.maxHeight : null,
          child: Column(
            key: const ValueKey('screen-kcal-tracker'),
            mainAxisSize: boundedHeight ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );
      },
    );
  }
}

/// Add-Block (feste Hoehe): readonly Such-Launcher + 2 Action-Buttons.
/// Suche/Barcode oeffnen ihre Flows (Sheet bzw. In-App-Scanner), KI-Scan die
/// In-App-Kamera. Keine Entrance-Opacity/Transform -> hit-testbar.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FoodSearchBar(onTap: onSearch),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _FoodActionButton(
                key: const ValueKey('food-action-barcode'),
                icon: Icons.qr_code_scanner_rounded,
                label: 'Barcode',
                filled: false,
                onTap: onBarcode,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FoodActionButton(
                key: const ValueKey('food-action-ai'),
                icon: Icons.auto_awesome_rounded,
                label: 'KI-Scan',
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

/// Readonly Such-Launcher (KEIN echtes TextField) -> oeffnet das Add-Sheet.
class _FoodSearchBar extends StatelessWidget {
  const _FoodSearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A11y: der Launcher sieht aus wie ein Textfeld, ist aber ein Knopf —
    // fuer Screenreader explizit als solcher markiert (das sichtbare
    // Platzhalter-Label uebernimmt die Beschriftung).
    return Semantics(
      button: true,
      child: InkWell(
        key: const ValueKey('food-search'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // Randlos: der Fill traegt die Form. Im Tab sind Suche, Chips und
          // Aktionen dieselbe Klasse „tippbare Flaeche" und teilen ihn sich.
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: const Row(
            children: [
              Icon(Icons.search_rounded, size: 18, color: textMuted),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Lebensmittel oder Mahlzeiten suchen…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kompakter Action-Button: Outline (filled:false) oder gefuelltes forgeLime
/// (filled:true). Keine Entrance-Animation -> stabil hit-testbar.
class _FoodActionButton extends StatelessWidget {
  const _FoodActionButton({
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
    final Color fg = filled ? bg : textPrimary;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Container(
          // Icon + einzeiliges Label nebeneinander statt uebereinander: liest
          // sich als eine Beschriftung, braucht knapp die halbe Hoehe des alten
          // zweizeiligen Blocks und bleibt bei grosser Systemschrift stabil.
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: filled ? forgeLime : surface,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KcalHeader extends StatelessWidget {
  const _KcalHeader({
    required this.onTrendsPressed,
    this.onSettingsPressed,
    this.onProfilePressed,
    this.profileInitial,
  });

  /// Einstieg in die Trend-Ansicht (Kalorien-/Makro-Verlauf). Immer sichtbar:
  /// die Trend-Seite haengt nicht am Store, sondern laedt selbst.
  final VoidCallback onTrendsPressed;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onProfilePressed;
  final String? profileInitial;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Ernährung',
              style: TextStyle(
                color: textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('topbar-trends'),
            onPressed: onTrendsPressed,
            tooltip: 'Trends',
            icon: const Icon(
              Icons.insights_rounded,
              size: 20,
              color: textMuted,
            ),
            visualDensity: VisualDensity.compact,
          ),
          if (onSettingsPressed != null)
            IconButton(
              key: const ValueKey('topbar-settings'),
              onPressed: onSettingsPressed,
              tooltip: 'Einstellungen',
              icon: const Icon(Icons.tune_rounded, size: 20, color: textMuted),
              visualDensity: VisualDensity.compact,
            ),
          if (onProfilePressed != null) ...[
            const SizedBox(width: 4),
            _ProfileBadge(initial: profileInitial, onTap: onProfilePressed!),
          ],
        ],
      ),
    );
  }
}

/// Kompakter Profil-Einstieg: weiche Lime-Kapsel mit Initial (rahmenlos,
/// wie die uebrigen tippbaren Flaechen des Tabs).
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.onTap, this.initial});

  final VoidCallback onTap;
  final String? initial;

  @override
  Widget build(BuildContext context) {
    final showInitial = initial != null && initial!.isNotEmpty;
    // A11y: die Kapsel zeigt nur ein Initial/Icon — ohne Label wuesste ein
    // Screenreader-Nutzer nicht, dass hier das Profil haengt.
    return Semantics(
      button: true,
      label: 'Profil öffnen',
      child: Material(
        key: const ValueKey('topbar-profile'),
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rControl),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: lime.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(rControl),
            ),
            alignment: Alignment.center,
            child: showInitial
                ? Text(
                    initial!,
                    style: const TextStyle(
                      color: lime,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  )
                : const Icon(Icons.person_rounded, color: lime, size: 17),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// B5: Kalenderarithmetik der Datumsleiste
// ---------------------------------------------------------------------------
//
// `Duration` ist Absolutzeit, kein Kalender. Am Montag 30.03.2026 in
// Europe/Berlin (Fruehjahrsumstellung am Sonntag 29.03., ein 23-Stunden-Tag)
// lieferte `today.subtract(Duration(days: 1))` den `2026-03-28 23:00`. Die
// Leiste rendete dann
//
//   Mi 25.3. | Do 26.3. | Fr 27.3. | Gestern 28.3. | Heute 30.3.
//
// Sonntag der 29.3. war nicht erreichbar, und der Chip „Gestern" trug den
// 28.3.: ein Tap darauf waehlte den falschen Tag, und jede von dort geloggte
// Mahlzeit bekam `local_day = 2026-03-28`. Spiegelbildlich verrechnete sich
// `.difference(...).inDays` auf zwei lokalen Mitternachten (23 h -> 0 Tage).
//
// Beides rechnet jetzt `day_math.dart`. Als freie Funktionen herausgezogen,
// weil sie sonst nur ueber `DateTime.now()` erreichbar waeren — an einem
// beliebigen Anker (etwa dem 30.03.2026) liessen sie sich dann gar nicht
// pruefen.

const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

/// Die Tage der Leiste: [pastDays] zurueckliegende plus [today], aufsteigend.
@visibleForTesting
List<DateTime> foodDateStripDays({
  required DateTime today,
  required int pastDays,
}) {
  return dayStrip(today: today, pastDays: pastDays);
}

/// Kopfzeile eines Chips. Fuer aeltere Tage der Wochentag statt nochmal des
/// Datums — darunter steht bereits „23.7.", zweimal dasselbe sah nach Fehler
/// aus.
@visibleForTesting
String foodDateChipLabel(DateTime today, DateTime date) {
  final offset = daysBetween(today, date);
  if (offset == 0) return 'Heute';
  if (offset == 1) return 'Gestern';
  return _weekdays[date.weekday - 1];
}

/// Die Zeile ueber den Chips, die den gewaehlten Tag benennt.
@visibleForTesting
String foodDateSelectedLabel(DateTime today, DateTime selected) {
  final offset = daysBetween(today, selected);
  if (offset == 0) return 'Heute';
  if (offset == 1) return 'Gestern';
  return 'Vor $offset Tagen';
}

class _FoodDateStrip extends StatelessWidget {
  const _FoodDateStrip({
    required this.selectedDate,
    required this.pastDays,
    required this.onSelected,
  });

  final DateTime selectedDate;
  final int pastDays;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final selected = DateUtils.dateOnly(selectedDate);
    final days = foodDateStripDays(today: today, pastDays: pastDays);

    // Keine umschliessende Karte mehr: die Chips tragen ihre Form selbst, ein
    // Rahmen um den Rahmen ist genau die Verschachtelung, die den Tab schwer
    // wirken liess. Uebrig bleibt eine leise Kopfzeile mit dem gewaehlten Tag.
    return Column(
      key: const ValueKey('food-date-strip'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Row(
            children: [
              const Icon(
                Icons.calendar_today_rounded,
                size: 12,
                color: textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  foodDateSelectedLabel(today, selected),
                  key: const ValueKey('food-date-selected-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
        // IntrinsicHeight + stretch: der Kalender-Knopf uebernimmt exakt die
        // Chip-Hoehe, ohne sie zu hartkodieren.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < days.length; index++) ...[
                Expanded(
                  child: _FoodDateChip(
                    key: ValueKey('food-date-chip-$index'),
                    date: days[index],
                    label: foodDateChipLabel(today, days[index]),
                    selected: DateUtils.isSameDay(days[index], selected),
                    onTap: () => onSelected(days[index]),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              _CalendarDayButton(
                key: const ValueKey('food-date-calendar'),
                // Liegt die Auswahl ausserhalb der Chips (aelterer Tag aus dem
                // Kalender), traegt der Knopf den Selected-Zustand — die
                // Auswahl bleibt damit immer sichtbar.
                selected: !days.any((d) => DateUtils.isSameDay(d, selected)),
                onTap: () => _pickFromCalendar(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Kalender-Zugriff auf aeltere Tage (jenseits der Chips). Der Dialog
  /// rendert dank der de-Lokalisierung in eatova_app.dart deutsch; die
  /// Auswahl laeuft ueber denselben [onSelected]-Pfad wie die Chips
  /// (setFoodDate-Kette, inkl. On-Demand-Nachladen im Store).
  Future<void> _pickFromCalendar(BuildContext context) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = DateTime(today.year - 2, today.month, today.day);
    final selectedDay = DateUtils.dateOnly(selectedDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDay.isBefore(firstDate) ? firstDate : selectedDay,
      firstDate: firstDate,
      lastDate: today,
      helpText: 'Tag wählen',
    );
    if (picked != null) onSelected(picked);
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
    // A11y-Muster wie der Zeitraum-Umschalter der Trend-Ansicht: Chip als
    // Button mit Auswahl-Zustand ansagen.
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? forgeLime : surface,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Wochentag tritt zurueck, das Datum traegt die Zeile — beim
              // gewaehlten Chip kehrt sich das um, weil dort der Kontext zaehlt.
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? bg : textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${date.day}.${date.month}.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? bg.withValues(alpha: 0.68) : textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quadratischer Kalender-Knopf am Ende der Datums-Chips: oeffnet den
/// (deutschen) showDatePicker fuer Tage jenseits der Chip-Leiste. Gleiche
/// Formensprache wie die Chips — weiche Flaeche, kein Hairline-Rahmen;
/// [selected] (Auswahl liegt ausserhalb der Chips) fuellt ihn wie einen
/// aktiven Chip.
class _CalendarDayButton extends StatelessWidget {
  const _CalendarDayButton({
    super.key,
    required this.selected,
    required this.onTap,
  });

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // A11y: reiner Icon-Knopf — ohne Label bliebe er fuer Screenreader stumm.
    return Semantics(
      button: true,
      selected: selected,
      label: 'Anderen Tag im Kalender wählen',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? forgeLime : surface,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: Icon(
            Icons.calendar_month_rounded,
            size: 18,
            color: selected ? bg : textMuted,
          ),
        ),
      ),
    );
  }
}

/// Lade-Zustand des Verlaufs, waehrend ein Alt-Tag on-demand nachgeladen
/// wird — Spinner statt eines faelschlich leeren Tages.
class _DayLoadingCard extends StatelessWidget {
  const _DayLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('food-day-loading'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          SizedBox(height: 10),
          Text(
            'Tag wird geladen…',
            style: TextStyle(
              color: textMuted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
