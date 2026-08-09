import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../models/lifetime_stats.dart';
import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/user_profile.dart';
import '../../services/day_math.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'today_day_strip.dart';
import 'today_hero.dart';
import 'today_sections.dart';
import 'today_texts.dart';

/// Der Tab „Heute" — das Tagesdashboard (Design-Refactor 2026-08-09).
///
/// Bewusst ein reines Anzeige-Widget: alle Daten kommen als Parameter, jede
/// Aktion geht als Callback zurueck an die Schale. Der Screen kennt weder
/// Store noch Sync — dadurch ist er ohne Backend pumpbar und die Schale
/// behaelt die Hoheit ueber Tab-Wechsel und Routen.
///
/// Abgrenzung zum Food-Tab: „Heute" beantwortet „wie stehe ich gerade da?",
/// der Food-Tab beantwortet „was habe ich gegessen und was trage ich nach?".
/// Deshalb liegt hier der Kalorien-Hero und dort die Mahlzeiten-Pflege.
class TodayScreen extends StatelessWidget {
  const TodayScreen({
    super.key,
    required this.userName,
    required this.profile,
    required this.consumedKcal,
    required this.burnedKcal,
    required this.macroProgress,
    required this.meals,
    required this.selectedDate,
    required this.streak,
    this.profileInitial,
    this.dayLoading = false,
    this.onDateSelected,
    this.onOpenCoach,
    this.onOpenProfile,
    this.onOpenMealSlot,
  });

  final String userName;
  final UserProfile profile;

  /// Gegessene Kalorien des [selectedDate].
  final int consumedKcal;

  /// Aus Schritten geschaetzt — an einem Nicht-Heute-Tag reicht die Schale
  /// bewusst 0 durch; die Kachel zeigt dann „—" statt einer Nullaussage.
  final int burnedKcal;

  final MacroProgress macroProgress;

  /// Nur die Mahlzeiten des [selectedDate].
  final List<LoggedMeal> meals;

  final DateTime selectedDate;

  /// Bereits aufgeloest ueber [LifetimeStats.effectiveStreakOn] — eine
  /// gerissene Kette ist hier schon 0.
  final int streak;

  final String? profileInitial;
  final bool dayLoading;

  final ValueChanged<DateTime>? onDateSelected;
  final VoidCallback? onOpenCoach;
  final VoidCallback? onOpenProfile;

  /// Der einzige Weg zum Loggen: eine Slot-Zeile fuehrt in den Food-Tab.
  /// Ein schwebender „Essen loggen"-Knopf stand hier bis 2026-08-10 daneben —
  /// er ist auf Nutzer-Entscheid entfallen (zwei Wege zum selben Ziel).
  final ValueChanged<MealSlot>? onOpenMealSlot;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    // Genau eine Uhrabfrage pro Aufbau: sonst koennten Begruessung und
    // Datums-Streifen auf verschiedenen Seiten von Mitternacht landen.
    final jetzt = clock.now();
    final heute = startOfDay(jetzt);
    final istHeute = daysBetween(heute, selectedDate) == 0;

    final restProtein =
        (profile.proteinGoalG - macroProgress.proteinG).round().clamp(0, 99999);

    // KEIN eigenes SafeArea und KEIN horizontaler Rand: beides liefert die
    // Schale bereits (eatova_home_page.dart:420-424). Ein zweites Padding
    // ergaebe 40 px Rand.
    //
    // Reine Liste, kein Stack: bis 2026-08-10 schwebte hier ein „Essen
    // loggen"-Knopf ueber der Liste, weshalb unten seine (mit der
    // Systemschrift wachsende) Hoehe frei bleiben musste. Der Knopf ist auf
    // Nutzer-Entscheid entfallen; die 12 sind jetzt nur noch Luft, damit die
    // letzte Karte nicht an der Navigationsleiste klebt (plus die 12 der
    // Schale).
    return ListView(
      key: const ValueKey('screen-today'),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
      children: <Widget>[
        _Kopfzeile(
          // Die Eyebrow folgt dem GEWAEHLTEN Tag — sonst widerspraeche sie
          // dem Datums-Streifen direkt darunter. Die Begruessung folgt der
          // Wanduhr: „Guten Morgen" ist eine Aussage ueber jetzt, nicht
          // ueber den aufgeschlagenen Tag.
          eyebrow: todayEyebrow(selectedDate),
          greeting: todayGreeting(jetzt),
          initial: profileInitial ?? todayInitial(userName),
          onOpenProfile: onOpenProfile,
        ),
        const SizedBox(height: 16),
        TodayDayStrip(
          selectedDate: selectedDate,
          today: heute,
          onSelected: onDateSelected,
        ),
        const SizedBox(height: 14),
        TodayCalorieHero(
          consumedKcal: consumedKcal,
          burnedKcal: burnedKcal,
          kcalGoal: profile.dailyKcalGoal,
          streak: streak,
        ),
        const SizedBox(height: 14),
        AppCard(
          key: const ValueKey('today-macros-card'),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionHeading(title: 'Makros', trailing: 'Tagesziele'),
              const SizedBox(height: 14),
              MacroBar(
                label: 'Protein',
                value: macroProgress.proteinG.round(),
                goal: profile.proteinGoalG,
                unit: 'g',
                color: t.protein,
              ),
              MacroBar(
                label: 'Kohlenhydrate',
                value: macroProgress.carbsG.round(),
                goal: profile.carbsGoalG,
                unit: 'g',
                color: t.carbs,
              ),
              MacroBar(
                label: 'Fett',
                value: macroProgress.fatG.round(),
                goal: profile.fatGoalG,
                unit: 'g',
                color: t.fat,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Auf einem Archivtag waere „Heutige Mahlzeiten" schlicht falsch.
        //
        // Ohne das `trailing: 'Manage'` der Vorlage: [SectionHeading]
        // zeichnet dort nur gedaempften Text, keinen Knopf. „Verwalten"
        // saehe aus wie ein Link, waere aber tot — und die Slot-Zeilen
        // darunter fuehren ohnehin schon in den Food-Tab.
        SectionHeading(
          title: istHeute ? 'Heutige Mahlzeiten' : 'Mahlzeiten',
        ),
        const SizedBox(height: 12),
        if (dayLoading)
          const TodayDayLoadingCard()
        else
          TodayMealsCard(meals: meals, onOpenSlot: onOpenMealSlot),
        const SizedBox(height: 14),
        TodayCoachBanner(
          teaser: coachTeaser(
            // Waehrend der Tag noch laedt, ist `meals` leer, OHNE dass der
            // Tag leer waere — „logge deine erste Mahlzeit" waere dann
            // eine Behauptung ueber ungeladene Daten.
            dayIsEmpty: !dayLoading && meals.isEmpty,
            remainingProteinG: restProtein,
            isToday: istHeute,
          ),
          onTap: onOpenCoach,
        ),
      ],
    );
  }
}

class _Kopfzeile extends StatelessWidget {
  const _Kopfzeile({
    required this.eyebrow,
    required this.greeting,
    required this.initial,
    this.onOpenProfile,
  });

  final String eyebrow;
  final String greeting;
  final String initial;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                eyebrow,
                key: const ValueKey('today-eyebrow'),
                style: AppType.eyebrow(t.ink2, size: 10.5),
              ),
              const SizedBox(height: 3),
              Text(
                greeting,
                style: AppType.display(30, color: t.ink, height: 1.1),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          button: true,
          // Umlaut, kein „oe": ein Semantics-Label ist gesprochener Text.
          label: 'Profil öffnen',
          // 14 statt rControl (15): die Vorlage nennt fuer diese 44er-Kachel
          // ausdruecklich 14, und laut Vertrag §3 gewinnt dort die Vorlage.
          child: Material(
            color: t.forest,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              key: const ValueKey('today-profile'),
              borderRadius: BorderRadius.circular(14),
              onTap: onOpenProfile,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  // FittedBox wie beim MealAvatar: die Kachel hat eine feste
                  // Kantenlaenge, der Buchstabe waechst mit der Systemschrift.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      initial,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: t.lime,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
