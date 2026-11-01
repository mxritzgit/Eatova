import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/app_entry.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

/// Today's card before the account's first entry (2026-11-01): one question
/// and the three ways to answer it, the same ways in as the app-icon
/// shortcuts. Search comes first: it needs no AI and spends nothing of the
/// Free pool. Describe and Photo ask for the AI consent in their own flows.
///
/// Derived, never stored: it shows while `HomeStore.firstEntryPending`
/// holds and is gone with the first entry. No reminder offer here; when
/// that comes is the reminder card's own rule.
class TodayFirstEntryCard extends StatelessWidget {
  const TodayFirstEntryCard({super.key, required this.onEntry});

  /// Opens a way in: [AppEntry.logMeal] (search and barcode),
  /// [AppEntry.describe] or [AppEntry.photo].
  final ValueChanged<AppEntry> onEntry;

  /// [SoftPillButton]'s chrome around its label: 20 px padding per side,
  /// the 18 px icon and its 8 px gap.
  static const double _pillChrome = 66;
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = l10n.todayFirstEntryTitle;
    final describe = SoftPillButton(
      key: const ValueKey('today-first-entry-describe'),
      label: l10n.todayFirstEntryDescribe,
      icon: Icons.mic_none_rounded,
      tone: SoftPillTone.neutral,
      expand: true,
      onTap: () => onEntry(AppEntry.describe),
    );
    final photo = SoftPillButton(
      key: const ValueKey('today-first-entry-photo'),
      label: l10n.todayFirstEntryPhoto,
      icon: Icons.photo_camera_outlined,
      tone: SoftPillTone.neutral,
      expand: true,
      onTap: () => onEntry(AppEntry.photo),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Container(
        key: const ValueKey('today-first-entry'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: t.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            HeadingSemantics(
              level: 2,
              child: Text(
                title,
                style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
              ),
            ),
            const SizedBox(height: 12),
            SoftPillButton(
              key: const ValueKey('today-first-entry-search'),
              label: l10n.todayFirstEntrySearch,
              icon: Icons.search_rounded,
              expand: true,
              onTap: () => onEntry(AppEntry.logMeal),
            ),
            const SizedBox(height: _gap),
            LayoutBuilder(
              builder: (context, constraints) {
                final half = (constraints.maxWidth - _gap) / 2;
                final sideBySide = <String>[
                  l10n.todayFirstEntryDescribe,
                  l10n.todayFirstEntryPhoto,
                ].every((label) => _labelWidth(context, label) + _pillChrome <=
                    half);
                if (!sideBySide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      describe,
                      const SizedBox(height: _gap),
                      photo,
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    Expanded(child: describe),
                    const SizedBox(width: _gap),
                    Expanded(child: photo),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// [label] on one line in [SoftPillButton]'s style at the system font.
  static double _labelWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: AppType.ui(14, weight: FontWeight.w700),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
