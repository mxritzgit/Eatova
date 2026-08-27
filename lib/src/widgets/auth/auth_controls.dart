import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../design/controls.dart';
import '../design/sheets.dart';

// ---------------------------------------------------------------------------
// AUTH CONTROLS — shared by auth_screen.dart and auth_code_screen.dart.
//
// Inputs follow the house rule: no hairline, no focus ring. The capsule is a
// [FieldCapsule] (rest `field`, focus `fieldFocus`, depth from [softShadow]).
// Colors via `context.t`, type via [AppType].
// ---------------------------------------------------------------------------

/// Borderless soft-capsule text field with an optional eyebrow label and
/// leading icon.
class AuthField extends StatefulWidget {
  const AuthField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.hint,
    this.label,
    this.icon,
    this.enabled = true,
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

  /// Small all-caps caption above the capsule.
  final String? label;
  final IconData? icon;
  final bool enabled;
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
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 18, color: _focused ? t.accent : t.ink2),
            const SizedBox(width: 10),
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
                style: AppType.ui(15, weight: FontWeight.w500, color: t.ink),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  hintText: widget.hint,
                  hintStyle: AppType.ui(15, color: t.ink2),
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
          Text(
            widget.label!.toUpperCase(),
            style: AppType.eyebrow(t.ink2, size: 10.5),
          ),
          const SizedBox(height: 8),
        ],
        Opacity(opacity: widget.enabled ? 1 : 0.6, child: capsule),
      ],
    );
  }
}

/// The password "eye": a real button with label and a 44 px hit box, so a
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
          width: 44,
          height: 44,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: toggleKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Icon(
                visible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 20,
                color: t.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Underlined text action (forgot password, resend, inline note action) with
/// button semantics and a 44 px minimum height.
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({
    super.key,
    required this.linkKey,
    required this.label,
    this.onTap,
    this.emphasis = false,
  });

  final Key linkKey;
  final String label;
  final VoidCallback? onTap;

  /// Accent instead of muted ink — for the one action a note offers.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = emphasis ? t.accent : t.ink2;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: InkWell(
        key: linkKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(rChip),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: AppType.ui(12.5, weight: FontWeight.w600, color: color)
                    .copyWith(
                  decoration: TextDecoration.underline,
                  decorationColor: color.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [PrimaryActionButton] with a loading state: while [loading] the same
/// ink surface shows a spinner and takes no taps.
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
    // Same geometry as PrimaryActionButton (ink fill, rButton,
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
          color: t.ink,
          borderRadius: BorderRadius.circular(rButton),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: t.bg),
        ),
      ),
    );
  }
}

enum AuthNoteTone { error, info }

/// Inline note under the form: error (danger) or confirmation (accent), with
/// an optional action link — the way out of a dead-end message.
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
    final color = isError ? t.danger : t.accent;
    final action = actionLabel;
    return Container(
      key: noteKey,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rControl),
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
                Icon(
                  isError
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    text,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w500,
                      color: color,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (action != null && onAction != null)
            Align(
              alignment: Alignment.centerRight,
              child: AuthTextLink(
                linkKey: actionKey ?? ValueKey('$text-action'),
                label: action,
                onTap: onAction,
                emphasis: true,
              ),
            ),
        ],
      ),
    );
  }
}
