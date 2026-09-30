import 'package:flutter/widgets.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// TAB CHROME — the top edge shared by the five tab root screens (dark
// redesign, 2026-09-28).
//
// The shell does not inset its tabs at the top: every tab runs to the screen
// edge and its content scrolls under the status bar, as in the design. Each
// tab starts its header [TabChrome.topInset] below the screen top — on the
// design's phone 47 (status bar) + 15 = 62 px. [StatusBarScrim] keeps the
// status bar legible over scrolled content.
// ---------------------------------------------------------------------------

/// The one title origin of all tabs.
abstract final class TabChrome {
  /// Gap between the status bar and a tab's header row.
  static const double headerGap = 15;

  /// Distance of a tab's header row from the screen top: the status bar
  /// (`MediaQuery.padding.top`, which the shell passes on) plus [headerGap].
  static double topInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top + headerGap;

  /// Key of each tab's header row, for the shared title-origin check.
  static const Key headerKey = ValueKey<String>('tab-header');
}

/// The page color behind the status bar, fading out over [TabChrome.headerGap]
/// below it, so content scrolled under the bar never meets the system icons.
///
/// At rest it covers only empty page (every header starts below it), so the
/// unscrolled tabs look exactly like the design. Decorative: no hit target,
/// and nothing when the window has no top inset.
class StatusBarScrim extends StatelessWidget {
  const StatusBarScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return const SizedBox.shrink();
    final bg = context.t.bg;
    final height = top + TabChrome.headerGap;
    return IgnorePointer(
      child: SizedBox(
        key: const ValueKey<String>('status-bar-scrim'),
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: <double>[0, top / height, 1],
              colors: <Color>[bg, bg, bg.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}
