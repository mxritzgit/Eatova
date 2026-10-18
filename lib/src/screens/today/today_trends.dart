import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import 'today_sections.dart' show TodayTapTarget;
import 'today_texts.dart';

/// The averages Today's trends card shows: the last seven completed days.
/// Null where no day has a value (no entries, no step source).
typedef TodayTrendsPreview = ({
  double? avgKcal,
  double? avgProteinG,
  double? avgSteps,
});

/// The way into the trends page (2026-10-18), at the end of Today: calories,
/// protein and steps of the last seven completed days, and a chevron. A tap
/// opens the page with every range up to six months.
class TodayTrendsCard extends StatelessWidget {
  const TodayTrendsCard({
    super.key,
    required this.preview,
    required this.onOpen,
  });

  final TodayTrendsPreview preview;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final kcal = preview.avgKcal;
    final protein = preview.avgProteinG;
    final steps = preview.avgSteps;
    final empty = kcal == null && steps == null;
    final cells = <(String, String)>[
      (
        l10n.todayTrendsKcalLabel,
        kcal == null ? '–' : '${kcalThousands(kcal.round(), l10n)} kcal',
      ),
      (l10n.todayMacroProtein, protein == null ? '–' : '${protein.round()} g'),
      // No step source: the column drops instead of a permanent dash.
      if (steps != null)
        (
          l10n.todayTrendsStepsLabel,
          formatThousands(steps.round(), l10n.localeName),
        ),
    ];
    final title = l10n.todayTrendsTitle;
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: l10n.todayTrendsOpenHint,
        child: PressScale(
          scale: kPressScaleCard,
          child: Material(
            color: t.surf,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(rCard),
              side: BorderSide(color: t.cardBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: TodayTapTarget(
              key: const ValueKey('today-trends'),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                title.toUpperCase(),
                                semanticsLabel: title,
                                style: AppType.ui(
                                  12,
                                  weight: FontWeight.w700,
                                  color: t.accentText,
                                  letterSpacing: 12 * 0.06,
                                  height: todayLineHeight,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.todayTrendsSub,
                                style: AppType.ui(
                                  13,
                                  weight: FontWeight.w500,
                                  color: t.ink2,
                                  height: todayLineHeight,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 24,
                          color: t.ink2,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (empty)
                      Text(
                        l10n.todayTrendsEmpty,
                        key: const ValueKey('today-trends-empty'),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w500,
                          color: t.ink2,
                          height: 1.35,
                        ),
                      )
                    else
                      // Natural widths that wrap: at large text a third of
                      // the card would cut "1.950 kcal" mid-number.
                      Wrap(
                        spacing: 24,
                        runSpacing: 10,
                        children: <Widget>[
                          for (final (label, value) in cells)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  label,
                                  style: AppType.ui(
                                    11.5,
                                    weight: FontWeight.w500,
                                    color: t.ink2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  value,
                                  style: AppType.display(
                                    17,
                                    weight: FontWeight.w700,
                                    color: t.ink,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
