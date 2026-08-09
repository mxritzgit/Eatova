import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/legal_links.dart';
import '../models/lifetime_stats.dart';
import '../models/user_profile.dart';
import '../models/weight_log.dart';
import '../services/health_service.dart';
import '../services/secure_screen.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/lively.dart';
import '../widgets/design/design.dart';
import '../widgets/profile/profile_widgets.dart';
import '../widgets/shared/data_export_sheet.dart';

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
    final streak = stats.effectiveStreakOn(DateTime.now());

    // Gesundheitsdaten (Gewicht, BMI, Verlauf) nicht ins App-Switcher-
    // Vorschaubild / Recents-Thumbnail leaken (Sicherheits-Audit 2026-08-09).
    return SecureScreenGuard(
      child: Scaffold(
        body: SafeArea(
          child: LivelyEntrance(
            // Bewusst SingleChildScrollView + Column statt des ListView aus der
            // Design-Vorlage: ein ListView mountet nur die sichtbaren Kinder,
            // und mehrere Tests greifen ohne vorheriges Scrollen auf weit unten
            // liegende Karten zu (Schritte-Wert, Health-Refresh, Export-Zeile).
            child: SingleChildScrollView(
              key: const ValueKey('screen-profile'),
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  PageHeader(
                    title: 'Mein Profil',
                    backKey: const ValueKey('profile-close'),
                    // Das Zahnrad ruft denselben Callback wie die Zeile
                    // „Profil & Ziele" — die Schale entscheidet, ob daraus ein
                    // Sheet oder eine Route wird.
                    trailing: SquareIconButton(
                      key: const ValueKey('profile-open-settings'),
                      icon: Icons.settings_outlined,
                      semanticLabel: 'Einstellungen',
                      onTap: onEditProfile,
                    ),
                  ),
                  const SizedBox(height: 14),
                  IdentityCard(name: name, profile: profile),
                  const SizedBox(height: 14),
                  ProfileStatRow(
                    left: ProfileStatTile(
                      label: 'STREAK',
                      value: '$streak',
                      unit: streak == 1 ? 'Tag' : 'Tage',
                    ),
                    right: ProfileStatTile(
                      label: 'MAHLZEITEN',
                      value: '${stats.mealsLogged}',
                      unit: 'gesamt',
                    ),
                  ),
                  const SizedBox(height: 12),
                  ProfileStatRow(
                    left: ProfileStatTile(
                      label: 'REKORD',
                      value: '${stats.longestStreak}',
                      unit: stats.longestStreak == 1 ? 'Tag' : 'Tage',
                    ),
                    right: ProfileStatTile(
                      label: 'WIEGEN',
                      value: '${stats.weightLogs}',
                      unit: 'Einträge',
                    ),
                  ),
                  const SizedBox(height: 22),
                  const SectionHeading(title: 'Dein Plan'),
                  const SizedBox(height: 12),
                  GoalPlanCard(profile: profile, onEdit: onEditProfile),
                  const SizedBox(height: 22),
                  const SectionHeading(title: 'Körper'),
                  const SizedBox(height: 12),
                  WeightCard(
                    profile: profile,
                    log: weightLog,
                    onLogWeight: onLogWeight,
                  ),
                  const SizedBox(height: 12),
                  BmiCard(profile: profile, log: weightLog),
                  const SizedBox(height: 22),
                  const SectionHeading(title: 'Tagesziele'),
                  const SizedBox(height: 12),
                  GoalsCard(
                    profile: profile,
                    dailyKcal: dailyConsumedKcal,
                    dailySteps: dailySteps,
                    onEdit: onEditProfile,
                  ),
                  const SizedBox(height: 22),
                  SectionHeading(
                    title: 'Fortschritt',
                    trailing: formatSessionDuration(stats.sessionDuration),
                  ),
                  const SizedBox(height: 12),
                  AchievementsGrid(
                    stats: stats,
                    trackingStreak: streak,
                    weightLogs: weightLog.entries.length,
                    favoritesCount: favoritesCount,
                  ),
                  const SizedBox(height: 22),
                  const SectionHeading(title: 'Verbindungen'),
                  const SizedBox(height: 12),
                  HealthConnectionCard(
                    state: healthAuthState,
                    lastFetch: healthLastFetch,
                    onConnect: onConnectHealth,
                    onRefresh: onRefreshHealth,
                  ),
                  const SizedBox(height: 22),
                  // Jeder andere Block traegt seine Abschnittszeile; ohne
                  // diese stuenden Export, Ausloggen und „Konto löschen" als
                  // einzige Gruppe unbeschriftet da.
                  const SectionHeading(title: 'Daten & Konto'),
                  const SizedBox(height: 12),
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
      ),
    );
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Konto wirklich löschen?'),
        content: const Text(
          'Dein Account und ALLE Daten (Profil, Mahlzeiten, Gewicht, Schlaf, '
          'Coach-Verlauf) werden unwiderruflich gelöscht. Das lässt sich nicht '
          'rückgängig machen.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            key: const ValueKey('confirm-delete-account'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: t.danger),
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
    // Ein Sheet fuer beide Einstiege (Profil und Einstellungen) — es lag
    // sonst zweimal im Baum und waere auseinandergelaufen.
    //
    // Mit Sync kommt die vollstaendige Server-Auskunft; ohne (Preview) bleibt
    // der Session-Snapshot. Der Fallback deckt zusaetzlich den Offline-Fall
    // ab — dann sagt das Sheet ehrlich, dass es nur die Session zeigt.
    showDataExportSheet(
      context,
      snapshot: () => voll != null ? voll() : Future.value(_buildSnapshot()),
      fallbackSnapshot: _buildSnapshot(),
      vollstaendig: voll != null,
    );
  }

  void _showAboutSheet(BuildContext context) {
    showEatovaSheet<void>(context, const _AboutSheet());
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
    final t = context.t;
    // Scrollbar statt starr: bei doppelter Systemschrift ist der Block aus
    // Beschreibung, Version, Build, Quellen und Datenschutz-Zeile hoeher als
    // der Bildschirm (gemessen: 251 px Ueberlauf). Der Datenschutz-Link steht
    // ganz unten — genau der Teil, der nie abgeschnitten werden darf.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(
                icon: Icons.bolt_rounded,
                color: t.accent,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Eatova', style: AppType.display(20, color: t.ink)),
                    const SizedBox(height: 2),
                    Text(
                      'Ernährung. Tracking. Coach.',
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Kalorien und Makros ohne Reibung tracken — per KI-Foto-Scan, '
            'Barcode und Produktsuche, mit einem persönlichen Ernährungs-Coach.',
            style: AppType.ui(13, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              final info = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
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
    final t = context.t;
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
          color: t.surf,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: t.line),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, color: t.ink2, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Datenschutzerklärung',
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
              ),
            ),
            Icon(Icons.open_in_new_rounded, color: t.ink2, size: 15),
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
    final t = context.t;
    return Row(
      children: <Widget>[
        Text(
          label,
          style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
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
    final t = context.t;
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
            style: AppType.ui(
              11,
              weight: FontWeight.w500,
              // Ohne Zusatz-Transparenz: `ink2` ist bereits der gedaempfte
              // Ton und exakt auf 4.5:1 ausgelegt. Ein weiteres 0.7 druecken
              // die Versionszeile im Hell-Modus auf 2.55:1 — das ist normaler
              // Text, kein deaktiviertes Bedienelement, also ohne Ausnahme.
              color: t.ink2,
              letterSpacing: 0.4,
            ),
          );
        },
      ),
    );
  }
}
