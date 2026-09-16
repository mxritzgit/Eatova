import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
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
      padding: EdgeInsets.fromLTRB(24, keyboardOpen ? 14 : 26, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _focus,
            builder: (context, _) => MediaQuery.withNoTextScaling(
              // The mark is one piece of artwork with a single spoken label.
              child: EatovaWordmark(
                fontSize: 38,
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
                ? const SizedBox(width: double.infinity, height: 14)
                : Padding(
                    padding: const EdgeInsets.only(top: 30, bottom: 26),
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
                              42,
                              color: t.ink,
                              height: 1.06,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.isRegister
                                ? l10n.authSublineRegister
                                : l10n.authSublineLogin,
                            style: AppType.ui(14, color: t.ink2, height: 1.45),
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

/// Both account routes stay visible; the underline follows the chosen route.
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final labels = [l10n.authToggleActionLogin, l10n.authToggleActionRegister];
    final style = AppType.ui(15, weight: FontWeight.w700);
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
          stacked |= measure.width + 32 > constraints.maxWidth / 2;
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
              borderRadius: BorderRadius.circular(rChip),
              child: Container(
                constraints: const BoxConstraints(minHeight: 50),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                decoration: stacked && selected
                    ? BoxDecoration(color: t.brandSurface)
                    : null,
                child: Text(
                  labels[register ? 1 : 0],
                  textAlign: TextAlign.center,
                  style: style.copyWith(color: selected ? t.ink : t.ink2),
                ),
              ),
            ),
          );
        }

        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [option(false), option(true)],
          );
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Row(
                children: [
                  Expanded(child: option(false)),
                  Expanded(child: option(true)),
                ],
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedAlign(
                  duration: motionDuration(
                    context,
                    const Duration(milliseconds: 320),
                  ),
                  curve: Curves.easeOutCubic,
                  alignment: isRegister
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    child: ColoredBox(
                      color: t.accent,
                      child: const SizedBox(height: 2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
