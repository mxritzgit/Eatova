import 'package:flutter/material.dart';

import '../../app/ai_trust.dart';
import '../../l10n/l10n.dart';
import '../../models/ai_consent.dart';
import '../../services/ai_trust_sync.dart' show isReportableMessageId;
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../design/design.dart';

/// "Report answer" for Coach output (Google Play's AI-content rule, review
/// 2026-10-19): a reason sheet, then one row in `ai_reports` with the
/// message id and the reason code. The message text never leaves the device
/// for this. A toast confirms; a failure says so and keeps nothing pending.
Future<void> reportAiOutput(
  BuildContext context, {
  required String messageId,
  String? sessionId,
  AiReportTarget target = AiReportTarget.answer,
}) async {
  final l10n = context.l10n;
  final controller = AiTrustScope.maybeOf(context)?.controller;
  if (controller == null ||
      !controller.canReport ||
      !isReportableMessageId(messageId)) {
    showAppSnack(
      context,
      l10n.coachReportFailed,
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
    return;
  }
  final reported = await showEatovaSheet<bool>(
    context,
    AiReportSheet(
      target: target,
      onSubmit: (reason) => controller.report(
        messageId: messageId,
        sessionId: sessionId,
        target: target,
        reason: reason,
      ),
    ),
  );
  if (reported != true || !context.mounted) return;
  showAppSnack(
    context,
    target == AiReportTarget.recipeImage
        ? l10n.coachReportImageDone
        : l10n.coachReportDone,
    icon: Icons.flag_outlined,
  );
}

/// The reasons as single-choice cards and one submit action. Pops true once
/// [onSubmit] succeeded; a failure stays in the sheet with a retry.
class AiReportSheet extends StatefulWidget {
  const AiReportSheet({
    super.key,
    required this.target,
    required this.onSubmit,
  });

  final AiReportTarget target;
  final Future<void> Function(AiReportReason reason) onSubmit;

  @override
  State<AiReportSheet> createState() => _AiReportSheetState();
}

class _AiReportSheetState extends State<AiReportSheet> {
  AiReportReason? _reason;
  bool _sending = false;
  bool _failed = false;

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() {
      _sending = true;
      _failed = false;
    });
    try {
      await widget.onSubmit(reason);
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  static String _label(AppLocalizations l10n, AiReportReason reason) =>
      switch (reason) {
        AiReportReason.incorrect => l10n.coachReportReasonIncorrect,
        AiReportReason.harmful => l10n.coachReportReasonHarmful,
        AiReportReason.inappropriate => l10n.coachReportReasonInappropriate,
        AiReportReason.other => l10n.coachReportReasonOther,
      };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final image = widget.target == AiReportTarget.recipeImage;
    return PopScope(
      canPop: !_sending,
      child: Column(
        key: const ValueKey('ai-report-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SheetHeader(
            title: image ? l10n.coachReportImageTitle : l10n.coachReportTitle,
            onClose: _sending ? null : () => Navigator.of(context).pop(false),
            closeKey: const ValueKey('ai-report-close'),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // In the scroll, not the header: at double text on a small
                  // phone the fixed part would leave no room for the reasons.
                  Text(
                    image ? l10n.coachReportImageIntro : l10n.coachReportIntro,
                    style: AppType.ui(13, color: t.ink2, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  for (final reason in AiReportReason.values) ...<Widget>[
                    OptionCard(
                      actionKey: ValueKey('ai-report-reason-${reason.code}'),
                      selected: _reason == reason,
                      onTap: () {
                        if (_sending) return;
                        setState(() {
                          _reason = reason;
                          _failed = false;
                        });
                      },
                      title: _label(l10n, reason),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_failed)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.coachReportFailed,
                        key: const ValueKey('ai-report-error'),
                        style: AppType.ui(13, color: t.danger, height: 1.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: PrimaryActionButton(
              key: const ValueKey('ai-report-submit'),
              label: _sending
                  ? l10n.coachReportSending
                  : l10n.coachReportSubmit,
              icon: Icons.flag_outlined,
              busy: _sending,
              onTap: _reason == null ? null : _submit,
            ),
          ),
        ],
      ),
    );
  }
}
