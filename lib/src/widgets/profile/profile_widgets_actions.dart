part of 'profile_widgets.dart';

class HealthConnectionCard extends StatelessWidget {
  const HealthConnectionCard({
    super.key,
    required this.state,
    required this.lastFetch,
    required this.onConnect,
    required this.onRefresh,
  });

  final HealthAuthState state;
  final DateTime? lastFetch;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isGranted = state == HealthAuthState.granted;
    // Review B3: „verbunden, aber es kommen keine Daten". Apple meldet das
    // Berechtigungs-Sheet als Erfolg, sobald es angezeigt wurde — auch wenn der
    // Nutzer keinen Schalter umgelegt hat. Dieser Zustand darf deshalb NICHT
    // wie „granted" aussehen, sondern muss zur richtigen Handlung führen.
    final isUnverified = state == HealthAuthState.unverified;
    final isDenied = state == HealthAuthState.denied;
    final isUnsupported = state == HealthAuthState.unsupported;
    final needsAttention = isUnverified || isDenied;
    final color = isGranted
        ? t.accent
        : needsAttention
            ? t.warning
            : t.ink2;
    final subtitle = isGranted
        ? lastFetch != null
            ? 'Synchronisiert · ${_formatTime(lastFetch!)}'
            : 'Verbunden'
        : isUnverified
            ? 'Keine Daten — in Einstellungen › Health › Datenzugriff & '
                'Geräte › Eatova alle Kategorien einschalten'
            : isDenied
                ? 'Zugriff entzogen — in Einstellungen › Health › Datenzugriff '
                    '& Geräte › Eatova wieder freigeben'
                : isUnsupported
                    ? 'Auf diesem Gerät nicht aktiv'
                    : 'Apple Health einrichten';
    // „Prüfen" statt „Verbinden", sobald wir schon einmal gefragt haben: iOS
    // zeigt das Sheet kein zweites Mal, der Tap re-verifiziert stattdessen die
    // Signale — genau das, was nach einem Besuch in den Einstellungen zählt.
    final actionLabel = needsAttention ? 'Prüfen' : 'Verbinden';

    return AppCard(
      child: Row(
        children: <Widget>[
          IconTile(
            icon:
                isGranted ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: color,
            size: 44,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Apple Health',
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  // 3 Zeilen, weil der Einstellungs-Pfad im unverifizierten /
                  // entzogenen Fall vollständig lesbar bleiben muss.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: color,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (isGranted)
            SquareIconButton(
              key: const ValueKey('profile-health-refresh'),
              icon: Icons.sync_rounded,
              semanticLabel: 'Aktualisieren',
              onTap: onRefresh,
            )
          else if (!isUnsupported)
            _CompactButton(
              buttonKey: const ValueKey('profile-health-connect'),
              label: actionLabel,
              onTap: onConnect,
            ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'gerade eben';
    if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min';
    if (diff.inHours < 24) return 'vor ${diff.inHours}h';
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.';
  }
}

/// Kleiner, gefuellter Knopf fuer eine Aktion IN einer Karte.
///
/// Bewusst nicht [PrimaryActionButton]: der ist die Hauptaktion einer Seite
/// (54 px hoch, volle Breite) und wuerde eine Karten-Zeile erschlagen. Der Key
/// wandert als [buttonKey] auf das aeusserste Material, damit ein Tap in der
/// Mitte den InkWell trifft.
class _CompactButton extends StatelessWidget {
  const _CompactButton({
    required this.buttonKey,
    required this.label,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      key: buttonKey,
      color: t.forest,
      borderRadius: BorderRadius.circular(rChip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rChip),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(
            label,
            style:
                AppType.ui(12, weight: FontWeight.w700, color: t.onForest),
          ),
        ),
      ),
    );
  }
}

// Hier stand bis 2026-08-10 `ProfileActionsCard` — die Gruppe „Daten & Konto"
// mit sechs Zeilen (`profile-action-edit/-reset/-export/-about/-logout/
// -delete`). Sie ist auf Nutzer-Entscheid entfallen, weil sie die Einstellungen
// doppelte:
//
//   * „Profil & Ziele"     -> `settings-open-goals`
//   * „Daten exportieren"  -> `settings-export`
//   * „Ausloggen"          -> `settings-sign-out`
//   * „Konto löschen"      -> `settings-delete-account`
//   * „Über Eatova"        -> `settings-about` (samt Sheet UMGEZOGEN, nicht
//                             geloescht: es traegt die ODbL-Quellennennung
//                             und die Datenschutz-Zeile nach DSGVO Art. 13)
//   * „Tagesdaten zurücksetzen" -> ersatzlos entfallen, mitsamt
//                             `HomeStore.resetTodayData` und
//                             `settings-reset-day`.
//
// Die Wege in die Einstellungen fuehren jetzt ueber das Zahnrad im Profil-Kopf
// (`profile-open-settings`) und den Food-Kopf (`topbar-settings`); die Wege zu
// den Zielen ueber `profile-goalplan-edit` und `profile-edit-goals`. Beides
// haelt `test/settings_erreichbarkeit_test.dart` fest.
