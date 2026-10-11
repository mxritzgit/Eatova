import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

/// The app's spinner: small, round-capped, in the accent. Replaces the
/// 36-40 px Material default wherever something loads.
///
/// Its own file so the controls (a busy button) and the feedback states
/// (a loading card) can both use it without importing each other.
class AppSpinner extends StatelessWidget {
  const AppSpinner({
    super.key,
    this.size = 22,
    this.strokeWidth = 2.4,
    this.color,
    this.trackColor,
    this.semanticsLabel,
  });

  final double size;
  final double strokeWidth;

  /// Defaults to [AppTokens.accent].
  final Color? color;

  /// The ring under the arc; defaults to the theme's `tile` track. On a
  /// filled surface (a busy button) pass a tint of the foreground instead.
  final Color? trackColor;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CircularProgressIndicator(
      strokeWidth: strokeWidth,
      strokeCap: StrokeCap.round,
      color: color ?? context.t.accent,
      backgroundColor: trackColor,
      semanticsLabel: semanticsLabel,
    ),
  );
}
