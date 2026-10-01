import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../design/controls.dart';
import '../design/sheets.dart';
import '../design/surfaces.dart';

/// Keeps the form readable on tablets and lets the keyboard resize it once.
class AuthPageLayout extends StatelessWidget {
  const AuthPageLayout({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: padding,
        child: child,
      ),
    ),
  );
}

/// The page ground of both auth screens: [AppTokens.bg] with one soft accent
/// glow behind the brand header, like the light behind the today hero and
/// the coach orb. Pure decoration — no semantics, no hit testing — and it
/// sits outside the safe area so it reaches under the status bar.
class AuthBackdrop extends StatelessWidget {
  const AuthBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Stack(
      children: [
        Positioned(
          top: -220,
          left: -170,
          width: 560,
          height: 520,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        t.accentGlow.withValues(alpha: 0.30),
                        t.accentGlow.withValues(alpha: 0.10),
                        t.accentGlow.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

/// Honors large text without splitting a headline's words on narrow phones.
///
/// Like the tab titles ([AppType.pageTitleMaxScale]) the headline grows with
/// the system text size only up to [maxPixelSize]: a display headline is large
/// text already, and the body below keeps the full scale.
class AuthHeadline extends StatelessWidget {
  const AuthHeadline(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  /// Largest rendered font size, reached at a high system text scale.
  static const double maxPixelSize = 60;

  @override
  Widget build(BuildContext context) => HeadingSemantics(
    level: 1,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context).clamp(
          maxScaleFactor: maxPixelSize / style.fontSize!,
        );
        final measure = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: scaler,
        );
        var longestWord = 0.0;
        for (final word in text.split(RegExp(r'\s+'))) {
          measure.text = TextSpan(text: word, style: style);
          measure.layout();
          if (measure.width > longestWord) longestWord = measure.width;
        }
        measure.dispose();
        final fit = longestWord == 0
            ? 1.0
            : ((constraints.maxWidth - 1) / longestWord).clamp(0.0, 1.0);
        return Text(
          text,
          textScaler: scaler,
          style: style.copyWith(
            fontSize: style.fontSize! * fit,
            letterSpacing: (style.letterSpacing ?? 0) * fit,
          ),
        );
      },
    ),
  );
}

// AUTH CONTROLS — shared by auth_screen.dart and auth_code_screen.dart.
//
// Inputs follow the house rule: no hairline, no focus ring. The capsule is a
// pill [FieldCapsule] (rest `field`, focus `fieldFocus`, error `fieldError`,
// depth from [softShadow]); focus also lights the leading icon disc in the
// accent, so focus never rests on the subtle fill change alone. Colors via
// `context.t`, type via [AppType].
// ---------------------------------------------------------------------------

/// Height floor of an [AuthField] capsule.
const double kAuthFieldHeight = 56;

/// Borderless soft-pill text field with an optional persistent label and a
/// leading icon disc.
class AuthField extends StatefulWidget {
  const AuthField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.hint,
    this.label,
    this.icon,
    this.enabled = true,
    this.error = false,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.textCapitalization = TextCapitalization.none,
    this.onSubmitted,
    this.trailing,
  });

  /// Goes on the [TextField] (tests enter text by it).
  final Key fieldKey;
  final TextEditingController controller;
  final String hint;

  /// Persistent caption above the capsule.
  final String? label;
  final IconData? icon;
  final bool enabled;

  /// Tints the capsule and the icon disc: the current note is about this
  /// field.
  final bool error;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (_focused != _focus.hasFocus) {
      setState(() => _focused = _focus.hasFocus);
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final capsule = FieldCapsule(
      focusNode: _focus,
      error: widget.error,
      enabled: widget.enabled,
      shape: SheetFieldShape.pill,
      constraints: const BoxConstraints(minHeight: kAuthFieldHeight),
      padding: EdgeInsets.only(
        left: widget.icon == null ? 20 : 10,
        right: widget.trailing == null ? 20 : 4,
      ),
      child: Row(
        children: [
          if (widget.icon != null) ...[
            AuthIconDisc(
              icon: widget.icon!,
              active: _focused,
              error: widget.error,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            // Spoken name for the field (pattern: manual_meal_sheet); without
            // it a screen reader only reads the hint.
            child: Semantics(
              label: widget.label ?? widget.hint,
              child: TextField(
                key: widget.fieldKey,
                controller: widget.controller,
                focusNode: _focus,
                enabled: widget.enabled,
                obscureText: widget.obscure,
                keyboardType: widget.keyboardType,
                textInputAction: widget.textInputAction,
                autofillHints: widget.autofillHints,
                autocorrect: widget.autocorrect,
                enableSuggestions: widget.enableSuggestions,
                textCapitalization: widget.textCapitalization,
                onSubmitted: widget.onSubmitted,
                cursorColor: t.accent,
                cursorOpacityAnimates: false,
                style: AppType.ui(15.5, weight: FontWeight.w600, color: t.ink),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 17),
                  hintText: widget.hint,
                  hintStyle: AppType.ui(15.5, color: t.ink2),
                ),
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              widget.label!,
              style: AppType.ui(13, weight: FontWeight.w700, color: t.ink2),
            ),
          ),
          const SizedBox(height: 8),
        ],
        capsule,
      ],
    );
  }
}

/// Round icon disc at the start of an input or a note. [active] lights it in
/// the accent (the field's focus mark), [error] in `danger`.
class AuthIconDisc extends StatelessWidget {
  const AuthIconDisc({
    super.key,
    required this.icon,
    this.active = false,
    this.error = false,
    this.size = 36,
  });

  final IconData icon;
  final bool active;
  final bool error;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (Color fill, Color ink) = error
        ? (t.danger.withValues(alpha: 0.16), t.danger)
        : active
        ? (t.accentTintStrong, t.accentText)
        : (t.tile, t.ink2);
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        curve: Curves.easeOut,
        width: size,
        height: size,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(icon, size: size * 0.5, color: ink),
      ),
    );
  }
}

/// The password "eye": a real button with label and a 48 px hit box, so a
/// screen reader announces it and a thumb hits it.
class AuthPasswordToggle extends StatelessWidget {
  const AuthPasswordToggle({
    super.key,
    required this.toggleKey,
    required this.visible,
    required this.showLabel,
    required this.hideLabel,
    this.onTap,
  });

  final Key toggleKey;
  final bool visible;
  final String showLabel;
  final String hideLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final label = visible ? hideLabel : showLabel;
    // The Semantics label carries the spoken text; the tooltip only serves
    // long-press/hover and must not be read a second time.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: toggleKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Icon(
                visible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 20,
                color: t.inkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text action (forgot password, resend, a note's way out) with button
/// semantics and a 48 px minimum height. [emphasis] draws it in the accent;
/// the quiet variant is `inkMuted` — still clearly a control by weight and
/// placement, never body-text grey.
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({
    super.key,
    required this.linkKey,
    required this.label,
    this.onTap,
    this.emphasis = false,
    this.icon,
    this.trailingIcon,
  });

  final Key linkKey;
  final String label;
  final VoidCallback? onTap;

  /// Accent instead of muted ink — for the one action a spot offers.
  final bool emphasis;

  /// Optional glyphs before / after the label, in the label colour.
  final IconData? icon;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = emphasis ? t.accentText : t.inkMuted;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: InkWell(
        key: linkKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(rPill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      13.5,
                      weight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 6),
                  Icon(trailingIcon, size: 16, color: color),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [PrimaryActionButton] with a loading state: while [loading] the same
/// accent pill shows a spinner and takes no taps.
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.loading,
    required this.enabled,
    required this.onTap,
    this.icon,
  });

  final Key buttonKey;
  final String label;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (!loading) {
      return PrimaryActionButton(
        key: buttonKey,
        label: label,
        icon: icon,
        onTap: enabled ? onTap : null,
      );
    }
    final t = context.t;
    // Same geometry and fill as PrimaryActionButton (accent pill, rButton,
    // kPrimaryButtonHeight), so nothing jumps when the spinner replaces the
    // label.
    return Semantics(
      button: true,
      enabled: false,
      label: label,
      child: Container(
        key: buttonKey,
        constraints: const BoxConstraints(minHeight: kPrimaryButtonHeight),
        decoration: BoxDecoration(
          color: t.accentFill,
          borderRadius: BorderRadius.circular(rButton),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: t.onAccentFill,
          ),
        ),
      ),
    );
  }
}

/// Quiet secondary pill (Google sign-in): card fill, 1 px `lineStrong` edge
/// like the redesign's neutral chips and header buttons, ink label.
class AuthSecondaryButton extends StatelessWidget {
  const AuthSecondaryButton({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.leading,
    required this.enabled,
    required this.onTap,
  });

  /// Goes on the [InkWell] (tests read its `onTap`).
  final Key buttonKey;
  final String label;
  final Widget leading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = StadiumBorder(side: BorderSide(color: t.lineStrong));
    return Semantics(
      button: true,
      enabled: enabled,
      child: AnimatedOpacity(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        opacity: enabled ? 1 : 0.55,
        child: PressScale(
          enabled: enabled,
          child: Material(
            color: t.surf,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: buttonKey,
              onTap: enabled ? onTap : null,
              customBorder: shape,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kPrimaryButtonHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 18,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox.square(dimension: 20, child: leading),
                      const SizedBox(width: 12),
                      // Flexible: at 200 % system font the label would
                      // otherwise burst the button width.
                      Flexible(
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          style: AppType.ui(
                            15,
                            weight: FontWeight.w700,
                            color: t.ink,
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
      ),
    );
  }
}

enum AuthNoteTone { error, info }

/// Inline note under the form: error (danger) or confirmation (accent), with
/// an optional action link — the way out of a dead-end message.
///
/// Calm on purpose: a faint tone tint, the tone only in the icon disc, the
/// sentence itself in readable `ink`.
class AuthInlineNote extends StatelessWidget {
  const AuthInlineNote({
    super.key,
    required this.noteKey,
    required this.text,
    required this.tone,
    this.actionKey,
    this.actionLabel,
    this.onAction,
  });

  final Key noteKey;
  final String text;
  final AuthNoteTone tone;
  final Key? actionKey;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isError = tone == AuthNoteTone.error;
    final color = isError ? t.danger : t.accentText;
    final action = actionLabel;
    return Container(
      key: noteKey,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: isError ? t.danger.withValues(alpha: 0.11) : t.accentTint,
        borderRadius: BorderRadius.circular(rTile),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live region on the sentence only: wrapping the action too would
          // merge the link into the announcement node and lose its button.
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      isError
                          ? Icons.priority_high_rounded
                          : Icons.check_rounded,
                      size: 16,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      text,
                      style: AppType.ui(
                        13.5,
                        weight: FontWeight.w500,
                        color: t.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (action != null && onAction != null)
            Padding(
              // Under the sentence, not under the disc; the link's own 12 px
              // inset is taken back so its text lines up with the sentence.
              padding: const EdgeInsets.only(left: 28),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AuthTextLink(
                  linkKey: actionKey ?? ValueKey('$text-action'),
                  label: action,
                  onTap: onAction,
                  emphasis: true,
                  trailingIcon: Icons.arrow_forward_rounded,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
