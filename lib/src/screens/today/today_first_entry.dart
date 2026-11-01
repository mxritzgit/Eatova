import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/app_entry.dart';
import '../../widgets/design/design.dart';
import 'today_prompt_card.dart';

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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // No lit answer: the page's one lit action is the next meal's "+".
    return TodayPromptCard(
      key: const ValueKey('today-first-entry'),
      title: l10n.todayFirstEntryTitle,
      icon: AppIcons.restaurant,
      actions: <Widget>[
        SoftPillButton(
          key: const ValueKey('today-first-entry-search'),
          label: l10n.todayFirstEntrySearch,
          icon: AppIcons.search,
          expand: true,
          onTap: () => onEntry(AppEntry.logMeal),
        ),
        TodayActionPair(
          labels: (l10n.todayFirstEntryDescribe, l10n.todayFirstEntryPhoto),
          first: SoftPillButton(
            key: const ValueKey('today-first-entry-describe'),
            label: l10n.todayFirstEntryDescribe,
            icon: AppIcons.mic,
            tone: SoftPillTone.neutral,
            expand: true,
            onTap: () => onEntry(AppEntry.describe),
          ),
          second: SoftPillButton(
            key: const ValueKey('today-first-entry-photo'),
            label: l10n.todayFirstEntryPhoto,
            icon: AppIcons.photoCamera,
            tone: SoftPillTone.neutral,
            expand: true,
            onTap: () => onEntry(AppEntry.photo),
          ),
        ),
      ],
    );
  }
}
