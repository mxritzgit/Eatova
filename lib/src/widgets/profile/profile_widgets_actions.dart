part of 'profile_widgets.dart';

class HealthConnectionCard extends StatelessWidget {
  const HealthConnectionCard({
    super.key,
    required this.state,
    required this.lastFetch,
    required this.onConnect,
    required this.onRefresh,
    this.healthConnect = false,
    this.syncing = false,
    this.onSettings,
  });

  final HealthAuthState state;
  final DateTime? lastFetch;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;
  final bool healthConnect;
  final bool syncing;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    if (healthConnect) {
      return _HealthConnectCard(
        state: state,
        lastFetch: lastFetch,
        syncing: syncing,
        onConnect: onConnect,
        onRefresh: onRefresh,
        onSettings: onSettings,
      );
    }
    final t = context.t;
    final l10n = context.l10n;
    final isGranted = state == HealthAuthState.granted;
    // Review B3: "connected but no data arrives". Apple reports the permission
    // sheet as success once shown, even if no toggle was flipped, so this state
    // must not look like "granted".
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
            ? l10n.profileHealthSyncedAt(_formatTime(lastFetch!, l10n))
            : l10n.profileHealthConnected
        : isUnverified
            ? l10n.profileHealthUnverifiedHint
            : isDenied
                ? l10n.profileHealthDeniedHint
                : isUnsupported
                    ? l10n.profileHealthUnsupportedHint
                    : l10n.profileHealthSetupHint;
    // "Check" instead of "Connect" once asked: iOS never shows the sheet twice,
    // so the tap re-verifies the signals after a trip to Settings.
    final actionLabel = needsAttention
        ? l10n.profileHealthActionCheck
        : l10n.profileHealthActionConnect;

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
                  // 3 lines so the Settings path stays fully readable in the
                  // unverified/denied case.
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
              semanticLabel: l10n.profileHealthRefreshSemantics,
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

  static String _formatTime(DateTime d, AppLocalizations l10n) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return l10n.profileHealthTimeJustNow;
    if (diff.inMinutes < 60) {
      return l10n.profileHealthTimeMinutesAgo(diff.inMinutes);
    }
    if (diff.inHours < 24) return l10n.profileHealthTimeHoursAgo(diff.inHours);
    return formatShortDate(d, l10n);
  }
}

class _HealthConnectCard extends StatelessWidget {
  const _HealthConnectCard({
    required this.state,
    required this.lastFetch,
    required this.syncing,
    required this.onConnect,
    required this.onRefresh,
    required this.onSettings,
  });

  final HealthAuthState state;
  final DateTime? lastFetch;
  final bool syncing;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final connected =
        state == HealthAuthState.granted || state == HealthAuthState.noData;
    final unavailable =
        state == HealthAuthState.unavailable ||
        state == HealthAuthState.unsupported;
    final subtitle = switch (state) {
      HealthAuthState.granted =>
        lastFetch == null
            ? l10n.healthConnectConnected
            : l10n.profileHealthSyncedAt(
                HealthConnectionCard._formatTime(lastFetch!, l10n),
              ),
      HealthAuthState.noData => l10n.healthConnectNoData,
      HealthAuthState.denied => l10n.healthConnectDenied,
      HealthAuthState.updateRequired => l10n.healthConnectUpdateRequired,
      HealthAuthState.unavailable ||
      HealthAuthState.unsupported => l10n.healthConnectUnavailable,
      HealthAuthState.error => l10n.healthConnectError,
      _ => l10n.healthConnectSetup,
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(
                icon: Icons.directions_walk_rounded,
                color: t.accent,
                size: 44,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  l10n.healthConnectTitle,
                  style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(subtitle, style: AppType.ui(12, color: t.ink2, height: 1.4)),
          const SizedBox(height: 8),
          Text(
            l10n.healthConnectStepsOnly,
            style: AppType.ui(12, color: t.ink2, height: 1.4),
          ),
          if (syncing) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              label: l10n.healthConnectLoading,
              child: LinearProgressIndicator(
                color: t.accent,
                backgroundColor: t.tile,
              ),
            ),
          ],
          if (!unavailable) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: ValueKey(
                    connected
                        ? 'profile-health-refresh'
                        : 'profile-health-connect',
                  ),
                  onPressed: syncing
                      ? null
                      : connected
                      ? onRefresh
                      : onConnect,
                  child: Text(
                    connected
                        ? l10n.healthConnectRefresh
                        : state == HealthAuthState.updateRequired
                        ? l10n.healthConnectInstall
                        : l10n.healthConnectConnect,
                  ),
                ),
                if (onSettings != null &&
                    state != HealthAuthState.updateRequired)
                  TextButton(
                    key: const ValueKey('profile-health-settings'),
                    onPressed: syncing ? null : onSettings,
                    child: Text(l10n.healthConnectSettings),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Small filled button for an action inside a card.
///
/// Not [PrimaryActionButton]: that one is a page's main action (54 px, full
/// width) and would swamp a card row. [buttonKey] sits on the outermost
/// Material so a tap in the middle hits the InkWell.
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

// `ProfileActionsCard` (the "data & account" group) is gone; it duplicated the
// settings page. Its rows now live as `settings-open-goals`, `settings-export`,
// `settings-sign-out`, `settings-delete-account` and `settings-about` (the
// about sheet moved, not deleted — it carries the ODbL attribution and the
// GDPR Art. 13 privacy line); reset-day dropped entirely.
// Settings are reached via `profile-open-settings` and `topbar-settings`, goals
// via `profile-goalplan-edit` / `profile-edit-goals`; pinned by
// `test/settings_erreichbarkeit_test.dart`.
