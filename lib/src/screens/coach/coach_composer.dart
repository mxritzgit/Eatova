part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Composer capsule on `surf`: attach, text, mic, send tile. Focus brightens
// the surface to `surf2` instead of drawing a ring; a tappable hint sits above
// it when the quota runs low.
// ---------------------------------------------------------------------------
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.canSend,
    required this.remaining,
    required this.draft,
    required this.listening,
    required this.onSubmit,
    required this.onMic,
    required this.onAttach,
    required this.onQuotaTap,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// Typing allowed (session loaded, quota left).
  final bool enabled;

  /// Actions allowed (additionally: no send in flight).
  final bool canSend;
  final int remaining;
  final String draft;
  final bool listening;
  final VoidCallback onSubmit;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final VoidCallback onQuotaTap;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late bool _focused = widget.focus.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focused != widget.focus.hasFocus) {
      setState(() => _focused = widget.focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final hasText = widget.draft.trim().isNotEmpty;
    final showQuotaHint = widget.remaining > 0 && widget.remaining <= 2;
    // No viewInsets padding: the home scaffold uses
    // `resizeToAvoidBottomInset: true`, so the keyboard is already accounted
    // for.
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showQuotaHint)
            _QuotaHint(remaining: widget.remaining, onTap: widget.onQuotaTap),
          AnimatedContainer(
            duration: motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            // Horizontal 0: the side margin comes from the shell.
            margin: const EdgeInsets.only(bottom: 4),
            constraints: const BoxConstraints(minHeight: 52, maxHeight: 160),
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            decoration: BoxDecoration(
              color: _focused ? t.surf2 : t.surf,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: t.line),
              // The only raised surface on this screen: the composer sits
              // above the scrolling list.
              boxShadow: softShadow(t),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                _ComposerIcon(
                  key: const ValueKey('coach-attach'),
                  icon: Icons.add_rounded,
                  enabled: widget.canSend,
                  onTap: widget.onAttach,
                  semanticLabel: l10n.coachAttachSemanticLabel,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: TextField(
                    key: const ValueKey('coach-input'),
                    cursorOpacityAnimates: false,
                    controller: widget.controller,
                    focusNode: widget.focus,
                    enabled: widget.enabled,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    style: AppType.ui(15.5, color: t.ink, height: 1.3),
                    cursorColor: t.accent,
                    decoration: InputDecoration(
                      // All four borders AND `filled` are needed: the app's
                      // inputDecorationTheme fills and outlines fields, so
                      // setting only `border` would leave a second boxed
                      // field inside the capsule (same as SheetField).
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 6),
                      // C8: the placeholder names the AI — in a running chat
                      // the composer is the only always-visible spot.
                      hintText: widget.remaining <= 0
                          ? l10n.coachComposerHintLimitReached
                          : widget.listening
                              ? l10n.coachComposerHintListening
                              : l10n.coachComposerHintDefault,
                      hintStyle: AppType.ui(15.5, color: t.ink2),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _MicButton(
                  enabled: widget.canSend,
                  listening: widget.listening,
                  onTap: widget.onMic,
                ),
                const SizedBox(width: 2),
                _SendButton(
                  active: hasText,
                  enabled: widget.canSend && hasText,
                  onTap: widget.onSubmit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle status hint above the composer once only 1–2 coach questions are
/// left. Tapping opens the quota sheet.
class _QuotaHint extends StatelessWidget {
  const _QuotaHint({required this.remaining, required this.onTap});

  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final shape = StadiumBorder(side: BorderSide(color: t.line));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          key: const ValueKey('coach-quota-hint'),
          color: t.surf,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: t.lime),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      l10n.coachQuotaHint(remaining),
                      style: AppType.ui(
                        11.5,
                        weight: FontWeight.w600,
                        color: t.ink2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerIcon extends StatelessWidget {
  const _ComposerIcon({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  /// Required, not optional: the button shows only a glyph, so without a name
  /// a screen reader announces just "button".
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: enabled ? onTap : null,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 38,
              height: 44,
              child: Center(
                // Plain glyph without a chip — the capsule carries the fill.
                child: Icon(
                  icon,
                  color: enabled ? t.ink2 : t.ink2.withValues(alpha: 0.5),
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic button in the composer. While [listening] a soft accent ring pulses
/// behind the icon (static under "reduce motion").
///
/// The listening state uses [AppTokens.accent], NOT `lime`: as a stroke on the
/// light composer capsule `lime` reaches only ~1.2:1, so the mic would look
/// idle while recording. `accent` carries in both modes.
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.enabled,
    required this.listening,
    required this.onTap,
  });

  final bool enabled;
  final bool listening;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.listening && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.listening
        ? t.accent
        : (widget.enabled ? t.ink2 : t.ink2.withValues(alpha: 0.5));
    return Semantics(
      key: const ValueKey('coach-mic'),
      button: true,
      enabled: widget.enabled,
      // The button is a toggle: the state belongs in the name, otherwise a
      // screen reader user never learns that recording is running.
      label: widget.listening
          ? l10n.coachMicLabelListening
          : l10n.coachMicLabelIdle,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
        // Fill also via `accent`: `forest` at 18 % sits practically on `surf`
        // in dark mode and was invisible there.
          color: widget.listening
              ? t.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: widget.enabled ? widget.onTap : null,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 42,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  if (widget.listening && !reduce)
                    RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, __) {
                          final v = _pulse.value;
                          return Container(
                            width: 24 + 14 * v,
                            height: 24 + 14 * v,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: t.accent.withValues(alpha: 0.5 * (1 - v)),
                                width: 1.5,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  Icon(Icons.mic_none_rounded, color: color, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Send button: forest tile with lime arrow once a draft is in the field,
/// quiet tile otherwise.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scharf = active && enabled;
    // A bare GestureDetector carries no semantics at all, so the button was
    // neither named nor recognisable as a button. `enabled` is part of it so
    // the locked state is announced instead of sounding like a dead button.
    return Semantics(
      button: true,
      enabled: enabled,
      label: context.l10n.coachSendLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: GestureDetector(
          key: const ValueKey('coach-send'),
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration:
                motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: scharf ? t.forest : t.tile,
            ),
            child: Icon(
              Icons.send_rounded,
              color: scharf ? t.lime : t.ink2,
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

/// Row in the attach sheet: icon tile + label.
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: <Widget>[
              IconTile(icon: icon, size: 36),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label,
                  style:
                      AppType.ui(15, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
/// Sheet behind the (i) in the header and behind the empty-state hint.
///
/// C8: the disclosure comes first, the daily quota below it — every message
/// ships a day snapshot (weight, goal, calories, open macros, today's meal
/// names) to a US third party, which was only stated in the privacy policy.
class _CoachInfoSheet extends StatelessWidget {
  const _CoachInfoSheet({required this.remaining, required this.dailyLimit});

  final int remaining;
  final int dailyLimit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // No own drag handle: showEatovaSheet sets showDragHandle.
              Text(
                l10n.coachTitle,
                style:
                    AppType.display(20, weight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoIntro,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoDataLabel),
              const SizedBox(height: 8),
              _InfoBullet(l10n.coachInfoBulletWeight),
              _InfoBullet(l10n.coachInfoBulletMacros),
              _InfoBullet(l10n.coachInfoBulletMeals),
              const SizedBox(height: 12),
              Text(
                l10n.coachInfoProvider,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: t.line),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoLimitLabel),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoLimitBody(remaining, dailyLimit),
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 14),
              _QuotaBar(remaining: remaining, total: dailyLimit),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section heading in the info sheet.
class _InfoLabel extends StatelessWidget {
  const _InfoLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Text(
      text,
      style: AppType.ui(13.5, weight: FontWeight.w700, color: t.ink),
    );
  }
}

/// Bullet row in the info sheet (lime dot + text).
class _InfoBullet extends StatelessWidget {
  const _InfoBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(top: 7, right: 9),
            decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(13, color: t.ink, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pct = total == 0 ? 0.0 : remaining / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: Stack(
            children: <Widget>[
              Container(height: 6, color: t.tile),
              FractionallySizedBox(
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(color: t.accent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$remaining / $total',
          style:
              AppType.display(12.5, weight: FontWeight.w600, color: t.ink),
        ),
      ],
    );
  }
}
