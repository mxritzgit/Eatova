import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
    this.onBuildFullExport,
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

  /// Liefert die VOLLSTAENDIGE Datenauskunft als JSON (DataExportService,
  /// direkt aus den Server-Tabellen). `null` im Preview-Betrieb ohne Sync —
  /// dann zeigt das Export-Sheet weiterhin nur den Session-Snapshot und
  /// sagt das auch (C7).
  final Future<String> Function()? onBuildFullExport;

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
    final voll = onBuildFullExport;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ExportSheet(
        // Mit Sync kommt die vollstaendige Server-Auskunft; ohne (Preview)
        // bleibt der Session-Snapshot. Der Fallback deckt zusaetzlich den
        // Offline-Fall ab — dann sagt das Sheet ehrlich, dass es nur die
        // Session zeigt.
        snapshot: voll != null ? voll() : Future.value(_buildSnapshot()),
        fallbackSnapshot: _buildSnapshot(),
        vollstaendig: voll != null,
      ),
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
      // C7: "workouts" und "waterMl" sind seit a267e15 tote Zaehler — ihre
      // Mutatoren wurden mit dem Training- und dem Heute-Tab entfernt, sie
      // stehen dauerhaft auf 0. Ein Export, der dem Nutzer "0 Trainings"
      // meldet, behauptet etwas ueber ein Feature, das es nicht gibt.
      // Die Spalten bleiben in der DB und im Modell (Wire-Kompatibilitaet),
      // nur der Export liest sie nicht mehr.
      ..writeln('    "meals": ${stats.mealsLogged},')
      ..writeln('    "weightLogs": ${stats.weightLogs}')
      ..writeln('  }')
      ..writeln('}');
    return buffer.toString();
  }
}

class _ExportSheet extends StatelessWidget {
  const _ExportSheet({
    required this.snapshot,
    required this.fallbackSnapshot,
    required this.vollstaendig,
  });

  /// Die (asynchron geladene) Auskunft — mit Sync die vollstaendige
  /// Server-Kopie, ohne der Session-Snapshot als bereits erfuellte Future.
  final Future<String> snapshot;

  /// Wird gezeigt, wenn [snapshot] fehlschlaegt (offline) — zusammen mit
  /// einem Hinweis, dass es sich dann NUR um die Session handelt.
  final String fallbackSnapshot;

  final bool vollstaendig;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return FutureBuilder<String>(
          future: snapshot,
          builder: (context, snap) {
            final laedt = snap.connectionState != ConnectionState.done;
            final fehler = snap.hasError;
            final text = snap.data ?? fallbackSnapshot;
            final untertitel = laedt
                ? 'Deine Daten werden vom Server geladen …'
                : fehler
                    ? 'Server nicht erreichbar — das hier ist nur der '
                        'Teil-Snapshot deiner aktuellen Session. Für die '
                        'vollständige Kopie bitte mit Internet erneut öffnen.'
                    : vollstaendig
                        ? 'Vollständige Kopie deiner gespeicherten Daten als '
                            'JSON — alle Tabellen, direkt vom Server geladen '
                            '(Art. 15/20 DSGVO).'
                        : 'In-Memory Snapshot deiner aktuellen Session als '
                            'JSON.';
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          vollstaendig ? 'Datenauskunft' : 'Daten Snapshot',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('profile-export-copy'),
                        onPressed: laedt
                            ? null
                            : () async {
                                await Clipboard.setData(
                                    ClipboardData(text: text));
                                if (context.mounted) {
                                  showAppSnack(
                                      context, 'Export in Zwischenablage',
                                      icon: Icons.content_copy_rounded,
                                      accent: cyan);
                                }
                              },
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text(
                          'Kopieren',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
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
                  Text(
                    untertitel,
                    style: const TextStyle(
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
                      child: laedt
                          ? const Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5),
                              ),
                            )
                          : SingleChildScrollView(
                              controller: controller,
                              child: SelectableText(
                                text,
                                style: const TextStyle(
                                  color: textPrimary,
                                  fontSize: 11.5,
                                  fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ],
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
      },
    );
  }
}

/// App-Metadaten zur Laufzeit (Version/Build aus pubspec via Plattform-API)
/// statt hartkodierter Strings, die beim Version-Bump auseinanderlaufen.
/// Lazy top-level Future: wird erst beim ersten Oeffnen des Ueber-Sheets
/// angefragt und danach wiederverwendet. In Widget-Tests (Channel nicht
/// gemockt) schlaegt die Future fehl — die UI faellt dann auf '—' zurueck.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  /// Datenquellen ehrlich + plattformgerecht: Produktdaten kommen aus
  /// OpenFoodFacts bzw. dem eigenen Suchindex; Schritte liefert Apple Health
  /// (nur iOS — auf Android ist der Health-Pfad ein No-op, also dort nicht
  /// nennen). "wger" war nie angebunden und ist raus.
  static String get _sources {
    const base = 'OpenFoodFacts · Eigener Suchindex';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return '$base · Apple Health';
    }
    return base;
  }

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
                    'Ernährung. Tracking. Coach.',
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
            'Kalorien und Makros ohne Reibung tracken — per KI-Foto-Scan, '
            'Barcode und Produktsuche, mit einem persönlichen Ernährungs-Coach.',
            style: TextStyle(
              color: textMuted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              final info = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AboutRow(label: 'Version', value: info?.version ?? '—'),
                  const SizedBox(height: 6),
                  _AboutRow(label: 'Build', value: info?.buildNumber ?? '—'),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          _AboutRow(label: 'Quellen', value: _sources),
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
    // Gleiche PackageInfo-Future wie das Ueber-Sheet: kein zweiter
    // Plattform-Roundtrip, und die Versionsnummer kann nie mehr von der
    // pubspec abweichen. Ohne Daten (laufende Future/Test) nur die Wortmarke.
    return Center(
      child: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final version = snapshot.data?.version;
          return Text(
            version == null ? 'Eatova' : 'Eatova · v$version',
            style: TextStyle(
              color: textMuted.withValues(alpha: 0.6),
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
            ),
          );
        },
      ),
    );
  }
}
