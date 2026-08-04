import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/legal_links.dart';
import '../models/lifetime_stats.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import '../services/health_service.dart';
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/lively.dart';
import '../widgets/profile/profile_widgets.dart';

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
    required this.favoritesCount,
    required this.onLogWeight,
    required this.onEditProfile,
    required this.onResetDay,
    required this.onConnectHealth,
    required this.onRefreshHealth,
    this.onSignOut,
    this.onDeleteAccount,
  });

  final String name;
  final UserProfile profile;
  final WeightLog weightLog;
  final LifetimeStats stats;
  final int dailyConsumedKcal;
  final int dailySteps;
  final HealthAuthState healthAuthState;
  final DateTime? healthLastFetch;
  final int favoritesCount;
  final ValueChanged<double> onLogWeight;
  final VoidCallback onEditProfile;
  final VoidCallback onResetDay;
  final VoidCallback onConnectHealth;
  final VoidCallback onRefreshHealth;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey('profile-close'),
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'Mein Profil',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        top: false,
        child: LivelyEntrance(
          child: SingleChildScrollView(
            key: const ValueKey('screen-profile'),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProfileHero(name: name),
              const SizedBox(height: 14),
              GoalPlanCard(profile: profile, onEdit: onEditProfile),
              const SizedBox(height: 14),
              BodyStatsCard(
                profile: profile,
                log: weightLog,
                onLogWeight: onLogWeight,
              ),
              const SizedBox(height: 14),
              WeightHistoryCard(log: weightLog, accent: lime),
              const SizedBox(height: 14),
              GoalsOverviewCard(
                profile: profile,
                dailyKcal: dailyConsumedKcal,
                dailySteps: dailySteps,
                onEdit: onEditProfile,
              ),
              const SizedBox(height: 14),
              LifetimeStatsCard(stats: stats),
              const SizedBox(height: 14),
              AchievementsGrid(
                stats: stats,
                trackingStreak: stats.effectiveStreakOn(DateTime.now()),
                weightLogs: weightLog.entries.length,
                favoritesCount: favoritesCount,
              ),
              const SizedBox(height: 14),
              HealthConnectionCard(
                state: healthAuthState,
                lastFetch: healthLastFetch,
                onConnect: onConnectHealth,
                onRefresh: onRefreshHealth,
              ),
              const SizedBox(height: 14),
              ProfileActionsCard(
                onEditProfile: onEditProfile,
                onResetDay: () {
                  Navigator.maybePop(context);
                  onResetDay();
                },
                onExport: () => _showExportSheet(context),
                onAbout: () => _showAboutSheet(context),
                onSignOut: onSignOut == null
                    ? null
                    : () async {
                        Navigator.maybePop(context);
                        await onSignOut!.call();
                      },
                onDeleteAccount: onDeleteAccount == null
                    ? null
                    : () => _confirmDeleteAccount(context),
              ),
              const SizedBox(height: 18),
              const _FooterCredit(),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        title: const Text(
          'Konto wirklich löschen?',
          style: TextStyle(color: textPrimary),
        ),
        content: const Text(
          'Dein Account und ALLE Daten (Profil, Mahlzeiten, Gewicht, Schlaf, '
          'Coach-Verlauf) werden unwiderruflich gelöscht. Das lässt sich nicht '
          'rückgängig machen.',
          style: TextStyle(color: textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            key: const ValueKey('confirm-delete-account'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: danger),
            child: const Text('Endgültig löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (context.mounted) Navigator.maybePop(context);
    await onDeleteAccount!.call();
  }

  void _showExportSheet(BuildContext context) {
    final snapshot = _buildSnapshot();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ExportSheet(snapshot: snapshot),
    );
  }

  void _showAboutSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      showDragHandle: true,
      builder: (_) => const _AboutSheet(),
    );
  }

  String _buildSnapshot() {
    final buffer = StringBuffer()
      ..writeln('{')
      ..writeln('  "name": "$name",')
      ..writeln('  "exportedAt": "${DateTime.now().toIso8601String()}",')
      ..writeln('  "profile": {')
      ..writeln('    "weightKg": ${profile.weightKg},')
      ..writeln('    "heightCm": ${profile.heightCm},')
      ..writeln('    "ageYears": ${profile.ageYears},')
      ..writeln('    "kcalGoal": ${profile.dailyKcalGoal},')
      ..writeln('    "waterGoalMl": ${profile.dailyWaterGoalMl},')
      ..writeln('    "stepsGoal": ${profile.dailyStepsGoal},')
      ..writeln('    "sleepGoalMin": ${profile.dailySleepGoalMinutes}')
      ..writeln('  },')
      ..writeln('  "today": {')
      ..writeln('    "kcal": $dailyConsumedKcal,')
      ..writeln('    "steps": $dailySteps')
      ..writeln('  },')
      ..writeln('  "weightLog": [');
    for (var i = 0; i < weightLog.entries.length; i++) {
      final e = weightLog.entries[i];
      buffer.write(
        '    { "ts": "${e.timestamp.toIso8601String()}", "kg": ${e.weightKg} }',
      );
      if (i != weightLog.entries.length - 1) buffer.write(',');
      buffer.writeln();
    }
    buffer
      ..writeln('  ],')
      ..writeln('  "stats": {')
      ..writeln('    "workouts": ${stats.workoutsCompleted},')
      ..writeln('    "meals": ${stats.mealsLogged},')
      ..writeln('    "waterMl": ${stats.waterTotalMl},')
      ..writeln('    "weightLogs": ${stats.weightLogs}')
      ..writeln('  }')
      ..writeln('}');
    return buffer.toString();
  }
}

class _ExportSheet extends StatelessWidget {
  const _ExportSheet({required this.snapshot});

  final String snapshot;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Daten Snapshot',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('profile-export-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: snapshot));
                      if (context.mounted) {
                        showAppSnack(context, 'Snapshot in Zwischenablage',
                            icon: Icons.content_copy_rounded, accent: cyan);
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: const Text(
                      'Kopieren',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: lime,
                      side: BorderSide(color: lime.withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(rControl),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'In-Memory Snapshot deiner aktuellen Session als JSON.',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: surfaceSoft,
                    borderRadius: BorderRadius.circular(rCard),
                    border: Border.all(color: hairline),
                  ),
                  child: SingleChildScrollView(
                    controller: controller,
                    child: SelectableText(
                      snapshot,
                      style: const TextStyle(
                        color: textPrimary,
                        fontSize: 11.5,
                        fontFeatures: [FontFeature.tabularFigures()],
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: lime.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: const Icon(Icons.bolt_rounded, color: lime, size: 22),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Eatova',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'FitnessPlan. Training. Recovery.',
                    style: TextStyle(
                      color: textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Ein moderner Fitness-Coach für klare Pläne, bessere Recovery '
            'und nachhaltigen Fortschritt.',
            style: TextStyle(
              color: textMuted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          const _AboutRow(label: 'Version', value: '1.0.0'),
          const SizedBox(height: 6),
          const _AboutRow(label: 'Build', value: '1'),
          const SizedBox(height: 6),
          const _AboutRow(label: 'Quellen', value: 'OpenFoodFacts · HealthKit · wger'),
          const SizedBox(height: 14),
          // DSGVO Art. 13 / App-Store: Datenschutz auch nach dem Login
          // erreichbar, nicht nur auf dem Auth-Screen.
          const _PrivacyLinkRow(),
        ],
      ),
    );
  }
}

/// Tappbare Datenschutz-Zeile. Oeffnet die Policy extern (url_launcher).
class _PrivacyLinkRow extends StatelessWidget {
  const _PrivacyLinkRow();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('profile-privacy-link'),
      onTap: () => launchUrl(
        Uri.parse(kPrivacyUrl),
        mode: LaunchMode.externalApplication,
      ),
      borderRadius: BorderRadius.circular(rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: hairline),
        ),
        child: Row(
          children: [
            const Icon(Icons.shield_outlined, color: textMuted, size: 16),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Datenschutzerklärung',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.open_in_new_rounded,
              color: textMuted.withValues(alpha: 0.7),
              size: 15,
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _FooterCredit extends StatelessWidget {
  const _FooterCredit();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Eatova · v1.0.0',
        style: TextStyle(
          color: textMuted.withValues(alpha: 0.6),
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
