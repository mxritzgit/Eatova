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

    final action = isGranted
        ? SquareIconButton(
            key: const ValueKey('profile-health-refresh'),
            icon: Icons.sync_rounded,
            semanticLabel: l10n.profileHealthRefreshSemantics,
            onTap: onRefresh,
          )
        : isUnsupported
        ? null
        : _CompactButton(
            buttonKey: const ValueKey('profile-health-connect'),
            label: actionLabel,
            onTap: onConnect,
          );
    // Short states sit as a status line under the name; the two repair
    // hints are sentences and get the full card width below.
    final longHint = needsAttention;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(
                icon: isGranted
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: color,
                size: 42,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Apple Health',
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    if (!longHint) ...[
                      const SizedBox(height: 3),
                      _StatusLine(
                        text: subtitle,
                        color: isGranted ? t.accentText : t.ink2,
                      ),
                    ],
                  ],
                ),
              ),
              if (isGranted) ...[const SizedBox(width: 8), action!],
            ],
          ),
          if (longHint) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                subtitle,
                style: AppType.ui(
                  13,
                  color: needsAttention ? color : t.ink2,
                  height: 1.45,
                ),
              ),
            ),
          ],
          if (!isGranted && action != null) ...[
            const SizedBox(height: 14),
            Padding(padding: const EdgeInsets.only(right: 4), child: action),
          ],
        ],
      ),
    );
  }

  static String _formatTime(DateTime d, AppLocalizations l10n) {
    final now = clock.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return l10n.profileHealthTimeJustNow;
    if (diff.inMinutes < 60) {
      return l10n.profileHealthTimeMinutesAgo(diff.inMinutes);
    }
    if (diff.inHours < 24) return l10n.profileHealthTimeHoursAgo(diff.inHours);
    return formatShortDate(d, l10n);
  }
}

/// Tinted capsule for the Health Connect actions; [quiet] for the secondary
/// one. 48 px tall like every touch target on the page.
ButtonStyle _pillStyle(AppTokens t, {bool quiet = false}) =>
    TextButton.styleFrom(
      backgroundColor: quiet ? t.surf2 : t.accentTint,
      foregroundColor: quiet ? t.inkSoft : t.accentText,
      disabledBackgroundColor: t.tile,
      disabledForegroundColor: t.inkDisabled,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: AppType.ui(14, weight: FontWeight.w700),
    );

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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(
                icon: Icons.directions_walk_rounded,
                color: connected ? t.accent : t.ink2,
                size: 42,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.healthConnectTitle,
                      style: AppType.ui(
                        15,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _StatusLine(
                      text: subtitle,
                      color: connected ? t.accentText : t.ink2,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.healthConnectStepsOnly,
            style: AppType.ui(12.5, color: t.ink2, height: 1.45),
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
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: ValueKey(
                    connected
                        ? 'profile-health-refresh'
                        : 'profile-health-connect',
                  ),
                  style: _pillStyle(t),
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
                    style: _pillStyle(t, quiet: true),
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

/// The connect/check action inside the health card: a full-width tinted
/// capsule, quieter than the page's primary "Log weight".
///
/// [buttonKey] sits on the outermost Material so a tap in the middle hits the
/// InkWell.
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
    return Semantics(
      button: true,
      child: PressScale(
        child: Material(
          key: buttonKey,
          color: t.accentTint,
          borderRadius: BorderRadius.circular(rButton),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(rButton),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Center(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      14,
                      weight: FontWeight.w700,
                      color: t.accentText,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A status dot and its line ("Synced · 12 min ago").
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // The dot rides inline, so it stays on the first line when the status
    // wraps at large text.
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 7),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ),
          TextSpan(text: text),
        ],
      ),
      style: AppType.ui(12.5, weight: FontWeight.w500, color: color),
    );
  }
}

// `ProfileActionsCard` (the "data & account" group) is gone; it duplicated the
// settings page. Its rows now live as `settings-open-goals`, `settings-export`,
// `settings-sign-out`, `settings-delete-account` and `settings-about` (the
// about sheet moved, not deleted — it carries the ODbL attribution and the
// GDPR Art. 13 privacy line); reset-day dropped entirely.
// Settings are reached via `profile-open-settings` and `today-settings`, goals
// via `profile-goalplan-edit` / `profile-edit-goals`; pinned by
// `test/settings_erreichbarkeit_test.dart`.
