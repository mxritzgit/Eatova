import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/ai_trust.dart';
import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/ai_consent_sheet.dart';
import 'settings_studio_widgets.dart';

// ---------------------------------------------------------------------------
// Settings → "AI & data" and "Feedback & support" (review 2026-10-19).
// ---------------------------------------------------------------------------

/// The account's AI consent controller, or null where Settings has none
/// (previews, tests without the app shell, the preview account without
/// sync); the row then drops out like the other rows without a controller.
AiTrustController? settingsAiTrust(BuildContext context) {
  final controller = AiTrustScope.maybeOf(context)?.controller;
  if (controller == null || !controller.consentRequired) return null;
  return controller;
}

/// Consent status with the one action that changes it: withdraw a valid
/// consent, give (or renew) a missing, withdrawn or outdated one.
class SettingsAiConsentRow extends StatelessWidget {
  const SettingsAiConsentRow({super.key, required this.controller});

  final AiTrustController controller;

  String _status(BuildContext context, AppLocalizations l10n) {
    final record = controller.record;
    if (!controller.loaded) return l10n.settingsAiDataConsentLoading;
    if (record == null) return l10n.settingsAiDataConsentNotGiven;
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(record.decidedAt.toLocal());
    if (record.pendingUpload) return l10n.settingsAiDataConsentPending;
    if (!record.granted) return l10n.settingsAiDataConsentWithdrawn(date);
    if (!record.allowsAi) return l10n.settingsAiDataConsentOutdated;
    return l10n.settingsAiDataConsentGiven(date);
  }

  Future<void> _withdraw(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        key: const ValueKey('settings-ai-withdraw-dialog'),
        title: l10n.settingsAiDataWithdrawTitle,
        body: l10n.settingsAiDataWithdrawBody,
        icon: Icons.auto_awesome_outlined,
        destructive: true,
        confirmKey: const ValueKey('settings-ai-withdraw-confirm'),
        confirmLabel: l10n.settingsAiDataWithdrawConfirm,
        cancelKey: const ValueKey('settings-ai-withdraw-cancel'),
        cancelLabel: l10n.commonCancel,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final logged = await controller.withdraw();
    if (!context.mounted) return;
    showAppSnack(
      context,
      logged
          ? l10n.settingsAiDataWithdrawnSnack
          : l10n.settingsAiDataWithdrawnPendingSnack,
      icon: Icons.check_circle_rounded,
    );
  }

  Future<void> _grant(BuildContext context) async {
    final l10n = context.l10n;
    final granted = await showAiConsentSheet(context, controller: controller);
    if (!granted || !context.mounted) return;
    showAppSnack(
      context,
      l10n.settingsAiDataGrantedSnack,
      icon: Icons.check_circle_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final t = context.t;
        final l10n = context.l10n;
        final allows = controller.allowsAi;
        // A pending withdrawal does not block a new grant: the grant logs it
        // first, so the server log keeps the order.
        final VoidCallback? action = !controller.loaded
            ? null
            : allows
            ? () => unawaited(_withdraw(context))
            : !controller.canRecord
            ? null
            : () => unawaited(_grant(context));
        return SettingsStudioRow(
          key: const ValueKey('settings-ai-consent'),
          leading: SettingsRowTile(
            icon: Icons.auto_awesome_outlined,
            tone: allows ? t.accent : null,
          ),
          title: l10n.settingsAiDataConsentTitle,
          subtitle: _status(context, l10n),
          chevron: false,
          trailing: Padding(
            padding: EdgeInsetsDirectional.only(
              start: settingsTileStacked(context) ? 0 : kSettingsTextInset,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey(
                  allows ? 'settings-ai-withdraw' : 'settings-ai-grant',
                ),
                onPressed: action,
                // The sync row's tonal capsule: the section's one action.
                style: TextButton.styleFrom(
                  backgroundColor: allows ? t.tile : t.accentTint,
                  foregroundColor: allows ? t.ink : t.accentText,
                  disabledBackgroundColor: t.tile,
                  disabledForegroundColor: t.ink3,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: const StadiumBorder(),
                  textStyle: AppType.ui(14, weight: FontWeight.w700),
                ),
                child: Text(
                  allows
                      ? l10n.settingsAiDataWithdrawAction
                      : l10n.settingsAiDataGrantAction,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// `mailto:` for "Feedback & support": the address and a subject with app
/// version and build, nothing else; the body is what the user types.
Uri supportMailUri(String subject) =>
    Uri.parse('mailto:$kSupportEmail?subject=${Uri.encodeComponent(subject)}');

/// Opens the mail app on [supportMailUri]. Without one the address is named
/// in a toast instead of the tap doing nothing.
Future<void> openSupportMail(
  BuildContext context, {
  Future<PackageInfo> Function() packageInfo = PackageInfo.fromPlatform,
}) async {
  final l10n = context.l10n;
  var version = '?';
  var build = '?';
  try {
    final info = await packageInfo();
    version = info.version;
    build = info.buildNumber;
  } catch (_) {
    // The subject still names the app; the version stays unknown.
  }
  var opened = false;
  try {
    opened = await launchUrl(
      supportMailUri(l10n.settingsSupportMailSubject(version, build)),
    );
  } catch (_) {
    opened = false;
  }
  if (opened || !context.mounted) return;
  showAppSnack(
    context,
    l10n.settingsSupportMailFailed,
    icon: Icons.mail_outline_rounded,
    tone: SnackTone.warning,
  );
}
