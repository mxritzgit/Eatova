import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/app_tokens.dart';
import '../../../widgets/common/lively.dart';
import '../../../widgets/design/design.dart';
import 'player_format.dart';

/// The player's header (spec A3): back, title, sets done/total, elapsed
/// active time, **Finish** and the menu (Pause/Resume, Discard).
class PlayerHeader extends StatelessWidget {
  const PlayerHeader({
    super.key,
    required this.title,
    required this.done,
    required this.total,
    required this.elapsed,
    required this.enabled,
    required this.backEnabled,
    required this.onBack,
    required this.onFinish,
    required this.onDiscard,
    this.onPause,
    this.onResume,
  });

  final String title;
  final int done;
  final int total;

  /// Time since the first ✓ or ▶; null before it.
  final Duration? Function() elapsed;
  final bool enabled;

  /// Leaving stays possible while a failed save waits for Retry.
  final bool backEnabled;
  final VoidCallback onBack;
  final VoidCallback onFinish;
  final VoidCallback onDiscard;
  final VoidCallback? onPause;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    // The soft accent pill ([SoftPillTone.accent]). Disabled while the
    // workout saves, it dims in its own tint like that pill: the theme's
    // disabled FilledButton is an accent wash that reads as selected. No
    // vertical padding, so at large text the compact header stays as short.
    final finish = PressScale(
      enabled: enabled,
      child: FilledButton(
        key: const ValueKey('training-timer-finish'),
        onPressed: enabled ? onFinish : null,
        style: FilledButton.styleFrom(
          backgroundColor: t.accentTint,
          foregroundColor: t.accentText,
          disabledBackgroundColor: t.accentTint.withValues(
            alpha: t.accentTint.a * 0.6,
          ),
          disabledForegroundColor: t.accentText.withValues(alpha: 0.45),
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const StadiumBorder(),
        ),
        child: Text(
          l.trainingTimerFinishShort,
          style: AppType.ui(14, weight: FontWeight.w800),
        ),
      ),
    );
    // The app's overflow menu: MenuRow entries that open under the trigger.
    // Discard only tints its glyph; the decision card that follows carries
    // the red action.
    final menu = PopupMenuButton<String>(
      key: const ValueKey('training-timer-menu'),
      tooltip: l.trainingTimerMenu,
      enabled: enabled,
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (value) => switch (value) {
        'pause' => onPause?.call(),
        'resume' => onResume?.call(),
        _ => onDiscard(),
      },
      itemBuilder: (context) => [
        if (onPause != null)
          eatovaMenuItem(
            key: const ValueKey('training-timer-pause'),
            value: 'pause',
            icon: Icons.pause_rounded,
            label: l.trainingTimerPause,
          ),
        if (onResume != null)
          eatovaMenuItem(
            key: const ValueKey('training-timer-resume'),
            value: 'resume',
            icon: Icons.play_arrow_rounded,
            label: l.trainingTimerResume,
          ),
        eatovaMenuItem(
          key: const ValueKey('training-timer-discard'),
          value: 'discard',
          icon: Icons.delete_outline_rounded,
          label: l.trainingTimerDiscard,
          destructive: true,
        ),
      ],
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeadingSemantics(
          level: 1,
          child: Text(
            title,
            style: AppType.ui(16, weight: FontWeight.w700, color: t.ink),
          ),
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 8,
          children: [
            Text(
              l.trainingTimerSetsDone(done, total),
              key: const ValueKey('training-timer-progress-label'),
              style: AppType.ui(13, color: t.ink2),
            ),
            _Elapsed(elapsed: elapsed),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Narrow or large text: Finish moves under the title.
              final compact =
                  constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(16) > 22;
              final top = Row(
                children: [
                  // The pushed pages' round chevron (44 px disc in a 48 px
                  // target), not Material's bare arrow; the disc lines up
                  // with the cards below.
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 10),
                    child: SheetCloseButton(
                      buttonKey: const ValueKey('training-timer-back'),
                      tooltip: l.trainingTimerBack,
                      icon: Icons.chevron_left_rounded,
                      onTap: backEnabled ? onBack : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: heading),
                  if (!compact) ...[const SizedBox(width: 8), finish],
                  menu,
                ],
              );
              if (!compact) return top;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  top,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: finish,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 4,
              borderRadius: BorderRadius.circular(rPill),
              color: t.accent,
              backgroundColor: t.tile,
              semanticsLabel: l.trainingTimerProgress(done, total),
            ),
          ),
        ],
      ),
    );
  }
}

/// Elapsed active time, refreshed once a second on its own (the list does
/// not rebuild for it).
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.elapsed});

  final Duration? Function() elapsed;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.elapsed() != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = widget.elapsed();
    if (elapsed == null) return const SizedBox.shrink();
    final seconds = elapsed.inSeconds;
    return Semantics(
      label: context.l10n.trainingTimerElapsedLabel(seconds ~/ 60),
      excludeSemantics: true,
      child: Text(
        formatClock(seconds),
        key: const ValueKey('training-timer-elapsed'),
        style: AppType.ui(13, weight: FontWeight.w600, color: context.t.ink2),
      ),
    );
  }
}
