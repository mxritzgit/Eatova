import 'package:flutter/material.dart';

import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';
import '../models/macro_progress.dart';
import '../models/meal_analysis_result.dart';
import '../models/user_profile.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/fallback_product_service.dart';
import '../services/meilisearch_product_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../config/search_config.dart';
import '../theme/app_colors.dart';
import '../widgets/kcal/add_meal_sheet.dart';
import '../widgets/kcal/calories_overview_card.dart';
import '../widgets/kcal/meal_analysis_sheet.dart';
import 'barcode_scanner_sheet.dart';

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
    String Function(MealAnalysisResult, MealSlot)? onAddMeal,
    void Function(String id, MealAnalysisResult scaled)? onUpdateMeal,
    this.isFavorite,
    this.onToggleFavorite,
    ValueChanged<String>? onRemoveFavorite,
    ValueChanged<String>? onRemoveMeal,
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

  // Default-onAddMeal liefert eine leere id zurueck (Preview/Test ohne echte
  // Persistenz). Eine spaetere Um-Portionierung trifft dann den No-op-Update.
  static String _noopAdd(MealAnalysisResult _, MealSlot __) => '';
  static void _noopDate(DateTime _) {}
  static void _noopUpdate(String _, MealAnalysisResult __) {}
  static void _noopString(String _) {}

  // Fast EU mirror (Meilisearch via Cloud Run proxy) with live OFF as fallback.
  // Ist der Mirror per Kill-Switch deaktiviert (leere OFF_PROXY_URL, z.B. nach
  // GCP-Trial-Ablauf 2026-08-29), wird OFF direkt genutzt — kein Mirror-Timeout.
  static ProductLookupService _defaultProductService() {
    const off = OpenFoodFactsProductService();
    if (!SearchConfig.mirrorEnabled) return off;
    return FallbackProductService(MeilisearchProductService(), off);
  }

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
  final String Function(MealAnalysisResult, MealSlot) onAddMeal;
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;

  /// Ist die Mahlzeit als Favorit angeheftet? Null -> kein Herz.
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favoriten-Toggle. Null -> kein Herz.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final ValueChanged<String> onRemoveFavorite;
  final ValueChanged<String> onRemoveMeal;

  void _openAddSheet(BuildContext context, MealSlot slot,
      {bool searchMode = false}) {
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
    final capture =
        await cameraLauncher.launch(context, initialSlot: _heuristicSlot());
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

        final historyCard = MealsTodayCard(
          meals: loggedMeals,
          onMealTap: (slot) => _openAddSheet(context, slot),
          onRemoveMeal: onRemoveMeal,
        );

        final children = <Widget>[
          const _KcalHeader(),
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
          if (boundedHeight)
            Expanded(flex: 40, child: calsCard)
          else
            calsCard,
          const SizedBox(height: 12),
          // Add-Block: FESTE Hoehe, NICHT Expanded -> sitzt klar oben,
          // damit Such-Launcher + Action-Buttons ohne Scroll hit-testbar sind.
          _FoodAddBlock(
            onSearch: () => _openAddSheet(context, _heuristicSlot(),
                searchMode: true),
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
    return InkWell(
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rControl),
      child: Container(
        // Icon + einzeiliges Label nebeneinander statt uebereinander: liest
        // sich als eine Beschriftung, braucht knapp die halbe Hoehe des alten
        // zweizeiligen Blocks und bleibt bei 1.3x-Systemschrift stabil.
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
    );
  }
}

class _KcalHeader extends StatelessWidget {
  const _KcalHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(2, 0, 0, 0),
      child: Text(
        'Ernährung',
        style: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
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
    final days = List<DateTime>.generate(
      pastDays + 1,
      (index) => today.subtract(Duration(days: pastDays - index)),
    );

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
              const Icon(Icons.calendar_today_rounded,
                  size: 12, color: textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _selectedLabel(today, selected),
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
        Row(
          children: [
            for (var index = 0; index < days.length; index++) ...[
              Expanded(
                child: _FoodDateChip(
                  key: ValueKey('food-date-chip-$index'),
                  date: days[index],
                  label: _chipLabel(index, today, days[index]),
                  selected: DateUtils.isSameDay(days[index], selected),
                  onTap: () => onSelected(days[index]),
                ),
              ),
              if (index != days.length - 1) const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }

  // Chip-Kopfzeile. Fuer aeltere Tage der Wochentag statt nochmal des Datums —
  // darunter steht bereits „23.7.", zweimal dasselbe sah nach Fehler aus.
  static const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  static String _chipLabel(int index, DateTime today, DateTime date) {
    final offset = today.difference(date).inDays;
    if (offset == 0) return 'Heute';
    if (offset == 1) return 'Gestern';
    return _weekdays[date.weekday - 1];
  }

  static String _selectedLabel(DateTime today, DateTime selected) {
    final offset = today.difference(selected).inDays;
    if (offset == 0) return 'Heute';
    if (offset == 1) return 'Gestern';
    return 'Vor $offset Tagen';
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
    return InkWell(
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
    );
  }
}
