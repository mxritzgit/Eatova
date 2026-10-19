import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/energy_check.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/profile/profile_widgets.dart' show formatKgDe;
import 'today_sections.dart' show TodayTapTarget;
import 'today_texts.dart';

/// The weekly check's progress line (docs/WEIGHT-TREND.md, stage 2): when
/// it can run at the earliest and what it still needs; once the data is
/// enough, a quiet confirmation instead.
///
/// The confirmation says only what is always true at that point: the check
/// runs on enough data. "Your goal fits" would be wrong when a cap or the
/// floor holds back a step the data asks for.
String todayWeighProgressText(
  EnergyCheckProgress progress,
  AppLocalizations l10n,
) {
  if (progress.ready) return l10n.todayWeighCheckReady;
  var line = l10n.todayWeighCheckIn(progress.daysUntil);
  if (progress.loggedDaysToGo > 0) {
    line = l10n.todayWeighJoin(
      line,
      l10n.todayWeighLoggedToGo(progress.loggedDaysToGo),
    );
  }
  if (progress.weighInsToGo > 0) {
    line = l10n.todayWeighJoin(
      line,
      l10n.todayWeighWeighInsToGo(progress.weighInsToGo),
    );
  }
  return line;
}

/// Weight chip and, with [progress], the weekly check's progress line, under
/// the macros on today. Quiet on purpose: a soft pill and a secondary line.
///
/// The line sits next to the chip while it fits there in two lines;
/// otherwise (a narrow phone, large text, the wider "Log weight" chip) it
/// moves under the chip. With [onExplain] the line is a button that
/// explains the weekly check (2026-10-19), marked by an info glyph.
class TodayWeighRow extends StatelessWidget {
  const TodayWeighRow({
    super.key,
    required this.latestKg,
    required this.onTap,
    this.progress,
    this.onExplain,
  });

  /// The latest weigh-in; null shows "Log weight".
  final double? latestKg;

  /// Opens the weigh-in sheet.
  final VoidCallback? onTap;
  final EnergyCheckProgress? progress;

  /// Opens the weekly check's explainer from the progress line.
  final VoidCallback? onExplain;

  static const double _gap = 12;

  /// The info glyph after a tappable line, with its gap.
  static const double _glyph = 19;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final kg = latestKg;
    final value = kg == null ? null : formatKgDe(kg, l10n);
    final p = progress;
    final text = p == null ? null : todayWeighProgressText(p, l10n);
    final style = AppType.ui(13, color: t.ink2, height: 1.3);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Bounded, so the chip's label can wrap instead of overflowing.
        final chip = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: _WeighChip(value: value, onTap: onTap),
        );
        if (text == null) {
          return Align(alignment: Alignment.centerLeft, child: chip);
        }
        final explain = onExplain;
        final label = Text(
          text,
          key: const ValueKey('today-weigh-progress'),
          style: style,
        );
        final line = explain == null
            ? label
            : Semantics(
                button: true,
                hint: l10n.weeklyCheckLineHint,
                child: Material(
                  type: MaterialType.transparency,
                  child: TodayTapTarget(
                    key: const ValueKey('today-weigh-progress-tap'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: explain,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Row(
                        children: <Widget>[
                          Flexible(child: label),
                          const SizedBox(width: 4),
                          ExcludeSemantics(
                            child: Icon(
                              Icons.info_outline_rounded,
                              size: _glyph - 4,
                              color: t.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
        final scaler = MediaQuery.textScalerOf(context);
        final beside =
            constraints.maxWidth - _WeighChip.width(value, l10n, scaler) - _gap;
        final stacked =
            beside < 120 ||
            _lineCount(
                  text,
                  style,
                  scaler,
                  beside - (explain == null ? 0 : _glyph),
                ) >
                2;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              chip,
              const SizedBox(height: 8),
              Padding(padding: const EdgeInsets.only(left: 4), child: line),
            ],
          );
        }
        return Row(
          children: <Widget>[
            chip,
            const SizedBox(width: _gap),
            Expanded(child: line),
          ],
        );
      },
    );
  }

  static int _lineCount(
    String text,
    TextStyle style,
    TextScaler scaler,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final lines = painter.computeLineMetrics().length;
    painter.dispose();
    return lines;
  }
}

/// The latest weight ([value], already formatted) on a soft pill, at least
/// 44 px high; without a weigh-in it reads "Log weight" in the accent ink.
class _WeighChip extends StatelessWidget {
  const _WeighChip({required this.value, required this.onTap});

  final String? value;
  final VoidCallback? onTap;

  static const double _iconSize = 18;
  static const double _iconGap = 8;
  static const double _padding = 14;

  static String _label(String? value, AppLocalizations l10n) =>
      value == null ? l10n.todayWeighChipLog : l10n.todayWeighChipValue(value);

  static TextStyle _style(AppTokens t, {required bool empty}) => AppType.ui(
    14,
    weight: FontWeight.w700,
    color: empty ? t.accentText : t.ink,
    height: todayLineHeight,
  );

  /// The chip's width on one line, for the row's layout decision.
  static double width(String? value, AppLocalizations l10n, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(
        text: _label(value, l10n),
        style: _style(AppTokens.dark, empty: value == null),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width + _iconSize + _iconGap + 2 * _padding;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final value = this.value;
    final shape = StadiumBorder(side: BorderSide(color: t.cardBorder));
    return Semantics(
      button: onTap != null,
      label: value == null
          ? l10n.todayWeighChipLog
          : l10n.todayWeighChipSemantics(value),
      child: PressScale(
        enabled: onTap != null,
        child: Material(
          color: t.surf,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: TodayTapTarget(
            key: const ValueKey('today-weigh-chip'),
            customBorder: shape,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _padding,
                  vertical: 6,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        value == null
                            ? Icons.add_rounded
                            : Icons.monitor_weight_outlined,
                        size: _iconSize,
                        color: t.accentText,
                      ),
                      const SizedBox(width: _iconGap),
                      Flexible(
                        child: Text(
                          _label(value, l10n),
                          key: const ValueKey('today-weigh-value'),
                          style: _style(t, empty: value == null),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
