import 'package:flutter/material.dart';
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
  });

  final String name;
  final UserProfile profile;
  final WeightLog weightLog;
  final LifetimeStats stats;
  final int dailyConsumedKcal;
  final int dailySteps;
  final HealthAuthState healthAuthState;
  final DateTime? healthLastFetch;
  final ValueChanged<double> onLogWeight;

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final streak = stats.effectiveStreakOn(DateTime.now());

    // Keep health data (weight, BMI, history) out of the app-switcher
    // thumbnail (security audit 2026-08-09).
    return SecureScreenGuard(
      child: Scaffold(
        body: SafeArea(
          child: LivelyEntrance(
            // SingleChildScrollView + Column, not a ListView: a ListView only
            // mounts visible children, and several tests reach far-down cards
            // without scrolling first.
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
                  const SizedBox(height: 14),
                  IdentityCard(name: name, profile: profile),
                  const SizedBox(height: 14),
                  ProfileStatRow(
                    left: ProfileStatTile(
                      label: l10n.profileLabelStreak,
                      value: '$streak',
                      unit: l10n.coachStreakUnit(streak),
                    ),
                    right: ProfileStatTile(
                      label: l10n.profileLabelMeals,
                      value: '${stats.mealsLogged}',
                      unit: l10n.profileUnitTotal,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ProfileStatRow(
                    left: ProfileStatTile(
                      label: l10n.profileLabelRecord,
                      value: '${stats.longestStreak}',
                      unit: l10n.coachStreakUnit(stats.longestStreak),
                    ),
                    right: ProfileStatTile(
                      label: l10n.profileLabelWeighIns,
                      value: '${stats.weightLogs}',
                      unit: l10n.profileUnitEntries,
                    ),
                  ),
                  const SizedBox(height: 22),
                  SectionHeading(title: l10n.profileSectionPlan),
                  const SizedBox(height: 12),
                  GoalPlanCard(profile: profile, onEdit: onEditProfile),
                  const SizedBox(height: 22),
                  SectionHeading(title: l10n.profileSectionBody),
                  const SizedBox(height: 12),
                  WeightCard(
                    profile: profile,
                    log: weightLog,
                    onLogWeight: onLogWeight,
                  ),
                  const SizedBox(height: 12),
                  BmiCard(profile: profile, log: weightLog),
                  const SizedBox(height: 22),
                  SectionHeading(title: l10n.profileSectionDailyGoals),
                  const SizedBox(height: 12),
                  GoalsCard(
                    profile: profile,
                    dailyKcal: dailyConsumedKcal,
                    dailySteps: dailySteps,
                    onEdit: onEditProfile,
                  ),
                  const SizedBox(height: 22),
                  SectionHeading(title: l10n.profileSectionConnections),
                  const SizedBox(height: 12),
                  HealthConnectionCard(
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
