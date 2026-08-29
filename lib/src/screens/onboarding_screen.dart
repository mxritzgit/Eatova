import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/model_limits.dart';
import '../models/user_profile.dart';
import '../services/kcal_calculator.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/motion.dart';
import '../widgets/design/design.dart';
import '../widgets/shared/target_bmi_hint.dart';

/// Mandatory onboarding: collects body data, activity and goal and computes
/// the daily target (Mifflin-St Jeor BMR x activity PAL +- goal delta). Runs
/// once per user; [UserProfile.onboardingCompleted] then closes the gate.
///
/// No text inputs on purpose: sliders and steppers are faster on a phone and
/// always yield values inside the DB constraints.
///
/// ## Ranges come from [ProfileLimits], never from literals
///
/// Mirrored numeric ranges were both a legal and a functional problem: the
/// minimum age of 16 is GDPR Art. 8 consent capacity (already moved once by
/// migration `20260807090000`), and the narrower copies silently clamped real
/// users (210 kg, 115 cm) to values they never entered.
///
/// The only remaining narrowing is the target weight, dynamically via
/// [_targetMin] / [_targetMax] — a consistency bound, not a range, so it
/// cannot drift.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.firstName,
    required this.initialProfile,
    required this.onComplete,
  });

  final String firstName;
  final UserProfile initialProfile;

  /// Receives the finished profile with computed daily target and
  /// onboardingCompleted = true. The caller persists it and leaves the gate.
  final ValueChanged<UserProfile> onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _GoalDirection { lose, maintain, gain }

enum _Step { intro, sex, age, height, weight, activity, goal, target, pace, diet, summary }

class _OnboardingScreenState extends State<OnboardingScreen> {
  late BiologicalSex _sex;
  late int _age;
  late int _height;
  late int _weight;
  late ActivityLevel _activity;
  late _GoalDirection _direction;
  late int _target;
  late DietPreference _diet;
  // Separate pace per direction, so switching back and forth loses nothing.
  WeightGoal _losePace = WeightGoal.lose05kg;
  WeightGoal _gainPace = WeightGoal.gain025kg;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile;
    _sex = p.sex;
    // Clamp to the DB bound only; anything narrower would silently substitute
    // a value the user never entered (see class docs).
    _age = p.ageYears
        .clamp(ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax)
        .toInt();
    _height = p.heightCm
        .clamp(ProfileLimits.heightCmMin, ProfileLimits.heightCmMax)
        .toInt();
    _weight = p.weightKg
        .clamp(ProfileLimits.weightKgMin, ProfileLimits.weightKgMax)
        .toInt();
    _activity = p.activityLevel;
    if (p.weightGoal.isLoss) {
      _direction = _GoalDirection.lose;
      _losePace = p.weightGoal;
    } else if (p.weightGoal.isGain) {
      _direction = _GoalDirection.gain;
      _gainPace = p.weightGoal;
    } else {
      _direction = _GoalDirection.maintain;
    }
    _target = clampProfileTargetWeightKg(p.targetWeightKg);
    _diet = p.diet;
  }

  /// Visible steps — target weight and pace are skipped for "maintain".
  List<_Step> get _steps => [
        _Step.intro,
        _Step.sex,
        _Step.age,
        _Step.height,
        _Step.weight,
        _Step.activity,
        _Step.goal,
        if (_direction != _GoalDirection.maintain) ...[
          _Step.target,
          _Step.pace,
        ],
        _Step.diet,
        _Step.summary,
      ];

  WeightGoal get _weightGoal => switch (_direction) {
        _GoalDirection.maintain => WeightGoal.maintain,
        _GoalDirection.lose => _losePace,
        _GoalDirection.gain => _gainPace,
      };

  /// Bounds the target weight to the chosen direction (lose -> below, gain ->
  /// above). The only remaining narrowing against the DB, and the only one
  /// that cannot be mirrored because it depends on the current weight.
  ///
  /// The rule itself lives in `user_profile.dart` — the goals page enforces the
  /// same one on typed input, and two copies drift (P9-08b).
  int get _targetMin => targetWeightMinFor(_weightGoal, _weight);
  int get _targetMax => targetWeightMaxFor(_weightGoal, _weight);

  /// clamp without an assert crash on inverted bounds (weight at an extreme).
  static int _safeClamp(int v, int lo, int hi) =>
      hi < lo ? lo : v.clamp(lo, hi).toInt();

  /// The target weight actually in play: [_target] narrowed to the window the
  /// direction leaves open. The ONE number the target step may show — picker,
  /// footnote, BMI hint and the saved plan all read this.
  ///
  /// [_NumberPicker] clamps what it draws but cannot write back, so a raw
  /// `_target` in the footnote made the sentence contradict the number right
  /// above it as soon as the weight moved under a target picked earlier
  /// (80 kg → "lose" → back → 60 kg showed "59 kg" over "15 kg abnehmen").
  ///
  /// The DB clamp on top catches the one window that inverts: gaining at
  /// 300 kg leaves min 301 > max 300, and `_safeClamp` would hand 301 to a
  /// column that ends at 300.
  int get _targetSafe =>
      clampProfileTargetWeightKg(_safeClamp(_target, _targetMin, _targetMax));

  UserProfile _draftProfile() {
    final target =
        _direction == _GoalDirection.maintain ? _weight : _targetSafe;
    return widget.initialProfile.copyWith(
      sex: _sex,
      ageYears: _age,
      heightCm: _height,
      weightKg: _weight,
      activityLevel: _activity,
      weightGoal: _weightGoal,
      targetWeightKg: target,
      diet: _diet,
    );
  }

  KcalTargets get _targets => const KcalCalculator().calculate(_draftProfile());

  /// What [option] actually yields with the body data collected so far —
  /// subtitle of every row in the pace step (B2).
  ///
  /// The pace step is 9 of 11, so weight, height, age, sex and activity are
  /// all fixed and `calculate` is unconditional here. Showing the requested
  /// delta instead would lie whenever the safety floor or the 1 % cap changes
  /// it — two pace options could then promise different rates for the same
  /// plan.
  ///
  /// The title keeps the chosen pace: it is the option's *name*, and two rows
  /// with the same effective rate would be indistinguishable. The consequence
  /// belongs in the subtitle.
  String _tempoFolge(WeightGoal option) {
    final l10n = context.l10n;
    final t = const KcalCalculator()
        .calculate(_draftProfile().copyWith(weightGoal: option));
    return l10n.commonKcalOutcomeLabel(t.kcal, t.effectivePaceLabel(l10n));
  }

  void _next() {
    if (_index >= _steps.length - 1) {
      _finish();
      return;
    }
    setState(() => _index++);
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index--);
  }

  /// Android system back (button or edge gesture) — must do what the header
  /// arrow does (D4).
  ///
  /// [OnboardingScreen] is the root route, so without this handler the engine
  /// falls back to `SystemNavigator.pop()` and kills the activity, losing
  /// every answer given so far (only `_finish()` persists anything).
  ///
  /// From step 1 the pop is intercepted and turned into a step back. On step 0
  /// `canPop` stays `true`: nothing is invested there, and the alternative —
  /// back to the auth screen — would mean signing out.
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    _back();
  }

  void _onDirectionChosen(_GoalDirection dir) {
    setState(() {
      _direction = dir;
      // A sensible default INSIDE the window the new direction opens: 5 kg
      // along it. The window itself comes from `_targetMin`/`_targetMax`, which
      // already read the direction assigned one line above — spelling the
      // bounds out a second time here is how the rule started drifting.
      _target = dir == _GoalDirection.maintain
          ? _weight
          : _safeClamp(
              dir == _GoalDirection.lose ? _weight - 5 : _weight + 5,
              _targetMin,
              _targetMax,
            );
    });
  }

  void _finish() {
    final t = _targets;
    final finished = _draftProfile().copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
      onboardingCompleted: true,
    );
    widget.onComplete(finished);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final step = _steps[_index];
    final progress = (_index + 1) / _steps.length;
    final isSummary = step == _Step.summary;

    return PopScope<Object?>(
      // Only the intro step releases the pop — see [_onPopInvoked].
      canPop: _index == 0,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        key: const ValueKey('screen-onboarding'),
        backgroundColor: t.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  progress: progress,
                  showBack: _index > 0,
                  onBack: _back,
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: AnimatedSwitcher(
                    duration:
                        motionDuration(context, const Duration(milliseconds: 240)),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, anim) {
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.06, 0),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      );
                    },
                    child: SingleChildScrollView(
                      key: ValueKey('onboarding-step-${step.name}'),
                      child: _buildStep(step),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  // [PrimaryActionButton] is a bare InkWell without `isButton`,
                  // so a screen reader would announce the CTA as plain text.
                  // Belongs in the library; here until then.
                  button: true,
                  child: PrimaryActionButton(
                    key: ValueKey(
                      isSummary ? 'onboarding-finish' : 'onboarding-next',
                    ),
                    label: switch (step) {
                      _Step.intro => l10n.onboardingStartCta,
                      _Step.summary => l10n.onboardingActivatePlanCta,
                      _ => l10n.onboardingNextCta,
                    },
                    onTap: _next,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(_Step step) {
    final l10n = context.l10n;
    return switch (step) {
      // Questions between intro and summary — what the user actually answers.
      _Step.intro => _IntroStep(
          firstName: widget.firstName,
          questionCount: _steps.length - 2,
        ),
      _Step.sex => _StepFrame(
          title: l10n.onboardingSexStepTitle,
          subtitle: l10n.onboardingSexStepSubtitle,
          child: _SexPicker(
            value: _sex,
            onChanged: (v) => setState(() => _sex = v),
          ),
        ),
      _Step.age => _StepFrame(
          title: l10n.onboardingAgeStepTitle,
          subtitle: l10n.onboardingAgeStepSubtitle,
          child: _NumberPicker(
            field: 'age',
            value: _age,
            min: ProfileLimits.ageYearsMin,
            max: ProfileLimits.ageYearsMax,
            unit: l10n.onboardingUnitYears,
            onChanged: (v) => setState(() => _age = v),
          ),
        ),
      _Step.height => _StepFrame(
          title: l10n.onboardingHeightStepTitle,
          subtitle: l10n.onboardingHeightStepSubtitle,
          child: _NumberPicker(
            field: 'height',
            value: _height,
            min: ProfileLimits.heightCmMin,
            max: ProfileLimits.heightCmMax,
            unit: l10n.commonUnitCm,
            onChanged: (v) => setState(() => _height = v),
          ),
        ),
      _Step.weight => _StepFrame(
          title: l10n.onboardingWeightStepTitle,
          subtitle: l10n.onboardingWeightStepSubtitle,
          child: _NumberPicker(
            field: 'weight',
            value: _weight,
            min: ProfileLimits.weightKgMin,
            max: ProfileLimits.weightKgMax,
            unit: l10n.commonUnitKg,
            // Deliberately does NOT follow the target weight along (P9-07b):
            // [_targetSafe] already keeps every shown number inside the window,
            // and writing the clamped value back would COST the choice. 80 kg
            // with a target of 70, weight down to 60 and back to 80 then ended
            // at 59 instead of the 70 the user had picked.
            onChanged: (v) => setState(() => _weight = v),
          ),
        ),
      _Step.activity => _StepFrame(
          title: l10n.onboardingActivityStepTitle,
          subtitle: l10n.onboardingActivityStepSubtitle,
          child: _ActivityPicker(
            value: _activity,
            onChanged: (v) => setState(() => _activity = v),
          ),
        ),
      _Step.goal => _StepFrame(
          title: l10n.onboardingGoalStepTitle,
          subtitle: l10n.onboardingGoalStepSubtitle,
          child: _GoalPicker(
            value: _direction,
            onChanged: _onDirectionChosen,
          ),
        ),
      _Step.target => _StepFrame(
          title: l10n.onboardingTargetStepTitle,
          subtitle: _direction == _GoalDirection.lose
              ? l10n.onboardingTargetStepSubtitleLose
              : l10n.onboardingTargetStepSubtitleGain,
          child: Column(
            children: [
              _NumberPicker(
                field: 'target',
                // [_targetSafe], not `_target`: number and footnote have to
                // mean the same kilograms.
                value: _targetSafe,
                min: _targetMin,
                max: _targetMax,
                unit: l10n.commonUnitKg,
                onChanged: (v) => setState(() => _target = v),
                footnote: _direction == _GoalDirection.lose
                    ? l10n.onboardingTargetFootnoteLose(
                        (_weight - _targetSafe).abs())
                    : l10n.onboardingTargetFootnoteGain(
                        (_weight - _targetSafe).abs()),
              ),
              // Soft, non-blocking BMI hint — same thresholds as the settings
              // sheet (below 18.5 / above 35).
              TargetBmiHint(
                margin: const EdgeInsets.only(top: 16),
                heightCm: _height,
                targetWeightKg: _targetSafe,
              ),
            ],
          ),
        ),
      _Step.pace => _StepFrame(
          title: l10n.onboardingPaceStepTitle,
          subtitle: _direction == _GoalDirection.lose
              ? l10n.onboardingPaceStepSubtitleLose
              : l10n.onboardingPaceStepSubtitleGain,
          child: _PacePicker(
            options: _direction == _GoalDirection.lose
                ? lossPaceGoals
                : gainPaceGoals,
            value: _direction == _GoalDirection.lose ? _losePace : _gainPace,
            outcomeFor: _tempoFolge,
            onChanged: (v) => setState(() {
              if (_direction == _GoalDirection.lose) {
                _losePace = v;
              } else {
                _gainPace = v;
              }
            }),
          ),
        ),
      _Step.diet => _StepFrame(
          title: l10n.onboardingDietStepTitle,
          subtitle: l10n.onboardingDietStepSubtitle,
          child: _DietPicker(
            value: _diet,
            onChanged: (v) => setState(() => _diet = v),
          ),
        ),
      _Step.summary => _SummaryStep(
          firstName: widget.firstName,
          targets: _targets,
          profile: _draftProfile(),
        ),
    };
  }
}

// ---------------------------------------------------------------------------
// Header + Footer
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.progress,
    required this.showBack,
    required this.onBack,
  });

  final double progress;
  final bool showBack;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        SizedBox(
          // Exactly the edge length of SquareIconButton, so the bar does not
          // jump between intro and step 1.
          width: 34,
          child: showBack
              ? SquareIconButton(
                  key: const ValueKey('onboarding-back'),
                  icon: Icons.chevron_left_rounded,
                  onTap: onBack,
                  // Real umlaut, not "ue": a Semantics label is SPOKEN text
                  // (cf. PageHeader in widgets/design/rows.dart).
                  semanticLabel: context.l10n.onboardingBackSemanticLabel,
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(rPill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: t.tile,
              valueColor: AlwaysStoppedAnimation<Color>(t.accent),
            ),
          ),
        ),
        const SizedBox(width: 46),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Generic step frame
// ---------------------------------------------------------------------------

class _StepFrame extends StatelessWidget {
  const _StepFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppType.display(28, color: t.ink, height: 1.08)),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 32),
        child,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Intro
// ---------------------------------------------------------------------------

class _IntroStep extends StatelessWidget {
  const _IntroStep({required this.firstName, required this.questionCount});

  final String firstName;

  /// Number of questions ahead; the intro must not promise "6" when the flow
  /// has 7 or 9.
  final int questionCount;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: t.forest,
            borderRadius: BorderRadius.circular(rSheet),
          ),
          child: Icon(Icons.flag_rounded, color: t.lime, size: 30),
        ),
        const SizedBox(height: 28),
        Text(
          l10n.onboardingWelcomeTitle(firstName),
          style: AppType.display(30, color: t.ink, height: 1.08),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.onboardingWelcomeBody(questionCount),
          style: AppType.ui(
            15,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 32),
        _IntroBullet(
          icon: Icons.calculate_rounded,
          text: l10n.onboardingBulletFormula,
        ),
        const SizedBox(height: 14),
        _IntroBullet(
          icon: Icons.local_fire_department_rounded,
          text: l10n.onboardingBulletAutoMacros,
        ),
        const SizedBox(height: 14),
        _IntroBullet(
          icon: Icons.tune_rounded,
          text: l10n.onboardingBulletAdjustable,
        ),
      ],
    );
  }
}

class _IntroBullet extends StatelessWidget {
  const _IntroBullet({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        IconTile(icon: icon, color: t.accent),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(
              14,
              weight: FontWeight.w500,
              color: t.ink,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pickers
// ---------------------------------------------------------------------------

class _SexPicker extends StatelessWidget {
  const _SexPicker({required this.value, required this.onChanged});

  final BiologicalSex value;
  final ValueChanged<BiologicalSex> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final labels = {
      BiologicalSex.male: (l10n.onboardingSexMale, Icons.male_rounded),
      BiologicalSex.female: (l10n.onboardingSexFemale, Icons.female_rounded),
      BiologicalSex.neutral: (l10n.onboardingSexNeutral, Icons.person_rounded),
    };
    // Width is reserved for the longest label at the current text scale
    // (like MacroBar, not FittedBox — that would freeze the label at 14 px).
    // When a third of the row cannot hold it, the tiles take the full width
    // and stack.
    const gap = 12.0;
    final labelWidth = MediaQuery.textScalerOf(context).scale(68) + 16;
    return LayoutBuilder(
      builder: (context, constraints) {
        final third = (constraints.maxWidth - 2 * gap) / 3;
        final tileWidth = labelWidth <= third ? third : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final sex in BiologicalSex.values)
              SizedBox(
                width: tileWidth,
                child: _TileCard(
                  keyValue: ValueKey('onboarding-sex-${sex.name}'),
                  selected: value == sex,
                  onTap: () => onChanged(sex),
                  child: Column(
                    children: [
                      Icon(
                        labels[sex]!.$2,
                        size: 30,
                        // Glyph and label sit ON [_TileCard]'s fill, so they
                        // take its counterpart — `lime` would be 1.07:1 there
                        // in dark mode.
                        color: value == sex ? t.onSelected : t.ink2,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        labels[sex]!.$1,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w700,
                          color: value == sex ? t.onSelected : t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ActivityPicker extends StatelessWidget {
  const _ActivityPicker({required this.value, required this.onChanged});

  final ActivityLevel value;
  final ValueChanged<ActivityLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        for (final level in ActivityLevel.values) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-activity-${level.name}'),
            selected: value == level,
            onTap: () => onChanged(level),
            title: level.label(l10n),
            subtitle: level.description(l10n),
            trailing: '×${level.palFactor}',
          ),
          if (level != ActivityLevel.values.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _GoalPicker extends StatelessWidget {
  const _GoalPicker({required this.value, required this.onChanged});

  final _GoalDirection value;
  final ValueChanged<_GoalDirection> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // The direction labels are byte-identical to [WeightGoalInfo.label] for
    // the matching [WeightGoal], so the same ARB keys are reused instead of
    // duplicate onboarding keys.
    final items = {
      _GoalDirection.lose: (
        l10n.commonWeightGoalLabelLose,
        l10n.onboardingGoalDescLose,
        Icons.trending_down_rounded,
      ),
      _GoalDirection.maintain: (
        l10n.commonWeightGoalLabelMaintain,
        l10n.onboardingGoalDescMaintain,
        Icons.trending_flat_rounded,
      ),
      _GoalDirection.gain: (
        l10n.commonWeightGoalLabelGain,
        l10n.onboardingGoalDescGain,
        Icons.trending_up_rounded,
      ),
    };
    return Column(
      children: [
        for (final dir in _GoalDirection.values) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-goal-${dir.name}'),
            selected: value == dir,
            onTap: () => onChanged(dir),
            title: items[dir]!.$1,
            subtitle: items[dir]!.$2,
            leadingIcon: items[dir]!.$3,
          ),
          if (dir != _GoalDirection.values.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _DietPicker extends StatelessWidget {
  const _DietPicker({required this.value, required this.onChanged});

  final DietPreference value;
  final ValueChanged<DietPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const icons = {
      DietPreference.none: Icons.restaurant_rounded,
      DietPreference.vegetarian: Icons.spa_rounded,
      DietPreference.vegan: Icons.eco_rounded,
      DietPreference.pescetarian: Icons.set_meal_rounded,
    };
    return Column(
      children: [
        for (final diet in DietPreference.values) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-diet-${diet.name}'),
            selected: value == diet,
            onTap: () => onChanged(diet),
            title: diet.label(l10n),
            subtitle: diet.description(l10n),
            leadingIcon: icons[diet],
          ),
          if (diet != DietPreference.values.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _PacePicker extends StatelessWidget {
  const _PacePicker({
    required this.options,
    required this.value,
    required this.outcomeFor,
    required this.onChanged,
  });

  final List<WeightGoal> options;
  final WeightGoal value;

  /// Subtitle of an option: the plan it yields with the answers so far. See
  /// `_OnboardingScreenState._tempoFolge`.
  final String Function(WeightGoal) outcomeFor;

  final ValueChanged<WeightGoal> onChanged;

  static String? _paceName(AppLocalizations l10n, WeightGoal goal) =>
      switch (goal) {
        WeightGoal.lose025kg => l10n.onboardingPaceNameSanft,
        WeightGoal.lose05kg => l10n.onboardingPaceNameModerat,
        WeightGoal.lose075kg => l10n.onboardingPaceNameZuegig,
        WeightGoal.lose1kg => l10n.onboardingPaceNameAmbitioniert,
        WeightGoal.gain025kg => l10n.onboardingPaceNameSanft,
        WeightGoal.gain05kg => l10n.onboardingPaceNameAmbitioniert,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        for (final goal in options) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-pace-${goal.name}'),
            selected: value == goal,
            onTap: () => onChanged(goal),
            title: l10n.onboardingPaceOptionTitle(
              _paceName(l10n, goal) ?? l10n.onboardingPaceNameFallback,
              goal.paceLabel(l10n),
            ),
            subtitle: outcomeFor(goal),
          ),
          if (goal != options.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Number picker (big value + slider + steppers)
// ---------------------------------------------------------------------------

class _NumberPicker extends StatelessWidget {
  const _NumberPicker({
    required this.field,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.footnote,
  });

  final String field;
  final int value;
  final int min;
  final int max;
  final String unit;
  final ValueChanged<int> onChanged;
  final String? footnote;

  // Defensive against inverted windows (e.g. "lose" at the weight minimum):
  // clamp and Slider assert lower <= upper.
  int get _hi => max < min ? min : max;

  void _set(int v) => onChanged(v.clamp(min, _hi).toInt());

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final safeValue = value.clamp(min, _hi).toInt();
    String spoken(double v) => '${v.round()} $unit';
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              keyValue: ValueKey('onboarding-$field-dec'),
              icon: Icons.remove_rounded,
              semanticLabel: l10n.onboardingStepDownSemanticLabel,
              onTap: () => _set(safeValue - 1),
            ),
            const SizedBox(width: 20),
            // Not a fixed width: at textScaler 2.0 the 52 pt digits exceed
            // 150 px. The column takes the remaining space; only the hero
            // number may shrink (F8-09), the unit scales like any label.
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$safeValue',
                      key: ValueKey('onboarding-$field-value'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: AppType.display(52, color: t.ink, height: 1),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    unit,
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      13,
                      weight: FontWeight.w600,
                      color: t.ink2,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            _StepButton(
              keyValue: ValueKey('onboarding-$field-inc'),
              icon: Icons.add_rounded,
              semanticLabel: l10n.onboardingStepUpSemanticLabel,
              onTap: () => _set(safeValue + 1),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_hi > min)
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: t.accent,
              inactiveTrackColor: t.tile,
              thumbColor: t.accent,
              overlayColor: t.accent.withValues(alpha: 0.15),
              trackHeight: 5,
            ),
            child: Slider(
              key: ValueKey('onboarding-$field-slider'),
              value: safeValue.toDouble(),
              min: min.toDouble(),
              max: _hi.toDouble(),
              // A screen reader hears "75 kg", not a percentage.
              label: spoken(safeValue.toDouble()),
              semanticFormatterCallback: spoken,
              onChanged: (v) => _set(v.round()),
            ),
          ),
        if (footnote != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: t.lime,
              borderRadius: BorderRadius.circular(rPill),
            ),
            child: Text(
              footnote!,
              textAlign: TextAlign.center,
              style: AppType.display(
                13,
                weight: FontWeight.w700,
                color: t.onLime,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.keyValue,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final Key keyValue;
  final IconData icon;

  /// Spoken name — the glyph alone says nothing to a screen reader.
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        key: keyValue,
        onTap: onTap,
        borderRadius: BorderRadius.circular(rPill),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: t.surf,
            shape: BoxShape.circle,
            border: Border.all(color: t.line),
          ),
          child: Icon(icon, color: t.ink, size: 24),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable selectable cards
// ---------------------------------------------------------------------------

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.keyValue,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final Key keyValue;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // One node per card: button + selected, label from the child text.
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          key: keyValue,
          onTap: onTap,
          borderRadius: BorderRadius.circular(rCard),
          child: AnimatedContainer(
            duration:
                motionDuration(context, const Duration(milliseconds: 160)),
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
            decoration: BoxDecoration(
              // Selected means a full fill, not a tinted border, so the
              // selection reads through contrast rather than hue — and the
              // fill is [SelectionTone], not `forest`: in dark mode `forest`
              // is itself a surface and the card sat at 1.33:1 on `surf`.
              color: selected ? t.selectedFill : t.surf,
              borderRadius: BorderRadius.circular(rCard),
              border: Border.all(
                color: selected ? t.selectedFill : t.line,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.keyValue,
    required this.selected,
    required this.onTap,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.leadingIcon,
  });

  final Key keyValue;
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String subtitle;
  final String? trailing;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // One node per row: button + selected, label from title and subtitle.
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        // [SelectionTone] — same language as [_TileCard] and every chip in
        // the app. See there for why `forest` had to go.
        decoration: BoxDecoration(
          color: selected ? t.selectedFill : t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: selected ? t.selectedFill : t.line),
        ),
        child: Row(
          children: [
            if (leadingIcon != null) ...[
              Icon(
                leadingIcon,
                size: 22,
                color: selected ? t.onSelected : t.ink2,
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w700,
                      color: selected ? t.onSelected : t.ink,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w500,
                      color: selected
                          ? t.onSelected.withValues(alpha: 0.78)
                          : t.ink2,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              Text(
                trailing!,
                style: AppType.display(
                  13,
                  weight: FontWeight.w700,
                  color: selected ? t.onSelected : t.ink2,
                ),
              ),
            ],
            if (selected) ...[
              const SizedBox(width: 10),
              // The tick is the second state channel next to the fill, so it
              // has to READ on that fill: `lime` on `ink` is 1.07:1 in dark
              // mode, [SelectionTone.onSelected] is 16.35:1.
              Icon(Icons.check_circle_rounded, color: t.onSelected, size: 20),
            ],
          ],
        ),
      ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

class _SummaryStep extends StatelessWidget {
  const _SummaryStep({
    required this.firstName,
    required this.targets,
    required this.profile,
  });

  final String firstName;
  final KcalTargets targets;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // [targets] was computed from exactly this profile — pass it through
    // instead of running `calculate` a second time.
    final weeks =
        const KcalCalculator().weeksToGoalRange(profile, targets: targets);
    final goal = profile.weightGoal;

    // `weeks == null` means there is no honest forecast (target reached, rate
    // in the rounding noise, or the floor flips the direction). Better no
    // number than an invented one; the why sits in [KcalTargets.paceWarning].
    //
    // Since the 2026-08-21 calorie review this is a RANGE: linear
    // (optimistic) to dynamic (requirement drops with every kilo). Without a
    // dynamic upper bound the deficit never reaches the target, and the text
    // says "at the earliest".
    final timeline = switch (goal) {
      WeightGoal.maintain =>
        l10n.onboardingTimelineMaintain(profile.weightKg),
      _ when weeks != null => timelineEstimateText(
          l10n,
          targetWeightKg: profile.targetWeightKg,
          weeks: weeks,
        ),
      _ => l10n.onboardingTimelineUnknown,
    };

    final t = context.t;
    // Computed once: effectivePaceLabel/paceWarning must yield the same string
    // in the text AND in the visibility check (B2).
    final paceWarning = targets.paceWarning(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.onboardingSummaryTitle(firstName),
          style: AppType.display(28, color: t.ink, height: 1.08),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.onboardingSummarySubtitle,
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        // Hero kcal card
        Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.forest,
            borderRadius: BorderRadius.circular(rHero),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: DotGridBackground(
                  color: t.onForest.withValues(alpha: 0.07),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
                child: Column(
                  children: [
                    Text(
                      l10n.onboardingSummaryKcalEyebrow,
                      textAlign: TextAlign.center,
                      style: AppType.eyebrow(
                        t.onForest.withValues(alpha: 0.70),
                        size: 11,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            '${targets.kcal}',
                            key: const ValueKey('onboarding-summary-kcal'),
                            maxLines: 1,
                            style:
                                AppType.display(52, color: t.lime, height: 1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: Text(
                            l10n.commonKcalUnit,
                            style: AppType.ui(
                              16,
                              weight: FontWeight.w700,
                              color: t.onForest.withValues(alpha: 0.70),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Macros on the page background, not on forest: t.protein would have
        // no readable contrast there in light mode.
        Row(
          children: [
            _MacroChip(
              label: l10n.todayMacroProtein,
              value: '${targets.proteinG} ${l10n.commonUnitG}',
              color: t.protein,
            ),
            const SizedBox(width: 12),
            _MacroChip(
              label: l10n.foodMacroTileCarbsLabel,
              value: '${targets.carbsG} ${l10n.commonUnitG}',
              color: t.carbs,
            ),
            const SizedBox(width: 12),
            _MacroChip(
              label: l10n.todayMacroFat,
              value: '${targets.fatG} ${l10n.commonUnitG}',
              color: t.fat,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Breakdown
        AppCard(
          padding: const EdgeInsets.all(16),
          radius: rCard,
          child: Column(
            children: [
              _BreakdownRow(
                label: l10n.onboardingSummaryBmrLabel,
                value: '${targets.bmr} ${l10n.commonKcalUnit}',
              ),
              const _BreakdownDivider(),
              _BreakdownRow(
                label: l10n.onboardingSummaryMaintenanceLabel(
                  profile.activityLevel.label(l10n),
                ),
                value: '${targets.maintenanceKcal} ${l10n.commonKcalUnit}',
                valueKey: const ValueKey('onboarding-summary-maintenance'),
              ),
              const _BreakdownDivider(),
              // B2: this shows the PLAN, not the wish. `goal.paceLabel` /
              // `goal.deltaLabel` keep promising the requested rate even after
              // the safety floor or the 1 % cap changed it. With the effective
              // rate the card also adds up: maintenance - target = delta.
              _BreakdownRow(
                key: const ValueKey('onboarding-summary-goal-row'),
                label: l10n.onboardingSummaryGoalLabel(
                  targets.effectivePaceLabel(l10n),
                ),
                value: _signedKcalLabel(targets.effectiveKcalDelta),
                highlight: targets.effectiveKcalDelta != 0,
              ),
            ],
          ),
        ),
        // Visible notice when daily target and chosen pace diverge, otherwise
        // the contradiction stays unexplained.
        if (paceWarning != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(rCard),
              border: Border.all(color: t.warning.withValues(alpha: 0.30)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.info_outline_rounded,
                    color: t.warning,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    paceWarning,
                    key: const ValueKey('onboarding-summary-pace-warning'),
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: t.ink,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.timeline_rounded, color: t.accent, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                timeline,
                key: const ValueKey('onboarding-summary-timeline'),
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w600,
                  color: t.ink,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          l10n.onboardingSummaryFootnote,
          style: AppType.ui(
            12,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({required this.label, required this.value, required this.color});

  final String label;
  final String value;

  /// Macro tone for the MARKER only, never for the number: on `surf` in light
  /// mode `carbs` reaches 3.39:1 and `fat` 3.73:1 — enough for a graphical
  /// object (WCAG 1.4.11, 3:1), short of text (4.5:1). Same rule as
  /// `trends_screen`: coloured dot, text in text tokens.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Expanded(
      child: AppCard(
        radius: rCard,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
        child: Column(
          children: [
            // Above the number, not beside it: three tiles share a phone width
            // and a leading dot would eat the number's own line at 200 % font.
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(height: 8),
            // No FittedBox (F8-09): the texts scale with the system font and
            // wrap inside the tile instead of shrinking back to 16/12 px.
            Text(
              value,
              maxLines: 2,
              textAlign: TextAlign.center,
              style:
                  AppType.display(16, weight: FontWeight.w700, color: t.ink),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Signed kcal label for a COMPUTED difference, e.g. "−797 kcal" / "±0".
///
/// Counterpart to [WeightGoalInfo.deltaLabel] but for
/// [KcalTargets.effectiveKcalDelta]; same notation including the real minus
/// sign (U+2212), so the card mixes no glyphs.
String _signedKcalLabel(int kcal) {
  if (kcal == 0) return '±0';
  final sign = kcal > 0 ? '+' : '−';
  return '$sign${kcal.abs()} kcal';
}

/// One row of the breakdown.
///
/// EXACTLY two [Text] children — `onboarding_screen_test` reads the goal row's
/// texts as a list and compares them literally.
class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.highlight = false,
  });

  final String label;
  final String value;
  final Key? valueKey;

  /// Lifts the number into the brand accent. Colour no longer encodes
  /// deficit vs. surplus — the sign in the text carries the direction.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: AppType.ui(13, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
        // Flexible, not Expanded: the value is always short, so it takes only
        // what it needs and the label column keeps the rest.
        Flexible(
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              style: AppType.display(
                13.5,
                weight: FontWeight.w700,
                color: highlight ? t.accent : t.ink,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BreakdownDivider extends StatelessWidget {
  const _BreakdownDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1, color: context.t.line),
    );
  }
}
