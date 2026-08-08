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
        ? lime
        : needsAttention
            ? orange
            : textMuted;
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
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(rControl),
            ),
            child: Icon(
              isGranted ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: color,
              size: 19,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Apple Health',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  // 3 Zeilen, weil der Einstellungs-Pfad im unverifizierten /
                  // entzogenen Fall vollständig lesbar bleiben muss.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (isGranted)
            IconButton(
              key: const ValueKey('profile-health-refresh'),
              onPressed: onRefresh,
              tooltip: 'Aktualisieren',
              icon: const Icon(
                Icons.sync_rounded,
                color: textMuted,
                size: 20,
              ),
            )
          else if (!isUnsupported)
            FilledButton(
              key: const ValueKey('profile-health-connect'),
              onPressed: onConnect,
              style: FilledButton.styleFrom(
                backgroundColor: lime,
                foregroundColor: bg,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.';
  }
}

class ProfileActionsCard extends StatelessWidget {
  const ProfileActionsCard({
    super.key,
    required this.onEditProfile,
    required this.onResetDay,
    required this.onExport,
    required this.onAbout,
    this.onSignOut,
    this.onDeleteAccount,
  });

  final VoidCallback onEditProfile;
  final VoidCallback onResetDay;
  final VoidCallback onExport;
  final VoidCallback onAbout;
  final VoidCallback? onSignOut;
  final VoidCallback? onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          _ActionRow(
            icon: Icons.tune_rounded,
            color: lime,
            title: 'Profil & Ziele',
            subtitle: 'Körper, Schritte, Kcal, Schlaf',
            onTap: onEditProfile,
            keyValue: const ValueKey('profile-action-edit'),
          ),
          const _Divider(),
          _ActionRow(
            icon: Icons.restart_alt_rounded,
            color: orange,
            title: 'Tagesdaten zurücksetzen',
            subtitle: 'Heute neu starten',
            onTap: onResetDay,
            keyValue: const ValueKey('profile-action-reset'),
          ),
          const _Divider(),
          _ActionRow(
            icon: Icons.ios_share_rounded,
            color: cyan,
            title: 'Daten exportieren',
            subtitle: 'JSON Snapshot',
            onTap: onExport,
            keyValue: const ValueKey('profile-action-export'),
          ),
          const _Divider(),
          _ActionRow(
            icon: Icons.info_outline_rounded,
            color: textMuted,
            title: 'Über Eatova',
            subtitle: 'Version & Mitwirkende',
            onTap: onAbout,
            keyValue: const ValueKey('profile-action-about'),
          ),
          if (onSignOut != null) ...[
            const _Divider(),
            _ActionRow(
              icon: Icons.logout_rounded,
              color: danger,
              title: 'Ausloggen',
              subtitle: 'Zurück zum Login',
              onTap: onSignOut!,
              keyValue: const ValueKey('profile-action-logout'),
            ),
          ],
          if (onDeleteAccount != null) ...[
            const _Divider(),
            _ActionRow(
              icon: Icons.delete_forever_rounded,
              color: danger,
              title: 'Konto löschen',
              subtitle: 'Account + alle Daten unwiderruflich',
              onTap: onDeleteAccount!,
              keyValue: const ValueKey('profile-action-delete'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.keyValue,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Key keyValue;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: keyValue,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: textMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: hairline,
    );
  }
}
