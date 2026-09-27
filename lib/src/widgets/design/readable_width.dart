import 'package:flutter/widgets.dart';

// ---------------------------------------------------------------------------
// READABLE WIDTH — phone-first layouts on tablets and landscape windows.
//
// Eatova's screens are designed for phone widths. On a large window a
// full-width column stretches cards and text lines past comfortable reading.
// [ReadableWidth] centres the content in a bounded column once the space is
// wider than [kReadableContentWidth], and is a strict no-op below it.
// ---------------------------------------------------------------------------

/// Widest content column for pages and tabs on large windows.
///
/// Matches the Material 3 default modal bottom-sheet width, so sheets opened
/// over a page line up with its column.
const double kReadableContentWidth = 640;

/// Centres [child] in at most [maxWidth] logical pixels of the available width.
///
/// Uses symmetric [Padding] instead of `Center` + `ConstrainedBox`: at or
/// below [maxWidth] the padding is zero, so the child receives exactly the
/// incoming constraints (tight stays tight) and phone layouts are unchanged.
/// The element tree is identical on both sides of the breakpoint, so resizing
/// or rotating a window keeps scroll positions and other child state.
///
/// Wrap the content, not the background: a page's backdrop should still fill
/// the window.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({
    super.key,
    this.maxWidth = kReadableContentWidth,
    required this.child,
  });

  final double maxWidth;
  final Widget child;

  /// Horizontal inset on each side that bounds [available] to [maxWidth].
  static double insetFor(
    double available, {
    double maxWidth = kReadableContentWidth,
  }) {
    if (!available.isFinite || available <= maxWidth) return 0;
    return (available - maxWidth) / 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = insetFor(constraints.maxWidth, maxWidth: maxWidth);
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: child,
        );
      },
    );
  }
}
