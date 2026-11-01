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
    this.weightImport,
    this.onWeightImportChanged,
  });

  final HealthAuthState state;
  final DateTime? lastFetch;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;
  final bool healthConnect;
  final bool syncing;
  final VoidCallback? onSettings;

  /// The scale import's switch (review 2026-10-22); null hides it.
  final bool? weightImport;
  final ValueChanged<bool>? onWeightImportChanged;

  /// The switch row, when it applies.
  Widget? get _weightImportRow {
    final value = weightImport;
    final onChanged = onWeightImportChanged;
    if (value == null || onChanged == null) return null;
    return _WeightImportRow(value: value, onChanged: onChanged);
  }

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
        weightImportRow: _weightImportRow,
      );
    }
    final weightImportRow = _weightImportRow;
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
        ? _CardActionButton(
            key: const ValueKey('profile-health-refresh'),
            icon: AppIcons.sync,
            tooltip: l10n.profileHealthRefreshSemantics,
            onTap: onRefresh,
          )
        : isUnsupported
        ? null
        // The card's own action, quieter than the page's lit "Log weight".
        : SoftPillButton(
            key: const ValueKey('profile-health-connect'),
            label: actionLabel,
            expand: true,
            onTap: onConnect,
          );
    // Short states sit as a status line under the name; the two repair
    // hints are sentences and get the full card width below.
    final longHint = needsAttention;
    // The header action's disc ends on the card's 18 px content edge, as on
    // the plan and body cards; its 44 px target reaches 4 px past it.
    return AppCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Filled while connected: the heart carries the state.
              IconBadge(
                color: color,
                size: IconBadgeSize.lg,
                child: StateIcon(AppIcons.favorite, on: isGranted),
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
          if (weightImportRow != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: weightImportRow,
            ),
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

class _HealthConnectCard extends StatelessWidget {
  const _HealthConnectCard({
    required this.state,
    required this.lastFetch,
    required this.syncing,
    required this.onConnect,
    required this.onRefresh,
    required this.onSettings,
    this.weightImportRow,
  });

  final HealthAuthState state;
  final DateTime? lastFetch;
  final bool syncing;
  final VoidCallback onConnect;
  final VoidCallback onRefresh;
  final VoidCallback? onSettings;
  final Widget? weightImportRow;

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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Steps are the app's footprint, not a walking figure.
              IconBadge(
                color: connected ? t.accent : t.ink2,
                size: IconBadgeSize.lg,
                child: const StepsIcon(),
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
            l10n.healthConnectStepsAndWeight,
            style: AppType.subhead(t.ink2),
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
                // The card's action as the secondary capsule; the settings
                // way out in the quiet tone beside it.
                SoftPillButton(
                  key: ValueKey(
                    connected
                        ? 'profile-health-refresh'
                        : 'profile-health-connect',
                  ),
                  label: connected
                      ? l10n.healthConnectRefresh
                      : state == HealthAuthState.updateRequired
                      ? l10n.healthConnectInstall
                      : l10n.healthConnectConnect,
                  onTap: syncing
                      ? null
                      : connected
                      ? onRefresh
                      : onConnect,
                ),
                if (onSettings != null &&
                    state != HealthAuthState.updateRequired)
                  SoftPillButton(
                    key: const ValueKey('profile-health-settings'),
                    label: l10n.healthConnectSettings,
                    tone: SoftPillTone.quiet,
                    onTap: syncing ? null : onSettings,
                  ),
              ],
            ),
          ],
          if (weightImportRow != null) ...[
            const SizedBox(height: 12),
            weightImportRow!,
          ],
        ],
      ),
    );
  }
}

/// The scale import's switch in the health card (review 2026-10-22): the
/// whole row toggles, and one merged node announces label and state.
class _WeightImportRow extends StatelessWidget {
  const _WeightImportRow({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MergeSemantics(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('profile-health-weight-import'),
          borderRadius: BorderRadius.circular(rTile),
          onTap: () => onChanged(!value),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.healthWeightImportSwitch,
                  style: AppType.ui(
                    14,
                    weight: FontWeight.w600,
                    color: t.ink,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              AppToggle(value: value, onChanged: onChanged),
            ],
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
    final style = AppType.ui(13, weight: FontWeight.w500, color: color);
    // The dot sits on the first line's centre, also when the status wraps
    // at large text; the text stays its own Text widget.
    final lineHeight = MediaQuery.textScalerOf(context).scale(13) * 1.25;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.only(top: (lineHeight - 7) / 2, right: 7),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
        Flexible(child: Text(text, style: style.copyWith(height: 1.25))),
      ],
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
