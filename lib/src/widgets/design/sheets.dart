import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// SHEETS — scaffold, input field and the opener.
//
// Geometry 1:1 from the design mock; colors from [AppTokens].
// ---------------------------------------------------------------------------

/// A bottom sheet's inside: title, line, fields, one action at the foot.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionLabel,
    this.destructive = false,
    this.onAction,
    this.actionEnabled = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String actionLabel;
  final bool destructive;

  /// Defaults to closing: a sheet without its own action only confirms.
  final VoidCallback? onAction;

  /// Arms the action. Disabled means dimmed and deaf, not invisible.
  final bool actionEnabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fill = destructive ? t.danger : t.forest;
    // Scrollable, not just shrink-wrapping: a plain Column overflowed by
    // ~101 px at textScaler 2.0.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: AppType.display(
              24,
              color: destructive ? t.danger : t.ink,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: AppType.ui(12.5, color: t.ink2, height: 1.45)),
          const SizedBox(height: 18),
          ...children,
          const SizedBox(height: 20),
          Opacity(
            opacity: actionEnabled ? 1 : 0.4,
            child: Material(
              color: fill,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: actionEnabled
                    ? (onAction ?? () => Navigator.of(context).maybePop())
                    : null,
                borderRadius: BorderRadius.circular(16),
                child: ConstrainedBox(
                  // Not a fixed SizedBox(height: 52): at textScaler 2.0 the
                  // label would be taller than the button.
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            actionLabel,
                            textAlign: TextAlign.center,
                            style: AppType.ui(
                              14.5,
                              weight: FontWeight.w700,
                              // `bg` is the counterpole to both fills in each
                              // mode, so it also contrasts on `danger`.
                              color: destructive ? t.bg : t.onForest,
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
        ],
      ),
    );
  }
}

/// Labelled input field in sheet style.
class SheetField extends StatelessWidget {
  const SheetField({
    super.key,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.controller,
    this.enabled = true,
    this.keyboardType,
    this.onChanged,
    this.errorText,
    this.suffix,
  });

  final String label;
  final String hint;
  final bool obscure;

  /// The static design mock needs no controller; real sheets do.
  final TextEditingController? controller;

  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  /// One [AppTokens.danger] line under the field; also colors the border.
  final String? errorText;

  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasError = errorText != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label.toUpperCase(), style: AppType.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 7),
          Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Container(
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: hasError ? t.danger : t.line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      obscureText: obscure,
                      keyboardType: keyboardType,
                      onChanged: onChanged,
                      cursorColor: t.accent,
                      style: AppType.ui(14, color: t.ink),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 15),
                        hintText: hint,
                        hintStyle: AppType.ui(14, color: t.ink2),
                      ),
                    ),
                  ),
                  if (suffix != null) suffix!,
                ],
              ),
            ),
          ),
          if (hasError) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              errorText!,
              style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gap between the top safe area and a sheet's top edge.
const double kSheetTopGap = 12;

/// Floor for [sheetMaxHeight], so a small screen or tall keyboard cannot
/// collapse the header into a few pixels.
const double kSheetMinHeight = 320;

/// The tallest a sheet may be without sliding under the top safe area, never
/// below [kSheetMinHeight].
///
/// Not a fixed fraction: that ignored the keyboard, so the route clamped the
/// sheet under the status bar and hid its header. Sheets in the tree use
/// [sheetMaxHeightOf].
double sheetMaxHeight(MediaQueryData mediaQuery) {
  final available = mediaQuery.size.height -
      mediaQuery.viewPadding.top -
      mediaQuery.viewInsets.bottom -
      kSheetTopGap;
  return math.max(kSheetMinHeight, available);
}

/// [sheetMaxHeight] for a sheet's build context. Inside
/// `showModalBottomSheet`'s builder `viewPadding.top` is already 0, so the
/// device safe area comes from the [FlutterView]; `useSafeArea: true` zeroes
/// it the same way and eats the gap.
double sheetMaxHeightOf(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final viewTop = MediaQueryData.fromView(View.of(context)).viewPadding.top;
  if (viewTop <= mediaQuery.viewPadding.top) return sheetMaxHeight(mediaQuery);
  return sheetMaxHeight(
    mediaQuery.copyWith(
      viewPadding: mediaQuery.viewPadding.copyWith(top: viewTop),
    ),
  );
}

/// Opens [sheet] as an Eatova bottom sheet: scroll-controlled, drag handle,
/// [rSheet] cap, keyboard inset and the safe-area cap ([sheetMaxHeight]).
Future<T?> showEatovaSheet<T>(BuildContext context, Widget sheet) {
  final t = context.t;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.bg,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        // `showDragHandle` adds a `kMinInteractiveDimension` pad ABOVE the
        // builder content, so it is subtracted here. Without the cap, long
        // content fills the screen up under the status bar.
        constraints: BoxConstraints(
          maxHeight: sheetMaxHeightOf(sheetContext) - kMinInteractiveDimension,
        ),
        child: sheet,
      ),
    ),
  );
}
