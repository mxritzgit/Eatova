part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Coach orb (dark redesign): a violet sphere with a soft glow, a breathing
// core and a pulsing halo. Static under "reduce motion", same look.
// ---------------------------------------------------------------------------
class CoachOrb extends StatefulWidget {
  const CoachOrb({super.key, this.size = 76});

  /// Diameter of the sphere; the halo reaches [haloScale] times as far.
  final double size;

  /// Halo diameter relative to the sphere (design: 180 px around 76 px).
  static const double haloScale = 180 / 76;

  /// One breath of sphere and halo, there and back (design: 5 s).
  static const Duration period = Duration(seconds: 5);

  @override
  State<CoachOrb> createState() => _CoachOrbState();
}

class _CoachOrbState extends State<CoachOrb>
    with SingleTickerProviderStateMixin {
  /// 0 → 1 → 0 over [CoachOrb.period], eased like the design's keyframes.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: CoachOrb.period ~/ 2,
  );
  late final Animation<double> _eased = CurvedAnimation(
    parent: _breath,
    curve: Curves.easeInOut,
  );
  late final Animation<double> _coreScale = Tween<double>(
    begin: 1,
    end: 1.06,
  ).animate(_eased);
  late final Animation<double> _haloScale = Tween<double>(
    begin: 1,
    end: 1.12,
  ).animate(_eased);
  late final Animation<double> _haloOpacity = Tween<double>(
    begin: 0.55,
    end: 1,
  ).animate(_eased);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _breath
        ..stop()
        ..value = 0;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = widget.size;
    final halo = s * CoachOrb.haloScale;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Halo. Its own boundary keeps the per-frame fade and scale out of
          // the Stack layer; the gradient itself is built once as the child.
          Positioned(
            left: (s - halo) / 2,
            top: (s - halo) / 2,
            width: halo,
            height: halo,
            child: RepaintBoundary(
              child: FadeTransition(
                opacity: _haloOpacity,
                child: ScaleTransition(
                  scale: _haloScale,
                  child: DecoratedBox(
                    key: const ValueKey('coach-orb-halo'),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          t.accentGlow,
                          t.accentGlow.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Glow. Static and outside both animated layers, so its 36 px blur
          // is recorded once instead of once per frame.
          Positioned.fill(
            child: DecoratedBox(
              key: const ValueKey('coach-orb-glow'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: t.accentGlow.withValues(alpha: 0.55),
                    blurRadius: 36,
                  ),
                ],
              ),
            ),
          ),
          // Breathing sphere: lit from the upper left like the design's
          // `radial-gradient(circle at 34% 28%, …)`. The boundary sits above
          // the scale: the gradient is redrawn at each scale anyway, what is
          // worth having is the isolation from the glow next to it.
          Positioned.fill(
            child: RepaintBoundary(
              child: ScaleTransition(
                scale: _coreScale,
                child: DecoratedBox(
                  key: const ValueKey('coach-orb-core'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.32, -0.44),
                      // Farthest corner from that centre, as CSS sizes it.
                      radius: 0.98,
                      colors: [t.orbLight, t.orbBody, t.orbMid, t.orbDeep],
                      stops: const [0, 0.26, 0.62, 1],
                    ),
                  ),
                  // The design's inner shadow (`inset -8px -10px 18px`): the
                  // lower right rim darkens. The same circle moved 8/10 px up
                  // left stays clear; outside it the shadow blurs in.
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(-8 / 38, -10 / 38),
                        radius: 0.62,
                        colors: [
                          t.shadowTint.withValues(alpha: 0),
                          t.shadowTint.withValues(alpha: 0),
                          t.shadowTint.withValues(alpha: 0.45),
                        ],
                        stops: const [0, 0.61, 1],
                      ),
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
