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

/// „Mein Profil" — Identitaet, Kennzahlen, Plan, Koerper, Tagesziele,
/// Verbindungen.
///
/// **Was hier bewusst NICHT mehr steht** (Nutzer-Entscheid 2026-08-10): der
/// Block „Daten & Konto". Seine sechs Zeilen doppelten die Einstellungen —
/// „Profil & Ziele", „Daten exportieren", „Ausloggen" und „Konto löschen"
/// stehen dort unveraendert (`settings-open-goals`, `settings-export`,
/// `settings-sign-out`, `settings-delete-account`), „Über Eatova" ist mit
/// seinem Sheet dorthin UMGEZOGEN (`settings-about`, samt der ODbL-Quellen-
/// nennung und der Datenschutz-Zeile nach DSGVO Art. 13), und „Tagesdaten
/// zurücksetzen" ist ersatzlos entfallen.
///
/// Der Weg in die Einstellungen ist das Zahnrad im Kopf; der Weg zu den Zielen
/// sind die Bearbeiten-Knoepfe an Plan- und Zielkarte. Beide Wege sind in
/// `test/settings_erreichbarkeit_test.dart` festgenagelt.
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

  /// Fuehrt auf „Profil & Ziele" — Koerperdaten, Aktivitaet, Kalorien.
  /// Haengt an den Bearbeiten-Knoepfen der Plan- und der Zielkarte
  /// (`profile-goalplan-edit`, `profile-edit-goals`).
  final VoidCallback onEditProfile;

  /// Fuehrt auf die Einstellungen (Konto, Anzeige, Daten).
  ///
  /// Bewusst getrennt von [onEditProfile]: Bis 2026-08-10 lagen beide
  /// auf demselben Callback. Das Zahnrad hier trug die Beschriftung
  /// „Einstellungen", oeffnete aber die Ziele — und die Einstellungen
  /// waren nur ueber ein Schieberegler-Symbol im Food-Kopf erreichbar.
  /// Ein Zahnrad, das nicht in die Einstellungen fuehrt, ist ein Fehler,
  /// kein Geschmack.
  final VoidCallback onOpenSettings;
  final VoidCallback onConnectHealth;
  final VoidCallback onRefreshHealth;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
            // liegende Karten zu (Schritte-Wert, Health-Refresh).
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
    // Die Versionsnummer kann nie von der pubspec abweichen — und seit dem
    // Umzug von „Über Eatova" in die Einstellungen ist das die einzige Stelle,
    // an der sie OHNE Tipp ablesbar ist. Ohne Daten (laufende Future/Test) nur
    // die Wortmarke.
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
