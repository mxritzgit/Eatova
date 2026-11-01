import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'settings_controls.dart' show SettingsGlyphTile;

// ---------------------------------------------------------------------------
// The three settings picker sheets (sex, activity level, weight goal).
//
// Plain bottom sheets over a route, like everywhere else in the app. The option
// keys (settings-sex-*, settings-activity-*, settings-weight-goal-*) are
// stable.
// ---------------------------------------------------------------------------

Future<BiologicalSex?> showSexPicker(
  BuildContext context, {
  required BiologicalSex value,
}) {
  final l10n = context.l10n;
  return showEatovaSheet<BiologicalSex>(
    context,
    _PickerSheet(
      title: l10n.goalsFieldSex,
      // The all-caps line must add something the title does not already say —
      // here the why, same wording as the onboarding step.
      groupLabel: l10n.settingsSexPickerGroupLabel,
      children: <Widget>[
        for (final option in BiologicalSex.values)
          _PickerRow<BiologicalSex>(
            key: ValueKey<String>('settings-sex-${option.name}'),
            leading: SettingsGlyphTile(
              child: Icon(switch (option) {
                BiologicalSex.male => AppIcons.male,
                BiologicalSex.female => AppIcons.female,
                BiologicalSex.neutral => AppIcons.person,
              }),
            ),
            title: option.label(l10n),
            result: option,
            selected: value == option,
          ),
      ],
    ),
  );
}

Future<ActivityLevel?> showActivityPicker(
  BuildContext context, {
  required ActivityLevel value,
}) {
  final l10n = context.l10n;
  return showEatovaSheet<ActivityLevel>(
    context,
    _PickerSheet(
      title: l10n.goalsFieldActivity,
      groupLabel: l10n.settingsActivityPickerGroupLabel,
      children: <Widget>[
        for (final option in ActivityLevel.values)
          _PickerRow<ActivityLevel>(
            key: ValueKey<String>('settings-activity-${option.name}'),
            leading: SettingsGlyphTile(
              child: _LevelMeter(
                level: option.index + 1,
                of: ActivityLevel.values.length,
              ),
            ),
            title: option.label(l10n),
            subtitle:
                '${option.description(l10n)} · ×${formatPalFactor(option, l10n)}',
            result: option,
            selected: value == option,
          ),
      ],
    ),
  );
}

/// [outcomeFor] supplies each option's subtitle: the plan it yields with the
/// body data currently on the page. The goal's raw kcal delta would show a
/// delta the safety floor and 1 % cap keep most users from ever reaching.
Future<WeightGoal?> showWeightGoalPicker(
  BuildContext context, {
  required WeightGoal value,
  required String Function(WeightGoal) outcomeFor,
}) {
  final l10n = context.l10n;
  return showEatovaSheet<WeightGoal>(
    context,
    _PickerSheet(
      title: l10n.settingsWeightGoalPickerTitle,
      groupLabel: l10n.settingsWeightGoalPickerGroupLabel,
      // No badges in this list: the hairlines start at the card margin.
      inset: ListDividerInset.edge,
      children: <Widget>[
        for (final option in WeightGoal.values)
          _PickerRow<WeightGoal>(
            // No glyph tile here: the seven options with their outcome lines
            // must fit one phone screen, and the title already names the
            // direction.
            key: ValueKey<String>('settings-weight-goal-${option.name}'),
            // Title = the choice, subtitle = its consequence.
            title: option.menuLabel(l10n),
            subtitle: outcomeFor(option),
            result: option,
            selected: value == option,
          ),
      ],
    ),
  );
}

class _PickerSheet extends StatelessWidget {
  const _PickerSheet({
    required this.title,
    required this.groupLabel,
    required this.children,
    this.inset = ListDividerInset.text,
  });

  final String title;
  final String groupLabel;
  final List<Widget> children;
  final ListDividerInset inset;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Title geometry of [SheetScaffold]; no action at the foot, because a tap
    // on an option already is the answer.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Sheet title = rank 1 (P9-06c). The group label below
            // is rank 2 since P9-06, and without this it would hang under
            // nothing.
            HeadingSemantics(
              level: 1,
              child: Text(
                title,
                style: AppType.display(24, color: t.ink, height: 1.15),
              ),
            ),
            const SizedBox(height: 18),
            // The group label is an all-caps line that says WHY the choice
            // matters: a quiet eyebrow (still rank 2) over the list, not a
            // second title competing with the sheet's.
            HeadingSemantics(
              level: 2,
              child: Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(groupLabel, style: AppType.sectionEyebrow(t.ink2)),
              ),
            ),
            const SizedBox(height: kSpace12),
            ListSection(spacing: 0, inset: inset, children: children),
          ],
        ),
      ),
    );
  }
}

/// One option. Closes the sheet with its own [BuildContext]; the caller's
/// context would pop the settings route instead.
///
/// A [ListRow] in a picker list: the chosen option ends in the accent check,
/// the others keep its space empty.
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.title,
    required this.result,
    required this.selected,
    this.subtitle,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final T result;
  final bool selected;

  /// The option's badge; from about 1.6x text it moves above the text, so
  /// the long option texts keep the width.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => ListRow(
    leading: leading,
    title: title,
    subtitle: subtitle,
    trailing: ListTrailing.check,
    selected: selected,
    dense: true,
    onTap: () => Navigator.pop<T>(context, result),
  );
}

/// An activity level as a small step meter: [level] of [of] bars filled,
/// rising left to right. Drawn in the tile's glyph colour.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.of});

  final int level;
  final int of;

  @override
  Widget build(BuildContext context) {
    final ink = IconTheme.of(context).color ?? context.t.inkMuted;
    return SizedBox(
      width: 22,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          for (var i = 0; i < of; i++)
            Container(
              width: 3,
              height: 6 + 12 * i / (of - 1),
              decoration: BoxDecoration(
                color: i < level ? ink : ink.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    );
  }
}
