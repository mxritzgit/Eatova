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

/// Der Tab „Food": Kopfzeile · Datums-Streifen · Such-Launcher mit
/// Barcode/KI-Scan · „Verlauf" mit den vier Slot-Karten.
///
/// **Ohne Kalorien-Karte.** Bis zum 2026-08-10 stand zwischen Scan-Chips und
/// Verlauf noch die `DailySummaryCard` (Rest-kcal, ZIEL/GEGESSEN/VERBRANNT,
/// drei Makro-Balken). Sie wiederholte, was der Tab „Heute" einen Tipp
/// entfernt bereits vollstaendig zeigt, und schob den Verlauf — die eigentliche
/// Aufgabe DIESES Tabs — auf einem 852-px-Schirm unter die Falz. Der Tab
/// beantwortet jetzt genau eine Frage: „was habe ich gegessen und was trage
/// ich nach?". Die Tagesbilanz beantwortet „Heute".
///
/// Die gegessenen kcal des angezeigten Tages bleiben trotzdem sichtbar — als
/// kleine Forest-Kachel im Kopf ([_KcalTile]), damit man beim Nachtragen nicht
/// blind ist.
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
    // 30 Tage manuell erreichbar (scrollbare Chip-Leiste, Heute zuerst);
    // alles davor laeuft ueber den Kalender. Bleibt unter dem
    // 35-Tage-Boot-Fenster von MealsSync — Chips treffen also immer
    // bereits geladene Tage.
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

  /// Nur noch durchgereicht: die drei Makro-Balken sassen in der entfernten
  /// Kalorien-Karte und stehen heute im Tab „Heute"
  /// (`today_screen.dart`, `today-macros-card`). Das Feld bleibt in der
  /// Signatur, weil `eatova_home_page.dart` es setzt — es zu streichen waere
  /// eine Aenderung an einer Datei, die diesem Paket nicht gehoert (steht als

  final UserProfile profile;
  final List<FavoriteMeal> favorites;
  final List<LoggedMeal> loggedMeals;


  /// Anfrage von aussen, das Hinzufuegen-Fenster fuer einen bestimmten Slot
  /// zu oeffnen — gesetzt vom Heute-Tab, wenn dort eine Mahlzeiten-Zeile
  /// getippt wird.
  ///
  /// Bewusst ein [ValueNotifier] und kein einfacher Parameter: die Schale
  /// cached die Tab-Widgets nach Identitaet (`_tabViews`), ein geaenderter
  /// Parameter erreichte den gebauten Tab also gar nicht. Die Identitaet des
  /// Notifiers bleibt stabil, sein Wert wandert.
  ///
  /// Der Empfaenger setzt den Wert beim Verarbeiten auf null zurueck — sonst
  /// oeffnete der naechste Besuch des Tabs ein Geister-Fenster.
  final ValueNotifier<MealSlot?>? addSlotRequest;

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
    //
    // DATA-6: ueber `mealsForFoodDate` gebucketet, nicht ueber
    // `isSameDay(loggedAt)` — siehe [_entriesBySlot].
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
      failureMessage: context.l10n.foodBarcodeNotFoundMessage(trimmed),
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

  /// Die Eintraege des angezeigten Tages, absteigend nach Zeitpunkt und mit
  /// ihrem Index in genau DIESER Liste.
  ///
  /// Die Indizes entstehen bewusst einmal fuer den ganzen Tag und nicht pro
  /// Slot-Karte: `food-history-entry-0` bleibt so der neueste Eintrag des
  /// Tages, worauf mehrere Flows bauen.
  ///
  /// Der Tages-Filter laeuft ueber `mealsForFoodDate` — denselben kanonischen
  /// DATA-6-Schluessel, aus dem auch [dailyConsumedKcal] entsteht. Ein eigenes `isSameDay(loggedAt, selectedDate)` waere genau
  /// die Logik, die DATA-6 abgeloest hat: eine Mahlzeit mit persistiertem
  /// `local_day` (23:45-Eintrag, spaeter unter anderem Zonen-/DST-Offset
  /// betrachtet) zaehlt dann in der Kopfzahl mit, faellt aber aus dem
  /// Tagebuch — der Tag zeigte kcal und darunter „Noch nichts geloggt".
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
          // Such-Launcher + Schnell-Chips. Keine Entrance-Animation, damit sie
          // in Widget-Tests stabil hit-testbar bleiben.
          _FoodAddBlock(
            onSearch: () =>
                _openAddSheet(context, _heuristicSlot(), searchMode: true),
            onBarcode: () => _scanBarcode(context),
            onAiScan: () => _scanWithCamera(context),
          ),
          // Hier stand bis 2026-08-10 die DailySummaryCard. Zwischen
          // Scan-Chips und Verlauf liegt jetzt nur noch der Abstand — die
          // Tagesbilanz traegt der Tab „Heute" (s. Klassenkommentar).
          const SizedBox(height: 14),
          if (dayLoading)
            const _DayLoadingCard()
          else
            // EAGER gebaut (Column, kein ListView): Finder laufen ueber den
            // Element-Baum — in einer lazy Liste existierten die unteren
            // Slot-Karten und ihre Eintraege schlicht nicht.
            SlidableAutoCloseBehavior(
              child: Column(
                key: const ValueKey('kcal-meals-today-card'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // „Verlauf" benennt den Block weiterhin — der Vertrag haelt
                  // das Wort fest (DESIGN_REFACTOR §6), und die Vorlage setzt
                  // ueber ihre Mahlzeiten-Liste genau so eine Abschnittszeile
                  // („Today's meals", nutrition_app(1).dart:935).
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
          // Ohne obere Schranke (Vorschau, Golden-Hosts) wuerde ein
          // Scrollview ins Unendliche wachsen — dann steht dieselbe Column
          // schlicht ungescrollt da.
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

/// Oeffnet das Hinzufuegen-Fenster, sobald von aussen ein Slot angefragt wird.
///
/// Sitzt IM Baum des Food-Tabs, weil das Sheet einen Context unterhalb des
/// Navigators braucht. Beide Ausloeser sind noetig: Der Tab wird lazy gebaut —
/// liegt die Anfrage beim Mounten schon vor (der Normalfall: erst Slot tippen,
/// dann Tab-Wechsel), kaeme ein reiner Listener zu spaet.
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
    // ERST zuruecksetzen, dann oeffnen: das Sheet laeuft asynchron, und ein
    // zweiter Notify waehrenddessen oeffnete es sonst doppelt.
    anfrage!.value = null;
    widget.onSlot(context, slot);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Wegweiser fuer einen Tag ohne einen einzigen Eintrag — einmal unter den
/// vier Slot-Karten, nicht in jeder von ihnen.
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

/// Add-Block: readonly Such-Launcher + 2 Schnell-Chips. Suche/Barcode oeffnen
/// ihre Flows (Sheet bzw. In-App-Scanner), KI-Scan die In-App-Kamera.
/// Keine Entrance-Opacity/Transform -> hit-testbar.
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

/// Readonly Such-Launcher (KEIN echtes TextField) -> oeffnet das Add-Sheet.
///
/// Die Optik stammt aus dem `SearchBarField` des Entwurfs, das Verhalten
/// bewusst nicht: ein echtes Feld hier oeffnete die Tastatur statt des
/// Sheets. Der echte Sucheingang bleibt `kcal-product-search-input`.
class _FoodSearchBar extends StatelessWidget {
  const _FoodSearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: der Launcher sieht aus wie ein Textfeld, ist aber ein Knopf —
    // fuer Screenreader explizit als solcher markiert (das sichtbare
    // Platzhalter-Label uebernimmt die Beschriftung).
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
                    // Wortgleich wie vor dem Refactor: die Suche findet
                    // Produkte UND eigene Mahlzeiten, und der Vertrag laesst
                    // ein Redesign kein Umbenennen sein (§6).
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

/// Schnell-Chip fuer Barcode und KI-Scan.
///
/// Bewusst NICHT [FilterChipPill]: der gemeinsame Chip setzt kein `maxLines`,
/// und `food_tab_layout_test` liest genau EINEN Text-Nachfahren mit
/// `maxLines == 1`. Ein Format-Parameter am gemeinsamen Baustein steht als
/// Aenderungswunsch im Bericht.
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

/// Einmalige Initialisierung der `intl`-Datumssymbole — derselbe Bool-Wächter
/// wie in `today_texts.dart` (dort nicht wiederverwendbar: die Variable ist
/// datei-privat). Der Screen haengt in einem `ListenableBuilder` am
/// `HomeStore` und baut bei JEDEM HomeStore-Wechsel neu — ohne den Wächter
/// wuerde `initializeDateFormatting()` seine (recht grosse) CLDR-Tabelle bei
/// jedem Rebuild neu aufbauen.
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// Ausgeschriebenes Datum als Untertitel des Seitentitels: „Montag, 10.
/// August" (`de`) / „Monday, August 10" (`en`).
///
/// Bewusst NICHT „Heute"/„Gestern"/„Vor N Tagen": diese relative Bezeichnung
/// traegt bereits `food-date-selected-label`, und Tests zaehlen sie einmal.
///
/// Seit der i18n-Migration (Paket 2, 2026-08-10) ueber `intl`s Skeleton
/// `MMMMEEEEd` statt lokaler Namenslisten — dieselbe Technik wie
/// `today_texts.dart:todayEyebrow`, nur ohne das `.toUpperCase()` dort. Die
/// CLDR-Daten liefern unter `de` byte-identisch zum alten Listen-Join
/// „Montag, 10. August" (verifiziert fuer einstellige Tage: `d` im Skeleton
/// polstert nicht auf „05").
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

  /// Einstieg in die Trend-Ansicht (Kalorien-/Makro-Verlauf). Immer sichtbar:
  /// die Trend-Seite haengt nicht am Store, sondern laedt selbst.
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
                // Zahnrad, nicht Schieberegler: seit der Aufteilung fuehrt
                // dieser Knopf in die EINSTELLUNGEN (Konto, Anzeige, Daten)
                // und nicht mehr in die Ziel-Eingabe.
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

/// Die Forest-Kachel rechts im Kopf.
///
/// Zahl und Beschriftung sind zwei getrennte Texte — mit einem einzigen
/// „N kcal" traeger die Baum den Text ein zweites Mal, und
/// `flows/food_scan_flow_test` zaehlt ihn genau einmal.
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
            // Der Tab zeigt jeden der letzten 30 Tage — „HEUTE" waere an
            // einem Archivtag schlicht falsch.
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

/// Kompakter Profil-Einstieg: weiche Marken-Kapsel mit Initial.
class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.onTap, this.initial});

  final VoidCallback onTap;
  final String? initial;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final showInitial = initial != null && initial!.isNotEmpty;
    // A11y: die Kapsel zeigt nur ein Initial/Icon — ohne Label wuesste ein
    // Screenreader-Nutzer nicht, dass hier das Profil haengt.
    return Semantics(
      button: true,
      // Wortgleich zu `todaySemanticsOpenProfile` (today_screen.dart) — beide
      // Tabs oeffnen dasselbe Profil, ein eigener Key waere dieselbe Aussage
      // zweimal in der ARB.
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
///
/// Seit der i18n-Migration (Paket 2, 2026-08-10) ueber `intl`s Skeleton `EE`
/// statt einer lokalen Zwei-Buchstaben-Liste. Die deutschen CLDR-Kuerzel
/// tragen einen Punkt („Mo.", „Di."), den die alte Liste nicht hatte —
/// abgeschnitten, damit `de` byte-identisch bleibt.
@visibleForTesting
String foodDateChipLabel(DateTime today, DateTime date, AppLocalizations l10n) {
  final offset = daysBetween(today, date);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  _ensureDateSymbols();
  return DateFormat('EE', l10n.localeName).format(date).replaceAll('.', '');
}

/// Die Zeile ueber den Chips, die den gewaehlten Tag benennt.
///
/// Zeichengleich zu `today_texts.dart:todayDateLabel` — beide lesen jetzt
/// dieselben ARB-Keys (`todayDateToday`/`todayDateYesterday`/
/// `todayDateDaysAgo`), damit die beiden Kopien nicht mehr auseinanderlaufen
/// koennen (Paket-1-Bericht, Drift-Risiko).
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
    // Auswahl beim Aufbau sichtbar machen (z. B. Restore auf einem Alt-Tag).
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(covariant _FoodDateStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!DateUtils.isSameDay(oldWidget.selectedDate, widget.selectedDate)) {
      // Der gewaehlte Tag (auch aus dem Kalender) scrollt sich selbst ins
      // Bild — vorher sprang der Fokus nur zurueck auf den Kalender-Knopf
      // und die Auswahl blieb unsichtbar.
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
    // Jenseits der Chips sitzt der Archiv-Chip am Listenanfang.
    final ziel = (index < 0 || index > widget.pastDays)
        ? 0.0
        : (index * (_chipWidth + _chipGap) - 2 * _chipWidth)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    final dauer = motionDuration(context, const Duration(milliseconds: 260));
    // Kein `animateTo(..., Duration.zero)`: DrivenScrollActivity haelt darauf
    // ein `assert(duration > Duration.zero)` und wuerde im Debug-Build werfen.
    // Unter reduzierter Bewegung springt die Leiste stattdessen.
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
    // Absteigend (Heute zuerst, wie der Tages-Picker im Edit-Sheet): bei 31
    // scrollbaren Chips muss der relevante Rand — heute — vorn stehen.
    // Chip-Index == Tages-Offset (chip-0 = Heute, chip-1 = Gestern, ...).
    final days = foodDateStripDays(today: today, pastDays: widget.pastDays)
        .reversed
        .toList(growable: false);
    final imStreifen = days.any((d) => DateUtils.isSameDay(d, selected));

    // Keine umschliessende Karte: die Chips tragen ihre Form selbst. Die
    // Kopfzeile benennt den gewaehlten Tag, der Kalender-Knopf rechts bleibt
    // fix stehen und wird bei einer Auswahl jenseits der Chips zur
    // Datums-Pill — die Auswahl ist damit IMMER sichtbar.
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
          // Mit der System-Schriftgroesse wachsen (A11y bis 200 %): die
          // fruehere IntrinsicHeight-Row skalierte automatisch, eine fixe
          // ListView-Hoehe wuerde bei textScale 2.0 ueberlaufen.
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
                  // Auswahl jenseits der 30 Tage: als VOLLWERTIGER Chip in
                  // Normalbreite am Listenanfang — nicht als breite Pill am
                  // Kalender-Knopf, die den uebrigen Chips den Platz nahm.
                  itemCount: days.length + (imStreifen ? 0 : 1),
                  separatorBuilder: (_, __) => const SizedBox(width: _chipGap),
                  itemBuilder: (context, index) {
                    if (!imStreifen && index == 0) {
                      return SizedBox(
                        width: _chipWidth,
                        child: _FoodDateChip(
                          key: const ValueKey('food-date-chip-archive'),
                          date: selected,
                          // Kopfzeile: Jahreszahl, wenn nicht aktuelles Jahr
                          // — sonst der Wochentag wie bei jedem Chip.
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

  /// Kalender-Zugriff auf aeltere Tage (jenseits der Chips). Der Dialog
  /// rendert in der aktiven App-Sprache — `eatova_app.dart` reicht
  /// `Localizations.override`/`supportedLocales` bis hierher durch (seit dem
  /// i18n-Grundgerüst; vorher fest auf `de`).
  /// Die Auswahl laeuft ueber denselben [onSelected]-Pfad wie die Chips
  /// (setFoodDate-Kette, inkl. On-Demand-Nachladen im Store).
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
    // A11y-Muster wie der Zeitraum-Umschalter der Trend-Ansicht: Chip als
    // Button mit Auswahl-Zustand ansagen.
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rChip),
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 160)),
          curve: Curves.easeOut,
          // Vertikal knapper als frueher (9): der 1-px-Rand der neuen Sprache
          // nimmt 2 px, und die Leiste ist auf 52 px festgenagelt (die Chip-
          // Geometrie 66/6 haengt an _scrollToSelected).
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
              // Wochentag tritt zurueck, das Datum traegt die Zeile — beim
              // gewaehlten Chip kehrt sich das um, weil dort der Kontext zaehlt.
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

  /// True, wenn die Auswahl jenseits der Chips liegt — der Knopf faerbt sich
  /// dann wie ein aktiver Chip; das Datum selbst zeigt der Archiv-Chip am
  /// Listenanfang (fixe Breite, nimmt den anderen Chips keinen Platz).
  final bool selected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: reiner Icon-Knopf — ohne Label bliebe er fuer Screenreader stumm.
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

/// Lade-Zustand des Tagebuchs, waehrend ein Alt-Tag on-demand nachgeladen
/// wird — GENAU EIN Spinner statt eines faelschlich leeren Tages. Er ersetzt
/// den kompletten Tagebuch-Block, nicht einzelne Karten.
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
            // Wortgleich zu `todayDayLoading` — beide Tabs zeigen denselben
            // Zwischenzustand.
            context.l10n.todayDayLoading,
            style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
