import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/local_day.dart';
import '../../theme/app_colors.dart';
import '../../theme/meal_slot_style.dart';
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
/// Hintergrund: die Verlaufskarte ([MealsTodayCard]) und das AddMealSheet
/// leben unterhalb von `MealAnalysisScreen`, dessen Konstruktor-Signatur
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
  /// rendert dank der de-Lokalisierung in eatova_app.dart deutsch). Grenzen
  /// wie der Food-Tab-Kalender: 2 Jahre zurueck, nichts in der Zukunft. Die
  /// Auswahl laeuft ueber denselben _day-State wie die Chips — gespeichert
  /// wird weiterhin ausschliesslich ueber updateLoggedMealDetails.
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
      helpText: 'Tag wählen',
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

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.92;

    return Container(
      key: const ValueKey('edit-meal-sheet'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
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
                      label: const Text(
                        'Portion & Bestandteile anpassen',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: cyan,
                        side: BorderSide(color: cyan.withValues(alpha: 0.45)),
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
                  const _SectionLabel('Mahlzeit'),
                  const SizedBox(height: 8),
                  SlotSelector(
                    key: const ValueKey('edit-meal-slot-select'),
                    selected: _slot,
                    keyPrefix: 'edit-slot-select-',
                    onSelected: (slot) => setState(() => _slot = slot),
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('Tag'),
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
                      label: const Text(
                        'Speichern',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: forgeLime,
                        foregroundColor: bg,
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
                        style: TextButton.styleFrom(foregroundColor: danger),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                        ),
                        label: const Text(
                          'Mahlzeit löschen',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
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
          color: hairline,
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
    final color = slot.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(slot.icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Mahlzeit bearbeiten',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-meal-sheet-close'),
            onPressed: onClose,
            tooltip: 'Schließen',
            icon: const Icon(Icons.close_rounded, color: textMuted),
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
    return Container(
      key: const ValueKey('edit-meal-summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.local_fire_department_outlined,
            color: orange,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${result.caloriesKcal} kcal · ${result.estimatedGrams} g',
              style: const TextStyle(
                color: textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Text(
            adjusted ? 'Angepasst' : result.sourceLabel,
            style: TextStyle(
              color: adjusted ? orange : textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
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
      style: const TextStyle(
        color: textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
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

  static const List<String> _weekdays = [
    'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So', // DateTime.weekday: 1 = Montag
  ];

  static String _chipLabel(DateTime today, DateTime date) {
    final offset = today.difference(date).inDays;
    if (offset == 0) return 'Heute';
    if (offset == 1) return 'Gestern';
    return _weekdays[date.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final days = [
      for (var i = 0; i < pastDays; i++) today.subtract(Duration(days: i)),
    ];
    // Liegt der aktuelle Tag der Mahlzeit ausserhalb des Fensters (Altbestand
    // am Fensterrand), haengt er hinten an, damit die Auswahl sichtbar bleibt.
    if (!days.any((d) => DateUtils.isSameDay(d, selected))) {
      days.add(DateUtils.dateOnly(selected));
    }

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
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                width: 64,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected ? forgeLime : surfaceSoft,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _chipLabel(today, date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? bg : textMuted,
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
                        color: isSelected
                            ? bg.withValues(alpha: 0.68)
                            : textPrimary,
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
    // A11y: "Anderes / Datum…" liest sich zerhackt — als ein Button mit
    // klarer Aktion ansagen.
    return Semantics(
      button: true,
      label: 'Anderes Datum im Kalender wählen',
      child: InkWell(
        key: const ValueKey('edit-day-calendar'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(rControl),
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: surfaceSoft,
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Anderes',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Datum…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
