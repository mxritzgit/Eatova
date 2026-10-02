import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../widgets/common/persistence_action.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/l10n.dart';
import '../models/lifetime_stats.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import '../services/health_service.dart';
import '../services/secure_screen.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/lively.dart';
import '../widgets/design/design.dart';
import '../widgets/profile/profile_widgets.dart';

/// Profile screen: identity, key figures, plan, body, daily goals,
/// connections.
///
/// The former "Daten & Konto" block is gone (user decision 2026-08-10): it
/// duplicated the settings, and "Über Eatova" moved there with its sheet
/// (`settings-about`). Settings are reached via the gear in the header, goals
/// via the edit buttons on the plan and goal cards; both paths are pinned by
/// `test/settings_erreichbarkeit_test.dart`.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.name,
    required this.profile,
    required this.weightLog,
    required this.stats,
    required this.dailyConsumedKcal,
    required this.dailySteps,
    required this.healthAuthState,
    required this.healthLastFetch,
    required this.onLogWeight,
    required this.onEditProfile,
    required this.onOpenSettings,
    required this.onConnectHealth,
    required this.onRefreshHealth,
    this.healthConnect = false,
    this.healthSyncing = false,
    this.onHealthSettings,
  });

  final String name;
  final UserProfile profile;
  final WeightLog weightLog;
  final LifetimeStats stats;
  final int dailyConsumedKcal;

  /// Validated steps for today; null means no current-day measurement.
  final int? dailySteps;
  final HealthAuthState healthAuthState;
  final DateTime? healthLastFetch;
  final PersistValueChanged<double> onLogWeight;

  /// Opens profile and goals (body data, activity, calories). Wired to the
  /// edit buttons of the plan and goal cards (`profile-goalplan-edit`,
  /// `profile-edit-goals`).
  final VoidCallback onEditProfile;

  /// Opens the settings (account, display, data).
  ///
  /// Deliberately separate from [onEditProfile]: both used to share one
  /// callback, so the gear opened the goals instead of the settings.
  final VoidCallback onOpenSettings;
  final VoidCallback onConnectHealth;
  final VoidCallback onRefreshHealth;
  final bool healthConnect;
  final bool healthSyncing;
  final VoidCallback? onHealthSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final t = context.t;
    // Same clock as the Today tab, so both show the same streak.
    final streak = stats.effectiveStreakOn(clock.now());

    // Keep health data (weight, BMI, history) out of the app-switcher
    // thumbnail (security audit 2026-08-09).
    return SecureScreenGuard(
      child: Scaffold(
        body: SafeArea(
          child: LivelyEntrance(
            // SingleChildScrollView + Column, not a ListView: a ListView only
            // mounts visible children, and several tests reach far-down cards
            // without scrolling first.
            child: ReadableWidth(
              child: SingleChildScrollView(
                key: const ValueKey('screen-profile'),
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    PageHeader(
                      title: l10n.profileTitle,
                      backKey: const ValueKey('profile-close'),
                      trailing: SquareIconButton(
                        key: const ValueKey('profile-open-settings'),
                        icon: Icons.settings_outlined,
                        semanticLabel: l10n.foodSemanticsSettings,
                        onTap: onOpenSettings,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Hero: who, what for, and the streak as its display
                    // figure; the lifetime counts follow as quieter tiles.
                    IdentityCard(
                      name: name,
                      profile: profile,
                      stats: ProfileStatRow(
                        left: ProfileStatTile(
                          label: l10n.profileLabelStreak,
                          value: '$streak',
                          count: streak,
                          unit: l10n.coachStreakUnit(streak),
                          icon: Icons.local_fire_department_rounded,
                          tone: t.activityInk,
                          framed: false,
                          large: true,
                        ),
                        right: ProfileStatTile(
                          label: l10n.profileLabelRecord,
                          value: '${stats.longestStreak}',
                          count: stats.longestStreak,
                          unit: l10n.coachStreakUnit(stats.longestStreak),
                          icon: Icons.emoji_events_rounded,
                          tone: t.activityInk,
                          framed: false,
                          large: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ProfileStatRow(
                      gap: 10,
                      left: ProfileStatTile(
                        label: l10n.profileLabelMeals,
                        value: '${stats.mealsLogged}',
                        count: stats.mealsLogged,
                        unit: l10n.profileUnitTotal,
                        icon: Icons.restaurant_rounded,
                      ),
                      right: ProfileStatTile(
                        label: l10n.profileLabelWeighIns,
                        value: '${stats.weightLogs}',
                        count: stats.weightLogs,
                        unit: l10n.profileUnitEntries(stats.weightLogs),
                        icon: Icons.monitor_weight_outlined,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SectionHeading(title: l10n.profileSectionPlan),
                    const SizedBox(height: 12),
                    GoalPlanCard(
                      profile: profile,
                      onEdit: onEditProfile,
                      currentWeightKg: weightLog.planWeightKg(clock.now()),
                    ),
                    const SizedBox(height: 28),
                    SectionHeading(title: l10n.profileSectionBody),
                    const SizedBox(height: 12),
                    WeightCard(
                      profile: profile,
                      log: weightLog,
                      onLogWeight: onLogWeight,
                    ),
                    const SizedBox(height: 10),
                    BmiCard(profile: profile, log: weightLog),
                    const SizedBox(height: 28),
                    SectionHeading(title: l10n.profileSectionDailyGoals),
                    const SizedBox(height: 12),
                    GoalsCard(
                      profile: profile,
                      dailyKcal: dailyConsumedKcal,
                      dailySteps: dailySteps,
                      onEdit: onEditProfile,
                    ),
                    const SizedBox(height: 28),
                    SectionHeading(title: l10n.profileSectionConnections),
                    const SizedBox(height: 12),
                    HealthConnectionCard(
                      healthConnect: healthConnect,
                      syncing: healthSyncing,
                      onSettings: onHealthSettings,
                      state: healthAuthState,
                      lastFetch: healthLastFetch,
                      onConnect: onConnectHealth,
                      onRefresh: onRefreshHealth,
                    ),
                    const SizedBox(height: 22),
                    const _FooterCredit(),
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

final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

class _FooterCredit extends StatelessWidget {
  const _FooterCredit();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The version comes from the pubspec and this is the only place it can be
    // read without a tap. Without data (pending future/test) show only the
    // wordmark.
    return Center(
      child: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final version = snapshot.data?.version;
          return Text(
            version == null ? 'Eatova' : 'Eatova · v$version',
            style: AppType.ui(
              11,
              weight: FontWeight.w500,
              // No extra opacity: `ink2` is already the muted tone at exactly
              // 4.5:1; another 0.7 would push this to 2.55:1 in light mode.
              color: t.ink2,
              letterSpacing: 0.4,
            ),
          );
        },
      ),
    );
  }
}
