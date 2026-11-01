import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/design/design.dart';
import 'today_glyphs.dart';
import 'today_sections.dart' show TodayTapTarget;
import 'today_texts.dart';

/// A quiet line before today's first entry (2026-10-19): yesterday is still
/// empty and an entry for it would keep the streak
/// (`HomeStore.yesterdayRescuesStreak`). A tap opens the add flow on
/// yesterday. No badge, no count: the streak pill already carries those.
class TodayYesterdayHint extends StatelessWidget {
  const TodayYesterdayHint({super.key, required this.onTap});

  final VoidCallback onTap;

  static const double _glyph = AppIconSize.button;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final text = context.l10n.streakYesterdayHint;
    final style = AppType.ui(
      14,
      weight: FontWeight.w600,
      color: t.ink2,
      height: todayLineHeight,
    );
    final line = MediaQuery.textScalerOf(context).scale(14) * todayLineHeight;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rCard),
      side: BorderSide(color: t.cardBorder),
    );
    return Semantics(
      button: true,
      label: text,
      child: PressScale(
        scale: kPressScaleCard,
        child: Material(
          color: t.surf,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: TodayTapTarget(
            key: const ValueKey('today-yesterday-hint'),
            customBorder: shape,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                // The cards' inset; the chevron ends where a list row's
                // does.
                padding: const EdgeInsets.fromLTRB(
                  kCardInset,
                  kSpace12,
                  kCardInset,
                  kSpace12,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            // On the first line when the text wraps.
                            Padding(
                              padding: EdgeInsets.only(
                                top: math.max(0, (line - _glyph) / 2),
                              ),
                              child: TodayGlyphIcon(
                                TodayGlyph.flame,
                                size: _glyph,
                                color: t.activityInk,
                              ),
                            ),
                            const SizedBox(width: kSpace12),
                            Expanded(child: Text(text, style: style)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        AppIcons.chevronRight,
                        size: AppIconSize.standard,
                        color: t.ink3,
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
