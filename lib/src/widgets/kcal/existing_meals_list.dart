import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../design/design.dart';

/// Zeigt die bereits geloggten Mahlzeiten fuer den aktuellen Slot+Tag
/// oben im AddMealSheet — mit X-Button zum Entfernen und (wenn [onEdit]
/// verdrahtet ist) Tap auf die Zeile zum Bearbeiten.
///
/// Der Kopf traegt die Slot-Summe als kcal UND Makros (Protein/KH/Fett):
/// nach dem Hinzufuegen will der Nutzer sehen, „wie viel Protein habe ich
/// jetzt beim Abendessen" — bis 2026-08-21 stand hier nur die kcal-Zahl.
/// Gerechnet wird mit [MacroProgress] (dieselbe Parse-/Summenlogik wie die
/// Tagesringe in `macroProgressForFoodDate`), NICHT durch eigenes Parsen der
/// String-Felder `result.protein` & Co.
class ExistingMealsList extends StatelessWidget {
  const ExistingMealsList({
    super.key,
    required this.meals,
    required this.slot,
    required this.onRemove,
    this.onEdit,
  });

  final List<LoggedMeal> meals;
  final MealSlot slot;
  final ValueChanged<String>? onRemove;

  /// Tap auf eine Zeile oeffnet das Bearbeiten-Sheet. Null -> Zeile nicht
  /// tippbar (bisheriges Verhalten).
  final ValueChanged<LoggedMeal>? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accent = slot.accentIn(context);
    final totals = meals.fold<MacroProgress>(
      MacroProgress.empty,
      (sum, m) => sum.add(m.result),
    );
    return AppCard(
      key: const ValueKey('analyse-existing-meals'),
      radius: rCard,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Expanded statt nackter Text: bei grosser Systemschrift
                    // darf die Versalien-Zeile umbrechen, statt die Row zu
                    // sprengen.
                    Expanded(
                      child: Text(
                        context.l10n.foodAlreadyAddedEyebrow,
                        style: AppType.eyebrow(t.ink2, size: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _SlotTotalLine(totals: totals),
              ],
            ),
          ),
          for (var i = 0; i < meals.length; i++) ...[
            if (i > 0)
              Divider(
                color: t.line,
                height: 1,
                indent: 14,
                endIndent: 14,
              ),
            _ExistingMealRow(
              meal: meals[i],
              onRemove: onRemove,
              onEdit: onEdit,
            ),
          ],
        ],
      ),
    );
  }
}

/// „Gesamt 980 kcal · P 62 g · K 90 g · F 35 g" als Slot-Summe.
///
/// Bewusst ein [Wrap] aus zwei Bloecken (Label+kcal, Makros) statt EINES
/// durchgehenden Strings: bei 390 pt und Textskala 1.3 passt die ganze Zeile
/// nicht mehr nebeneinander — ein Wrap setzt dann den kompletten Makro-Block
/// in die naechste Zeile, waehrend ein einzelner Text irgendwo zwischen
/// „P 62" und „g" umbraeche oder einen Trennpunkt am Zeilenende haengen
/// liesse. Die kcal-Zahl bleibt ein eigenes Text-Widget mit dem bisherigen
/// Wortlaut (`'980 kcal'`), weil Flow-Tests genau diesen Text suchen.
class _SlotTotalLine extends StatelessWidget {
  const _SlotTotalLine({required this.totals});

  final MacroProgress totals;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Wrap(
      key: const ValueKey('analyse-existing-total'),
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Label+kcal ebenfalls als Wrap statt Row: bei doppelter Systemschrift
        // (EatovaApp-Deckel 2.0) passen „Gesamt" und die Zahl nicht mehr
        // nebeneinander in 390 pt — eine Row wuerde ueberlaufen, der Wrap
        // setzt die Zahl unter das Label.
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.foodSlotTotalLabel,
              key: const ValueKey('analyse-existing-total-label'),
              style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
            ),
            Text(
              '${totals.kcal} kcal',
              key: const ValueKey('analyse-existing-total-kcal'),
              style: AppType.display(
                12,
                weight: FontWeight.w700,
                color: t.ink,
              ),
            ),
          ],
        ),
        Text(
          l10n.foodMacroSummary(
            totals.proteinG.round(),
            totals.carbsG.round(),
            totals.fatG.round(),
          ),
          key: const ValueKey('analyse-existing-total-macros'),
          style: AppType.display(
            11.5,
            weight: FontWeight.w500,
            color: t.ink2,
          ),
        ),
      ],
    );
  }
}

class _ExistingMealRow extends StatelessWidget {
  const _ExistingMealRow({
    required this.meal,
    required this.onRemove,
    required this.onEdit,
  });

  final LoggedMeal meal;
  final ValueChanged<String>? onRemove;
  final ValueChanged<LoggedMeal>? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final macros = MacroProgress.empty.add(meal.result);
    // Makros unbekannt (Parser liefert '-', MacroProgress liest 0) -> keine
    // Zeile „P 0 g · K 0 g · F 0 g", die eine Messung vortaeuschen wuerde.
    // Die Slot-Summe oben bleibt davon unberuehrt: dort zaehlt 0 ehrlich
    // als „nichts Bekanntes dazu", genau wie in den Tagesringen.
    final hasMacros =
        macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meal.result.mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  '${meal.result.caloriesKcal} kcal · ${meal.result.estimatedGrams} g',
                  style: AppType.display(
                    11.5,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
                if (hasMacros) ...[
                  const SizedBox(height: 2),
                  Text(
                    context.l10n.foodMacroSummary(
                      macros.proteinG.round(),
                      macros.carbsG.round(),
                      macros.fatG.round(),
                    ),
                    key: ValueKey('analyse-existing-macros-${meal.id}'),
                    style: AppType.display(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              key: ValueKey('analyse-existing-remove-${meal.id}'),
              iconSize: 18,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => onRemove!(meal.id),
              icon: Icon(Icons.close_rounded, color: t.ink2),
              tooltip: context.l10n.foodRemoveTooltip,
            ),
        ],
      ),
    );
    if (onEdit == null) return row;
    // A11y: die Zeile sieht aus wie reine Anzeige — als Button mit klarer
    // Aktion ansagen, sonst bleibt der Edit-Tap unentdeckbar.
    return Semantics(
      button: true,
      hint: context.l10n.foodEditMealTitle,
      child: InkWell(
        key: ValueKey('analyse-existing-edit-${meal.id}'),
        onTap: () => onEdit!(meal),
        borderRadius: BorderRadius.circular(rControl),
        child: row,
      ),
    );
  }
}
