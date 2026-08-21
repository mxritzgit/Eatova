import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'edit_meal_sheet.dart';

/// Ein Eintrag des Tagebuchs samt seinem Index in der TAGESLISTE.
///
/// Der Index kommt bewusst nicht pro Karte, sondern aus einer einzigen,
/// absteigend nach `loggedAt` sortierten Liste des ganzen Tages — nur so
/// bleibt `food-history-entry-0` der neueste Eintrag des Tages, worauf
/// `flows/food_log_flow_test`, `edit_meal_sheet_test` und `flows/recipes_flow`
/// bauen.
@immutable
class DiaryEntry {
  const DiaryEntry(this.meal, this.index);

  final LoggedMeal meal;

  /// Position in der Tagesliste (0 = neueste Mahlzeit des Tages).
  final int index;
}

/// Eine Slot-Karte des Tagebuchs: Avatar, Slot-Name, „N kcal · N Einträge",
/// ein Plus-Knopf, der GENAU DIESEN Slot im Add-Sheet oeffnet, und darunter
/// die Eintraege als wischbare Zeilen.
class DiaryMealCard extends StatelessWidget {
  const DiaryMealCard({
    super.key,
    required this.slot,
    required this.entries,
    this.onAddToSlot,
    this.onMealTap,
    this.onRemoveMeal,
  });

  final MealSlot slot;

  /// Die Eintraege dieses Slots mit ihrem Tages-Index.
  final List<DiaryEntry> entries;

  /// Plus-Knopf und leerer Add-Slot: oeffnet das Add-Sheet in [slot].
  final ValueChanged<MealSlot>? onAddToSlot;

  /// Rueckfall fuer den Tap auf eine Zeile, wenn kein [MealEditScope] ueber
  /// der Karte liegt (Preview/Standalone).
  final ValueChanged<MealSlot>? onMealTap;

  final ValueChanged<String>? onRemoveMeal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    // kcal UND Makros des Slots aus einer Summe — dieselbe Zahlenbasis wie
    // die Tagesbilanz (MacroProgress), statt die Gramm-Strings hier noch
    // einmal zu parsen.
    final total = entries.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, e) => sum.add(e.meal.result),
    );

    return AppCard(
      radius: rCard,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
            child: Row(
              children: <Widget>[
                MealAvatar(letter: slot.initial(l10n), color: color, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        slot.label(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          14.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entries.isEmpty
                            ? l10n.todayMealSlotEmpty
                            : l10n.foodDiarySlotSummary(
                                total.kcal,
                                entries.length,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.display(11.5, color: t.ink2),
                      ),
                      // Slot-Makros als eigene Zeile unter der Summe — die
                      // Summenzeile selbst bleibt unveraendert (Tests lesen
                      // sie als Ganzes).
                      if (entries.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 1),
                        Text(
                          _macroLine(l10n, total),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.display(11, color: t.ink2),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onAddToSlot != null) ...<Widget>[
                  const SizedBox(width: 8),
                  _SlotAddButton(
                    slot: slot,
                    onTap: () => onAddToSlot!(slot),
                  ),
                ],
              ],
            ),
          ),
          for (final entry in entries)
            _SlidableEntry(
              entry: entry,
              accent: color,
              onMealTap: onMealTap,
              onRemoveMeal: onRemoveMeal,
            ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              child: DottedAddSlot(
                key: ValueKey('food-slot-empty-${slot.name}'),
                label: l10n.foodSlotAddLabel(slot.label(l10n)),
                onTap: onAddToSlot == null ? null : () => onAddToSlot!(slot),
              ),
            ),
        ],
      ),
    );
  }
}

/// „P 12 g · K 48 g · F 6 g" (en: „P 12 g · C 48 g · F 6 g") — gerundete
/// Gramm aus einer [MacroProgress]-Summe. Fuer den Slot-Kopf (alle Eintraege)
/// und jede Verlaufszeile (ein Eintrag) dieselbe Funktion, damit Zeilen und
/// Kopf nie auseinanderlaufen.
String _macroLine(AppLocalizations l10n, MacroProgress m) =>
    l10n.foodMacroSummary(m.proteinG.round(), m.carbsG.round(), m.fatG.round());

/// Der Forest-Plus-Knopf der Slot-Karte.
class _SlotAddButton extends StatelessWidget {
  const _SlotAddButton({required this.slot, required this.onTap});

  final MealSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      button: true,
      label: l10n.foodSlotAddLabel(slot.label(l10n)),
      child: Material(
        key: ValueKey('food-slot-add-${slot.name}'),
        color: t.forest,
        borderRadius: BorderRadius.circular(rChip),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rChip),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(Icons.add_rounded, size: 17, color: t.lime),
          ),
        ),
      ),
    );
  }
}

/// Anteil der Zeilenbreite, den die aufgezogene Lösch-Aktion einnimmt.
/// Auch das Fenster der Reveal-Animation: der SlidableController laeuft beim
/// Aufziehen von 0 bis genau zu diesem Wert (und beim Dismiss weiter bis 1).
const double _deleteExtent = 0.26;

class _SlidableEntry extends StatelessWidget {
  const _SlidableEntry({
    required this.entry,
    required this.accent,
    required this.onMealTap,
    required this.onRemoveMeal,
  });

  final DiaryEntry entry;
  final Color accent;
  final ValueChanged<MealSlot>? onMealTap;
  final ValueChanged<String>? onRemoveMeal;

  @override
  Widget build(BuildContext context) {
    final meal = entry.meal;
    // Bearbeiten-Sheet, wenn die Home-Schale den MealEditScope bereitstellt:
    // Tap auf den Eintrag editiert GENAU DIESE Mahlzeit (Portion/Slot/Tag).
    // Ohne Scope (Preview/Standalone) bleibt das alte Verhalten: Tap oeffnet
    // das Add-Sheet des Slots.
    final editScope = MealEditScope.maybeOf(context);
    final VoidCallback? tap;
    if (editScope != null) {
      tap = () => showEditMealSheet(
            context,
            meal: meal,
            onUpdateMeal: editScope.onUpdateMeal,
            onRemoveMeal: editScope.onRemoveMeal,
          );
    } else if (onMealTap != null) {
      tap = () => onMealTap!(meal.slot);
    } else {
      tap = null;
    }

    final row = _HistoryEntry(
      key: ValueKey('food-history-entry-${entry.index}'),
      meal: meal,
      accent: accent,
      index: entry.index,
      onTap: tap,
    );

    // Ohne Lösch-Callback: schlichte Zeile (kein Swipe).
    if (onRemoveMeal == null) return row;

    // Links-Swipe: Zeile + Lösch-Button laufen gemeinsam (ScrollMotion). Ganz
    // durchwischen loescht direkt (DismissiblePane); Tap auf den Button
    // animiert die Zeile erst raus und entfernt sie dann aus dem Store.
    return ClipRect(
      key: ValueKey('food-history-clip-${meal.id}'),
      child: Slidable(
        key: ValueKey('slide-${meal.id}'),
        groupTag: 'food-history',
        endActionPane: ActionPane(
          motion: const ScrollMotion(),
          extentRatio: _deleteExtent,
          dismissible: DismissiblePane(
            onDismissed: () => onRemoveMeal!(meal.id),
          ),
          children: <Widget>[
            _DeleteMealAction(
              key: ValueKey('food-history-delete-${entry.index}'),
              onDelete: () => onRemoveMeal!(meal.id),
            ),
          ],
        ),
        child: row,
      ),
    );
  }
}

class _DeleteMealAction extends StatelessWidget {
  const _DeleteMealAction({super.key, required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final controller = Slidable.of(context);
    final reveal = controller == null
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(
            parent: controller.animation,
            curve: const Interval(
              0.0,
              _deleteExtent,
              curve: Curves.easeOutCubic,
            ),
          );
    return CustomSlidableAction(
      // Kein autoClose: das wuerde direkt nach dem Tap ein close() feuern und
      // die dismiss()-Animation abwuergen -> onDelete liefe nie.
      autoClose: false,
      onPressed: (actionContext) {
        HapticFeedback.mediumImpact();
        final slidable = Slidable.of(actionContext);
        if (slidable == null) {
          onDelete();
          return;
        }
        // Erst die Zeile rausschieben + Luecke zusammenziehen, dann loeschen —
        // sonst springt die Liste hart, sobald der Store neu baut.
        //
        // BEWUSST OHNE `motionDuration`: flutter_slidable startet die
        // Resize-Animation mit `forward(from: 0)` und setzt im selben Zug
        // `resized = true`. Bei `Duration.zero` steht der Controller schon im
        // Build danach auf `completed` und der Debug-Assert der Bibliothek
        // („A dismissed Slidable widget is still part of the tree") wirft,
        // bevor `onDelete` die Zeile aus dem Baum genommen hat.
        slidable.dismiss(
          ResizeRequest(const Duration(milliseconds: 220), onDelete),
        );
      },
      backgroundColor: Colors.transparent,
      foregroundColor: t.danger,
      padding: EdgeInsets.zero,
      child: FadeTransition(
        opacity: reveal,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(reveal),
          child: Semantics(
            button: true,
            label: context.l10n.foodEntryDeleteSemantics,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: t.danger.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: t.danger.withValues(alpha: 0.25)),
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                color: t.danger,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryEntry extends StatefulWidget {
  const _HistoryEntry({
    super.key,
    required this.meal,
    required this.accent,
    required this.index,
    required this.onTap,
  });

  final LoggedMeal meal;
  final Color accent;
  final int index;
  final VoidCallback? onTap;

  @override
  State<_HistoryEntry> createState() => _HistoryEntryState();
}

class _HistoryEntryState extends State<_HistoryEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final CurvedAnimation _in = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  bool _gestartet = false;

  // Der Auftritt haengt an MediaQuery („Bewegung reduzieren") und startet
  // deshalb hier statt in initState: dort darf noch kein InheritedWidget
  // abgefragt werden.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_gestartet) return;
    _gestartet = true;

    _controller.duration =
        motionDuration(context, const Duration(milliseconds: 280));
    // Sanfter Stagger beim Listenaufbau; einzelne neue Eintraege sliden ohne
    // spuerbare Wartezeit rein. Ueber die id-Keys der Slidable-Wrapper bleibt
    // der State pro Mahlzeit erhalten -> kein Re-Play beim Loeschen anderer.
    // pumpAndSettle wartet den Stagger ab, Taps bleiben also stabil.
    final delay = motionDelay(
      context,
      Duration(milliseconds: 40 * math.min(widget.index, 5)),
    );
    if (delay == Duration.zero) {
      // Kein Timer-Umweg: unter reduzierter Bewegung steht die Zeile im
      // ersten Frame, ohne dass ein Test darauf pumpen muesste.
      _controller.forward();
      return;
    }
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _in.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final meal = widget.meal;
    final grams = meal.result.estimatedGrams;
    final amount = grams > 0 ? '~$grams g' : l10n.foodPortionFallback;
    // Sind alle drei Makros unbekannt (Altbestand ohne Naehrwerte), gibt es
    // keine Makro-Zeile: „P 0 g · K 0 g · F 0 g" saehe nach einer Messung
    // aus. Gleiche Regel wie in ExistingMealsList; die Slot-Summe im Kopf
    // zeigt 0 dagegen immer (wie die Tagesringe).
    final rowMacros = MacroProgress.empty.add(meal.result);
    final hasMacros =
        rowMacros.proteinG > 0 || rowMacros.carbsG > 0 || rowMacros.fatG > 0;

    return FadeTransition(
      opacity: _in,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.20),
          end: Offset.zero,
        ).animate(_in),
        // A11y: die Verlaufszeile oeffnet das Bearbeiten-Sheet — als Button
        // mit Hint ansagen (nur wenn ueberhaupt ein Tap verdrahtet ist).
        child: Semantics(
          button: widget.onTap != null,
          hint: widget.onTap == null ? null : l10n.foodEditMealTitle,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.surf,
              border: Border(top: BorderSide(color: t.line)),
            ),
            child: InkWell(
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 11,
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 3,
                      height: 26,
                      decoration: BoxDecoration(
                        color: widget.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            meal.result.mealName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 1),
                          // Der Slot steht hier ein zweites Mal (die Karte
                          // nennt ihn schon): die Zeile bleibt so auch
                          // ausserhalb ihrer Karte selbsterklaerend — und
                          // edit_meal_sheet_test liest genau dieses Format
                          // als EIN Text-Widget.
                          Text(
                            '${meal.slot.label(l10n)} · $amount',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.ui(11, color: t.ink2),
                          ),
                          // Makros der Mahlzeit als DRITTE Zeile, nicht neben
                          // „Slot · Menge": neben der kcal-Spalte bleiben bei
                          // 390 pt und Textskalierung 1.3 nur ~110 pt fuer
                          // „P 12 g · K 48 g · F 6 g" — die Zeile wuerde
                          // abgeschnitten (diary_meal_card_macros_test misst
                          // das mit den echten Schriften).
                          if (hasMacros) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              _macroLine(l10n, rowMacros),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.display(11, color: t.ink2),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '${meal.result.caloriesKcal} kcal',
                          style: AppType.display(
                            12.5,
                            weight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatMealTime(meal.loggedAt),
                          style: AppType.display(11, color: t.ink2),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lokale Wanduhr-Zeit `HH:mm` einer Mahlzeit fuer die Verlaufszeile.
String formatMealTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
