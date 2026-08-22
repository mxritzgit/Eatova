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
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
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
          // Glow
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
          // Rotating ring
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _spin,
              builder: (_, __) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                          colors: [t.forest, t.lime, t.forest]),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Breathing core
          Positioned.fill(
            left: 6,
            top: 6,
            right: 6,
            bottom: 6,
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
        ],
      ),
    );
  }
}
