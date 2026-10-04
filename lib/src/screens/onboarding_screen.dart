import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/model_limits.dart';
import '../models/user_profile.dart';
import '../services/kcal_calculator.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/motion.dart';
import '../widgets/common/persistence_action.dart';
import '../widgets/design/design.dart';
import 'onboarding/onboarding_chrome.dart';
import 'onboarding/onboarding_models.dart';
import 'onboarding/onboarding_plan_step.dart';
import 'onboarding/onboarding_question_steps.dart';

/// Mandatory onboarding: asks for the goal, body data and activity, and
/// computes the daily target (Mifflin-St Jeor BMR x activity PAL +- goal
/// delta). Runs once per user; [UserProfile.onboardingCompleted] then closes
/// the gate. Which questions it asks, in which order and why:
/// docs/ONBOARDING-2026-10-04.md.
///
/// Flow: goal -> about you -> body -> activity -> target* -> pace* -> diet
/// (optional) -> plan. *Only for a direction with a reachable target.
///
/// No text inputs on purpose: steppers and sliders are faster on a phone and
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
/// `_targetWindow` — a consistency bound, not a range, so it cannot drift.
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
  final PersistValueChanged<UserProfile> onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// A target nobody chose yet sits this far from today's weight.
const int _kDefaultTargetDistanceKg = 5;

/// A step change: fade plus a short slide in the direction of travel.
const Duration _kStepTransition = Duration(milliseconds: 280);

/// How far (in step widths) a step slides while it fades.
const double _kStepSlide = 0.06;

/// Height of the fades at the top and bottom edge of a step's scroll view.
const double _kEdgeFade = 16;

class _OnboardingScreenState extends State<OnboardingScreen> {
  late BiologicalSex _sex;
  late int _age;
  late int _height;
  late int _weight;
  late ActivityLevel _activity;
  late OnboardingDirection _direction;
  late DietPreference _diet;

  /// Target weights the user chose (or the profile brought), per direction.
  ///
  /// A direction without an entry follows today's weight, see [_targetSafe].
  /// The goal is asked before the weight, so a default fixed at that moment
  /// would describe the weight the screen started with, not the user's.
  final _chosenTargets = <OnboardingDirection, int>{};

  // Separate pace per direction, so switching back and forth loses nothing.
  WeightGoal _losePace = WeightGoal.lose05kg;
  WeightGoal _gainPace = WeightGoal.gain025kg;

  OnboardingStep _step = OnboardingStep.goal;

  /// Where a plan edit started; null outside one. Editing the goal walks its
  /// follow-up questions (target, pace) before the plan, every other edit
  /// returns after one question.
  OnboardingStep? _editOrigin;

  /// Direction of the last move, for the step transition.
  bool _forward = true;

  /// The daily target the plan showed last; its next reveal counts from it.
  int? _shownKcal;

  bool _saving = false;

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
    _direction = onboardingDirectionOf(p.weightGoal);
    if (p.weightGoal.isLoss) _losePace = p.weightGoal;
    if (p.weightGoal.isGain) _gainPace = p.weightGoal;
    // A stored target counts as chosen only while it still means the stored
    // direction. A target on the wrong side (the model default: 78 kg "to
    // lose" at 78 kg) used to open the step on the window edge — 77 kg, one
    // kilo, a plan nobody picked.
    final storedTarget = clampProfileTargetWeightKg(p.targetWeightKg);
    if (_direction != OnboardingDirection.maintain &&
        isConsistentTargetWeight(p.weightGoal, _weight, storedTarget)) {
      _chosenTargets[_direction] = storedTarget;
    }
    _diet = p.diet;
  }

  WeightGoal get _weightGoal => switch (_direction) {
    OnboardingDirection.maintain => WeightGoal.maintain,
    OnboardingDirection.lose => _losePace,
    OnboardingDirection.gain => _gainPace,
  };

  /// The target weights the chosen direction leaves open (lose -> below today's
  /// weight, gain -> above), or `null` when it leaves none.
  ///
  /// ONE window, read by everything: picker bounds, the number, the footnote,
  /// the BMI hint, the plan and whether the target step exists. TWO clamps
  /// with different rules were the actual defect (J1) — a picker that folded
  /// an inverted window up onto its own `min` drew 301 above a footnote
  /// reading "0 kg", and every button was dead.
  ///
  /// The rule itself lives in `user_profile.dart` — the goals page enforces the
  /// same one on typed input, and two copies drift (P9-08b).
  ///
  /// `null` is an EMPTY window, not an error: gaining at the 300 kg end of the
  /// column (min 301 > max 300) and losing at the 30 kg one (min 30 > max 29)
  /// leave no weight that still means the direction.
  ({int min, int max})? get _targetWindow {
    final min = targetWeightMinFor(_weightGoal, _weight);
    final max = targetWeightMaxFor(_weightGoal, _weight);
    return min > max ? null : (min: min, max: max);
  }

  /// The target weight in play: the chosen one (else today's weight moved
  /// [_kDefaultTargetDistanceKg] along the direction), narrowed to
  /// [_targetWindow]. The ONE number the target step and the plan may show.
  ///
  /// Narrowed, never written back: a chosen 70 kg shows as 59 while the
  /// weight reads 60, and comes back as 70 once the weight does (P9-07b).
  ///
  /// With an empty window today's weight is the only value left; the target
  /// step is skipped there and the plan reads as maintain through
  /// [UserProfileWeightPlan.effectiveWeightGoal], which is what it is.
  int get _targetSafe {
    final window = _targetWindow;
    if (window == null) return _weight;
    final wanted =
        _chosenTargets[_direction] ??
        (_direction == OnboardingDirection.lose
            ? _weight - _kDefaultTargetDistanceKg
            : _weight + _kDefaultTargetDistanceKg);
    return wanted.clamp(window.min, window.max).toInt();
  }

  /// Target and pace are asked only for a direction with at least one target
  /// weight that still means it; without one there is nothing to pick.
  bool get _asksTarget =>
      _direction != OnboardingDirection.maintain && _targetWindow != null;

  bool _isAsked(OnboardingStep step) => switch (step) {
    OnboardingStep.target || OnboardingStep.pace => _asksTarget,
    _ => true,
  };

  /// The steps of this flow, in order (the enum order).
  List<OnboardingStep> get _steps => <OnboardingStep>[
    for (final step in OnboardingStep.values)
      if (_isAsked(step)) step,
  ];

  /// The questions a plan edit from [_editOrigin] walks, in order.
  List<OnboardingStep> get _editChain {
    final origin = _editOrigin!;
    final chain = origin == OnboardingStep.goal
        ? const <OnboardingStep>[
            OnboardingStep.goal,
            OnboardingStep.target,
            OnboardingStep.pace,
          ]
        : <OnboardingStep>[origin];
    return <OnboardingStep>[
      for (final step in chain)
        if (_isAsked(step)) step,
    ];
  }

  /// The step Next leads to.
  OnboardingStep get _nextStep {
    if (_editOrigin != null) {
      final chain = _editChain;
      final i = chain.indexOf(_step);
      return i >= 0 && i + 1 < chain.length
          ? chain[i + 1]
          : OnboardingStep.summary;
    }
    return OnboardingStep.values.firstWhere(
      (step) => step.index > _step.index && _isAsked(step),
      orElse: () => OnboardingStep.summary,
    );
  }

  /// The step Back leads to, null on the first step.
  OnboardingStep? get _previousStep {
    if (_editOrigin != null) {
      final chain = _editChain;
      final i = chain.indexOf(_step);
      return i > 0 ? chain[i - 1] : OnboardingStep.summary;
    }
    for (final step in OnboardingStep.values.reversed) {
      if (step.index < _step.index && _isAsked(step)) return step;
    }
    return null;
  }

  UserProfile _draftProfile() {
    final target = _direction == OnboardingDirection.maintain
        ? _weight
        : _targetSafe;
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

  /// What [option] actually yields with the answers so far — subtitle of
  /// every pace option (B2).
  ///
  /// Body data and activity precede the pace. Showing the requested delta
  /// instead would lie whenever the safety floor or the 1 % cap changes it —
  /// two pace options could then promise different rates for the same plan.
  /// The title keeps the chosen pace: it is the option's *name*, and two rows
  /// with the same effective rate would be indistinguishable.
  String _paceOutcome(WeightGoal option) {
    final l10n = context.l10n;
    final t = const KcalCalculator().calculate(
      _draftProfile().copyWith(weightGoal: option),
    );
    return l10n.commonKcalOutcomeLabel(t.kcal, t.effectivePaceLabel(l10n));
  }

  void _goTo(OnboardingStep step, {required bool forward}) => setState(() {
    if (_step == OnboardingStep.summary) _shownKcal = _targets.kcal;
    if (step == OnboardingStep.summary) _editOrigin = null;
    _forward = forward;
    _step = step;
  });

  void _next() {
    if (_saving) return;
    if (_step == OnboardingStep.summary) {
      _finish();
      return;
    }
    _goTo(_nextStep, forward: true);
  }

  void _back() {
    if (_saving) return;
    final previous = _previousStep;
    if (previous == null) return;
    _goTo(previous, forward: false);
  }

  void _edit(OnboardingStep step) {
    if (_saving) return;
    setState(() {
      _shownKcal = _targets.kcal;
      _editOrigin = step;
      _forward = true;
      _step = step;
    });
  }

  /// Android system back (button or edge gesture) — must do what the header
  /// arrow does (D4).
  ///
  /// [OnboardingScreen] is the root route, so without this handler the engine
  /// falls back to `SystemNavigator.pop()` and kills the activity, losing
  /// every answer given so far (only `_finish()` persists anything).
  ///
  /// Later steps step back; plan edits return to the plan. The first step
  /// releases system Back, preserving the existing root-route behavior.
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop || _saving) return;
    _back();
  }

  Future<void> _finish() async {
    if (_saving) return;
    final t = _targets;
    final finished = _draftProfile().copyWith(
      dailyKcalGoal: t.kcal,
      proteinGoalG: t.proteinG,
      carbsGoalG: t.carbsG,
      fatGoalG: t.fatG,
      onboardingCompleted: true,
    );
    setState(() => _saving = true);
    await tryPersistChange(context, () => widget.onComplete(finished));
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) =>
      CommitDismissGuard(pending: _saving, child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final steps = _steps;
    final index = steps.indexOf(_step).clamp(0, steps.length - 1);
    final atStart = _step == steps.first && _editOrigin == null;
    return PopScope<Object?>(
      canPop: atStart,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        key: const ValueKey('screen-onboarding'),
        backgroundColor: t.bg,
        body: SafeArea(
          child: ReadableWidth(
            maxWidth: 560,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OnboardingHeader(
                    index: index,
                    count: steps.length,
                    phaseLabel: _step.phaseLabel(l10n),
                    onBack: atStart ? null : _back,
                  ),
                  const SizedBox(height: 6),
                  Expanded(child: _stepSwitcher(context)),
                  const SizedBox(height: 4),
                  PrimaryActionButton(
                    key: ValueKey(
                      _step == OnboardingStep.summary
                          ? 'onboarding-finish'
                          : 'onboarding-next',
                    ),
                    label: _ctaLabel(l10n),
                    onTap: _saving ? null : _next,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _ctaLabel(AppLocalizations l10n) {
    if (_step == OnboardingStep.summary) return l10n.onboardingActivatePlanCta;
    if (_editOrigin != null && _nextStep == OnboardingStep.summary) {
      return l10n.onboardingReviewChanges;
    }
    if (_step == OnboardingStep.diet && _diet == DietPreference.none) {
      return l10n.onboardingWithoutPreference;
    }
    return l10n.onboardingNextCta;
  }

  /// The current step in its own scroll view; a step change fades and slides
  /// in the direction of travel. Reduced motion swaps without a transition.
  ///
  /// Content scrolling under the header or toward the button fades out over
  /// [_kEdgeFade] instead of being cut mid-glyph; the scroll padding keeps
  /// the resting content clear of both fades.
  Widget _stepSwitcher(BuildContext context) {
    final t = context.t;
    final currentKey = ValueKey('onboarding-step-${_step.name}');
    final travel = _forward ? 1.0 : -1.0;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final edge = bounds.height <= 0
            ? 0.0
            : (_kEdgeFade / bounds.height).clamp(0.0, 0.5);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Only the alpha matters for dstIn; any opaque token works.
          colors: <Color>[
            t.bg.withValues(alpha: 0),
            t.bg,
            t.bg,
            t.bg.withValues(alpha: 0),
          ],
          stops: <double>[0, edge, 1 - edge, 1],
        ).createShader(bounds);
      },
      child: _switcher(context, currentKey, travel),
    );
  }

  Widget _switcher(BuildContext context, Key currentKey, double travel) {
    return AnimatedSwitcher(
      duration: motionDuration(context, _kStepTransition),
      switchInCurve: kMotionCurve,
      switchOutCurve: kMotionCurve,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: <Widget>[...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final incoming = child.key == currentKey;
        // The leaving step slides the other way and no longer takes taps
        // or focus while it fades.
        final from = Offset((incoming ? 1 : -1) * travel * _kStepSlide, 0);
        return IgnorePointer(
          ignoring: !incoming,
          child: ExcludeSemantics(
            excluding: !incoming,
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: from,
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
          ),
        );
      },
      child: SingleChildScrollView(
        key: currentKey,
        padding: const EdgeInsets.only(top: _kEdgeFade, bottom: _kEdgeFade + 8),
        child: _buildStep(context),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    final l10n = context.l10n;
    return switch (_step) {
      OnboardingStep.goal => OnboardingGoalStep(
        firstName: widget.firstName,
        value: _direction,
        onChanged: (direction) => setState(() => _direction = direction),
      ),
      OnboardingStep.basics => OnboardingBasicsStep(
        sex: _sex,
        onSex: (sex) => setState(() => _sex = sex),
        age: _age,
        onAge: (age) => setState(() => _age = age),
      ),
      OnboardingStep.body => OnboardingBodyStep(
        height: _height,
        onHeight: (height) => setState(() => _height = height),
        weight: _weight,
        // Chosen targets stay raw so backtracking never loses an answer.
        onWeight: (weight) => setState(() => _weight = weight),
      ),
      OnboardingStep.activity => OnboardingActivityStep(
        value: _activity,
        onChanged: (level) => setState(() => _activity = level),
      ),
      OnboardingStep.target => _buildTargetStep(),
      OnboardingStep.pace => OnboardingPaceStep(
        direction: _direction,
        value: _weightGoal,
        outcomeFor: _paceOutcome,
        forecast: onboardingTimelineText(l10n, _draftProfile(), _targets),
        onChanged: (pace) => setState(() {
          if (pace.isLoss) _losePace = pace;
          if (pace.isGain) _gainPace = pace;
        }),
      ),
      OnboardingStep.diet => OnboardingDietStep(
        value: _diet,
        onChanged: (diet) => setState(() => _diet = diet),
      ),
      OnboardingStep.summary => _buildPlanStep(context),
    };
  }

  /// Built only while [_asksTarget] holds, so the window is never empty here.
  Widget _buildTargetStep() {
    final window = _targetWindow;
    if (window == null) return const SizedBox.shrink();
    return OnboardingTargetStep(
      direction: _direction,
      weight: _weight,
      height: _height,
      target: _targetSafe,
      min: window.min,
      max: window.max,
      onChanged: (target) => setState(() => _chosenTargets[_direction] = target),
    );
  }

  Widget _buildPlanStep(BuildContext context) {
    final l10n = context.l10n;
    final profile = _draftProfile();
    final targets = const KcalCalculator().calculate(profile);
    final kg = l10n.commonUnitKg;
    final pace = _weightGoal;
    return OnboardingPlanStep(
      firstName: widget.firstName,
      profile: profile,
      targets: targets,
      // The first reveal counts from maintenance, so a deficit or surplus is
      // seen; after an edit it counts from the number shown before.
      countFrom: _shownKcal ?? targets.maintenanceKcal,
      answers: <OnboardingReviewItem>[
        OnboardingReviewItem(
          OnboardingStep.goal,
          l10n.onboardingPhaseGoal,
          profile.effectiveWeightGoal.label(l10n),
        ),
        OnboardingReviewItem(
          OnboardingStep.basics,
          l10n.onboardingPhaseBasics,
          '${onboardingSexLabel(l10n, profile.sex)} · '
              '${profile.ageYears} ${l10n.onboardingUnitYears}',
        ),
        OnboardingReviewItem(
          OnboardingStep.body,
          l10n.onboardingPhaseBody,
          '${profile.heightCm} ${l10n.commonUnitCm} · ${profile.weightKg} $kg',
        ),
        OnboardingReviewItem(
          OnboardingStep.activity,
          l10n.onboardingPhaseActivity,
          profile.activityLevel.label(l10n),
        ),
        if (_asksTarget) ...<OnboardingReviewItem>[
          OnboardingReviewItem(
            OnboardingStep.target,
            l10n.onboardingReviewTarget,
            '${profile.targetWeightKg} $kg',
          ),
          OnboardingReviewItem(
            OnboardingStep.pace,
            l10n.onboardingReviewPace,
            l10n.onboardingPaceOptionTitle(
              onboardingPaceName(l10n, pace),
              pace.paceLabel(l10n),
            ),
          ),
        ],
        OnboardingReviewItem(
          OnboardingStep.diet,
          l10n.onboardingPhaseDiet,
          profile.diet.label(l10n),
        ),
      ],
      onEdit: _edit,
    );
  }
}
