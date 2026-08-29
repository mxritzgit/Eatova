import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

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
/// body data currently on the page. A raw `deltaLabel` would show a delta the
/// safety floor and 1 % cap keep most users from ever reaching.
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
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
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
                style: AppType.display(23, color: t.ink, height: 1.15),
              ),
            ),
            const SizedBox(height: 14),
            SettingsGroup(label: groupLabel, children: children),
          ],
        ),
      ),
    );
  }
}

/// One option. Closes the sheet with its own [BuildContext]; the caller's
/// context would pop the settings route instead.
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.title,
    required this.result,
    required this.selected,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final T result;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      chevron: false,
      onTap: () => Navigator.pop<T>(context, result),
      trailing: selected
          ? Icon(Icons.check_rounded, size: 18, color: t.accent)
          : const SizedBox(width: 18),
    );
  }
}
