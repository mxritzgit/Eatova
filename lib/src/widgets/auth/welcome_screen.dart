import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Boot/welcome gate: "finding focus".
///
/// While ProfileSync.load() runs, the brand's focus ring *is* the loading
/// indicator — dimmed track, a lime comet orbiting, a breathing centre dot.
/// Once data arrives the focus locks in: full track, ticks snap on, the ring
/// shrinks into its place in the wordmark while "eat" and "va" slide out. A
/// fresh login then shows the greeting; a session restore fades straight out.
///
/// Intentional: this screen does NOT follow the display mode. It uses
/// [AppTokens.forest], [AppTokens.lime] and [AppTokens.onForest] in both
/// themes, which is safe because that trio is contrast-checked in both
/// palettes. Do not "fix" it to `t.bg`/`t.ink` — in light mode that gives a
/// beige screen with a near-invisible ring.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.firstName,
    required this.profileReady,
    required this.onComplete,
    this.celebrateLogin = false,
  });

  /// First name for the greeting (see `EatovaUser.firstNameFor`).
  final String firstName;

  /// Resolves once the profile load is done.
  final Future<void> profileReady;

  /// Called when the welcome animation has finished and the page should move
  /// on to the HomePage.
  final VoidCallback onComplete;

  /// True only on a fresh login/register: plays the greeting with a hold after
  /// the lock-in. False on session restore, where the mark locks in quickly and
  /// the screen fades straight out.
  final bool celebrateLogin;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _loopController;
  late final AnimationController _assembleController;
  late final AnimationController _exitController;
  bool _showWelcome = false;
  bool _bootStarted = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    );
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _assembleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    widget.profileReady.then(_onProfileReady);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootStarted) return;
    _bootStarted = true;
    // A11y: with reduced motion, no intro and no endless loop — the mark is
    // assembled immediately. Tests rely on nothing ticking here.
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) {
      _introController.value = 1;
      _assembleController.value = 1;
    } else {
      _introController.forward();
      _loopController.repeat();
    }
  }

  Future<void> _onProfileReady(void _) async {
    if (!mounted) return;
    // A11y: reduced motion collapses lock-in and hold to near-instant.
    _assembleController.duration = motionDuration(
      context,
      Duration(milliseconds: widget.celebrateLogin ? 460 : 380),
    );
    _exitController.duration =
        motionDuration(context, const Duration(milliseconds: 320));
    final holdDelay = motionDelay(
      context,
      Duration(milliseconds: widget.celebrateLogin ? 900 : 0),
    );
    // Lock in: the ring becomes the wordmark (faster on session restore).
    await _assembleController.forward();
    if (!mounted) return;
    _loopController.stop();
    if (widget.celebrateLogin) {
      setState(() => _showWelcome = true);
    }
    if (holdDelay > Duration.zero) await Future<void>.delayed(holdDelay);
    if (!mounted) return;
    await _exitController.forward();
    if (!mounted) return;
    widget.onComplete();
  }

  @override
  void dispose() {
    _introController.dispose();
    _loopController.dispose();
    _assembleController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Brand surface, not the mode surface — see the class doc.
    return Scaffold(
      key: const ValueKey('screen-welcome'),
      backgroundColor: t.forest,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _exitController,
          builder: (context, child) {
            final exit = _exitController.value;
            return Opacity(
              opacity: 1 - exit,
              child: Transform.translate(
                offset: Offset(0, -16 * exit),
                child: Transform.scale(
                  scale: 1 - 0.015 * exit,
                  child: child,
                ),
              ),
            );
          },
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: Listenable.merge(
                    [_introController, _loopController, _assembleController],
                  ),
                  builder: (context, _) {
                    final iv = _introController.value;
                    double seg(double a, double b, Curve curve) =>
                        curve.transform(((iv - a) / (b - a)).clamp(0.0, 1.0));
                    // Staged intro: the mark fades in, the ring draws itself,
                    // ticks and dot follow, then the hunt takes over.
                    final appear = seg(0.0, 0.35, Curves.easeOutCubic);
                    final draw = seg(0.08, 0.60, Curves.easeInOutCubic);
                    final ticksIn = seg(0.52, 0.86, Curves.easeOutCubic);
                    final dotPop = seg(0.62, 0.95, Curves.easeOutBack);
                    final cometIn = seg(0.60, 0.80, Curves.easeOutCubic);
                    // Lock-in: position/size follow the eased curve, the comet
                    // leaves within the first third.
                    final av =
                        _reduceMotion ? 1.0 : _assembleController.value;
                    final assemble = Curves.easeInOutCubic.transform(av);
                    final hunt =
                        _reduceMotion ? 0.0 : 1 - (av / 0.35).clamp(0.0, 1.0);
                    // Dot breathing: one full wave per orbit.
                    final breath = 0.5 -
                        0.5 * math.cos(2 * math.pi * _loopController.value);
                    // Painted lettering, so screen readers need a label.
                    return Semantics(
                      label: 'Eatova',
                      child: SizedBox(
                        key: const ValueKey('boot-mark'),
                        width: 280,
                        height: 132,
                        child: CustomPaint(
                          painter: _BootMarkPainter(
                            ring: t.lime,
                            text: t.onForest,
                            appear: appear,
                            draw: draw,
                            ticksIn: ticksIn,
                            dotPop: dotPop,
                            cometIn: cometIn,
                            orbit: _loopController.value,
                            breath: breath,
                            hunt: hunt,
                            assemble: assemble,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 26),
                // Reserved height so the mark does not jump when the greeting
                // appears. A MINIMUM, scaled with the system text size: at
                // textScaler 2.0 the two-line greeting needs more than 68 px,
                // and a fixed height would overflow there.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: MediaQuery.textScalerOf(context).scale(68),
                  ),
                  child: AnimatedSwitcher(
                    duration: motionDuration(
                      context,
                      const Duration(milliseconds: 260),
                    ),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    child: _showWelcome
                        ? _WelcomeText(
                            key: const ValueKey('welcome-text'),
                            firstName: widget.firstName,
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('boot-hold'),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the whole boot mark: focus ring (circle, four ticks, centre dot —
/// geometry identical to eatova_wordmark.dart) plus the "eat" and "va"
/// lettering.
///
/// [assemble] cross-fades the ring's two states: 0 = hunting (large, centred,
/// dimmed track, orbiting comet, breathing dot), 1 = locked in (full track,
/// opaque ticks, shrunk to wordmark size between the letters).
class _BootMarkPainter extends CustomPainter {
  const _BootMarkPainter({
    required this.ring,
    required this.text,
    required this.appear,
    required this.draw,
    required this.ticksIn,
    required this.dotPop,
    required this.cometIn,
    required this.orbit,
    required this.breath,
    required this.hunt,
    required this.assemble,
  });

  /// Font size of the assembled wordmark; larger than the auth screen's 26
  /// because here the mark is the whole stage.
  static const double _fontSize = 30;

  /// Edge length of the focus-ring box while hunting (before lock-in).
  static const double _loaderBox = 76;

  final Color ring;
  final Color text;

  /// 0..1 fade-in of the whole mark during the intro.
  final double appear;

  /// 0..1 circle drawing (arc from 12 o'clock).
  final double draw;

  /// 0..1 staggered appearance of the four ticks.
  final double ticksIn;

  /// 0..1 dot pop (easeOutBack, may overshoot slightly).
  final double dotPop;

  /// 0..1 comet fade-in once the circle is drawn.
  final double cometIn;

  /// Comet head position; 0..1 is one full orbit.
  final double orbit;

  /// 0..1 dot breathing phase (visible only while hunting).
  final double breath;

  /// 1 = hunting (dimmed track, comet, breathing), 0 = locked in.
  final double hunt;

  /// 0..1 lock-in: the ring shrinks into its wordmark slot and the letters
  /// slide out. Arrives already eased.
  final double assemble;

  @override
  void paint(Canvas canvas, Size size) {
    if (appear <= 0.001) return;
    final center = size.center(Offset.zero);

    // Intro: the whole mark scales in slightly.
    canvas.save();
    final introScale = 0.92 + 0.08 * appear;
    canvas.translate(center.dx, center.dy);
    canvas.scale(introScale);
    canvas.translate(-center.dx, -center.dy);

    const inlineBox = _fontSize * 0.82;
    final w = _loaderBox + (inlineBox - _loaderBox) * assemble;
    const pad = _fontSize * 0.05;

    // Only lay out the letters once they become visible.
    final letterAlpha = (appear * assemble).clamp(0.0, 1.0);
    TextPainter? eat;
    TextPainter? va;
    var totalW = w;
    if (letterAlpha > 0.001) {
      TextPainter layoutOf(String s) => TextPainter(
            text: TextSpan(
              text: s,
              style: AppType.display(
                _fontSize,
                weight: FontWeight.w800,
                letterSpacing: _fontSize * -0.02,
                height: 1.0,
                color: text.withValues(alpha: letterAlpha),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
      eat = layoutOf('eat');
      va = layoutOf('va');
      totalW = eat.width + pad * 2 + w + va.width;
    }

    // The ring's slot in the finished wordmark; centred while hunting. The
    // vertical offset puts it on the lowercase midline, as in the wordmark.
    final ringCenterFinal = Offset(
      center.dx - totalW / 2 + (eat?.width ?? 0) + pad + w / 2,
      center.dy + _fontSize * 0.09,
    );
    final ringCenter = Offset.lerp(center, ringCenterFinal, assemble)!;

    // Same geometry as _FocusRingPainter, relative to the animated box w.
    final stroke = w * 0.105;
    final tick = w * 0.115;
    final gap = w * 0.075;
    final ringRadius = w / 2 - tick - gap - stroke / 2;
    final dotR = w * 0.10;
    final rect = Rect.fromCircle(center: ringCenter, radius: ringRadius);

    // Circle: dimmed track while hunting, full once locked in.
    final trackAlpha = (0.30 + 0.70 * (1 - hunt)) * appear;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * draw,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = ring.withValues(alpha: trackAlpha),
    );

    // Comet: dimmed tail, bright head with a soft glow. Runs only while
    // hunting and only once the circle is complete.
    final cometAlpha = hunt * cometIn * appear;
    if (cometAlpha > 0.001) {
      final head = -math.pi / 2 + 2 * math.pi * orbit;
      const tailSweep = math.pi * 0.5;
      const headSweep = math.pi * 0.16;
      canvas.drawArc(
        rect,
        head - tailSweep,
        tailSweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = ring.withValues(alpha: 0.30 * cometAlpha),
      );
      canvas.drawArc(
        rect,
        head - headSweep,
        headSweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke + 2
          ..strokeCap = StrokeCap.round
          ..color = ring.withValues(alpha: 0.35 * cometAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawArc(
        rect,
        head - headSweep,
        headSweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = ring.withValues(alpha: 0.95 * cometAlpha),
      );
    }

    // Four ticks at 12/3/6/9, staggered in. Half dimmed while hunting, they
    // snap to full opacity on lock-in — the "focus found" signal.
    final tickPaint = Paint()
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..color = ring.withValues(alpha: (0.55 + 0.45 * (1 - hunt)) * appear);
    final inner = ringRadius + stroke / 2 + gap;
    const dirs = [Offset(0, -1), Offset(1, 0), Offset(0, 1), Offset(-1, 0)];
    for (var i = 0; i < dirs.length; i++) {
      final local = ((ticksIn - i * 0.12) / 0.64).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final d = dirs[i];
      canvas.drawLine(
        ringCenter + d * inner,
        ringCenter + d * (inner + tick * local),
        tickPaint,
      );
    }

    // Centre dot: pops during the intro, breathes while hunting.
    if (dotPop > 0) {
      final r = dotR * dotPop * (1 + 0.10 * breath * hunt);
      canvas.drawCircle(
        ringCenter,
        r,
        Paint()..color = ring.withValues(alpha: appear),
      );
    }

    // Letters slide out sideways from the ring during lock-in.
    if (eat != null && va != null) {
      final slide = 10 * (1 - assemble);
      final eatX = ringCenter.dx - w / 2 - pad - eat.width + slide;
      final vaX = ringCenter.dx + w / 2 + pad - slide;
      final textY = center.dy - eat.height / 2;
      eat.paint(canvas, Offset(eatX, textY));
      va.paint(canvas, Offset(vaX, textY));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BootMarkPainter old) =>
      old.ring != ring ||
      old.text != text ||
      old.appear != appear ||
      old.draw != draw ||
      old.ticksIn != ticksIn ||
      old.dotPop != dotPop ||
      old.cometIn != cometIn ||
      old.orbit != orbit ||
      old.breath != breath ||
      old.hunt != hunt ||
      old.assemble != assemble;
}

class _WelcomeText extends StatelessWidget {
  const _WelcomeText({super.key, required this.firstName});

  final String firstName;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.onboardingWelcomeTitle(firstName),
          textAlign: TextAlign.center,
          style: AppType.display(
            22,
            weight: FontWeight.w700,
            letterSpacing: -0.4,
            color: t.onForest,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.authWelcomeSignedIn,
          textAlign: TextAlign.center,
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            // Muted, but on the brand surface — not t.ink2, which is tuned
            // for the mode background and would clash with forest.
            color: t.onForest.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}
