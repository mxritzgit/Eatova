import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/ai_trust.dart';
import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../screens/settings/settings_controls.dart' show openLegalLink;
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// The AI consent gate (review 2026-10-19, P1).
//
// EVERY call into an AI Edge Function (analyze-meal, coach-chat,
// recipe-import) passes [ensureAiConsent] first, in the screen or sheet that
// starts it: the photo scan in the Food tab and in the add sheet, describing
// a meal, the Coach's send funnel and the recipe import. A source rule
// (test/ai_consent/ai_consent_entry_points_test.dart) fails any method that
// calls one of those services without asking first.
// ---------------------------------------------------------------------------

/// Whether an AI feature may send right now WITHOUT asking: the decision is
/// known and allows it. Synchronous, for callers that must act before their
/// first await (the Coach clears its composer there).
bool aiConsentSettled(BuildContext context) {
  final binding = AiTrustScope.maybeOf(context);
  if (binding == null) return true;
  return binding.controller?.allowsAi ?? false;
}

/// Asks for the AI consent when the account has none, and answers whether the
/// AI call may go ahead. False means: send nothing.
///
/// Outside the app shell (widget tests, previews) there is no [AiTrustScope]
/// and nothing to ask. Inside it, a missing account binding fails closed.
/// While a consent sheet is open, every further caller waits for it instead
/// of stacking a second one.
Future<bool> ensureAiConsent(BuildContext context) async {
  final binding = AiTrustScope.maybeOf(context);
  if (binding == null) return true;
  final controller = binding.controller;
  if (controller == null) return false;
  if (controller.allowsAi) return true;
  unawaited(controller.load());
  try {
    await controller.ready.timeout(kAiConsentReadyBudget);
  } on TimeoutException {
    // The sheet is the safe answer to an unknown state.
  }
  if (!context.mounted) return false;
  if (controller.allowsAi) return true;
  if (!controller.canRecord) return false;
  return controller.promptOnce(
    () => showAiConsentSheet(context, controller: controller),
  );
}

/// Opens the consent sheet; true once the server logged the grant.
Future<bool> showAiConsentSheet(
  BuildContext context, {
  required AiTrustController controller,
}) async {
  final granted = await showEatovaSheet<bool>(
    context,
    AiConsentSheet(controller: controller),
  );
  return granted ?? false;
}

/// What the AI features send and to whom, the explicit health data checkbox
/// (unticked) and the two ways out. "Not now" and every dismissal send
/// nothing; "Agree" logs the grant on the server and only then reports true.
class AiConsentSheet extends StatefulWidget {
  const AiConsentSheet({super.key, required this.controller});

  final AiTrustController controller;

  @override
  State<AiConsentSheet> createState() => _AiConsentSheetState();
}

class _AiConsentSheetState extends State<AiConsentSheet> {
  bool _healthData = false;
  bool _saving = false;
  bool _failed = false;

  Future<void> _accept() async {
    if (!_healthData || _saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.controller.grant();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failed = true;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(widget.controller.allowsAi);
  }

  void _notNow() {
    if (_saving) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final body = AppType.ui(14, color: t.ink2, height: 1.5);
    return PopScope(
      canPop: !_saving,
      child: Column(
        key: const ValueKey('ai-consent-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SheetHeader(
            title: l10n.aiConsentTitle,
            leading: const ExcludeSemantics(
              child: IconTile(
                icon: Icons.auto_awesome_outlined,
                size: 44,
                glyphSize: 20,
                radius: rControl,
              ),
            ),
            onClose: _notNow,
            closeEnabled: !_saving,
            closeKey: const ValueKey('ai-consent-close'),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(l10n.aiConsentIntro, style: body),
                  _Section(
                    label: l10n.aiConsentFeaturesLabel,
                    text: l10n.aiConsentFeaturesBody,
                  ),
                  _Section(
                    label: l10n.aiConsentDataLabel,
                    text: l10n.aiConsentDataBody,
                  ),
                  _Section(
                    label: l10n.aiConsentProvidersLabel,
                    text: l10n.aiConsentProvidersBody,
                  ),
                  _Section(
                    label: l10n.aiConsentVoluntaryLabel,
                    text: l10n.aiConsentVoluntaryBody,
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('ai-consent-privacy'),
                      onPressed: () => openLegalLink(context, kPrivacyUrl),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text(l10n.aiConsentPrivacyLink),
                      style: TextButton.styleFrom(
                        foregroundColor: t.accentText,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 44),
                        textStyle: AppType.ui(14, weight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ConsentCheck(
                    value: _healthData,
                    enabled: !_saving,
                    label: l10n.aiConsentHealthCheckbox,
                    onChanged: (value) => setState(() {
                      _healthData = value;
                      _failed = false;
                    }),
                  ),
                  if (_failed) ...<Widget>[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.aiConsentSaveFailed,
                        key: const ValueKey('ai-consent-error'),
                        style: AppType.ui(13, color: t.danger, height: 1.4),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                PrimaryActionButton(
                  key: const ValueKey('ai-consent-accept'),
                  label: _saving ? l10n.aiConsentSaving : l10n.aiConsentAccept,
                  busy: _saving,
                  onTap: _healthData ? _accept : null,
                ),
                const SizedBox(height: 10),
                EatovaDialogAction(
                  buttonKey: const ValueKey('ai-consent-not-now'),
                  label: l10n.aiConsentNotNow,
                  secondary: true,
                  onPressed: _saving ? null : _notNow,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          HeadingSemantics(
            level: 2,
            child: Text(label, style: AppType.sectionEyebrow(t.inkMuted)),
          ),
          const SizedBox(height: 6),
          Text(text, style: AppType.ui(14, color: t.ink, height: 1.5)),
        ],
      ),
    );
  }
}

/// The unticked health data checkbox: a card in the selection language of the
/// option cards, with a square mark instead of the radio. The whole card is
/// the target and one semantics node (checkbox, checked).
class _ConsentCheck extends StatelessWidget {
  const _ConsentCheck({
    required this.value,
    required this.enabled,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final radius = BorderRadius.circular(rCard);
    final duration = motionDuration(context, kSelectionDuration);
    return MergeSemantics(
      child: Semantics(
        checked: value,
        enabled: enabled,
        child: AnimatedContainer(
          duration: duration,
          decoration: BoxDecoration(
            color: value ? Color.alphaBlend(t.accentTint, t.surf) : t.surf,
            borderRadius: radius,
            border: Border.all(
              color: value ? t.accent : t.lineStrong,
              width: kSelectionEdge,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('ai-consent-health-check'),
              onTap: enabled ? () => onChanged(!value) : null,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: AnimatedContainer(
                        duration: duration,
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: value ? t.selectedFill : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: value ? t.selectedFill : t.ink3,
                            width: kSelectionEdge,
                          ),
                        ),
                        child: value
                            ? Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: t.onSelected,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.ink,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
