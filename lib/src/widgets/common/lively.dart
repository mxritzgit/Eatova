import 'package:flutter/material.dart';

/// Subtle entrance: soft fade-in plus a slight upward glide.
///
/// The child always stays in the widget tree (only opacity/transform change),
/// so hit-testing, keys and widget tests are untouched. A changing [key]
/// replays the entrance.
class LivelyEntrance extends StatefulWidget {
  const LivelyEntrance({
    super.key,
    required this.child,
    this.offsetY = 10,
    this.duration = const Duration(milliseconds: 320),
    this.curve = Curves.easeOutCubic,
  });

  final Widget child;
  final double offsetY;
  final Duration duration;
  final Curve curve;

  @override
  State<LivelyEntrance> createState() => _LivelyEntranceState();
}

class _LivelyEntranceState extends State<LivelyEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _anim = CurvedAnimation(parent: _controller, curve: widget.curve);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A11y: respect "reduce motion" — show the content statically.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return widget.child;
    }
    // FadeTransition instead of a raw animated Opacity: the latter forces a
    // saveLayer (offscreen raster of the whole page) every frame. The
    // RepaintBoundary rasters the page once so the entrance only recomposites
    // the finished layer; the glide stays a cheap transform layer.
    return FadeTransition(
      opacity: _anim,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, (1 - _anim.value) * widget.offsetY),
            child: child,
          );
        },
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
