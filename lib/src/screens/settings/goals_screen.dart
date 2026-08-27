import 'package:flutter/material.dart';

import '../../app/home_store.dart' show ReminderState;
import '../../l10n/l10n.dart';
import '../../models/model_limits.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/settings_sheet.dart' show SettingsResult;
import '../../widgets/shared/target_bmi_hint.dart';
import 'settings_controls.dart';
import 'settings_pickers.dart';
import 'settings_plan_hero.dart';

/// The goal settings, a full page rather than a modal bottom sheet.
///
/// As a route the drag guard disappears (a [PopScope] covers back button and
/// system back), second-level picker sheets become normal navigation, and the
/// ~20 settings get the room they need.
///
/// [Navigator.pop] returns a [SettingsResult] (or null on cancel), so the shell
/// can call `applySettings` unchanged.
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({
    super.key,
    required this.profile,
    this.notificationsEnabled = false,
    this.reminderState,
    this.onOpenSystemSettings,
  });

  final UserProfile profile;

  /// Callers that do not know the full state pass only this flag; it maps to
  /// [ReminderState.off]/[ReminderState.active] — "blocked by the system" can
  /// then never be shown.
  final bool notificationsEnabled;

  final ReminderState? reminderState;

  /// Route into the system notification settings. Without it the blocked state
  /// shows the hint and NO button — a button that opens nothing is the same
  /// kind of lie as the switch that caused D11. The project currently has no
  /// such route: `url_launcher` only fires ACTION_VIEW intents on Android and
  /// cannot reach `Settings.ACTION_APP_NOTIFICATION_SETTINGS`.
  final VoidCallback? onOpenSystemSettings;

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  late final TextEditingController _weight;
  late final TextEditingController _height;
  late final TextEditingController _age;
  late final TextEditingController _steps;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _targetWeight;
  late BiologicalSex _sex;
  late ActivityLevel _activity;
  late WeightGoal _goal;

  /// True when the user overrode kcal/macros by hand. Comes from the persisted
  /// [UserProfile.manualEnergy] (F7-01) — never reconstructed by comparing
  /// stored and computed numbers, which flipped every profile to manual after
  /// each calculator change. Saving writes it back explicitly.
  late bool _manualEnergy;

  /// Local reminder state (D11). On save this becomes
  /// [SettingsResult.notificationsEnabled], but only for
  /// [ReminderState.active] — "blocked" is not "on".
  late ReminderState _reminder;

  // --- Baseline for the discard prompt (D5) --------------------------------
  late final ReminderState _reminderStart;
  late final bool _manualStart;
  late final Map<TextEditingController, String> _textStart;

  @override
  void initState() {
    super.initState();
    _reminder = widget.reminderState ??
        (widget.notificationsEnabled
            ? ReminderState.active
            : ReminderState.off);
    _reminderStart = _reminder;
    final p = widget.profile;
    _weight = TextEditingController(text: p.weightKg.toString());
    _height = TextEditingController(text: p.heightCm.toString());
    _age = TextEditingController(text: p.ageYears.toString());
    _steps = TextEditingController(text: p.dailyStepsGoal.toString());
    _kcal = TextEditingController(text: p.dailyKcalGoal.toString());
    _protein = TextEditingController(text: p.proteinGoalG.toString());
    _carbs = TextEditingController(text: p.carbsGoalG.toString());
    _fat = TextEditingController(text: p.fatGoalG.toString());
    _targetWeight = TextEditingController(text: p.targetWeightKg.toString());
    _sex = p.sex;
    _activity = p.activityLevel;
    _goal = p.weightGoal;

    _manualEnergy = p.manualEnergy;
    _manualStart = _manualEnergy;
    if (!_manualEnergy) {
      // Live mode: the stored goals are only a cache of an earlier
      // calculation. Prefill the (hidden) energy fields from the live result,
      // so flipping to manual starts from the number on the hero, not from a
      // stale one.
      final t = const KcalCalculator().calculate(p);
      _kcal.text = t.kcal.toString();
      _protein.text = t.proteinG.toString();
      _carbs.text = t.carbsG.toString();
      _fat.text = t.fatG.toString();
    }
    _textStart = <TextEditingController, String>{
      for (final c in _alleFelder) c: c.text,
    };
  }

  List<TextEditingController> get _alleFelder => <TextEditingController>[
        _weight,
        _height,
        _age,
        _steps,
        _kcal,
        _protein,
        _carbs,
        _fat,
        _targetWeight,
      ];

  @override
  void dispose() {
    _weight.dispose();
    _height.dispose();
    _age.dispose();
    _steps.dispose();
    _kcal.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _targetWeight.dispose();
    super.dispose();
  }

  // --- Field validation (C1) -----------------------------------------------
  //
  // `FilteringTextInputFormatter.digitsOnly` is a TYPE guard, not a RANGE
  // guard. Typing "75,5" drops the comma and sends 755 to
  // `profiles.weight_kg` (`between 30 and 300`); the PostgreSQL 23514 message
  // carries the whole failed row including the e-mail — the source of the
  // Sentry leak C1.
  //
  // For user input REJECT is right, not clamp: clamping 755 to 300 would write
  // a number the user never meant. Bounds come from the SQL migrations
  // (model_limits.dart).

  // The `_bereichXxx` getters interpolate their numbers from [ProfileLimits]
  // (deliberately, do NOT inline literals) via ARB keys with {min}/{max}
  // placeholders, so they can reach `context.l10n`.
  String get _bereichKg => context.l10n
      .settingsRangeErrorKg(ProfileLimits.weightKgMin, ProfileLimits.weightKgMax);
  String get _bereichCm => context.l10n
      .settingsRangeErrorCm(ProfileLimits.heightCmMin, ProfileLimits.heightCmMax);
  String get _bereichAlter => context.l10n.settingsRangeErrorYears(
      ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax);
  String get _bereichSchritte => context.l10n.settingsRangeErrorSteps(
      ProfileLimits.dailyStepsGoalMin, ProfileLimits.dailyStepsGoalMax);
  String get _bereichKcal => context.l10n.settingsRangeErrorKcal(
      ProfileLimits.dailyKcalGoalMin, ProfileLimits.dailyKcalGoalMax);
  String get _bereichProtein => context.l10n.settingsRangeErrorGrams(
      ProfileLimits.proteinGoalGMin, ProfileLimits.proteinGoalGMax);
  String get _bereichCarbs => context.l10n.settingsRangeErrorGrams(
      ProfileLimits.carbsGoalGMin, ProfileLimits.carbsGoalGMax);
  String get _bereichFett => context.l10n
      .settingsRangeErrorGrams(ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax);

  /// Error text for the field, or `null` if the value may go to the DB.
  String? _fehler(
    TextEditingController c,
    bool Function(num) gueltig,
    String bereich,
  ) {
    final text = c.text.trim();
    if (text.isEmpty) return context.l10n.settingsFieldRequired;
    final wert = int.tryParse(text);
    if (wert == null || !gueltig(wert)) return bereich;
    return null;
  }

  String? get _weightError =>
      _fehler(_weight, isValidProfileWeightKg, _bereichKg);
  String? get _heightError =>
      _fehler(_height, isValidProfileHeightCm, _bereichCm);
  String? get _ageError => _fehler(_age, isValidProfileAgeYears, _bereichAlter);
  String? get _targetWeightError =>
      _fehler(_targetWeight, isValidProfileTargetWeightKg, _bereichKg);
  String? get _stepsError =>
      _fehler(_steps, isValidDailyStepsGoal, _bereichSchritte);

  // The manual path validates against the DB bounds (800..7000), not the
  // calculator's tighter floors (1200/1350/1500 by sex): setting 1000 on
  // purpose is allowed.
  String? get _kcalError => _fehler(_kcal, isValidDailyKcalGoal, _bereichKcal);
  String? get _proteinError =>
      _fehler(_protein, isValidProteinGoalG, _bereichProtein);
  String? get _carbsError => _fehler(_carbs, isValidCarbsGoalG, _bereichCarbs);
  String? get _fatError => _fehler(_fat, isValidFatGoalG, _bereichFett);

  /// Hidden fields do not count: in live mode kcal and macros come from the
  /// calculation, which respects its own bounds.
  bool get _hatFehler => <String?>[
        _weightError,
        _heightError,
        _ageError,
        _targetWeightError,
        _stepsError,
        if (_manualEnergy) ...<String?>[
          _kcalError,
          _proteinError,
          _carbsError,
          _fatError,
        ],
      ].any((f) => f != null);

  /// The field value if valid, else [fallback].
  ///
  /// For the live calculation: while an invalid value stands, the plan card
  /// keeps showing the last sensible plan instead of a target for 755 kg. On
  /// the save path the fallback cannot fire — [_hatFehler] is already false.
  int _wertOder(
    TextEditingController c,
    bool Function(num) gueltig,
    int fallback,
  ) {
    final wert = int.tryParse(c.text.trim());
    return (wert != null && gueltig(wert)) ? wert : fallback;
  }

  /// Profile with the calorie-relevant fields only — the basis for the live
  /// calculation (energy fields do NOT feed into calculate()).
  UserProfile _draftForCalc() {
    final p = widget.profile;
    return p.copyWith(
      weightKg: _wertOder(_weight, isValidProfileWeightKg, p.weightKg),
      heightCm: _wertOder(_height, isValidProfileHeightCm, p.heightCm),
      // Minimum age 16 (GDPR art. 8, health data) — same bound as onboarding
      // and the DB constraint. Rejected, not silently clamped: clamping wrote
      // an invented age into a 12-year-old's profile.
      ageYears: _wertOder(_age, isValidProfileAgeYears, p.ageYears),
      sex: _sex,
      activityLevel: _activity,
      targetWeightKg: _wertOder(
        _targetWeight,
        isValidProfileTargetWeightKg,
        p.targetWeightKg,
      ),
      weightGoal: _goal,
    );
  }

  KcalTargets get _liveTargets =>
      const KcalCalculator().calculate(_draftForCalc());

  // --- Pace: choice vs. plan (B2) ------------------------------------------
  //
  // The plan card shows the effective pace, the goal row the promised one.
  // Rule: **if more than one pace string is on screen, a third must connect
  // them.** The choice stays on top, the consequence below it.

  /// Subtitle of an option in the weight-goal picker: the plan it yields with
  /// the body data currently on the page.
  ///
  /// In manual mode the daily target no longer depends on pace, so any computed
  /// number would claim something the switch just turned off.
  String _zielFolge(WeightGoal option) {
    final l10n = context.l10n;
    if (_manualEnergy) return l10n.goalsManualNoChangeHint;
    final t = const KcalCalculator()
        .calculate(_draftForCalc().copyWith(weightGoal: option));
    return l10n.commonKcalOutcomeLabel(t.kcal, t.effectivePaceLabel(l10n));
  }

  /// The line below the weight-goal row — `null` while it carries the same pace
  /// label as the plan card.
  ///
  /// Compares **strings**, not numbers: the user sees text, and the explanation
  /// is needed exactly when two different texts are on screen.
  String? _zielAbweichung({required int tagesziel, required KcalTargets t}) {
    final l10n = context.l10n;
    final label = paceLabelForWeeklyRateKg(
      wochenrateKg(tagesziel: tagesziel, erhaltung: t.maintenanceKcal),
      l10n,
    );
    if (label == _goal.paceLabel(l10n)) return null;
    return l10n.commonKcalOutcomeLabel(tagesziel, label);
  }

  UserProfile _buildProfile() {
    final p = widget.profile;
    final t = _liveTargets;
    // copyWith preserves fields the screen never touches, above all
    // onboardingCompleted — otherwise saving sends the user back to onboarding.
    // Water and sleep goals are no longer editable (F7-06: nothing reads
    // them), so they pass through unchanged as well.
    return _draftForCalc().copyWith(
      dailyStepsGoal: _wertOder(_steps, isValidDailyStepsGoal, p.dailyStepsGoal),
      // Explicit in both directions: live -> false, manual -> true.
      manualEnergy: _manualEnergy,
      dailyKcalGoal:
          _manualEnergy ? _wertOder(_kcal, isValidDailyKcalGoal, t.kcal) : t.kcal,
      proteinGoalG: _manualEnergy
          ? _wertOder(_protein, isValidProteinGoalG, t.proteinG)
          : t.proteinG,
      carbsGoalG: _manualEnergy
          ? _wertOder(_carbs, isValidCarbsGoalG, t.carbsG)
          : t.carbsG,
      fatGoalG:
          _manualEnergy ? _wertOder(_fat, isValidFatGoalG, t.fatG) : t.fatG,
    );
  }

  // --- Discard prompt (D5) -------------------------------------------------

  /// Did the user touch anything? Nine number fields, three pickers and two
  /// switches — none of them may vanish silently.
  ///
  /// The theme mode is not in this list: it lives in [SettingsScreen] as a
  /// device setting, is persisted immediately and cannot be discarded.
  bool get _dirty {
    final p = widget.profile;
    if (_sex != p.sex || _activity != p.activityLevel || _goal != p.weightGoal) {
      return true;
    }
    if (_manualEnergy != _manualStart) return true;
    if (_reminder != _reminderStart) return true;
    return _textStart.entries.any((e) => e.key.text != e.value);
  }

  /// Guards EVERY intercepted close attempt — back button and system back both
  /// go through [Navigator.maybePop] and thus the [PopScope]. Repeated attempts
  /// do not stack dialogs.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // The dialog is already popped; the page is the top route again.
    // Deliberately without a result: discarded is not saved.
    Navigator.of(context).pop();
  }

  /// Text for the current reminder state (D11). Three states, three sentences;
  /// "blocked" is a system setting, not an error.
  String get _reminderText => switch (_reminder) {
        ReminderState.off => context.l10n.goalsReminderTextOff,
        ReminderState.active => context.l10n.goalsReminderTextActive,
        ReminderState.blocked => context.l10n.goalsReminderTextBlocked,
      };

  /// In live mode, refill the energy fields from the fresh calculation to keep
  /// the page consistent, then redraw.
  void _recompute() {
    if (!_manualEnergy) {
      final t = _liveTargets;
      _kcal.text = t.kcal.toString();
      _protein.text = t.proteinG.toString();
      _carbs.text = t.carbsG.toString();
      _fat.text = t.fatG.toString();
    }
    setState(() {});
  }

  void _toggleManual(bool manual) {
    setState(() {
      _manualEnergy = manual;
      if (!manual) {
        final t = _liveTargets;
        _kcal.text = t.kcal.toString();
        _protein.text = t.proteinG.toString();
        _carbs.text = t.carbsG.toString();
        _fat.text = t.fatG.toString();
      }
    });
  }

  void _save() {
    Navigator.pop(
      context,
      SettingsResult(
        profile: _buildProfile(),
        // D11: only "active" means a reminder actually fires in the evening.
        notificationsEnabled: _reminder == ReminderState.active,
      ),
    );
  }

  Future<void> _pickSex() async {
    final gewaehlt = await showSexPicker(context, value: _sex);
    if (gewaehlt == null || !mounted) return;
    _sex = gewaehlt;
    _recompute();
  }

  Future<void> _pickActivity() async {
    final gewaehlt = await showActivityPicker(context, value: _activity);
    if (gewaehlt == null || !mounted) return;
    _activity = gewaehlt;
    _recompute();
  }

  Future<void> _pickWeightGoal() async {
    final gewaehlt = await showWeightGoalPicker(
      context,
      value: _goal,
      outcomeFor: _zielFolge,
    );
    if (gewaehlt == null || !mounted) return;
    _goal = gewaehlt;
    _recompute();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final ziele = _liveTargets;
    final heroKcal = _manualEnergy
        ? _wertOder(_kcal, isValidDailyKcalGoal, ziele.kcal)
        : ziele.kcal;
    final heroProtein = _manualEnergy
        ? _wertOder(_protein, isValidProteinGoalG, ziele.proteinG)
        : ziele.proteinG;
    final heroCarbs = _manualEnergy
        ? _wertOder(_carbs, isValidCarbsGoalG, ziele.carbsG)
        : ziele.carbsG;
    final heroFat =
        _manualEnergy ? _wertOder(_fat, isValidFatGoalG, ziele.fatG) : ziele.fatG;

    return PopScope<SettingsResult>(
      // D5: back button and system back both go through Navigator.maybePop and
      // therefore ask the pop disposition. A route needs no drag guard — it has
      // neither barrier nor swipe-to-dismiss.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      // Same data class as the profile (weight, height, age, target weight), so
      // the same screenshot/recents protection.
      child: SecureScreenGuard(
        child: Scaffold(
          key: const ValueKey('screen-goals'),
          body: SafeArea(
            // Bottom inset too: this route carries no navigation bar, so
            // without it the save button and legal links would sit under the
            // system gesture bar. Deliberately NOT a ListView: tests read the
            // footer before anyone scrolls, and a lazy list never builds it.
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  PageHeader(
                    large: l10n.goalsPageTitle,
                    backKey: const ValueKey('settings-close'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l10n.goalsIntroHint,
                    style: AppType.ui(12.5, color: t.ink2, height: 1.45),
                  ),
                  const SizedBox(height: 18),
                  SettingsPlanHero(
                    kcal: heroKcal,
                    protein: heroProtein,
                    carbs: heroCarbs,
                    fat: heroFat,
                    targets: ziele,
                    manual: _manualEnergy,
                  ),
                  const SizedBox(height: 22),
                  ..._koerperGruppe(),
                  ..._zielGruppe(heroKcal: heroKcal, ziele: ziele),
                  ..._energieGruppe(),
                  ..._tageszieleGruppe(),
                  ..._erinnerungenGruppe(t),
                  if (_hatFehler) ...<Widget>[
                    SettingsNote(
                      l10n.goalsValidationSummary,
                      key: const ValueKey('settings-validation-note'),
                      tone: t.danger,
                      icon: Icons.error_outline_rounded,
                      boxed: true,
                    ),
                    const SizedBox(height: 14),
                  ],
                  Semantics(
                    // [PrimaryActionButton] is a bare InkWell and carries
                    // neither `isButton` nor an enabled state. Without this
                    // wrapper the disabled save button would sound like a
                    // normal button that does nothing to a screen reader.
                    button: true,
                    enabled: !_hatFehler,
                    child: Opacity(
                      // PrimaryActionButton cannot express "disabled" itself;
                      // same solution as SheetScaffold.
                      opacity: _hatFehler ? 0.4 : 1,
                      child: PrimaryActionButton(
                        key: const ValueKey('settings-save'),
                        label: l10n.commonSave,
                        icon: Icons.check_rounded,
                        onTap: _hatFehler ? null : _save,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const SettingsLegalLinks(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Groups ---------------------------------------------------------------

  List<Widget> _koerperGruppe() {
    final l10n = context.l10n;
    return <Widget>[
      SettingsGroup(
        label: l10n.goalsGroupBody,
        children: <Widget>[
          SettingsNumberRow(
            label: l10n.goalsFieldWeight,
            suffix: l10n.commonUnitKg,
            controller: _weight,
            fieldKey: const ValueKey('settings-weight'),
            errorText: _weightError,
            onChanged: (_) => _recompute(),
          ),
          SettingsNumberRow(
            label: l10n.goalsFieldHeight,
            suffix: l10n.commonUnitCm,
            controller: _height,
            fieldKey: const ValueKey('settings-height'),
            errorText: _heightError,
            onChanged: (_) => _recompute(),
          ),
          SettingsNumberRow(
            label: l10n.goalsFieldAge,
            suffix: l10n.goalsUnitAgeAbbrev,
            controller: _age,
            fieldKey: const ValueKey('settings-age'),
            errorText: _ageError,
            onChanged: (_) => _recompute(),
          ),
          SettingsRow(
            key: const ValueKey('settings-sex'),
            title: l10n.goalsFieldSex,
            value: _sex.label(l10n),
            onTap: _pickSex,
          ),
        ],
      ),
    ];
  }

  List<Widget> _zielGruppe({
    required int heroKcal,
    required KcalTargets ziele,
  }) {
    final t = context.t;
    final l10n = context.l10n;
    final p = widget.profile;
    final bmiHeight = _wertOder(_height, isValidProfileHeightCm, p.heightCm);
    final bmiTarget = _wertOder(
      _targetWeight,
      isValidProfileTargetWeightKg,
      p.targetWeightKg,
    );
    // Soft, non-blocking BMI hint — same bounds as the onboarding goal step
    // (below 18.5 / above 35). Visibility is decided here so SettingsGroup
    // does not draw a divider around an empty child.
    final zeigtBmiHinweis = targetBmiHintText(
          heightCm: bmiHeight,
          targetWeightKg: bmiTarget,
        ) !=
        null;
    final abweichung = _zielAbweichung(tagesziel: heroKcal, t: ziele);

    return <Widget>[
      SettingsGroup(
        label: l10n.goalsGroupActivityGoal,
        children: <Widget>[
          SettingsRow(
            key: const ValueKey('settings-activity'),
            title: l10n.goalsFieldActivity,
            subtitle: l10n.goalsFieldActivitySubtitle,
            value: '${_activity.label(l10n)} · ×${formatPalFactor(_activity, l10n)}',
            onTap: _pickActivity,
          ),
          SettingsNumberRow(
            label: l10n.goalsFieldTargetWeight,
            suffix: l10n.commonUnitKg,
            controller: _targetWeight,
            fieldKey: const ValueKey('settings-target-weight'),
            errorText: _targetWeightError,
            onChanged: (_) => _recompute(),
          ),
          if (zeigtBmiHinweis)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TargetBmiHint(
                heightCm: bmiHeight,
                targetWeightKg: bmiTarget,
              ),
            ),
          // Row and its extra line are ONE group child, or SettingsGroup would
          // draw a divider between the row and its own footnote.
          Column(
            children: <Widget>[
              SettingsRow(
                key: const ValueKey('settings-weight-goal'),
                title: l10n.goalsFieldWeightGoal,
                subtitle: _goal.label(l10n),
                // Stays the CHOSEN pace: the row shows what the user picked;
                // what it turns into is the line below.
                value: _goal.paceLabel(l10n),
                onTap: _pickWeightGoal,
              ),
              if (abweichung != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 13),
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      abweichung,
                      key: const ValueKey('settings-weight-goal-effective'),
                      style: AppType.ui(
                        11.5,
                        weight: FontWeight.w500,
                        color: t.ink2,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ];
  }

  List<Widget> _energieGruppe() {
    final l10n = context.l10n;
    return <Widget>[
      SettingsGroup(
        label: l10n.goalsGroupEnergyMacros,
        children: <Widget>[
          SettingsRow(
            title: l10n.goalsFieldManual,
            chevron: false,
            // The whole row toggles; tapping beside the switch used to hit
            // nothing. A tap ON the switch is still won by its own recognizer
            // (inner wins the gesture arena), so it never toggles twice.
            onTap: () => _toggleManual(!_manualEnergy),
            trailing: AppToggle(
              key: const ValueKey('settings-manual-energy'),
              value: _manualEnergy,
              onChanged: _toggleManual,
              semanticLabel: l10n.goalsManualSemanticLabel,
            ),
          ),
          if (!_manualEnergy)
            SettingsNote(l10n.goalsAutoNote)
          else ...<Widget>[
            SettingsNumberRow(
              label: l10n.goalsFieldKcalGoal,
              suffix: l10n.commonKcalUnit,
              controller: _kcal,
              fieldKey: const ValueKey('settings-kcal'),
              errorText: _kcalError,
              onChanged: (_) => setState(() {}),
            ),
            SettingsNumberRow(
              label: l10n.todayMacroProtein,
              suffix: l10n.commonUnitG,
              controller: _protein,
              fieldKey: const ValueKey('settings-protein'),
              errorText: _proteinError,
              onChanged: (_) => setState(() {}),
            ),
            SettingsNumberRow(
              label: l10n.foodMacroTileCarbsLabel,
              suffix: l10n.commonUnitG,
              controller: _carbs,
              fieldKey: const ValueKey('settings-carbs'),
              errorText: _carbsError,
              onChanged: (_) => setState(() {}),
            ),
            SettingsNumberRow(
              label: l10n.todayMacroFat,
              suffix: l10n.commonUnitG,
              controller: _fat,
              fieldKey: const ValueKey('settings-fat'),
              errorText: _fatError,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    ];
  }

  /// Only the step goal is left (F7-06): water and sleep goals were settings
  /// without an effect — nothing in the app reads them since the tracking
  /// tabs went. The columns and defaults stay; the rows are gone.
  List<Widget> _tageszieleGruppe() {
    final l10n = context.l10n;
    return <Widget>[
      SettingsGroup(
        label: l10n.goalsGroupDailyTargets,
        children: <Widget>[
          SettingsNumberRow(
            label: l10n.goalsFieldSteps,
            suffix: l10n.goalsUnitPerDay,
            controller: _steps,
            fieldKey: const ValueKey('settings-steps-goal'),
            errorText: _stepsError,
            onChanged: (_) => setState(() {}),
          ),
          SettingsNote(l10n.goalsDailyTargetsNote),
        ],
      ),
    ];
  }

  List<Widget> _erinnerungenGruppe(AppTokens t) {
    final l10n = context.l10n;
    return <Widget>[
      SettingsGroup(
        label: l10n.goalsGroupReminders,
        children: <Widget>[
          SettingsRow(
            title: l10n.goalsFieldReminders,
            subtitle: l10n.goalsRemindersSubtitle,
            chevron: false,
            // Like the manual switch: the whole row is the target. Off (null)
            // while blocked — otherwise D11 would have a back door, since the
            // disabled switch adds no recognizer and the row would take the
            // tap.
            onTap: _reminder == ReminderState.blocked
                ? null
                : () => setState(
                      () => _reminder = _reminder == ReminderState.active
                          ? ReminderState.off
                          : ReminderState.active,
                    ),
            trailing: AppToggle(
              key: const ValueKey('settings-notifications'),
              value: _reminder == ReminderState.active,
              // D11: do NOT allow toggling while blocked. On Android 13+ the
              // system stops showing a dialog after two refusals, so the
              // switch would snap back and look like an app bug.
              enabled: _reminder != ReminderState.blocked,
              semanticLabel: _reminder == ReminderState.blocked
                  ? l10n.goalsReminderBlockedSemantics
                  : l10n.goalsReminderActiveSemantics,
              onChanged: (v) => setState(
                () => _reminder =
                    v ? ReminderState.active : ReminderState.off,
              ),
            ),
          ),
          SettingsNote(
            _reminderText,
            key: const ValueKey('settings-reminder-note'),
            tone: _reminder == ReminderState.blocked ? t.warning : t.ink2,
            icon: _reminder == ReminderState.blocked
                ? Icons.notifications_off_outlined
                : Icons.info_outline_rounded,
          ),
          if (_reminder == ReminderState.blocked &&
              widget.onOpenSystemSettings != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SettingsSecondaryButton(
                key: const ValueKey('settings-open-system-settings'),
                label: l10n.goalsOpenSystemSettings,
                icon: Icons.settings_outlined,
                tone: t.warning,
                onTap: widget.onOpenSystemSettings,
              ),
            ),
        ],
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// D5: discard prompt
// ---------------------------------------------------------------------------

/// "Discard changes?" — the shared confirmation for every way of leaving a
/// filled page.
///
/// `barrierDismissible: true` (default) is intentional: a tap outside means
/// cancel, the harmless answer.
///
/// **Duplicated:** the same confirmation lives in `edit_meal_sheet.dart` and
/// `recipe_create_sheet.dart` (both still with `_DiscardDragGuard`). The copies
/// belong in the shared library.
///
/// Returns `true` = discard, `false`/dismissed = keep editing.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final t = dialogContext.t;
      return AlertDialog(
        key: const ValueKey('discard-changes-dialog'),
        title: Text(l10n.foodDiscardChangesTitle),
        content: Text(l10n.goalsDiscardChangesBody),
        actions: <Widget>[
          TextButton(
            key: const ValueKey('discard-changes-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.foodDiscardChangesKeepEditing),
          ),
          TextButton(
            key: const ValueKey('discard-changes-confirm'),
            style: TextButton.styleFrom(foregroundColor: t.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.foodDiscardChangesConfirm),
          ),
        ],
      );
    },
  );
  return verwerfen ?? false;
}
