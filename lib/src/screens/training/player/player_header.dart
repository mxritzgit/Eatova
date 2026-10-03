import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/app_tokens.dart';
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
    final finish = FilledButton(
      key: const ValueKey('training-timer-finish'),
      onPressed: enabled ? onFinish : null,
      style: FilledButton.styleFrom(
        backgroundColor: t.accentTint,
        foregroundColor: t.accentText,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      child: Text(
        l.trainingTimerFinishShort,
        style: AppType.ui(14, weight: FontWeight.w800),
      ),
    );
    final menu = PopupMenuButton<String>(
      key: const ValueKey('training-timer-menu'),
      tooltip: l.trainingTimerMenu,
      enabled: enabled,
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) => switch (value) {
        'pause' => onPause?.call(),
        'resume' => onResume?.call(),
        _ => onDiscard(),
      },
      itemBuilder: (context) => [
        if (onPause != null)
          PopupMenuItem(
            key: const ValueKey('training-timer-pause'),
            value: 'pause',
            child: Text(l.trainingTimerPause),
          ),
        if (onResume != null)
          PopupMenuItem(
            key: const ValueKey('training-timer-resume'),
            value: 'resume',
            child: Text(l.trainingTimerResume),
          ),
        PopupMenuItem(
          key: const ValueKey('training-timer-discard'),
          value: 'discard',
          child: Text(
            l.trainingTimerDiscard,
            style: TextStyle(color: t.danger),
          ),
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
                  IconButton(
                    key: const ValueKey('training-timer-back'),
                    tooltip: l.trainingTimerBack,
                    onPressed: backEnabled ? onBack : null,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
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
