import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../common/motion.dart';

/// Boot-/Welcome-Gate der App. Waehrend ProfileSync.load() laeuft, "laedt"
/// das Bolt-Logo sichtbar auf: ein Lime-Komet wandert um den Kapsel-Rahmen
/// (der Rahmen IST der Ladeindikator, kein separater Spinner), der Glow
/// atmet, das "Eatova"-Wortmark trackt sich ein. Bei frischem Login folgt
/// Check-Morph + "Willkommen, X", bei Session-Restore direkt der Fade-out
/// in die HomePage.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.firstName,
    required this.profileReady,
    required this.onComplete,
    this.celebrateLogin = false,
  });

  /// Vorname fuer die Begruessung. Faellt auf "Pilot" zurueck.
  final String firstName;

  /// Future das resolved sobald der Profil-Load durch ist.
  final Future<void> profileReady;

  /// Wird gerufen wenn die Welcome-Animation komplett durchgelaufen ist
  /// und die Page sich zur HomePage weiterklicken soll.
  final VoidCallback onComplete;

  /// True nur bei frischem Login/Register: dann spielt nach dem Load
  /// noch die Check-Icon + "Willkommen, $firstName"-Animation. Bei
  /// Session-Restore false -> direkt durchspringen sobald Daten da
  /// sind (Splash dient nur dazu Default-Flashes zu vermeiden).
  final bool celebrateLogin;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _loopController;
  late final AnimationController _checkController;
  late final AnimationController _exitController;
  bool _showCheck = false;
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
    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
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
    // A11y: unter reduzierter Bewegung kein Intro und KEIN Dauer-Loop —
    // der Ring bleibt als statische Spur stehen und der Screen ist sofort
    // im Endzustand (Tests verlassen sich darauf, dass hier nichts tickt).
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion) {
      _introController.value = 1;
    } else {
      _introController.forward();
      _loopController.repeat();
    }
  }

  Future<void> _onProfileReady(void _) async {
    if (!mounted) return;
    // A11y: bei reduzierter Bewegung Animationen + Halte-Pause auf ~instant
    // kollabieren — der User soll nicht aufs Intro-Gate warten.
    _checkController.duration =
        motionDuration(context, const Duration(milliseconds: 520));
    _exitController.duration =
        motionDuration(context, const Duration(milliseconds: 320));
    final holdDelay =
        motionDelay(context, const Duration(milliseconds: 900));
    if (!widget.celebrateLogin) {
      // Session-Restore: kurz ausfaden und direkt zum Home.
      await _exitController.forward();
      if (!mounted) return;
      widget.onComplete();
      return;
    }
    setState(() => _showCheck = true);
    await _checkController.forward();
    if (!mounted) return;
    _loopController.stop();
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
    _checkController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('screen-welcome'),
      backgroundColor: bg,
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
            child: AnimatedBuilder(
              animation: Listenable.merge(
                [_introController, _loopController, _checkController],
              ),
              builder: (context, _) {
                final iv = _introController.value;
                double seg(double a, double b, Curve curve) =>
                    curve.transform(((iv - a) / (b - a)).clamp(0.0, 1.0));
                // Orchestrierter Einstieg: Logo poppt, dann Ring, dann Text.
                final logoIn = seg(0.0, 0.42, Curves.easeOutCubic);
                final logoPop = seg(0.0, 0.55, Curves.easeOutBack);
                final ringIn = seg(0.40, 0.78, Curves.easeOutCubic);
                final textIn = seg(0.28, 1.0, Curves.easeOutCubic);
                // Atem-Phase des Glows: eine volle Welle pro Ring-Runde.
                final breath =
                    0.5 - 0.5 * math.cos(2 * math.pi * _loopController.value);
                // Check-Morph (nur celebrateLogin): die ersten ~45% der
                // Check-Animation fuellen die Kapsel und blenden Ring +
                // Atmung aus, danach zeichnet sich der Haken.
                final morph = Curves.easeOutCubic
                    .transform((_checkController.value / 0.45).clamp(0.0, 1.0));

                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _BootLogo(
                      showCheck: _showCheck,
                      checkController: _checkController,
                      appear: logoIn,
                      pop: logoPop,
                      ringOpacity: ringIn * (1 - morph),
                      ringT: _loopController.value,
                      breath: breath * (1 - morph),
                      morph: morph,
                      staticRing: _reduceMotion,
                    ),
                    const SizedBox(height: 26),
                    // Feste Hoehe, damit der Logo-Block beim Wechsel
                    // Wortmark -> Willkommens-Text nicht springt.
                    SizedBox(
                      height: 68,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeIn,
                        child: _showCheck
                            ? _WelcomeText(
                                key: const ValueKey('welcome-text'),
                                firstName: widget.firstName,
                              )
                            : _BootWordmark(
                                key: const ValueKey('loading-hint'),
                                reveal: textIn,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _BootLogo extends StatelessWidget {
  const _BootLogo({
    required this.showCheck,
    required this.checkController,
    required this.appear,
    required this.pop,
    required this.ringOpacity,
    required this.ringT,
    required this.breath,
    required this.morph,
    required this.staticRing,
  });

  final bool showCheck;
  final AnimationController checkController;

  /// 0..1 Einblendung beim Intro.
  final double appear;

  /// easeOutBack-Skalierung beim Intro (leichter Overshoot).
  final double pop;

  /// Sichtbarkeit des Lade-Rings.
  final double ringOpacity;

  /// Position des Lade-Kometen, 0..1 = eine Runde um die Kapsel.
  final double ringT;

  /// 0..1 Atem-Phase von Glow + Skalierung.
  final double breath;

  /// 0..1 Check-Morph: Kapsel waechst und fuellt sich lime.
  final double morph;

  /// Reduzierte Bewegung: nur die statische Ring-Spur zeichnen.
  final bool staticRing;

  @override
  Widget build(BuildContext context) {
    final capsuleSize = 72 + 12 * morph;
    final capsuleRadius = rSheet + 2 * morph;
    final fill = Color.lerp(lime.withValues(alpha: 0.16), lime, morph)!;
    final scale = (0.86 + 0.14 * pop) * (1 + 0.02 * breath);

    return Opacity(
      opacity: appear,
      child: Transform.scale(
        scale: scale,
        child: SizedBox(
          width: 112,
          height: 112,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: ringOpacity.clamp(0.0, 1.0),
                child: CustomPaint(
                  size: const Size(94, 94),
                  painter: _ChargeRingPainter(t: ringT, animate: !staticRing),
                ),
              ),
              Container(
                width: capsuleSize,
                height: capsuleSize,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(capsuleRadius),
                  boxShadow: [
                    // Naher Glow, atmet im Takt des Rings.
                    BoxShadow(
                      color: lime.withValues(
                        alpha: 0.10 + 0.08 * breath + 0.25 * morph,
                      ),
                      blurRadius: 20 + 6 * breath + 10 * morph,
                      offset: const Offset(0, 8),
                    ),
                    // Weiter Ambient-Halo statt separatem Hintergrund-Layer.
                    BoxShadow(
                      color: lime.withValues(
                        alpha: 0.04 + 0.03 * breath + 0.04 * morph,
                      ),
                      blurRadius: 48,
                      spreadRadius: 6,
                    ),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutBack,
                        ),
                      ),
                      child: child,
                    ),
                  );
                },
                child: showCheck
                    ? _AnimatedCheck(
                        key: const ValueKey('check'),
                        controller: checkController,
                      )
                    : const Icon(
                        Icons.bolt_rounded,
                        key: ValueKey('bolt'),
                        color: lime,
                        size: 34,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Der Ladeindikator: eine feine Spur um die Logo-Kapsel plus ein
/// Lime-Komet (gedimmter Schweif, heller Kopf mit weichem Glow), der
/// die Runde entlangwandert — das Logo "laedt auf".
class _ChargeRingPainter extends CustomPainter {
  const _ChargeRingPainter({required this.t, required this.animate});

  /// Position des Kometen-Kopfs, 0..1 = eine volle Runde.
  final double t;

  /// False unter reduzierter Bewegung: dann nur die statische Spur.
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(1.5),
      const Radius.circular(33),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = lime.withValues(alpha: 0.10),
    );
    if (!animate) return;

    final metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final len = metric.length;
    final head = t * len;

    final tail = _segment(metric, head - len * 0.30, len * 0.30);
    final tip = _segment(metric, head - len * 0.10, len * 0.10);
    canvas.drawPath(
      tail,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..color = lime.withValues(alpha: 0.26),
    );
    // Weicher Glow unter dem Kopf, dann der scharfe Kopf selbst.
    canvas.drawPath(
      tip,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = lime.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      tip,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = lime.withValues(alpha: 0.95),
    );
  }

  /// Pfad-Segment mit Wraparound am Rundenende.
  Path _segment(ui.PathMetric metric, double start, double length) {
    final len = metric.length;
    var s = start % len;
    if (s < 0) s += len;
    final e = s + length;
    final path = metric.extractPath(s, math.min(e, len));
    if (e > len) {
      path.addPath(metric.extractPath(0, e - len), Offset.zero);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _ChargeRingPainter old) =>
      old.t != t || old.animate != animate;
}

class _AnimatedCheck extends StatelessWidget {
  const _AnimatedCheck({super.key, required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return CustomPaint(
          size: const Size(34, 34),
          painter: _CheckPainter(progress: controller.value),
        );
      },
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = bg
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Pfad: linker tiefer Punkt -> unterer Knick -> oberer Endpunkt.
    final a = Offset(size.width * 0.20, size.height * 0.52);
    final b = Offset(size.width * 0.44, size.height * 0.72);
    final c = Offset(size.width * 0.80, size.height * 0.32);

    // Erste Haelfte: a -> b. Zweite Haelfte: b -> c.
    final t = progress.clamp(0.0, 1.0);
    final path = Path()..moveTo(a.dx, a.dy);
    if (t <= 0.5) {
      final localT = t / 0.5;
      path.lineTo(
        a.dx + (b.dx - a.dx) * localT,
        a.dy + (b.dy - a.dy) * localT,
      );
    } else {
      final localT = (t - 0.5) / 0.5;
      path
        ..lineTo(b.dx, b.dy)
        ..lineTo(
          b.dx + (c.dx - b.dx) * localT,
          b.dy + (c.dy - b.dy) * localT,
        );
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) => old.progress != progress;
}

/// "Eatova"-Wortmark, das sich beim Intro eintrackt: Letter-Spacing
/// zieht sich von weit auf eng zusammen, waehrend es einfadet und
/// leicht aufsteigt. Kein separater Spinner — das Laden zeigt der Ring.
class _BootWordmark extends StatelessWidget {
  const _BootWordmark({super.key, required this.reveal});

  /// 0..1 Intro-Fortschritt.
  final double reveal;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: reveal,
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - reveal)),
        child: Text(
          'Eatova',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 3.4 - 3.8 * reveal,
            color: textPrimary,
          ),
        ),
      ),
    );
  }
}

class _WelcomeText extends StatelessWidget {
  const _WelcomeText({super.key, required this.firstName});

  final String firstName;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Willkommen, $firstName.',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Du bist drin.',
          style: TextStyle(
            color: textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
