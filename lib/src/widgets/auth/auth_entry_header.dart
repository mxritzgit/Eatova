import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../design/controls.dart';
import '../shared/eatova_wordmark.dart';
import 'auth_controls.dart';

/// Open, typographic entry with one finite focus movement in the brand mark.
class AuthEntryHeader extends StatefulWidget {
  const AuthEntryHeader({
    super.key,
    required this.isRegister,
    required this.keyboardOpen,
  });

  final bool isRegister;
  final bool keyboardOpen;

  @override
  State<AuthEntryHeader> createState() => _AuthEntryHeaderState();
}

class _AuthEntryHeaderState extends State<AuthEntryHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _focus = AnimationController.unbounded(
    vsync: this,
    value: -1,
  );
  bool _started = false;

  void _settleFocus({bool entering = false}) {
    final target = widget.isRegister ? 1.0 : 0.0;
    if (reducedMotion(context)) {
      _focus.value = target;
    } else {
      _focus.animateTo(
        target,
        duration: Duration(milliseconds: entering ? 720 : 440),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _settleFocus(entering: true);
    } else if (reducedMotion(context)) {
      _settleFocus();
    }
  }

  @override
  void didUpdateWidget(covariant AuthEntryHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRegister != widget.isRegister) _settleFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final keyboardOpen = widget.keyboardOpen;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, keyboardOpen ? 12 : 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _focus,
            builder: (context, _) => MediaQuery.withNoTextScaling(
              // The mark is one piece of artwork with a single spoken label.
              child: EatovaWordmark(
                fontSize: 32,
                textColor: t.ink,
                ringColor: t.accent,
                focusTurn: _focus.value,
              ),
            ),
          ),
          maybeAnimatedSize(
            context,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: keyboardOpen
                ? const SizedBox(width: double.infinity, height: 18)
                : Padding(
                    padding: const EdgeInsets.only(top: 34, bottom: 28),
                    child: AnimatedSwitcher(
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 240),
                      ),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topLeft,
                        children: [
                          for (final child in previous)
                            ExcludeSemantics(child: child),
                          if (current != null) current,
                        ],
                      ),
                      child: Column(
                        key: ValueKey(widget.isRegister),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AuthHeadline(
                            widget.isRegister
                                ? l10n.authHeadlineRegister
                                : l10n.authHeadlineLogin,
                            style: AppType.display(
                              40,
                              color: t.ink,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.isRegister
                                ? l10n.authSublineRegister
                                : l10n.authSublineLogin,
                            style: AppType.ui(
                              15.5,
                              weight: FontWeight.w500,
                              color: t.ink2,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The two account routes as one segmented pill in the app's selection
/// language ([SelectionTone]): a flush `softFill` track with no edge and a
/// `selectedFill` thumb with an `onSelected` label that slides to the chosen
/// route. Labels that do not fit side by side stack into two full-width rows;
/// the chosen one keeps the thumb's fill.
///
/// The thumb's own fill draws the selection boundary, no ring (WCAG 1.4.11):
/// 7.8:1 (dark) / 5.0:1 (light) against the track; its label 8.6:1 / 6.6:1,
/// the other label (`ink2`) 7.6:1 / 5.2:1 on the track. The quiet tint with
/// an accent edge it replaces measured 1.3:1 without that edge. The thumb
/// stays flush (no cast light): the lit submit below, which often carries
/// the same words, remains the one lit action.
///
/// Keyboard focus brightens, never a ring: [kLitFocusOverlay] over the thumb
/// (still 9.0:1 / 3.4:1 against the track, label 10.0:1 / 4.5:1) or over the
/// track, where the other label turns `ink` (8.4:1 / 14.3:1; `ink2` would
/// drop to 4.3:1 on the brightened dark track).
class AuthModeSelector extends StatelessWidget {
  const AuthModeSelector({
    super.key,
    required this.isRegister,
    required this.enabled,
    required this.onChanged,
  });

  final bool isRegister;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// Inset of the thumb inside the track.
  static const double _inset = 4;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final labels = [l10n.authToggleActionLogin, l10n.authToggleActionRegister];
    final style = AppType.ui(15, weight: FontWeight.w800);
    final motion = motionDuration(context, const Duration(milliseconds: 280));
    return LayoutBuilder(
      builder: (context, constraints) {
        final measure = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        );
        var stacked = false;
        for (final label in labels) {
          measure.text = TextSpan(text: label, style: style);
          measure.layout();
          stacked |= measure.width + 40 > constraints.maxWidth / 2 - _inset;
        }
        measure.dispose();

        // Stacked rows sit in a card-radius track; their corners stay
        // concentric with it.
        final ShapeBorder trackShape = stacked
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(rCard))
            : const StadiumBorder();
        final ShapeBorder segmentShape = stacked
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rCard - _inset),
              )
            : const StadiumBorder();

        Widget option(bool register) => _ModeSegment(
          inkKey: ValueKey(
            register ? 'auth-toggle-register' : 'auth-toggle-login',
          ),
          label: labels[register ? 1 : 0],
          style: style,
          selected: register == isRegister,
          filled: stacked,
          shape: segmentShape,
          motion: motion,
          onTap: enabled ? () => onChanged(register) : null,
        );

        // Locked while a sign-in runs: dimmed like the rest of the form.
        Widget lockable(Widget child) => AnimatedOpacity(
          duration: motionDuration(
            context,
            const Duration(milliseconds: 160),
          ),
          opacity: enabled ? 1 : 0.55,
          child: child,
        );
        final track = ShapeDecoration(color: t.softFill, shape: trackShape);
        if (stacked) {
          return lockable(DecoratedBox(
            decoration: track,
            child: Padding(
              padding: const EdgeInsets.all(_inset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [option(false), option(true)],
              ),
            ),
          ));
        }
        return lockable(DecoratedBox(
          decoration: track,
          child: Padding(
            padding: const EdgeInsets.all(_inset),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedAlign(
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    alignment: isRegister
                        ? AlignmentDirectional.centerEnd
                        : AlignmentDirectional.centerStart,
                    child: FractionallySizedBox(
                      widthFactor: 0.5,
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: t.selectedFill,
                          shape: segmentShape,
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: option(false)),
                    Expanded(child: option(true)),
                  ],
                ),
              ],
            ),
          ),
        ));
      },
    );
  }
}

/// One route of [AuthModeSelector]. It paints its own state layer above the
/// thumb and the track (an ink highlight would sit under their fills): a
/// press deepens it a step, keyboard focus brightens it with
/// [kLitFocusOverlay] and turns an unselected label `ink`.
class _ModeSegment extends StatefulWidget {
  const _ModeSegment({
    required this.inkKey,
    required this.label,
    required this.style,
    required this.selected,
    required this.filled,
    required this.shape,
    required this.motion,
    required this.onTap,
  });

  /// Goes on the [InkWell] (tests read its `onTap`).
  final Key inkKey;
  final String label;
  final TextStyle style;
  final bool selected;

  /// Draws the selected fill itself (stacked rows); side by side the sliding
  /// thumb draws it.
  final bool filled;
  final ShapeBorder shape;
  final Duration motion;
  final VoidCallback? onTap;

  @override
  State<_ModeSegment> createState() => _ModeSegmentState();
}

class _ModeSegmentState extends State<_ModeSegment> {
  bool _focused = false;
  bool _pressed = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_modeChanged);
  }

  void _modeChanged(FocusHighlightMode mode) {
    if (_focused) setState(() {});
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_modeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final selected = widget.selected;
    final keyboard =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final ink = selected ? t.onSelected : (keyboard ? t.ink : t.ink2);
    final layer = _pressed
        ? ink.withValues(alpha: 0.10)
        : keyboard
        ? kLitFocusOverlay
        : ink.withValues(alpha: _hovered ? 0.05 : 0);
    final fill = t.selectedFill.withValues(
      alpha: widget.filled && selected ? 1 : 0,
    );
    return Semantics(
      selected: selected,
      button: true,
      enabled: widget.onTap != null,
      child: InkWell(
        key: widget.inkKey,
        onTap: widget.onTap,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
        onHover: (hovered) => setState(() => _hovered = hovered),
        customBorder: widget.shape,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: AnimatedContainer(
          duration: widget.motion,
          curve: Curves.easeOutCubic,
          decoration: ShapeDecoration(shape: widget.shape, color: fill),
          child: AnimatedContainer(
            duration: motionDuration(context, kMotionPressIn),
            curve: Curves.easeOut,
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: ShapeDecoration(shape: widget.shape, color: layer),
            child: AnimatedDefaultTextStyle(
              duration: widget.motion,
              curve: Curves.easeOutCubic,
              style: widget.style.copyWith(color: ink),
              child: Text(widget.label, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
