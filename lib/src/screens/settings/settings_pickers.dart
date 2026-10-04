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
                BiologicalSex.male => Icons.male_rounded,
                BiologicalSex.female => Icons.female_rounded,
                BiologicalSex.neutral => Icons.person_outline_rounded,
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
  });

  final String title;
  final String groupLabel;
  final List<Widget> children;

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
            // Sheet title = rank 1 (P9-06c). The SettingsGroup caption below
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
            SettingsGroup(label: groupLabel, children: children),
          ],
        ),
      ),
    );
  }
}

/// One option. Closes the sheet with its own [BuildContext]; the caller's
/// context would pop the settings route instead.
///
/// The chosen option carries the app's selection language: an accent-tinted
/// row and a filled accent radio; the others an empty ring.
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

  /// The option's glyph tile; dropped from about 1.6x text, where the long
  /// option texts need the width.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? t.accentTint : Colors.transparent,
        child: SettingsRow(
          leading: MediaQuery.textScalerOf(context).scale(15) > 24
              ? null
              : leading,
          title: title,
          subtitle: subtitle,
          chevron: false,
          dense: true,
          onTap: () => Navigator.pop<T>(context, result),
          trailing: ExcludeSemantics(child: _Radio(selected: selected)),
        ),
      ),
    );
  }
}

/// 22 px radio mark: a filled accent disc with a check, or an empty ring.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? t.selectedFill : Colors.transparent,
        border: selected ? null : Border.all(color: t.ink3, width: 1.5),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 15, color: t.onSelected)
          : null,
    );
  }
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
