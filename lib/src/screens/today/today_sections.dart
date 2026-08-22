import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import 'today_texts.dart';

/// Die Mahlzeiten-Karte: vier feste Slot-Zeilen statt einer Liste geloggter
/// Eintraege.
///
/// Bewusst anders als der Verlauf im Food-Tab: dort geht es um einzelne
/// Mahlzeiten (bearbeiten, loeschen), hier um die Frage „welcher Teil meines
/// Tages steht noch offen?". Ein leerer Slot ist deshalb eine ZEILE, keine
/// Leerstelle — sonst waere genau die Auskunft weg, um die es geht.
class TodayMealsCard extends StatelessWidget {
  const TodayMealsCard({super.key, required this.meals, this.onOpenSlot});

  /// Nur die Mahlzeiten des gewaehlten Tages.
  final List<LoggedMeal> meals;

  final ValueChanged<MealSlot>? onOpenSlot;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const ValueKey('today-meals-card'),
      clip: true,
      child: Column(
        children: <Widget>[
          for (final slot in MealSlot.values)
            TodayMealRow(
              slot: slot,
              // Zuordnung ueber LoggedMeal.slot (logged_meal.dart:60-65):
              // ein `forcedSlot` gewinnt dort vor der Uhrzeit-Heuristik. Selbst
              // nach der Uhrzeit zu bucketen wuerde jede manuelle Slot-Wahl
              // des Nutzers stillschweigend ueberschreiben.
              meals: meals
                  .where((meal) => meal.slot == slot)
                  .toList(growable: false),
              last: slot == MealSlot.values.last,
              onTap: onOpenSlot == null ? null : () => onOpenSlot!(slot),
            ),
        ],
      ),
    );
  }
}

/// Eine Slot-Zeile: Avatar, Name, Untertitel, kcal-Summe.
class TodayMealRow extends StatelessWidget {
  const TodayMealRow({
    super.key,
    required this.slot,
    required this.meals,
    this.last = false,
    this.onTap,
  });

  final MealSlot slot;
  final List<LoggedMeal> meals;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final kcal = meals.fold<int>(
      0,
      (summe, meal) => summe + meal.result.caloriesKcal,
    );

    // Material(transparent) unter dem InkWell: die Vorlage setzt das InkWell
    // direkt in die Karte, dort liegt die Tipp-Welle UNTER der Kartenflaeche
    // und ist unsichtbar — der Tap wirkt dann tot.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('today-meal-row-${slot.name}'),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: last ? null : Border(bottom: BorderSide(color: t.line)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              MealAvatar(letter: slot.initial(l10n), color: slot.accentOn(t)),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      slot.label(l10n),
                      style:
                          AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mealSlotSubtitle(meals, l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.ui(11.5, color: t.ink2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    kcalThousands(kcal, l10n),
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  Text(
                    l10n.todayMealKcalLabel,
                    style: AppType.ui(
                      9.5,
                      weight: FontWeight.w500,
                      color: t.ink2,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Die Schritte-Karte unter dem Kalorien-Hero: Tagesstand, Fortschritt zum
/// Schrittziel und die daraus geschaetzten kcal — die Rechnung hinter der
/// VERBRANNT-Kachel, an einer Stelle sichtbar gemacht (Nutzer-Wunsch
/// 2026-08-22).
///
/// Gleiche Anatomie wie eine [TodayMealRow] (Kachel links, Titel + Untertitel,
/// Zahl + Einheit rechts), darunter ein Balken wie in [MacroBar] — damit die
/// Karte als Teil derselben Familie gelesen wird und nicht als Fremdkoerper.
///
/// Die Schale laesst die Karte ganz weg, wenn es keine Schrittquelle gibt
/// (`TodayScreen.steps == null`): ohne Health-Anbindung stuende hier sonst
/// jeden Tag „0 / 8.000" — eine Aussage ueber Daten, die es nicht gibt.
class TodayStepsCard extends StatelessWidget {
  const TodayStepsCard({
    super.key,
    required this.steps,
    required this.goal,
    required this.burnedKcal,
  });

  final int steps;

  /// `UserProfile.dailyStepsGoal` (Ziele-Seite, min. 1000).
  final int goal;

  /// Die aus [steps] geschaetzten kcal (HomeStore.burnedKcalForFoodDate).
  /// 0 heisst „keine Aussage" — der Teil des Untertitels entfaellt dann.
  final int burnedKcal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final locale = l10n.localeName;

    final schritte = steps.clamp(0, 9999999).toInt();
    final ziel = goal.clamp(0, 9999999).toInt();
    final pct = ziel <= 0 ? 0.0 : (schritte / ziel).clamp(0.0, 1.0);
    final erreicht = ziel > 0 && schritte >= ziel;

    // „≈ 261 kcal verbrannt · Ziel 8.000" bzw. „… · Ziel erreicht".
    final untertitel = <String>[
      if (burnedKcal > 0)
        l10n.todayStepsBurned(formatThousands(burnedKcal, locale)),
      if (erreicht)
        l10n.todayStepsGoalReached
      else if (ziel > 0)
        l10n.todayStepsGoal(formatThousands(ziel, locale)),
    ].join(' · ');

    return AppCard(
      key: const ValueKey('today-steps-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Kachel statt Buchstaben-Avatar: Schritte sind kein Slot.
              // 14 wie das Profil-Badge der Kopfzeile; Lime-Ton, damit sie an
              // die VERBRANNT-Kachel im Hero anschliesst.
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: t.lime.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.directions_walk_rounded,
                  size: 22,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.todayStepsTitle,
                      style:
                          AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                    ),
                    if (untertitel.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        untertitel,
                        key: const ValueKey('today-steps-subtitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(11.5, color: t.ink2),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    formatThousands(schritte, locale),
                    key: const ValueKey('today-steps-value'),
                    style: AppType.display(
                      16,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  Text(
                    l10n.todayStepsUnit,
                    style: AppType.ui(
                      9.5,
                      weight: FontWeight.w500,
                      color: t.ink2,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Derselbe Balken wie [MacroBar] (Hoehe, Radius, Animation), nur
          // ohne die Label-/Wert-Spalten — die stehen hier schon darueber.
          Semantics(
            label: l10n.todaySemanticsStepsProgress,
            value: l10n.todaySemanticsStepsProgressValue(
              formatThousands(schritte, locale),
              formatThousands(ziel, locale),
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: pct),
              duration: motionDuration(
                context,
                const Duration(milliseconds: 500),
              ),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  key: const ValueKey('today-steps-bar'),
                  value: v,
                  minHeight: 9,
                  backgroundColor: t.tile,
                  valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Das Banner zum KI-Coach — mit einem konkreten Teaser aus den Restmakros.
class TodayCoachBanner extends StatelessWidget {
  const TodayCoachBanner({super.key, required this.teaser, this.onTap});

  final String teaser;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('today-coach-banner'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf2,
        // 24 wie [AppCard] (und wie die Vorlage): das Banner steht in derselben
        // Spalte wie die Makro- und Mahlzeiten-Karten und muss deren Ecken
        // treffen — rCard (22) waere hier der sichtbare Ausreisser.
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.line),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -30,
            top: -30,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: t.lime.withValues(alpha: 0.30),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.todayCoachEyebrow, style: AppType.eyebrow(t.ink2)),
                const SizedBox(height: 6),
                // Abweichung von der Vorlage (SizedBox(width: 230)): eine feste
                // Textbreite bricht bei grosser Systemschrift. Die Spalte gibt
                // dem Text ohnehin die Kartenbreite, der Kreis oben rechts
                // liegt hinter dem Text und stoert ihn nicht.
                Text(
                  teaser,
                  style: AppType.display(
                    19,
                    weight: FontWeight.w700,
                    color: t.ink,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: t.forest,
                    borderRadius: BorderRadius.circular(rChip),
                    child: InkWell(
                      key: const ValueKey('today-coach-cta'),
                      onTap: onTap,
                      borderRadius: BorderRadius.circular(rChip),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                l10n.todayCoachCta,
                                style: AppType.ui(
                                  12,
                                  weight: FontWeight.w600,
                                  color: t.onForest,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: t.lime,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Der Tag wird gerade nachgeladen — Spinner statt einer faelschlich leeren
/// Mahlzeiten-Karte. Text wortgleich zum Food-Tab
/// (meal_analysis_screen.dart:965).
class TodayDayLoadingCard extends StatelessWidget {
  const TodayDayLoadingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      key: const ValueKey('today-day-loading'),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.todayDayLoading,
            style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
