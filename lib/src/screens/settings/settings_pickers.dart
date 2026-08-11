import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';

// ---------------------------------------------------------------------------
// Die drei Auswahl-Sheets der Einstellungen (Geschlecht, Aktivitaetslevel,
// Gewichtsziel).
//
// Als das Sheet noch ein Sheet war, war das eine zweite modale Ebene ueber
// einer ersten. Auf der Seite ist es schlicht ein Bottom-Sheet ueber einer
// Route — dieselbe Konstruktion, die die App ueberall sonst nutzt.
// Die Options-Schluessel (settings-sex-*, settings-activity-*,
// settings-weight-goal-*) bleiben unveraendert.
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
      // Nicht noch einmal „GESCHLECHT" unter der Ueberschrift „Geschlecht":
      // die Versalien-Zeile soll etwas beitragen, das der Titel nicht schon
      // sagt — hier das Warum (dieselbe Begruendung wie im Onboarding-Schritt).
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
            subtitle: '${option.description(l10n)} · ×${option.palFactor}',
            result: option,
            selected: value == option,
          ),
      ],
    ),
  );
}

/// [outcomeFor] liefert den Untertitel jeder Option: den Plan, den sie mit den
/// Koerperdaten ergibt, die gerade auf der Seite stehen. Frueher stand hier
/// `option.deltaLabel` („−1100 kcal") — ein Delta, das die 1200er-Klemme fuer
/// die Mehrheit nie erreicht.
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
            // Titel = die Auswahl (das gewaehlte Tempo ist der Name der
            // Option), Untertitel = ihre Folge.
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
            Text(title, style: AppType.display(23, color: t.ink, height: 1.15)),
            const SizedBox(height: 14),
            SettingsGroup(label: groupLabel, children: children),
          ],
        ),
      ),
    );
  }
}

/// Eine Option. Sie schliesst das Sheet mit ihrem eigenen [BuildContext] —
/// mit dem Kontext der aufrufenden Seite wuerde stattdessen die
/// Einstellungs-Route gepoppt.
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
