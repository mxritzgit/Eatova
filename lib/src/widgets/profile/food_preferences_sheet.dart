import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/user_profile.dart';
import '../../theme/app_tokens.dart';
import '../common/persistence_action.dart';
import '../design/design.dart';

/// Opens the diet editor (F8): diet type, foods the user avoids and a short
/// dislikes text. [onSave] runs only from the save button; the sheet stays
/// open with the draft when it fails.
Future<void> showFoodPreferencesSheet(
  BuildContext context, {
  required FoodPreferences initial,
  required PersistValueChanged<FoodPreferences> onSave,
}) => showEatovaSheet<void>(
  context,
  FoodPreferencesSheet(initial: initial, onSave: onSave),
  // Under the discard guard: Material's handle would pop past it.
  dragHandle: false,
);

/// The profile's "Diet" card: what is set, and the way into the editor.
class FoodPreferencesCard extends StatelessWidget {
  const FoodPreferencesCard({
    super.key,
    required this.preferences,
    this.onSave,
  });

  final FoodPreferences preferences;

  /// Null hides the edit button (previews, tests without a store).
  final PersistValueChanged<FoodPreferences>? onSave;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final avoided = sortedFoodAvoidances(
      preferences.avoidances,
    ).map((a) => a.label(l10n)).join(', ');
    final save = onSave;
    return AppCard(
      key: const ValueKey('profile-food-prefs'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PreferenceRow(
            icon: Icons.restaurant_menu_rounded,
            tone: t.protein,
            label: l10n.foodPrefsDietLabel,
            value: preferences.diet.label(l10n),
          ),
          const SizedBox(height: 14),
          _PreferenceRow(
            icon: Icons.no_food_outlined,
            tone: t.carbs,
            label: l10n.foodPrefsAvoidLabel,
            value: avoided.isEmpty ? l10n.foodPrefsCardNothing : avoided,
          ),
          if (preferences.dislikes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            _PreferenceRow(
              icon: Icons.thumb_down_alt_outlined,
              tone: t.fat,
              label: l10n.foodPrefsDislikesLabel,
              value: preferences.dislikes,
            ),
          ],
          if (save != null) ...<Widget>[
            const SizedBox(height: 16),
            SoftPillButton(
              key: const ValueKey('profile-edit-food-prefs'),
              label: l10n.foodPrefsEditCta,
              icon: Icons.tune_rounded,
              expand: true,
              onTap: () => showFoodPreferencesSheet(
                context,
                initial: preferences,
                onSave: save,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Label above value, read as one node ("Diet type, Vegan").
class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow({
    required this.icon,
    required this.tone,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color tone;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExcludeSemantics(
          child: IconTile.custom(
            color: tone,
            size: 40,
            glyphSize: 20,
            child: Icon(icon),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppType.ui(
                    12.5,
                    weight: FontWeight.w600,
                    color: t.ink2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The editor itself. Public for widget tests; open it through
/// [showFoodPreferencesSheet].
class FoodPreferencesSheet extends StatefulWidget {
  const FoodPreferencesSheet({
    super.key,
    required this.initial,
    required this.onSave,
  });

  final FoodPreferences initial;
  final PersistValueChanged<FoodPreferences> onSave;

  @override
  State<FoodPreferencesSheet> createState() => _FoodPreferencesSheetState();
}

class _FoodPreferencesSheetState extends State<FoodPreferencesSheet> {
  late DietPreference _diet = widget.initial.diet;
  late final Set<FoodAvoidance> _avoid = <FoodAvoidance>{
    ...widget.initial.avoidances,
  };
  late final TextEditingController _dislikes = TextEditingController(
    text: widget.initial.dislikes,
  )..addListener(_onDislikesChanged);

  bool _saving = false;

  /// Guards every intercepted close (back, barrier, drag, close button), so
  /// repeated attempts do not stack dialogs.
  bool _discardOpen = false;

  @override
  void dispose() {
    _dislikes.removeListener(_onDislikesChanged);
    _dislikes.dispose();
    super.dispose();
  }

  void _onDislikesChanged() => setState(() {});

  FoodPreferences get _draft => FoodPreferences(
    diet: _diet,
    avoidances: Set<FoodAvoidance>.unmodifiable(_avoid),
    dislikes: normalizeFoodDislikes(_dislikes.text),
  );

  bool get _dirty => _draft != widget.initial;

  void _toggle(FoodAvoidance avoidance) {
    if (!_avoid.remove(avoidance)) _avoid.add(avoidance);
  }

  static IconData _dietIcon(DietPreference diet) => switch (diet) {
    DietPreference.none => Icons.restaurant_rounded,
    DietPreference.vegetarian => Icons.spa_outlined,
    DietPreference.vegan => Icons.eco_outlined,
    DietPreference.pescetarian => Icons.set_meal_outlined,
  };

  Future<void> _save() async {
    if (_saving) return;
    if (!_dirty) {
      // Nothing changed: no profile op for an unchanged row.
      Navigator.of(context).pop();
      return;
    }
    final draft = _draft;
    setState(() => _saving = true);
    final saved = await tryPersistChange(context, () => widget.onSave(draft));
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.of(context).pop();
  }

  Future<void> _askDiscard() async {
    if (_saving || _discardOpen) return;
    _discardOpen = true;
    final discard = await confirmDiscardChanges(
      context,
      body: context.l10n.foodPrefsDiscardBody,
    );
    _discardOpen = false;
    if (!mounted || !discard) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _dirty;
    return CommitDismissGuard(
      pending: _saving,
      child: PopScope<Object?>(
        canPop: !dirty,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          unawaited(_askDiscard());
        },
        child: SheetDismissGuard(
          active: dirty,
          onDismissAttempt: _askDiscard,
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SheetHandle(onDismiss: () => Navigator.of(context).maybePop()),
          SheetHeader(
            title: l10n.foodPrefsSheetTitle,
            subtitle: l10n.foodPrefsSheetSubtitle,
            onClose: () => Navigator.of(context).maybePop(),
            closeEnabled: !_saving,
            closeKey: const ValueKey('food-prefs-close'),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _GroupHeading(l10n.foodPrefsDietLabel),
                  for (final diet in DietPreference.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OptionCard(
                        actionKey: ValueKey('food-prefs-diet-${diet.name}'),
                        selected: _diet == diet,
                        onTap: () => setState(() => _diet = diet),
                        title: diet.label(l10n),
                        subtitle: diet.description(l10n),
                        leading: OptionGlyphTile(icon: _dietIcon(diet)),
                      ),
                    ),
                  const SizedBox(height: 14),
                  _GroupHeading(l10n.foodPrefsAvoidLabel),
                  Text(
                    l10n.foodPrefsAvoidHint,
                    style: AppType.ui(13, color: t.ink2, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final avoidance in FoodAvoidance.values)
                        FilterChipPill(
                          key: ValueKey('food-prefs-avoid-${avoidance.name}'),
                          label: avoidance.label(l10n),
                          selected: _avoid.contains(avoidance),
                          onTap: () => setState(() => _toggle(avoidance)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SheetField(
                    label: l10n.foodPrefsDislikesLabel,
                    semanticLabel: l10n.foodPrefsDislikesLabel,
                    hint: l10n.foodPrefsDislikesHint,
                    controller: _dislikes,
                    fieldKey: const ValueKey('food-prefs-dislikes'),
                    maxLength: kFoodDislikesMaxChars,
                    // Angle brackets are refused by the server check; the
                    // rest is normalized on save (normalizeFoodDislikes).
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.deny(RegExp('[<>]')),
                    ],
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    bottomGap: 6,
                  ),
                  Text(
                    l10n.foodPrefsDislikesLimit(kFoodDislikesMaxChars),
                    style: AppType.ui(11.5, color: t.ink2),
                  ),
                  const SizedBox(height: 18),
                  SignalNote(
                    l10n.foodPrefsCoachNotice,
                    key: const ValueKey('food-prefs-notice'),
                    tone: t.warning,
                    icon: Icons.health_and_safety_outlined,
                    boxed: true,
                  ),
                  const SizedBox(height: 18),
                  PrimaryActionButton(
                    key: const ValueKey('food-prefs-save'),
                    label: l10n.commonSave,
                    icon: Icons.check_rounded,
                    busy: _saving,
                    onTap: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A group title inside the sheet, announced as a level-2 heading.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: HeadingSemantics(
      level: 2,
      child: Text(text, style: AppType.display(19, color: context.t.ink)),
    ),
  );
}
