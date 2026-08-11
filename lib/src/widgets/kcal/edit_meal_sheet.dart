import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/day_math.dart';
import '../../services/local_day.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/motion.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';
import 'slot_selector.dart';

/// Store-Callback fuer das Bearbeiten-Sheet: aendert Portion/Bestandteile,
/// Slot und/oder Tag einer geloggten Mahlzeit (null = unveraendert) und
/// liefert den neuen Stand zurueck (null, wenn die id nicht mehr existiert).
typedef UpdateMealDetails =
    LoggedMeal? Function(
      String id, {
      MealAnalysisResult? result,
      MealSlot? slot,
      DateTime? day,
    });

/// Stellt die Edit-Callbacks des HomeStore unterhalb des Food-Tabs bereit.
///
/// Hintergrund: die Slot-Karten des Tagebuchs (`DiaryMealCard`) und das
/// AddMealSheet leben unterhalb von `MealAnalysisScreen`, dessen Signatur
/// hier bewusst nicht angefasst wird — der Scope reicht die Callbacks an den
/// Screen VORBEI direkt zu den Widgets, die das Bearbeiten-Sheet oeffnen.
/// Fehlt der Scope (Preview/Standalone-Tests), fallen die Widgets auf ihr
/// bisheriges Verhalten zurueck.
class MealEditScope extends InheritedWidget {
  const MealEditScope({
    super.key,
    required this.onUpdateMeal,
    required this.onRemoveMeal,
    required super.child,
  });

  final UpdateMealDetails onUpdateMeal;
  final ValueChanged<String> onRemoveMeal;

  /// Bewusst OHNE Dependency-Registrierung (getInherited…): die Callbacks
  /// sind stabile Store-Tear-offs, und der Lookup passiert auch ausserhalb
  /// von build (Sheet-Oeffner).
  static MealEditScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MealEditScope>();

  @override
  bool updateShouldNotify(MealEditScope oldWidget) =>
      onUpdateMeal != oldWidget.onUpdateMeal ||
      onRemoveMeal != oldWidget.onRemoveMeal;
}

/// Ergebnis des Bearbeiten-Sheets fuer Aufrufer mit lokaler Listen-Kopie
/// (AddMealSheet): gespeicherter neuer Stand oder Loeschung. null (Future-
/// Ergebnis) heisst: geschlossen ohne Aenderung.
class MealEditOutcome {
  const MealEditOutcome.saved(LoggedMeal this.meal) : deleted = false;
  const MealEditOutcome.deleted() : meal = null, deleted = true;

  final LoggedMeal? meal;
  final bool deleted;
}

/// Oeffnet das Bearbeiten-Sheet fuer eine geloggte Mahlzeit. [onRemoveMeal]
/// null -> kein Loeschen-Button (z.B. wenn der Aufrufer keinen Remove-Pfad
/// verdrahtet hat).
Future<MealEditOutcome?> showEditMealSheet(
  BuildContext context, {
  required LoggedMeal meal,
  required UpdateMealDetails onUpdateMeal,
  ValueChanged<String>? onRemoveMeal,
}) {
  return showModalBottomSheet<MealEditOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Bewusst kein Token: der Scrim hinter einem Sheet dunkelt in beiden
    // Anzeige-Modi ab — ein heller Scrim wuerde nichts daempfen.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) {
      return EditMealSheet(
        meal: meal,
        onUpdateMeal: onUpdateMeal,
        onRemoveMeal: onRemoveMeal,
      );
    },
  );
}

/// D5: „Aenderungen verwerfen?" — die gemeinsame Bestaetigung fuer JEDEN
/// Weg, ein ausgefuelltes Sheet zu schliessen.
///
/// `barrierDismissible: true` ist Absicht: ein Tap neben den Dialog ist
/// „Abbrechen", also die harmlose Antwort. Der Dialog liegt dabei auf dem
/// Root-Navigator und damit UEBER der Sheet-Route — sein eigener Barrier
/// schluckt den Tap, das Sheet darunter bekommt ihn nie zu sehen. Der Dialog
/// kann sich also nicht selbst mitsamt dem Sheet wegklicken.
///
/// Rueckgabe: `true` = verwerfen, `false`/abgebrochen = offen lassen.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final t = context.t;
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.foodDiscardChangesTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(
        l10n.foodDiscardChangesBody,
        style: AppType.ui(13, color: t.ink2, height: 1.4),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// D5: faengt das Nach-unten-Ziehen eines modalen Bottom-Sheets ab.
///
/// **Warum das noetig ist:** ein `PopScope` deckt nur die halbe Miete ab. Die
/// beiden Dismiss-Wege laufen im Framework verschieden:
///
///  * Barriere-Tap → `ModalBarrier.handleDismiss` → `Navigator.maybePop`
///    (`modal_barrier.dart:225-230`) — fragt die Pop-Disposition, also
///    `PopScope`.
///  * Ziehen → `BottomSheet._handleDragEnd` → `onClosing` → **`Navigator.pop`**
///    (`bottom_sheet.dart:769-771`) — fragt sie **nicht**. Ein `PopScope` sieht
///    diesen Weg nie.
///
/// Von innerhalb des Sheets gibt es dafuer genau einen Hebel: die
/// Gesten-Arena. Der `_BottomSheetGestureDetector` sitzt ueber dem
/// `builder`-Kind; ein eigener Vertikal-Drag-Erkenner IM Kind liegt tiefer und
/// gewinnt die Arena — dasselbe Prinzip, aus dem eine ScrollView im Sheet das
/// Ziehen schluckt. Scrollbare Bereiche liegen wiederum tiefer als dieser
/// Guard und bleiben unberuehrt.
///
/// Ist [active] false (nichts geaendert), wird gar kein Erkenner registriert —
/// das Sheet laesst sich dann wie gewohnt wegziehen. Ein Sheet, das man ohne
/// Dialog nicht mehr zubekommt, waere schlimmer als der Bug.
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Mindeststrecke nach unten, ab der ein Zug als „zumachen" gilt. Bewusst
  /// klein: der Guard schluckt die Geste ohnehin, die Frage ist nur, ob der
  /// Nutzer dazu eine Antwort bekommt.
  static const double _closeIntentPx = 32;

  /// Flick-Schwelle, gespiegelt an `_kMinFlingVelocity` aus bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Ohne translucent bleiben Luecken zwischen den Kindern unbedeckt.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

class EditMealSheet extends StatefulWidget {
  const EditMealSheet({
    super.key,
    required this.meal,
    required this.onUpdateMeal,
    this.onRemoveMeal,
  });

  final LoggedMeal meal;
  final UpdateMealDetails onUpdateMeal;
  final ValueChanged<String>? onRemoveMeal;

  @override
  State<EditMealSheet> createState() => _EditMealSheetState();
}

class _EditMealSheetState extends State<EditMealSheet> {
  /// Tage rueckwaerts ab heute im Chip-Picker. Deckt sich mit dem
  /// 35-Tage-Boot-Fenster von MealsSync.loadLoggedMeals. Aeltere Ziele gehen
  /// seit dem On-Demand-Nachladen (home_store._ensureArchiveDayLoaded) ueber
  /// den „Anderes Datum…"-Eintrag: die Zeile bleibt serverseitig erhalten und
  /// der Food-Tab laedt den Zieltag bei Kalender-Auswahl nach — verschobene
  /// Mahlzeiten verschwinden also nicht mehr, sie liegen nur ausserhalb des
  /// Boot-Fensters.
  static const int _pickerDays = 35;

  late MealAnalysisResult _result;
  bool _resultChanged = false;
  late MealSlot _slot;
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    _result = widget.meal.result;
    _slot = widget.meal.slot;
    // effectiveLocalDay ('YYYY-MM-DD') parst als lokale Mitternacht — genau
    // der Tages-Anker, den auch das Bucketing nutzt.
    _day = DateUtils.dateOnly(DateTime.parse(widget.meal.effectiveLocalDay));
  }

  bool get _slotChanged => _slot != widget.meal.slot;

  bool get _dayChanged => localDayKey(_day) != widget.meal.effectiveLocalDay;

  bool get _dirty => _resultChanged || _slotChanged || _dayChanged;

  /// Portion/Bestandteile ueber den BESTEHENDEN Editor anpassen
  /// (showWeightAdjustmentSheet aus meal_widgets_adjust.dart) — identisches
  /// Muster wie MealAnalysisSheet._adjustPortion, nur ohne Sofort-Save: die
  /// Aenderung wird erst mit „Speichern" uebernommen.
  Future<void> _adjustPortion() async {
    final adjustment = await showWeightAdjustmentSheet(context, _result);
    if (!mounted || adjustment == null) return;

    MealAnalysisResult? candidate;
    if (adjustment is int && adjustment > 0) {
      candidate = _result.adjustedToGrams(adjustment);
    } else if (adjustment is List<MealComponent>) {
      candidate = _result.adjustedToItems(adjustment);
    }
    if (candidate == null) return;
    setState(() {
      _result = candidate!;
      _resultChanged = true;
    });
  }

  /// „Anderes Datum…": Kalender fuer Ziele jenseits der 35 Chips (der Dialog
  /// rendert in der aktiven App-Sprache). Grenzen wie der Food-Tab-Kalender:
  /// 2 Jahre zurueck, nichts in der Zukunft. Die Auswahl laeuft ueber
  /// denselben _day-State wie die Chips — gespeichert wird weiterhin
  /// ausschliesslich ueber updateLoggedMealDetails.
  Future<void> _pickOtherDay() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = DateTime(today.year - 2, today.month, today.day);
    var initial = _day;
    if (initial.isBefore(firstDate)) initial = firstDate;
    if (initial.isAfter(today)) initial = today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: today,
      helpText: context.l10n.foodDatePickerHelpText,
    );
    if (!mounted || picked == null) return;
    setState(() => _day = DateUtils.dateOnly(picked));
  }

  void _save() {
    final updated = widget.onUpdateMeal(
      widget.meal.id,
      result: _resultChanged ? _result : null,
      slot: _slotChanged ? _slot : null,
      day: _dayChanged ? _day : null,
    );
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(updated == null ? null : MealEditOutcome.saved(updated));
  }

  void _delete() {
    widget.onRemoveMeal?.call(widget.meal.id);
    if (!mounted) return;
    Navigator.of(context).pop(const MealEditOutcome.deleted());
  }

  /// D5: laeuft fuer jeden abgefangenen Dismiss-Versuch — Barriere-Tap,
  /// System-Zurueck und Schliessen-Kreuz kommen ueber [PopScope], das Ziehen
  /// ueber [_DiscardDragGuard]. Mehrfach-Versuche stapeln keine Dialoge.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Der Dialog ist zu diesem Zeitpunkt bereits gepoppt — die oberste Route
    // ist wieder das Sheet. Bewusst ohne Ergebnis: verworfen ist nicht
    // gespeichert.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.92;

    return PopScope<MealEditOutcome?>(
      // Nur solange wirklich etwas offen ist. Ohne Aenderung schliesst das
      // Sheet wie bisher sofort.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: _buildSheet(mediaQuery, maxHeight),
      ),
    );
  }

  Widget _buildSheet(MediaQueryData mediaQuery, double maxHeight) {
    final t = context.t;
    final l10n = context.l10n;
    // Kein SheetScaffold: fixer Kopf ueber einem gedeckelten Scrollbereich,
    // zwei Fussaktionen (Speichern + Loeschen) — und `edit-meal-save-button`
    // muss ein FilledButton bleiben, weil Tests seinen `onPressed` lesen.
    return Container(
      key: const ValueKey('edit-meal-sheet'),
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
          _Header(
            slot: _slot,
            mealName: _result.mealName,
            onClose: () => Navigator.of(context).maybePop(),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('edit-meal-sheet-scroll'),
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + mediaQuery.viewPadding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SummaryCard(result: _result, adjusted: _resultChanged),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('edit-meal-adjust-button'),
                      onPressed: _adjustPortion,
                      icon: const Icon(Icons.tune_rounded, size: 17),
                      label: Text(
                        l10n.foodAdjustPortionButton,
                        style: AppType.ui(13.5, weight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.ink,
                        side: BorderSide(color: t.line),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rControl),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionMeal),
                  const SizedBox(height: 8),
                  SlotSelector(
                    key: const ValueKey('edit-meal-slot-select'),
                    selected: _slot,
                    keyPrefix: 'edit-slot-select-',
                    onSelected: (slot) => setState(() => _slot = slot),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(l10n.foodSectionDay),
                  const SizedBox(height: 8),
                  _DayPicker(
                    selected: _day,
                    pastDays: _pickerDays,
                    onSelected: (day) => setState(() => _day = day),
                    onCalendarTap: _pickOtherDay,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('edit-meal-save-button'),
                      onPressed: _dirty ? _save : null,
                      icon: const Icon(Icons.check_rounded, size: 17),
                      label: Text(
                        l10n.commonSave,
                        style: AppType.ui(14, weight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.forest,
                        foregroundColor: t.onForest,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rControl),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onRemoveMeal != null) ...[
                    const SizedBox(height: 6),
                    Center(
                      child: TextButton.icon(
                        key: const ValueKey('edit-meal-delete-button'),
                        onPressed: _delete,
                        style: TextButton.styleFrom(foregroundColor: t.danger),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                        ),
                        label: Text(
                          l10n.foodDeleteMealButton,
                          style: AppType.ui(13, weight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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

class _Header extends StatelessWidget {
  const _Header({
    required this.slot,
    required this.mealName,
    required this.onClose,
  });

  final MealSlot slot;
  final String mealName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
      child: Row(
        children: [
          MealAvatar(letter: slot.initial(l10n), color: color, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.foodEditMealTitle,
                  style: AppType.display(18, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-meal-sheet-close'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// Kompakte Live-Zusammenfassung der (ggf. bereits angepassten) Werte.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.result, required this.adjusted});

  final MealAnalysisResult result;
  final bool adjusted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('edit-meal-summary'),
      radius: rCard,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            color: t.accent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${result.caloriesKcal} kcal · ${result.estimatedGrams} g',
              style: AppType.display(16, color: t.ink),
            ),
          ),
          Text(
            adjusted
                ? context.l10n.foodAdjustedLabel
                : result.resolvedSourceLabel(context.l10n),
            style: AppType.ui(
              11,
              weight: FontWeight.w600,
              color: adjusted ? t.ink : t.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

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

/// Einmalige Initialisierung der `intl`-Datumssymbole — derselbe Bool-Wächter
/// wie in `meal_analysis_screen.dart`/`today_texts.dart` (dateiprivat, daher
/// nicht wiederverwendbar).
bool _dateSymbolsReady = false;
void _ensureDateSymbols() {
  if (_dateSymbolsReady) return;
  initializeDateFormatting();
  _dateSymbolsReady = true;
}

/// B5: die Tage des Chip-Pickers — [count] Kalendertage abwaerts ab [today]
/// (heute zuerst), plus [selected], falls dieser Tag ausserhalb des Fensters
/// liegt (Altbestand am Fensterrand soll sichtbar bleiben).
///
/// Frueher stand hier
/// `[for (var i = 0; i < pastDays; i++) today.subtract(Duration(days: i))]`.
/// `Duration` ist Absolutzeit: am Montag 30.03.2026 in Europe/Berlin
/// (Fruehjahrsumstellung am Sonntag 29.03., ein 23-Stunden-Tag) liefert
/// `subtract(Duration(days: 1))` den `2026-03-28 23:00`. Der Sonntag war aus
/// dem Picker **nicht erreichbar**, der Chip „Gestern" trug den 28.03., und
/// eine bewusst auf Sonntag verschobene Mahlzeit landete dauerhaft auf Samstag
/// — serverseitig, ueber `local_day`. Bei [_EditMealSheetState._pickerDays]
/// = 35 betraf das ein Fuenf-Wochen-Fenster nach jeder Umstellung.
///
/// [count] ist die **Anzahl** der Tage, nicht der Offset zum aeltesten. Wer
/// dafuer `dayStrip` nimmt, muss `pastDays: count - 1` schreiben und
/// `.reversed` anhaengen — `dayStrip(pastDays: count).reversed` liefert einen
/// Tag zu viel. [recentDaysDescending] nimmt die Anzahl direkt entgegen und
/// kann sich deshalb gar nicht verzaehlen.
@visibleForTesting
List<DateTime> editMealPickerDays({
  required DateTime today,
  required int count,
  DateTime? selected,
}) {
  final days = List<DateTime>.of(
    recentDaysDescending(today: today, count: count),
  );
  if (selected != null && !days.any((d) => DateUtils.isSameDay(d, selected))) {
    days.add(startOfDay(selected));
  }
  return days;
}

/// B5: die Beschriftung eines Tag-Chips.
///
/// Frueher `today.difference(date).inDays`. Auf zwei lokalen Mitternachten
/// ueber die Fruehjahrsumstellung sind das 23 Stunden → `inDays == 0`, der
/// Vortag hiess also „Heute". [daysBetween] rechnet ueber `(y, m, d)`-Tripel
/// in UTC und kennt darum keine Sommerzeit.
///
/// Seit der i18n-Migration (Paket 2, 2026-08-10) ueber `intl`s Skeleton `EE`
/// statt einer lokalen Zwei-Buchstaben-Liste — dieselbe Technik wie
/// `meal_analysis_screen.dart:foodDateChipLabel` (dort nicht importierbar:
/// screens/ importiert widgets/, nicht umgekehrt). Die deutschen CLDR-Kuerzel
/// tragen einen Punkt („Mo."), den die alte Liste nicht hatte — abgeschnitten,
/// damit `de` byte-identisch bleibt.
@visibleForTesting
String editMealDayChipLabel({
  required DateTime today,
  required DateTime date,
  required AppLocalizations l10n,
}) {
  final offset = daysBetween(today, date);
  if (offset == 0) return l10n.todayDateToday;
  if (offset == 1) return l10n.todayDateYesterday;
  _ensureDateSymbols();
  return DateFormat('EE', l10n.localeName).format(date).replaceAll('.', '');
}

/// Horizontaler Chip-Picker ueber die letzten [pastDays] Tage (heute zuerst),
/// gespiegelt an den Datums-Chips des Food-Tabs. Als letzter Eintrag haengt
/// „Anderes Datum…" ([onCalendarTap]) — der oeffnet den seit der
/// de-Lokalisierung deutschen showDatePicker fuer Ziele jenseits der Chips.
class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.selected,
    required this.pastDays,
    required this.onSelected,
    required this.onCalendarTap,
  });

  final DateTime selected;
  final int pastDays;
  final ValueChanged<DateTime> onSelected;
  final VoidCallback onCalendarTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final today = startOfDay(DateTime.now());
    // B5: Kalender-, keine Absolutzeitarithmetik — siehe [editMealPickerDays].
    final days = editMealPickerDays(
      today: today,
      count: pastDays,
      selected: selected,
    );

    return SizedBox(
      key: const ValueKey('edit-meal-day-picker'),
      height: 58,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // +1: „Anderes Datum…"-Eintrag am Ende (Kalender).
        itemCount: days.length + 1,
        separatorBuilder: (context, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == days.length) {
            return _CalendarChip(onTap: onCalendarTap);
          }
          final date = days[index];
          final isSelected = DateUtils.isSameDay(date, selected);
          // A11y-Muster wie die Datums-Chips im Food-Tab: Button + Zustand.
          return Semantics(
            button: true,
            selected: isSelected,
            child: InkWell(
              key: ValueKey('edit-day-chip-$index'),
              onTap: () => onSelected(date),
              borderRadius: BorderRadius.circular(rControl),
              child: AnimatedContainer(
                duration:
                    motionDuration(context, const Duration(milliseconds: 160)),
                curve: Curves.easeOut,
                width: 64,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected ? t.forest : t.surf,
                  borderRadius: BorderRadius.circular(rControl),
                  border: Border.all(
                    color: isSelected ? Colors.transparent : t.line,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      editMealDayChipLabel(today: today, date: date, l10n: l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(
                        10.5,
                        weight: FontWeight.w700,
                        color: isSelected ? t.lime : t.ink2,
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
                        color: isSelected ? t.onForest : t.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// „Anderes Datum…"-Eintrag am Ende des Tag-Pickers: gleiche Chip-Form,
/// oeffnet den Kalender fuer Ziele jenseits der 35 Tage.
class _CalendarChip extends StatelessWidget {
  const _CalendarChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: "Anderes / Datum…" liest sich zerhackt — als ein Button mit
    // klarer Aktion ansagen.
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.foodOtherDateCalendarSemantics,
      child: InkWell(
        key: const ValueKey('edit-day-calendar'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: t.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.foodOtherDateLine1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  10.5,
                  weight: FontWeight.w700,
                  color: t.ink2,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                l10n.foodOtherDateLine2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.display(
                  11.5,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
