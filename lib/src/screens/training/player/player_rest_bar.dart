import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../theme/app_tokens.dart';
import '../../../widgets/design/design.dart';
import 'player_format.dart';

/// What the rest bar and the full-screen rest view show and do.
final class PlayerRestState {
  const PlayerRestState({
    required this.seconds,
    required this.running,
    required this.nextExercise,
    required this.nextSet,
    required this.alertsOff,
    required this.enabled,
    required this.onShorter,
    required this.onLonger,
    required this.onSkip,
    required this.onResume,
    required this.onAlertSettings,
  });

  final int seconds;
  final bool running;
  final String nextExercise;
  final int nextSet;
  final bool alertsOff;
  final bool enabled;
  final VoidCallback onShorter;
  final VoidCallback onLonger;
  final VoidCallback onSkip;
  final VoidCallback onResume;
  final VoidCallback onAlertSettings;
}

/// The rest pinned under the list (spec A3): mm:ss ≥ 34 pt, −15 s, +15 s and
/// Skip; a tap on the time opens [PlayerRestView].
class PlayerRestBar extends StatelessWidget {
  const PlayerRestBar({super.key, required this.rest, required this.onExpand});

  final PlayerRestState rest;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final time = Semantics(
      button: true,
      label: l.trainingTimerSecondsRemaining(rest.seconds),
      hint: l.trainingTimerRestExpand,
      excludeSemantics: true,
      onTap: onExpand,
      child: InkWell(
        key: const ValueKey('training-timer-rest-expand'),
        onTap: onExpand,
        borderRadius: BorderRadius.circular(rControl),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            formatClock(rest.seconds),
            key: const ValueKey('training-timer-rest-time'),
            style: AppType.display(36, color: t.ink, height: 1.1),
          ),
        ),
      ),
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rest.running ? l.trainingTimerRestLabel : l.trainingTimerPaused,
          style: AppType.eyebrow(t.accentText, size: 11),
        ),
        const SizedBox(height: 2),
        Text(
          l.trainingTimerRestNext(rest.nextExercise, rest.nextSet),
          style: AppType.ui(13, color: t.ink2),
        ),
      ],
    );
    return Container(
      key: const ValueKey('training-rest-bar'),
      decoration: BoxDecoration(
        color: t.surf,
        border: Border(top: BorderSide(color: t.lineStrong)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: [heading, time],
            ),
            if (rest.alertsOff) ...[
              const SizedBox(height: 6),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _AlertsOffChip(onTap: rest.onAlertSettings),
              ),
            ],
            const SizedBox(height: 8),
            PlayerRestControls(rest: rest),
          ],
        ),
      ),
    );
  }
}

/// Full-screen rest, readable from the bench (tap on the bar's time).
class PlayerRestView extends StatelessWidget {
  const PlayerRestView({
    super.key,
    required this.rest,
    required this.onCollapse,
  });

  final PlayerRestState rest;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return Material(
      key: const ValueKey('training-rest-view'),
      color: t.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: IconButton(
                key: const ValueKey('training-timer-rest-collapse'),
                tooltip: l.trainingTimerRestCollapse,
                onPressed: onCollapse,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            const SizedBox(height: 24),
            HeadingSemantics(
              level: 1,
              child: Text(
                rest.running ? l.trainingTimerRestLabel : l.trainingTimerPaused,
                textAlign: TextAlign.center,
                style: AppType.display(22, color: t.accentText),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              label: l.trainingTimerSecondsRemaining(rest.seconds),
              excludeSemantics: true,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formatClock(rest.seconds),
                  key: const ValueKey('training-rest-view-time'),
                  style: AppType.display(96, color: t.ink, height: 1),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l.trainingTimerRestNext(rest.nextExercise, rest.nextSet),
              textAlign: TextAlign.center,
              style: AppType.ui(16, color: t.ink2),
            ),
            if (rest.alertsOff) ...[
              const SizedBox(height: 12),
              Center(child: _AlertsOffChip(onTap: rest.onAlertSettings)),
            ],
            const SizedBox(height: 32),
            PlayerRestControls(rest: rest),
          ],
        ),
      ),
    );
  }
}

/// −15 s · +15 s · (Resume) · Skip; stacks on narrow or large-text screens.
class PlayerRestControls extends StatelessWidget {
  const PlayerRestControls({super.key, required this.rest});

  final PlayerRestState rest;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    Widget button(
      String id,
      String text,
      String? label,
      VoidCallback action, {
      bool primary = false,
      IconData? icon,
    }) {
      final style = primary
          ? FilledButton.styleFrom(
              backgroundColor: t.accentFill,
              foregroundColor: t.onAccentFill,
              minimumSize: const Size(64, 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            )
          : FilledButton.styleFrom(
              backgroundColor: t.surf2,
              foregroundColor: t.ink,
              minimumSize: const Size(64, 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            );
      final child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 6)],
          Flexible(child: Text(text, textAlign: TextAlign.center)),
        ],
      );
      final widget = FilledButton(
        key: ValueKey('training-timer-$id'),
        onPressed: rest.enabled ? action : null,
        style: style,
        child: child,
      );
      return label == null
          ? widget
          : Semantics(
              label: label,
              excludeSemantics: true,
              button: true,
              enabled: rest.enabled,
              onTap: rest.enabled ? action : null,
              child: widget,
            );
    }

    final buttons = [
      button(
        'rest-minus',
        l.trainingTimerRestShorter,
        l.trainingTimerRestShorterLabel,
        rest.onShorter,
      ),
      button(
        'rest-plus',
        l.trainingTimerRestLonger,
        l.trainingTimerRestLongerLabel,
        rest.onLonger,
      ),
      if (!rest.running)
        button(
          'rest-resume',
          l.trainingTimerResume,
          null,
          rest.onResume,
          icon: Icons.play_arrow_rounded,
        ),
      button(
        'skip-rest',
        l.trainingTimerSkipRest,
        null,
        rest.onSkip,
        primary: true,
        icon: Icons.skip_next_rounded,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack =
            constraints.maxWidth < 340 ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        if (stack) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: buttons,
          );
        }
        return Row(
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                flex: i == buttons.length - 1 ? 2 : 1,
                child: buttons[i],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AlertsOffChip extends StatelessWidget {
  const _AlertsOffChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return Semantics(
      button: true,
      label: l.trainingTimerAlertsOffLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: const ValueKey('training-timer-alerts-off'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(rPill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.notifications_off_outlined, size: 16, color: t.ink2),
              const SizedBox(width: 6),
              Text(
                l.trainingTimerAlertsOff,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
