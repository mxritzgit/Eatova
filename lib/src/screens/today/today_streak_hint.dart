import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final text = context.l10n.streakYesterdayHint;
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
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: ExcludeSemantics(
                  child: Row(
                    children: <Widget>[
                      TodayGlyphIcon(
                        TodayGlyph.flame,
                        size: 18,
                        color: t.activityInk,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          text,
                          style: AppType.ui(
                            13.5,
                            weight: FontWeight.w600,
                            color: t.ink2,
                            height: todayLineHeight,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 22,
                        color: t.ink2,
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
