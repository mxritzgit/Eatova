import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../shared/eatova_wordmark.dart';

/// Boot/welcome gate: the focus ring locks in.
///
/// The first frame repeats the native launch screen exactly: the page ground
/// with the focus ring alone, 80 logical px, centred on the full screen (see
/// `tool/launch_mark.py`). So a cold start hands over from native to Flutter
/// without a visible change. From there:
///  * profile slow: after a beat the ring hunts for focus, a quarter turn of
///    the ticks with the lens contracting, then a rest; the mark itself is
///    the loading indicator, no spinner;
///  * profile ready: the ring shrinks into its slot in the wordmark while
///    "eat" and "va" emerge from behind it, then the stage fades out. On a
///    session restore that is about 600 ms from data to home;
///  * fresh login: the ring is revealed first (it follows the auth screen,
///    not the native splash), and after the lock-in a short greeting holds.
///
/// Colours are mode tokens (`bg`, `ink`, `inkMuted`, `accent`): in the dark
/// palette `bg` is the native launch colour #09090C, and the light palette's
/// pairs keep the mark and greeting readable should light mode return.
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

  /// Edge length of the focus ring before the lock-in, in logical px. The
  /// native launch marks are drawn at exactly this size (dp / pt), see
  /// `tool/launch_mark.py`; test/launch_screen_handoff_test.dart pins both.
  static const double launchMarkSize = 80;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

/// Soft start, long landing: the ring moves as one decisive gesture.
const Curve _kLockCurve = Cubic(0.3, 0.0, 0.0, 1.0);

/// Entrances (reveal, letters, greeting): fast start, no overshoot.
const Curve _kEnterCurve = Cubic(0.2, 0.0, 0.0, 1.0);

/// Exit: holds still a moment, then gets out of the way.
const Curve _kExitCurve = Cubic(0.4, 0.0, 1.0, 1.0);

/// One focus hunt: rest first, then a quarter turn. The leading rest means a
/// profile that arrives within ~0.5 s never sees the loader move.
const Duration _kHuntPeriod = Duration(milliseconds: 1200);
const double _kHuntRest = 0.4;

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _loopController;
  late final AnimationController _lockController;
  late final AnimationController _exitController;
  bool _showWelcome = false;
  bool _bootStarted = false;

  /// Hunt position (quarter turns, 0..1) when the profile arrived; the
  /// lock-in finishes that turn instead of snapping back.
  double _turnAtLock = 0;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _loopController = AnimationController(vsync: this, duration: _kHuntPeriod);
    _lockController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 560),
    );
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    widget.profileReady.then(_onProfileReady);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootStarted) return;
    _bootStarted = true;
    // A11y: with reduced motion the ring stands still, as on the native
    // launch screen: no reveal, no hunt. Tests rely on nothing ticking here.
    final still = reducedMotion(context);
    if (still || !widget.celebrateLogin) {
      // Cold start: the native launch screen already showed the ring.
      _introController.value = 1;
    } else {
      _introController.forward();
    }
    if (!still) _loopController.repeat();
  }

  double _huntTurn() {
    final p = _loopController.value;
    if (p <= _kHuntRest) return 0;
    return Curves.easeInOutCubic.transform((p - _kHuntRest) / (1 - _kHuntRest));
  }

  Future<void> _onProfileReady(void _) async {
    if (!mounted) return;
    // A11y: reduced motion collapses lock-in, hold and exit to instant.
    _lockController.duration = motionDuration(
      context,
      Duration(milliseconds: widget.celebrateLogin ? 560 : 380),
    );
    _exitController.duration = motionDuration(
      context,
      Duration(milliseconds: widget.celebrateLogin ? 300 : 240),
    );
    final holdDelay = motionDelay(
      context,
      Duration(milliseconds: widget.celebrateLogin ? 1000 : 0),
    );
    _turnAtLock = _loopController.isAnimating ? _huntTurn() : 0;
    _loopController.stop();
    // Never waits for a running reveal: it finishes inside the lock-in.
    final locked = _lockController.forward();
    if (widget.celebrateLogin) {
      // The greeting starts while the wordmark is still landing, so the two
      // read as one gesture.
      await Future<void>.delayed(_lockController.duration! * 0.7);
      if (!mounted) return;
      setState(() => _showWelcome = true);
    }
    await locked;
    if (!mounted) return;
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
    _lockController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final mark = AnimatedBuilder(
      animation: Listenable.merge([
        _introController,
        _loopController,
        _lockController,
      ]),
      builder: (context, _) {
        final lock = _lockController.value;
        final turn = _lockController.isDismissed
            ? _huntTurn()
            : _turnAtLock == 0
            ? 0.0
            // The interrupted quarter turn completes early in the lock-in,
            // so the ticks stand square before the lettering arrives.
            : _turnAtLock +
                  (1 - _turnAtLock) *
                      _kEnterCurve.transform((lock / 0.45).clamp(0.0, 1.0));
        // Painted lettering, so screen readers need a label.
        return Semantics(
          label: 'Eatova',
          child: SizedBox(
            key: const ValueKey('boot-mark'),
            width: 300,
            height: _LaunchMarkPainter.stageHeight,
            child: CustomPaint(
              painter: _LaunchMarkPainter(
                ring: t.accent,
                text: t.ink,
                intro: _introController.value,
                turn: turn,
                lock: lock,
              ),
            ),
          ),
        );
      },
    );
    final greeting = AnimatedSwitcher(
      duration: motionDuration(context, const Duration(milliseconds: 420)),
      switchInCurve: _kEnterCurve,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: _showWelcome
          ? _WelcomeText(
              key: const ValueKey('welcome-text'),
              firstName: widget.firstName,
            )
          : const SizedBox.shrink(key: ValueKey('boot-hold')),
    );
    return Scaffold(
      key: const ValueKey('screen-welcome'),
      backgroundColor: t.bg,
      body: AnimatedBuilder(
        animation: _exitController,
        builder: (context, child) {
          final exit = _kExitCurve.transform(_exitController.value);
          return Opacity(
            opacity: 1 - exit,
            child: Transform.scale(scale: 1 - 0.02 * exit, child: child),
          );
        },
        // No SafeArea: the mark centres on the full screen, like the native
        // launch screen. The layout keeps the greeting inside the insets.
        child: CustomMultiChildLayout(
          delegate: _StageLayout(
            insets:
                MediaQuery.viewPaddingOf(context) + const EdgeInsets.all(24),
          ),
          children: [
            LayoutId(id: _StageSlot.mark, child: mark),
            LayoutId(id: _StageSlot.greeting, child: greeting),
          ],
        ),
      ),
    );
  }
}

enum _StageSlot { mark, greeting }

/// Centres the mark on the full screen and hangs the greeting below it. Only
/// when the greeting would cross the bottom inset (large text on a short
/// screen) does the pair move up, never above the top inset.
class _StageLayout extends MultiChildLayoutDelegate {
  _StageLayout({required this.insets});

  final EdgeInsets insets;

  static const double _gap = 20;

  @override
  void performLayout(Size size) {
    final markSize = layoutChild(
      _StageSlot.mark,
      BoxConstraints.tight(
        Size(math.min(300, size.width), _LaunchMarkPainter.stageHeight),
      ),
    );
    final greetingSize = layoutChild(
      _StageSlot.greeting,
      BoxConstraints(maxWidth: math.max(0, size.width - 48)),
    );
    var top = (size.height - markSize.height) / 2;
    final bottom = top + markSize.height + _gap + greetingSize.height;
    final limit = size.height - insets.bottom;
    if (greetingSize.height > 0 && bottom > limit) {
      top = math.max(math.min(insets.top, top), top - (bottom - limit));
    }
    positionChild(
      _StageSlot.mark,
      Offset((size.width - markSize.width) / 2, top),
    );
    positionChild(
      _StageSlot.greeting,
      Offset(
        (size.width - greetingSize.width) / 2,
        top + markSize.height + _gap,
      ),
    );
  }

  @override
  bool shouldRelayout(_StageLayout oldDelegate) => oldDelegate.insets != insets;
}

/// Paints the boot mark: the focus ring (via [paintFocusRing]) and, during
/// the lock-in, the "eat" and "va" lettering of the wordmark.
///
/// The ring's centre stays on the stage's vertical centre throughout, so the
/// mark never drifts up or down; the lettering is set around it exactly as
/// [EatovaWordmark] sets it.
class _LaunchMarkPainter extends CustomPainter {
  const _LaunchMarkPainter({
    required this.ring,
    required this.text,
    required this.intro,
    required this.turn,
    required this.lock,
  });

  static const double loaderBox = WelcomeScreen.launchMarkSize;

  /// Font size of the finished wordmark.
  static const double fontSize = 42;

  static const double stageHeight = 96;

  final Color ring;
  final Color text;

  /// 0..1 reveal (fresh login only; 1 on a cold start).
  final double intro;

  /// Quarter turns of the focus hunt.
  final double turn;

  /// 0..1 lock-in, linear; the painter applies the curves.
  final double lock;

  TextPainter _letters(String s) => TextPainter(
    text: TextSpan(
      text: s,
      style: AppType.display(
        fontSize,
        weight: FontWeight.w800,
        letterSpacing: fontSize * -0.02,
        height: 1.0,
        color: text,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  /// [lock] mapped into [begin]..[end] and eased with [curve].
  double _phase(double begin, double end, Curve curve) =>
      curve.transform(((lock - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    if (intro <= 0) return;
    final center = size.center(Offset.zero);
    // Lock-in choreography: the ring contracts first (so its ticks are clear
    // of the letters before those show), glides into its slot a little
    // longer, and the two words rise into place as it lands.
    final shrink = _phase(0, 0.5, _kEnterCurve);
    final glide = _phase(0, 0.8, _kLockCurve);
    final riseEat = _phase(0.2, 1, _kEnterCurve);
    final riseVa = _phase(0.26, 1, _kEnterCurve);

    const inlineBox = fontSize * 0.82;
    const pad = fontSize * 0.05;
    final box = lerpDouble(loaderBox, inlineBox, shrink)!;

    TextPainter? eat;
    TextPainter? va;
    var eatX = 0.0;
    var vaX = 0.0;
    var ringX = center.dx;
    if (lock > 0) {
      eat = _letters('eat');
      va = _letters('va');
      final total = eat.width + pad + inlineBox + pad + va.width;
      eatX = center.dx - total / 2;
      vaX = eatX + eat.width + pad + inlineBox + pad;
      final slotX = eatX + eat.width + pad + inlineBox / 2;
      ringX = lerpDouble(center.dx, slotX, glide)!;
    }
    final ringCenter = Offset(ringX, center.dy);

    // Reveal: the ring settles in from slightly larger, the ticks pull in
    // from outside like a lens finding focus, the dot arrives last.
    final reveal = _kEnterCurve.transform(intro);
    final dot = _kEnterCurve.transform(((intro - 0.35) / 0.65).clamp(0.0, 1.0));
    canvas.save();
    canvas.translate(ringCenter.dx, ringCenter.dy);
    canvas.scale(1.06 - 0.06 * reveal);
    canvas.translate(-ringCenter.dx, -ringCenter.dy);
    paintFocusRing(
      canvas,
      ringCenter,
      box,
      ring.withValues(alpha: ring.a * reveal),
      turn: turn,
      tickReach: box * 0.28 * (1 - reveal),
      dotScale: dot,
    );
    canvas.restore();

    if (eat == null || va == null) return;
    // As in the wordmark: text box centred 0.09 em above the ring's centre.
    final textY = center.dy - fontSize * 0.09 - eat.height / 2;
    // Each word rises out of its own line, masked at the baseline so it
    // appears to come up through a slot, never sliding across the ring.
    final line = Rect.fromLTRB(
      0,
      textY - fontSize * 0.25,
      size.width,
      textY + eat.height,
    );
    void rise(TextPainter word, double x, double t) {
      if (t <= 0) return;
      final settled = t >= 1;
      canvas.save();
      if (!settled) canvas.clipRect(line);
      final alpha = (t * 1.4).clamp(0.0, 1.0);
      if (alpha < 1) {
        canvas.saveLayer(line, Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      }
      word.paint(canvas, Offset(x, textY + fontSize * 0.62 * (1 - t)));
      if (alpha < 1) canvas.restore();
      canvas.restore();
    }

    rise(eat, eatX, riseEat);
    rise(va, vaX, riseVa);
  }

  @override
  bool shouldRepaint(covariant _LaunchMarkPainter old) =>
      old.ring != ring ||
      old.text != text ||
      old.intro != intro ||
      old.turn != turn ||
      old.lock != lock;
}

class _WelcomeText extends StatelessWidget {
  const _WelcomeText({super.key, required this.firstName});

  final String firstName;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.onboardingWelcomeTitle(firstName),
            textAlign: TextAlign.center,
            style: AppType.display(
              28,
              weight: FontWeight.w700,
              letterSpacing: -0.5,
              color: t.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.authWelcomeSignedIn,
            textAlign: TextAlign.center,
            style: AppType.ui(15, weight: FontWeight.w500, color: t.inkMuted),
          ),
        ],
      ),
    );
  }
}
