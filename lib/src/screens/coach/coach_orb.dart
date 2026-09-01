part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Animated coach orb (rotating sweep + breathing core). Static under "reduce
// motion", but the look is unchanged.
// ---------------------------------------------------------------------------
class CoachOrb extends StatefulWidget {
  const CoachOrb({super.key, this.size = 92});
  final double size;

  @override
  State<CoachOrb> createState() => _CoachOrbState();
}

class _CoachOrbState extends State<CoachOrb> with TickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 7));
  late final AnimationController _breathe = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _spin.stop();
      _breathe.stop();
    } else {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_breathe.isAnimating) _breathe.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = widget.size;
    // Bright pole of the orb: forest carries the surface, lime the light.
    final kern = Color.lerp(t.forest, t.lime, 0.55)!;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Glow. Static, and no longer dragged along: both animated layers
          // below sit behind their own RepaintBoundary, so this 40px shadow
          // blur is recorded once instead of once per animation frame.
          Positioned(
            left: -18,
            top: -18,
            right: -18,
            bottom: -18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: t.forest.withValues(alpha: 0.22),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          // Rotating ring. Outer boundary: keeps the per-frame rotation out of
          // the Stack's layer, so the glow above is not re-recorded with it.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _spin,
              // The blurred sweep is the builder's `child`, not part of the
              // builder body: built once, and behind its own RepaintBoundary
              // also painted once. Every frame then only swaps the transform
              // matrix instead of re-recording an ImageFilter layer at 60fps.
              //
              // Safe for this geometry: the ring is a full-bleed circle
              // centred in the box, Transform.rotate turns it about that same
              // centre, and an isotropic Gaussian (sigmaX == sigmaY) is
              // rotation-invariant — blurring then rotating and rotating then
              // blurring give the same pixels. Nothing depends on the sweep's
              // angle relative to the screen.
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  // Container, not DecoratedBox: this is the Stack's only
                  // unpositioned child, so it gets loose constraints and has
                  // to expand itself to fill them.
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient:
                          SweepGradient(colors: [t.forest, t.lime, t.forest]),
                    ),
                  ),
                ),
              ),
              builder: (_, child) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: child,
              ),
            ),
          ),
          // Breathing core. ScaleTransition already carries the gradient as
          // its `child`, so nothing is rebuilt per frame; the boundary is here
          // because the scale marks needs-paint every frame, which without it
          // would repaint the whole Stack layer — the glow's blur included.
          // No second boundary under the scale: the core is a plain gradient
          // with no filter, and its raster has to be redrawn at the new scale
          // either way, so a cached layer would only add compositing.
          Positioned.fill(
            left: 6,
            top: 6,
            right: 6,
            bottom: 6,
            child: RepaintBoundary(
              child: ScaleTransition(
                scale: Tween(begin: 1.0, end: 1.06).animate(
                    CurvedAnimation(parent: _breathe, curve: Curves.easeInOut)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.36, -0.4),
                      colors: [kern, t.forest],
                      stops: const [0, 0.75],
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
