import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Boot-/Welcome-Gate der App: „Fokus finden".
///
/// Waehrend ProfileSync.load() laeuft, sucht der Kamera-Fokusring der Marke
/// (das ◎ aus „eat◎va", s. eatova_wordmark.dart) sichtbar den Fokus: die
/// Ringspur steht gedimmt, ein Lime-Komet laeuft die Runde, der
/// Mittelpunkt-Dot atmet — der Ring IST der Ladeindikator, kein separater
/// Spinner. Sobald die Daten da sind, rastet der Fokus ein: die Spur wird
/// voll, die Ticks schnappen auf, der Ring schrumpft an seinen Platz im
/// Schriftzug, waehrend „eat" und „va" seitlich heraustreten — der Lader
/// wird buchstaeblich zum Logo. Bei frischem Login folgt „Willkommen, X",
/// bei Session-Restore direkt der Fade-out in die HomePage.
///
/// ABSICHT — dieser Screen folgt dem Anzeige-Modus NICHT:
/// Er ist der erste Eindruck der Marke, nicht eine Seite des Alltags. Deshalb
/// steht er in BEIDEN Modi auf derselben Flaeche: [AppTokens.forest] als Grund,
/// [AppTokens.lime] fuer Ring und Komet, [AppTokens.onForest] fuer die
/// Schrift. Das ist erlaubt, weil genau dieses Trio in beiden Paletten
/// kontrast-gesichert ist (`test/theme/app_tokens_test.dart` prueft
/// onForest/forest auf WCAG AA) — es braucht also keinen Helligkeits-Abzweig,
/// nur einen konstanten Marken-Auftritt.
///
/// Bitte NICHT auf `t.bg`/`t.ink` "korrigieren". Im Hellmodus wuerde daraus ein
/// beiger Screen mit fast unsichtbarem Lime-Ring; der Marken-Moment waere
/// weg. `test/widgets/welcome_screen_test.dart` haelt das fest.
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

  /// True nur bei frischem Login/Register: dann spielt nach dem Einrasten
  /// noch die "Willkommen, $firstName"-Sequenz mit Halte-Pause. Bei
  /// Session-Restore false -> die Marke rastet schnell ein und der Screen
  /// blendet direkt aus (Splash dient nur dazu Default-Flashes zu vermeiden).
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
    // A11y: unter reduzierter Bewegung kein Intro und KEIN Dauer-Loop —
    // die Marke steht sofort fertig zusammengesetzt da und der Screen ist
    // im Endzustand (Tests verlassen sich darauf, dass hier nichts tickt).
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
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
    // A11y: bei reduzierter Bewegung Einrasten + Halte-Pause auf ~instant
    // kollabieren — der User soll nicht aufs Intro-Gate warten.
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
    // Einrasten: der Ring wird zur Wortmarke (Session-Restore etwas
    // schneller — der Moment soll sitzen, nicht aufhalten).
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
    // Marken-Flaeche statt Modus-Flaeche — Begruendung am Klassenkopf.
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
                    // Orchestrierter Einstieg: Marke faedt ein, der Ring
                    // zeichnet sich, Ticks und Dot folgen, dann uebernimmt
                    // der Suchlauf (Komet + Dot-Atmung).
                    final appear = seg(0.0, 0.35, Curves.easeOutCubic);
                    final draw = seg(0.08, 0.60, Curves.easeInOutCubic);
                    final ticksIn = seg(0.52, 0.86, Curves.easeOutCubic);
                    final dotPop = seg(0.62, 0.95, Curves.easeOutBack);
                    final cometIn = seg(0.60, 0.80, Curves.easeOutCubic);
                    // Einrasten: Position/Groesse laufen ueber die geeaste
                    // Kurve, der Komet verabschiedet sich im ersten Drittel.
                    final av =
                        _reduceMotion ? 1.0 : _assembleController.value;
                    final assemble = Curves.easeInOutCubic.transform(av);
                    final hunt =
                        _reduceMotion ? 0.0 : 1 - (av / 0.35).clamp(0.0, 1.0);
                    // Atem-Phase des Dots: eine volle Welle pro Runde.
                    final breath = 0.5 -
                        0.5 * math.cos(2 * math.pi * _loopController.value);
                    // Gemalter Schriftzug -> fuer Screenreader ein Label.
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
                // Reservierte Hoehe, damit die Marke beim Einblenden des
                // Willkommens-Texts nicht springt. Bewusst eine MINDEST-Hoehe
                // und mit der Systemschrift skaliert: bei textScaler 2.0
                // braucht der zweizeilige Willkommens-Text mehr als 68 px,
                // und eine feste Hoehe waere dort ein RenderFlex-Ueberlauf
                // statt einer ruhigen Kante.
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

/// Zeichnet die komplette Boot-Marke in einem Painter: Fokusring (Kreis,
/// vier Ticks, Mittelpunkt-Dot — Geometrie identisch zu
/// eatova_wordmark.dart) plus die Schriftzuege „eat" und „va".
///
/// Der Ring lebt in ZWEI Zustaenden, die [assemble] ueberblendet:
///  * 0 — Suchlauf: gross und allein in der Mitte, Spur gedimmt, ein
///    Lime-Komet laeuft die Runde, der Dot atmet ([hunt] = 1).
///  * 1 — eingerastet: volle Spur, Ticks auf voller Deckkraft, geschrumpft
///    auf Wortmarken-Groesse an seinem Platz zwischen „eat" und „va".
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

  /// Schriftgroesse der fertigen Wortmarke — bewusst groesser als die 26 des
  /// Auth-Screens: hier ist die Marke der ganze Auftritt.
  static const double _fontSize = 30;

  /// Kantenlaenge der Fokusring-Box im Suchlauf (vor dem Einrasten).
  static const double _loaderBox = 76;

  final Color ring;
  final Color text;

  /// 0..1 Einblendung der ganzen Marke beim Intro.
  final double appear;

  /// 0..1 Kreis-Einzeichnung (Bogen ab 12 Uhr).
  final double draw;

  /// 0..1 gestaffeltes Erscheinen der vier Ticks.
  final double ticksIn;

  /// 0..1 Dot-Pop (easeOutBack, darf leicht ueberschiessen).
  final double dotPop;

  /// 0..1 Einblendung des Kometen nach fertig gezeichnetem Kreis.
  final double cometIn;

  /// Position des Kometen-Kopfs, 0..1 = eine volle Runde.
  final double orbit;

  /// 0..1 Atem-Phase des Dots (nur im Suchlauf sichtbar).
  final double breath;

  /// 1 = Suchlauf (gedimmte Spur, Komet, Atmung), 0 = eingerastet.
  final double hunt;

  /// 0..1 Einrasten: Ring schrumpft/gleitet an seinen Wortmarken-Platz,
  /// die Buchstaben treten seitlich heraus. Kommt bereits geeast herein.
  final double assemble;

  @override
  void paint(Canvas canvas, Size size) {
    if (appear <= 0.001) return;
    final center = size.center(Offset.zero);

    // Intro: die ganze Marke skaliert dezent ein.
    canvas.save();
    final introScale = 0.92 + 0.08 * appear;
    canvas.translate(center.dx, center.dy);
    canvas.scale(introScale);
    canvas.translate(-center.dx, -center.dy);

    const inlineBox = _fontSize * 0.82;
    final w = _loaderBox + (inlineBox - _loaderBox) * assemble;
    const pad = _fontSize * 0.05;

    // Buchstaben nur vermessen, sobald sie sichtbar werden.
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

    // Ring-Platz in der fertigen Wortmarke; waehrend des Suchlaufs steht er
    // in der Mitte. Der vertikale Versatz (fontSize * 0.09) setzt ihn wie in
    // eatova_wordmark.dart optisch auf die Mittellinie der Kleinbuchstaben.
    final ringCenterFinal = Offset(
      center.dx - totalW / 2 + (eat?.width ?? 0) + pad + w / 2,
      center.dy + _fontSize * 0.09,
    );
    final ringCenter = Offset.lerp(center, ringCenterFinal, assemble)!;

    // Geometrie wie _FocusRingPainter (eatova_wordmark.dart), nur auf die
    // animierte Boxgroesse w bezogen.
    final stroke = w * 0.105;
    final tick = w * 0.115;
    final gap = w * 0.075;
    final ringRadius = w / 2 - tick - gap - stroke / 2;
    final dotR = w * 0.10;
    final rect = Rect.fromCircle(center: ringCenter, radius: ringRadius);

    // Kreis: waehrend des Suchlaufs gedimmte Spur, beim Einrasten voll.
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

    // Komet: der Fokus "sucht" — gedimmter Schweif, heller Kopf mit weichem
    // Glow. Laeuft nur im Suchlauf und erst, wenn der Kreis fertig ist.
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

    // Vier Ticks auf 12/3/6/9 Uhr, gestaffelt eingeblendet. Im Suchlauf
    // halb gedimmt, beim Einrasten schnappen sie auf volle Deckkraft —
    // das "Fokus sitzt"-Signal.
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

    // Mittelpunkt-Dot: poppt beim Intro, atmet im Suchlauf.
    if (dotPop > 0) {
      final r = dotR * dotPop * (1 + 0.10 * breath * hunt);
      canvas.drawCircle(
        ringCenter,
        r,
        Paint()..color = ring.withValues(alpha: appear),
      );
    }

    // Buchstaben: treten beim Einrasten seitlich aus dem Ring heraus.
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Willkommen, $firstName.',
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
          'Du bist drin.',
          textAlign: TextAlign.center,
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            // Gedaempft, aber auf der Marken-Flaeche — nicht t.ink2, das ist
            // fuer den Modus-Grund gestimmt und liefe hier gegen forest.
            color: t.onForest.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}
