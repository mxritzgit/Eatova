import 'dart:math' as math;

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
    required this.alertsAsk,
    required this.onAlertsOff,
  });

  final int seconds;
  final bool running;
  final String nextExercise;
  final int nextSet;
  final bool alertsOff;
  final bool enabled;
  final VoidCallback onShorter;

  /// Null while +15 s would pass the planned rest (the button is off).
  final VoidCallback? onLonger;
  final VoidCallback onSkip;
  final VoidCallback onResume;

  /// The "Alerts off" chip asks the system (never requested on this device)
  /// rather than opening the notification settings.
  final bool alertsAsk;
  final VoidCallback onAlertsOff;
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
    final label = rest.running
        ? l.trainingTimerRestLabel
        : l.trainingTimerPaused;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tracked caps like the app's other eyebrows ("NEXT WORKOUT"); the
        // tracking on mixed case read as "R e s t".
        Text(
          label.toUpperCase(),
          semanticsLabel: label,
          style: AppType.sectionEyebrow(t.accentText, size: 11),
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
                child: _AlertsOffChip(rest: rest),
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

/// Full-screen rest, readable from the bench (tap on the bar's time): close
/// at the top, the time in the middle, the controls at the bottom within
/// reach of the thumb.
class PlayerRestView extends StatelessWidget {
  const PlayerRestView({
    super.key,
    required this.rest,
    required this.onCollapse,
  });

  final PlayerRestState rest;
  final VoidCallback onCollapse;

  static const EdgeInsets _padding = EdgeInsets.fromLTRB(20, 8, 20, 24);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    final time = Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            Center(child: _AlertsOffChip(rest: rest)),
          ],
        ],
      ),
    );
    return Material(
      key: const ValueKey('training-rest-view'),
      color: t.bg,
      // At least one screen tall, so close, time and controls spread over
      // it; large text scrolls instead.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: _padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - _padding.vertical),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SheetCloseButton(
                    buttonKey: const ValueKey('training-timer-rest-collapse'),
                    tooltip: l.trainingTimerRestCollapse,
                    onTap: onCollapse,
                  ),
                ),
                time,
                PlayerRestControls(rest: rest),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small rest pill: key suffix, visible text, spoken name and glyph.
typedef _RestPill = ({
  String id,
  String text,
  String? label,
  IconData? icon,
  VoidCallback? onTap,
});

/// −15 s · +15 s · (Resume) · Skip in one row of one height while every
/// label fits on one line (measured, so "Pause überspringen" gets the width
/// it needs). Where they do not, the small pills go above a full-width Skip.
class PlayerRestControls extends StatelessWidget {
  const PlayerRestControls({super.key, required this.rest});

  final PlayerRestState rest;

  static const double _gap = 8;

  /// What a pill adds to its label: [SoftPillButton]'s 20 px sides or
  /// [PrimaryActionButton]'s 16 px ones, and an 18 px icon with its gap.
  static const double _softSides = 40;
  static const double _primarySides = 32;
  static const double _iconRoom = 26;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    VoidCallback? live(VoidCallback? action) => rest.enabled ? action : null;
    final small = <_RestPill>[
      (
        id: 'rest-minus',
        text: l.trainingTimerRestShorter,
        label: l.trainingTimerRestShorterLabel,
        icon: null,
        onTap: live(rest.onShorter),
      ),
      (
        id: 'rest-plus',
        text: l.trainingTimerRestLonger,
        label: l.trainingTimerRestLongerLabel,
        icon: null,
        onTap: live(rest.onLonger),
      ),
      if (!rest.running)
        (
          id: 'rest-resume',
          text: l.trainingTimerResume,
          label: null,
          icon: Icons.play_arrow_rounded,
          onTap: live(rest.onResume),
        ),
    ];
    // Neutral soft pills: an unavailable +15 s dims; it never takes the
    // accent of a selected or primary control.
    final pills = [
      for (final pill in small)
        SoftPillButton(
          key: ValueKey('training-timer-${pill.id}'),
          label: pill.text,
          semanticLabel: pill.label,
          icon: pill.icon,
          tone: SoftPillTone.neutral,
          onTap: pill.onTap,
        ),
    ];
    final skip = PrimaryActionButton(
      key: const ValueKey('training-timer-skip-rest'),
      label: l.trainingTimerSkipRest,
      icon: Icons.skip_next_rounded,
      height: kButtonMinHeight,
      onTap: live(rest.onSkip),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        double textWidth(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width.ceilToDouble();
          painter.dispose();
          return width;
        }

        // The width each pill needs for its label on one line.
        final smallWidths = [
          for (final pill in small)
            textWidth(pill.text, AppType.ui(14, weight: FontWeight.w700)) +
                _softSides +
                (pill.icon == null ? 0 : _iconRoom),
        ];
        final skipWidth =
            textWidth(
              l.trainingTimerSkipRest,
              AppType.ui(15, weight: FontWeight.w800),
            ) +
            _primarySides +
            _iconRoom;
        final maxWidth = constraints.maxWidth;
        final smallTotal = smallWidths.fold(0.0, (sum, width) => sum + width);
        final smallRowWidth = smallTotal + _gap * (small.length - 1);
        final free = maxWidth - smallRowWidth - _gap - skipWidth;

        // One height for a row of pills, whatever each label's line height;
        // [widths] are the shares of the row's width.
        Widget row(List<Widget> children, List<double> widths) =>
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(width: _gap),
                    Expanded(
                      flex: (widths[i] * 100).round(),
                      child: children[i],
                    ),
                  ],
                ],
              ),
            );

        if (free >= 0) {
          // Every label on one line; Skip and the small pills split what is
          // left, so −15 s and +15 s stay a matched pair.
          return row(
            [...pills, skip],
            [
              for (final width in smallWidths)
                width + free / 2 * width / smallTotal,
              skipWidth + free / 2,
            ],
          );
        }
        // A wide bar keeps the running rest's single row even where Skip's
        // label has to wrap (German below 390 px): one height, no stacking
        // under the list. Otherwise the small pills go above a full-width
        // Skip.
        final wide = maxWidth >= 340 && scaler.scale(14) <= 21;
        if (wide && small.length == 2) {
          return row([...pills, skip], const [1, 1, 2]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (smallRowWidth <= maxWidth)
              row(pills, smallWidths)
            else
              for (var i = 0; i < pills.length; i++) ...[
                if (i > 0) const SizedBox(height: _gap),
                pills[i],
              ],
            const SizedBox(height: _gap),
            skip,
          ],
        );
      },
    );
  }
}

class _AlertsOffChip extends StatelessWidget {
  const _AlertsOffChip({required this.rest});

  final PlayerRestState rest;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = context.t;
    return Semantics(
      button: true,
      label: rest.alertsAsk
          ? l.trainingTimerAlertsOffAskLabel
          : l.trainingTimerAlertsOffLabel,
      excludeSemantics: true,
      onTap: rest.onAlertsOff,
      child: InkWell(
        key: const ValueKey('training-timer-alerts-off'),
        onTap: rest.onAlertsOff,
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
