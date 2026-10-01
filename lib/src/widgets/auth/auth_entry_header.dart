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

/// The two account routes as one segmented pill: a card-fill track with a
/// `lineStrong` edge (like the redesign's neutral chips) and an accent thumb
/// that slides to the chosen route. Labels that do not fit side by side stack
/// into two full-width rows; the chosen one keeps the accent fill.
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

        Widget option(bool register) {
          final selected = register == isRegister;
          return Semantics(
            selected: selected,
            button: true,
            enabled: enabled,
            child: InkWell(
              key: ValueKey(
                register ? 'auth-toggle-register' : 'auth-toggle-login',
              ),
              onTap: enabled ? () => onChanged(register) : null,
              customBorder: const StadiumBorder(),
              child: AnimatedContainer(
                duration: motion,
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                // Stacked rows carry their own fill; side by side the
                // sliding thumb below draws it.
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  color: stacked && selected
                      ? t.selectedFill
                      : t.selectedFill.withValues(alpha: 0),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  style: style.copyWith(
                    color: selected ? t.onSelected : t.inkMuted,
                  ),
                  child: Text(
                    labels[register ? 1 : 0],
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        final edge = BorderSide(color: t.lineStrong);
        if (stacked) {
          return DecoratedBox(
            decoration: ShapeDecoration(
              color: t.surf,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rCard),
                side: edge,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(_inset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [option(false), option(true)],
              ),
            ),
          );
        }
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: t.surf,
            shape: StadiumBorder(side: edge),
          ),
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
                          shape: const StadiumBorder(),
                          color: t.selectedFill,
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
        );
      },
    );
  }
}
