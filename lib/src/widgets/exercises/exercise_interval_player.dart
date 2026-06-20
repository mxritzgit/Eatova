import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/exercises/exercise_clip.dart';
import '../../models/exercises/workout.dart';
import '../../theme/app_colors.dart';

/// Vollbild-Workout-Player für einen [Workout]: spielt pro [WorkoutStep] das
/// (stummgeschaltete, geloopte) Übungsvideo während der Arbeitsphase, blendet
/// danach eine Pause ein und schließt mit einer Erfolgs-Zusammenfassung.
///
/// Bewusst self-contained: KEINE Abhängigkeit von HomeStore, Supabase oder
/// irgendeinem App-Service. Die Zeitsteuerung läuft über einen einzigen
/// 1-Sekunden-[Timer.periodic], der in [dispose] zwingend gecancelt wird; so
/// lässt sich der Ablauf in Widget-Tests deterministisch via
/// `tester.pump(const Duration(seconds: 1))` durchsteppen.
class ExerciseIntervalPlayer extends StatefulWidget {
  const ExerciseIntervalPlayer({super.key, required this.workout, this.onFinished});

  final Workout workout;
  final VoidCallback? onFinished;

  @override
  State<ExerciseIntervalPlayer> createState() => _ExerciseIntervalPlayerState();
}

/// Phasen des Ablaufs. [leadIn] zählt einmalig vor der ersten Übung herunter,
/// danach wechseln sich [work] und [rest] pro Step ab, bis [done] erreicht ist.
enum _Phase { leadIn, work, rest, done }

class _ExerciseIntervalPlayerState extends State<ExerciseIntervalPlayer> {
  /// Sekunden des Bereit?-Countdowns vor der ersten Übung.
  static const int _leadInSeconds = 3;

  Timer? _ticker;

  _Phase _phase = _Phase.leadIn;

  /// Index des aktuellen Steps in `workout.steps`.
  int _stepIndex = 0;

  /// Verbleibende Sekunden der laufenden Phase.
  int _remaining = _leadInSeconds;

  /// Gesamtsekunden der laufenden Phase (für den Fortschrittsring).
  int _phaseTotal = _leadInSeconds;

  bool _paused = false;

  /// Ein initialisierter (oder bewusst als „fehlgeschlagen" markierter)
  /// Controller pro Step-Index. Lazy aufgebaut: nur der aktuelle und der nächste
  /// Step werden vorbereitet, jeder Eintrag wird in [dispose] freigegeben.
  final Map<int, VideoPlayerController> _controllers =
      <int, VideoPlayerController>{};

  /// Step-Indizes, deren Video erfolgreich initialisiert wurde.
  final Set<int> _ready = <int>{};

  /// Step-Indizes, deren Asset fehlt / fehlerhaft ist — zeigen den Platzhalter.
  final Set<int> _failed = <int>{};

  List<WorkoutStep> get _steps => widget.workout.steps;

  int get _stepCount => _steps.length;

  @override
  void initState() {
    super.initState();
    // Vorab den ersten Clip laden, damit das Video zum WORK-Start bereitsteht.
    _prepareController(0);
    _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    for (final VideoPlayerController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  // --- Video-Lifecycle ------------------------------------------------------

  /// Baut (idempotent) den Controller für [index] und initialisiert ihn. Robust:
  /// Fehlt das Asset oder schlägt `initialize()` fehl, landet der Index in
  /// [_failed] und der Platzhalter wird gezeigt — nie ein Crash.
  Future<void> _prepareController(int index) async {
    if (index < 0 || index >= _stepCount) return;
    if (_controllers.containsKey(index)) return;

    final VideoPlayerController controller =
        VideoPlayerController.asset(_steps[index].clip.videoAsset);
    _controllers[index] = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!mounted) return;
      setState(() => _ready.add(index));
      // Falls dieser Step gerade aktiv in der WORK-Phase ist, sofort starten.
      if (_phase == _Phase.work && index == _stepIndex && !_paused) {
        await controller.play();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed.add(index));
    }
  }

  /// True, solange für [index] noch kein spielbares Video bereitsteht — also
  /// während der Initialisierung ODER nach einem Fehler ([_failed]). Dann wird
  /// statt des Players der Platzhalter gezeigt.
  bool _isPlaceholder(int index) =>
      _failed.contains(index) || !_ready.contains(index);

  /// Aktiver Controller des laufenden Steps, sofern spielbereit.
  VideoPlayerController? get _activeController {
    if (_isPlaceholder(_stepIndex)) return null;
    return _controllers[_stepIndex];
  }

  void _playActive() {
    final VideoPlayerController? controller = _activeController;
    if (controller != null) {
      controller.play();
    }
  }

  void _pauseActive() {
    final VideoPlayerController? controller = _activeController;
    if (controller != null) {
      controller.pause();
    }
  }

  // --- Zeitsteuerung --------------------------------------------------------

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (_paused || _phase == _Phase.done) return;
    if (_remaining > 1) {
      setState(() => _remaining -= 1);
      return;
    }
    // Diese Phase ist abgelaufen — zur nächsten wechseln.
    _advancePhase();
  }

  /// Wechselt von der gerade abgelaufenen Phase in die nächste.
  void _advancePhase() {
    switch (_phase) {
      case _Phase.leadIn:
        _enterWork(0);
      case _Phase.work:
        final int restSeconds = _steps[_stepIndex].restSeconds;
        if (restSeconds > 0 && _stepIndex < _stepCount - 1) {
          _enterRest(restSeconds);
        } else if (_stepIndex < _stepCount - 1) {
          // restSeconds == 0: direkt zur nächsten Übung.
          _enterWork(_stepIndex + 1);
        } else {
          _enterDone();
        }
      case _Phase.rest:
        _enterWork(_stepIndex + 1);
      case _Phase.done:
        break;
    }
  }

  void _enterWork(int index) {
    // Den vorigen Clip anhalten (er bleibt für „Zurück" erhalten).
    _pauseActive();
    final int clamped = index.clamp(0, _stepCount - 1);
    setState(() {
      _phase = _Phase.work;
      _stepIndex = clamped;
      _phaseTotal = _steps[clamped].workSeconds;
      _remaining = _steps[clamped].workSeconds;
    });
    // Aktuellen Clip starten + den nächsten schon vorbereiten.
    if (!_paused) _playActive();
    _prepareController(clamped);
    _prepareController(clamped + 1);
  }

  void _enterRest(int restSeconds) {
    _pauseActive();
    setState(() {
      _phase = _Phase.rest;
      _phaseTotal = restSeconds;
      _remaining = restSeconds;
    });
    // Den nächsten Clip schon im Hintergrund laden.
    _prepareController(_stepIndex + 1);
  }

  void _enterDone() {
    _pauseActive();
    setState(() {
      _phase = _Phase.done;
      _remaining = 0;
      _phaseTotal = 1;
    });
  }

  // --- Steuerung (Controls) -------------------------------------------------

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _pauseActive();
    } else if (_phase == _Phase.work) {
      _playActive();
    }
  }

  /// „Pause überspringen" bzw. nächste Übung.
  void _skip() {
    if (_phase == _Phase.done) return;
    if (_phase == _Phase.rest) {
      _enterWork(_stepIndex + 1);
      return;
    }
    // In WORK / leadIn: zur nächsten Übung springen, sonst beenden.
    if (_stepIndex < _stepCount - 1) {
      _enterWork(_stepIndex + 1);
    } else {
      _enterDone();
    }
  }

  /// Zur vorherigen Übung. In der ersten Übung nur diese neu starten.
  void _previous() {
    if (_phase == _Phase.done) return;
    final int target = _phase == _Phase.rest ? _stepIndex : _stepIndex - 1;
    _enterWork(target.clamp(0, _stepCount - 1));
  }

  void _finish() {
    widget.onFinished?.call();
    Navigator.maybePop(context);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: _phase == _Phase.done ? _buildDone() : _buildActive(),
      ),
    );
  }

  Widget _buildActive() {
    final WorkoutStep step = _steps[_stepIndex];
    final bool isRest = _phase == _Phase.rest;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Vollflächiges Video bzw. Platzhalter hinter dem Scrim.
        Positioned.fill(child: _buildVideoLayer(isRest: isRest)),
        const Positioned.fill(child: _GradientScrim()),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildTopRow(),
                const Spacer(),
                if (isRest)
                  _buildRestBody(step)
                else
                  _buildWorkBody(step),
                const Spacer(),
                _buildTimerRing(),
                const SizedBox(height: 24),
                _buildControls(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoLayer({required bool isRest}) {
    // In der Pause die Übung optisch zurücknehmen (gedämpfte Fläche).
    if (isRest) {
      return const ColoredBox(color: bg);
    }
    final VideoPlayerController? controller = _activeController;
    if (controller == null || _isPlaceholder(_stepIndex)) {
      return _VideoPlaceholder(name: _steps[_stepIndex].clip.name);
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildTopRow() {
    return Row(
      children: <Widget>[
        _CircleIconButton(
          icon: Icons.close_rounded,
          onPressed: () => Navigator.maybePop(context),
          buttonKey: const ValueKey<String>('player-close'),
          tooltip: 'Schließen',
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.workout.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.all(Radius.circular(rPill)),
            border: Border.fromBorderSide(
              BorderSide(color: hairline),
            ),
          ),
          child: Text(
            '${_stepIndex + 1}/$_stepCount',
            style: const TextStyle(
              color: textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkBody(WorkoutStep step) {
    final List<String> cues = step.clip.cues.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          step.clip.name,
          key: const ValueKey<String>('player-exercise-name'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: textPrimary,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 12),
        _FocusChip(label: step.clip.focus),
        const SizedBox(height: 16),
        if (cues.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String cue in cues) _CueChip(label: cue),
            ],
          ),
      ],
    );
  }

  Widget _buildRestBody(WorkoutStep currentStep) {
    final int nextIndex = _stepIndex + 1;
    final bool hasNext = nextIndex < _stepCount;
    final ExerciseClip? next = hasNext ? _steps[nextIndex].clip : null;
    final String nextName = next?.name ?? '—';
    final String nextCue =
        (next != null && next.cues.isNotEmpty) ? next.cues.first : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
      decoration: const BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.all(Radius.circular(rSheet)),
        border: Border.fromBorderSide(BorderSide(color: hairline)),
        boxShadow: cardShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Text(
            'PAUSE',
            style: TextStyle(
              color: lime,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Nächste Übung',
            style: TextStyle(
              color: textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            nextName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (nextCue.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                color: surfaceSoft,
                borderRadius: BorderRadius.all(Radius.circular(rChip)),
                border: Border.fromBorderSide(BorderSide(color: hairline)),
              ),
              child: Text(
                nextCue,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          TextButton(
            onPressed: _skip,
            style: TextButton.styleFrom(
              foregroundColor: lime,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: const Text(
              'Überspringen',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimerRing() {
    final double progress = _phaseTotal <= 0
        ? 0
        : (1 - (_remaining / _phaseTotal)).clamp(0.0, 1.0).toDouble();
    final bool isRest = _phase == _Phase.rest;
    final bool isLeadIn = _phase == _Phase.leadIn;
    final Color ringColor = isRest ? limeBright : lime;
    final String caption = isLeadIn
        ? 'Bereit?'
        : isRest
            ? 'Pause'
            : 'Los geht\'s';
    return Center(
      key: const ValueKey<String>('player-timer'),
      child: SizedBox(
        width: 184,
        height: 184,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            SizedBox.expand(
              child: CustomPaint(
                painter: _RingPainter(
                  progress: progress,
                  trackColor: hairline,
                  progressColor: ringColor,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '$_remaining',
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 64,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  style: const TextStyle(
                    color: textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        _CircleIconButton(
          icon: Icons.skip_previous_rounded,
          onPressed: _previous,
          buttonKey: const ValueKey<String>('player-prev'),
          tooltip: 'Vorherige Übung',
        ),
        _CircleIconButton(
          icon: _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          onPressed: _togglePause,
          buttonKey: const ValueKey<String>('player-pause'),
          tooltip: _paused ? 'Fortsetzen' : 'Pausieren',
          emphasized: true,
        ),
        _CircleIconButton(
          icon: Icons.skip_next_rounded,
          onPressed: _skip,
          buttonKey: const ValueKey<String>('player-skip'),
          tooltip: 'Nächste Übung',
        ),
      ],
    );
  }

  Widget _buildDone() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: _CircleIconButton(
              icon: Icons.close_rounded,
              onPressed: () => Navigator.maybePop(context),
              buttonKey: const ValueKey<String>('player-close'),
              tooltip: 'Schließen',
            ),
          ),
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              color: surface,
              shape: BoxShape.circle,
              boxShadow: cardShadow,
            ),
            child: const Icon(
              Icons.check_rounded,
              color: lime,
              size: 52,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Geschafft!',
            style: TextStyle(
              color: textPrimary,
              fontSize: 34,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.workout.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: textMuted,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: surfaceSoft,
              borderRadius: BorderRadius.all(Radius.circular(rPill)),
              border: Border.fromBorderSide(BorderSide(color: hairline)),
            ),
            child: Text(
              '${widget.workout.exerciseCount} Übungen abgeschlossen',
              style: const TextStyle(
                color: textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _finish,
              style: FilledButton.styleFrom(
                backgroundColor: lime,
                foregroundColor: bg,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(rControl)),
                ),
              ),
              child: const Text(
                'Fertig',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private Bausteine
// ---------------------------------------------------------------------------

/// Dunkler Verlauf oben + unten, damit Text über dem Video lesbar bleibt.
class _GradientScrim extends StatelessWidget {
  const _GradientScrim();

  @override
  Widget build(BuildContext context) {
    // Aus dem `bg`-Token abgeleitete Alpha-Stufen (kein hartkodiertes Hex):
    // oben/unten kräftig abdunkeln, Mitte nahezu transparent, damit das Video
    // sichtbar bleibt und Text trotzdem lesbar ist.
    final Color top = bg.withValues(alpha: 0.80);
    final Color mid = bg.withValues(alpha: 0.20);
    final Color bottom = bg.withValues(alpha: 0.90);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[top, mid, mid, bottom],
          stops: const <double>[0.0, 0.28, 0.62, 1.0],
        ),
      ),
    );
  }
}

/// Platzhalter, wenn ein Video(-Asset) (noch) nicht bereit ist — verhindert
/// einen Crash und zeigt stattdessen eine ruhige `surface`-Karte.
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.fitness_center_rounded,
              color: textMuted,
              size: 72,
            ),
            const SizedBox(height: 16),
            Text(
              name,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: textMuted,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fokus-/Kategorie-Chip in Markenfarbe (z.B. „Beine", „Cardio").
class _FocusChip extends StatelessWidget {
  const _FocusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: const BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.all(Radius.circular(rPill)),
        border: Border.fromBorderSide(BorderSide(color: lime)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: lime,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Kleiner Hinweis-Chip (Form-Cue) mit Hairline-Rand und gedämpfter Schrift.
class _CueChip extends StatelessWidget {
  const _CueChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: const BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.all(Radius.circular(rPill)),
        border: Border.fromBorderSide(BorderSide(color: hairline)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: textMuted,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Runder Icon-Button für Kopfzeile und Steuerleiste. Der hervorgehobene
/// Zustand ([emphasized]) füllt mit der Markenfarbe (Play/Pause-Toggle).
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    required this.buttonKey,
    required this.tooltip,
    this.emphasized = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Key buttonKey;
  final String tooltip;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final double size = emphasized ? 72 : 52;
    final Color background = emphasized ? lime : surface;
    final Color foreground = emphasized ? bg : textPrimary;
    return Semantics(
      button: true,
      label: tooltip,
      child: Material(
        key: buttonKey,
        color: background,
        shape: emphasized
            ? const CircleBorder()
            : const CircleBorder(side: BorderSide(color: hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              color: foreground,
              size: emphasized ? 36 : 24,
            ),
          ),
        ),
      ),
    );
  }
}

/// Zeichnet den kreisförmigen Countdown-Ring: voller Track + Fortschrittsbogen,
/// der oben (12 Uhr) startet und im Uhrzeigersinn wächst.
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 10;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (size.shortestSide - stroke) / 2;

    final Paint track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    if (progress <= 0) return;

    final Paint arc = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    const double startAngle = -1.5707963267948966; // -pi/2, oben.
    final double sweepAngle = 6.283185307179586 * progress; // 2*pi.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.trackColor != trackColor;
  }
}
