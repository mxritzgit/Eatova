import 'package:flutter/material.dart';

import '../models/user_profile.dart';
import '../services/kcal_calculator.dart';
import '../theme/app_colors.dart';
import '../widgets/shared/target_bmi_hint.dart';

/// Verpflichtendes Onboarding: erhebt Körperdaten, Aktivität und Ziel und
/// berechnet daraus ein genaues Tagesziel (Mifflin-St Jeor BMR × Aktivitäts-PAL
/// ± Ziel-Delta). Läuft genau einmal pro User — danach setzt
/// [UserProfile.onboardingCompleted] das Gate auf erledigt.
///
/// Bewusst ohne Texteingaben: Slider + Stepper sind auf dem Phone schneller,
/// vermeiden Tastatur-Sprünge und liefern immer Werte innerhalb der
/// DB-Constraints (weight 30–300, height 100–250, age 16–100).
/// Mindestalter 16: Einwilligungsfähigkeit nach Art. 8 DSGVO bei
/// Gesundheitsdaten (Art. 9) — konsistent mit PRIVACY.md und DB-Constraint.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.firstName,
    required this.initialProfile,
    required this.onComplete,
  });

  final String firstName;
  final UserProfile initialProfile;

  /// Bekommt das fertige Profil inkl. berechnetem Tagesziel und
  /// onboardingCompleted = true. Der Aufrufer persistiert + verlässt das Gate.
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
  // Getrennte Tempo-Auswahl je Richtung, damit Hin-/Herwechseln nichts verliert.
  WeightGoal _losePace = WeightGoal.lose05kg;
  WeightGoal _gainPace = WeightGoal.gain025kg;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile;
    _sex = p.sex;
    _age = p.ageYears.clamp(16, 99).toInt();
    _height = p.heightCm.clamp(120, 220).toInt();
    _weight = p.weightKg.clamp(40, 200).toInt();
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
    _target = p.targetWeightKg.clamp(40, 200).toInt();
    _diet = p.diet;
  }

  /// Sichtbare Schritte — Zielgewicht und Tempo entfallen bei „halten".
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

  /// Wunschgewicht passend zur Richtung begrenzen, damit es nie der aktuellen
  /// Richtung widerspricht (Abnehmen → unter, Zunehmen → über).
  int get _targetMin => _direction == _GoalDirection.gain ? _weight + 1 : 40;
  int get _targetMax => _direction == _GoalDirection.lose ? _weight - 1 : 200;

  /// clamp ohne Assert-Crash bei invertierten Grenzen (Gewicht am Extrem).
  static int _safeClamp(int v, int lo, int hi) =>
      hi < lo ? lo : v.clamp(lo, hi).toInt();

  UserProfile _draftProfile() {
    final target = _direction == _GoalDirection.maintain
        ? _weight
        : _safeClamp(_target, _targetMin, _targetMax);
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

  void _onDirectionChosen(_GoalDirection dir) {
    setState(() {
      _direction = dir;
      // Sinnvolles Default-Wunschgewicht je Richtung setzen.
      if (dir == _GoalDirection.lose) {
        _target = _safeClamp(_weight - 5, 40, _weight - 1);
      } else if (dir == _GoalDirection.gain) {
        _target = _safeClamp(_weight + 5, _weight + 1, 200);
      } else {
        _target = _weight;
      }
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
    final step = _steps[_index];
    final progress = (_index + 1) / _steps.length;
    final isSummary = step == _Step.summary;

    return Scaffold(
      key: const ValueKey('screen-onboarding'),
      backgroundColor: bg,
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
                  duration: const Duration(milliseconds: 240),
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
              _PrimaryButton(
                keyValue: ValueKey(isSummary ? 'onboarding-finish' : 'onboarding-next'),
                label: switch (step) {
                  _Step.intro => 'Los geht\'s',
                  _Step.summary => 'Plan aktivieren',
                  _ => 'Weiter',
                },
                onTap: _next,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(_Step step) {
    return switch (step) {
      _Step.intro => _IntroStep(firstName: widget.firstName),
      _Step.sex => _StepFrame(
          title: 'Dein Geschlecht',
          subtitle: 'Beeinflusst deinen Grundumsatz.',
          child: _SexPicker(
            value: _sex,
            onChanged: (v) => setState(() => _sex = v),
          ),
        ),
      _Step.age => _StepFrame(
          title: 'Wie alt bist du?',
          subtitle: 'Der Energiebedarf sinkt mit dem Alter.',
          child: _NumberPicker(
            field: 'age',
            value: _age,
            min: 16,
            max: 99,
            unit: 'Jahre',
            onChanged: (v) => setState(() => _age = v),
          ),
        ),
      _Step.height => _StepFrame(
          title: 'Deine Größe',
          subtitle: 'Für die Bedarfs- und Schrittberechnung.',
          child: _NumberPicker(
            field: 'height',
            value: _height,
            min: 120,
            max: 220,
            unit: 'cm',
            onChanged: (v) => setState(() => _height = v),
          ),
        ),
      _Step.weight => _StepFrame(
          title: 'Dein aktuelles Gewicht',
          subtitle: 'Startpunkt für deinen Plan.',
          child: _NumberPicker(
            field: 'weight',
            value: _weight,
            min: 40,
            max: 200,
            unit: 'kg',
            onChanged: (v) => setState(() => _weight = v),
          ),
        ),
      _Step.activity => _StepFrame(
          title: 'Wie aktiv bist du?',
          subtitle: 'Dein Alltag ohne gezähltes Training.',
          child: _ActivityPicker(
            value: _activity,
            onChanged: (v) => setState(() => _activity = v),
          ),
        ),
      _Step.goal => _StepFrame(
          title: 'Was ist dein Ziel?',
          subtitle: 'Bestimmt deine tägliche Kalorienmenge.',
          child: _GoalPicker(
            value: _direction,
            onChanged: _onDirectionChosen,
          ),
        ),
      _Step.target => _StepFrame(
          title: 'Dein Wunschgewicht',
          subtitle: _direction == _GoalDirection.lose
              ? 'Wohin willst du abnehmen?'
              : 'Wohin willst du aufbauen?',
          child: Column(
            children: [
              _NumberPicker(
                field: 'target',
                value: _target,
                min: _targetMin,
                max: _targetMax,
                unit: 'kg',
                onChanged: (v) => setState(() => _target = v),
                footnote: '${(_weight - _target).abs()} kg '
                    '${_direction == _GoalDirection.lose ? 'abnehmen' : 'zunehmen'}',
              ),
              // Sanfter, nicht blockierender BMI-Hinweis — gleiche Grenze wie
              // im Settings-Sheet (unter 18,5 / über 35).
              TargetBmiHint(
                margin: const EdgeInsets.only(top: 16),
                heightCm: _height,
                targetWeightKg: _safeClamp(_target, _targetMin, _targetMax),
              ),
            ],
          ),
        ),
      _Step.pace => _StepFrame(
          title: 'Welches Tempo?',
          subtitle: _direction == _GoalDirection.lose
              ? 'Wie schnell willst du abnehmen?'
              : 'Wie schnell willst du aufbauen?',
          child: _PacePicker(
            options: _direction == _GoalDirection.lose
                ? lossPaceGoals
                : gainPaceGoals,
            value: _direction == _GoalDirection.lose ? _losePace : _gainPace,
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
          title: 'Ernährungsweise?',
          subtitle: 'Wir empfehlen dir passende Rezepte. '
              'Durchsuchen kannst du immer alle.',
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
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: showBack
              ? IconButton(
                  key: const ValueKey('onboarding-back'),
                  onPressed: onBack,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_back_rounded, size: 22),
                  color: textMuted,
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(rPill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: surfaceSoft,
              valueColor: const AlwaysStoppedAnimation<Color>(lime),
            ),
          ),
        ),
        const SizedBox(width: 46),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.keyValue,
    required this.label,
    required this.onTap,
  });

  final Key keyValue;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        key: keyValue,
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: lime,
          foregroundColor: bg,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rCard),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            color: textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w500,
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
  const _IntroStep({required this.firstName});

  final String firstName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: lime.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(rSheet),
            border: Border.all(color: lime.withValues(alpha: 0.28)),
          ),
          child: const Icon(Icons.flag_rounded, color: lime, size: 30),
        ),
        const SizedBox(height: 28),
        Text(
          'Willkommen, $firstName.',
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'In 6 kurzen Schritten berechnen wir dein persönliches Tagesziel — '
          'genau abgestimmt auf deinen Körper und dein Wunschgewicht.',
          style: TextStyle(
            color: textMuted,
            fontSize: 15,
            height: 1.45,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 32),
        const _IntroBullet(
          icon: Icons.calculate_rounded,
          text: 'Wissenschaftliche Mifflin-St-Jeor-Formel',
        ),
        const SizedBox(height: 14),
        const _IntroBullet(
          icon: Icons.local_fire_department_rounded,
          text: 'Kalorien & Makros automatisch gesetzt',
        ),
        const SizedBox(height: 14),
        const _IntroBullet(
          icon: Icons.tune_rounded,
          text: 'Jederzeit in den Einstellungen anpassbar',
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
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: lime.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(rControl),
          ),
          child: Icon(icon, color: lime, size: 18),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
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
    const labels = {
      BiologicalSex.male: ('Männlich', Icons.male_rounded),
      BiologicalSex.female: ('Weiblich', Icons.female_rounded),
      BiologicalSex.neutral: ('Divers', Icons.person_rounded),
    };
    return Row(
      children: [
        for (final sex in BiologicalSex.values) ...[
          Expanded(
            child: _TileCard(
              keyValue: ValueKey('onboarding-sex-${sex.name}'),
              selected: value == sex,
              onTap: () => onChanged(sex),
              child: Column(
                children: [
                  Icon(
                    labels[sex]!.$2,
                    size: 30,
                    color: value == sex ? lime : textMuted,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    labels[sex]!.$1,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: value == sex ? textPrimary : textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (sex != BiologicalSex.values.last) const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _ActivityPicker extends StatelessWidget {
  const _ActivityPicker({required this.value, required this.onChanged});

  final ActivityLevel value;
  final ValueChanged<ActivityLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final level in ActivityLevel.values) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-activity-${level.name}'),
            selected: value == level,
            onTap: () => onChanged(level),
            title: level.label,
            subtitle: level.description,
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
    const items = {
      _GoalDirection.lose: ('Abnehmen', 'Fett verlieren, Defizit', Icons.trending_down_rounded),
      _GoalDirection.maintain: ('Gewicht halten', 'Form & Energie stabil', Icons.trending_flat_rounded),
      _GoalDirection.gain: ('Zunehmen', 'Muskeln aufbauen, Überschuss', Icons.trending_up_rounded),
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
            title: diet.label,
            subtitle: diet.description,
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
    required this.onChanged,
  });

  final List<WeightGoal> options;
  final WeightGoal value;
  final ValueChanged<WeightGoal> onChanged;

  static const _paceNames = {
    WeightGoal.lose025kg: 'Sanft',
    WeightGoal.lose05kg: 'Moderat',
    WeightGoal.lose075kg: 'Zügig',
    WeightGoal.lose1kg: 'Ambitioniert',
    WeightGoal.gain025kg: 'Sanft',
    WeightGoal.gain05kg: 'Ambitioniert',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final goal in options) ...[
          _RowCard(
            keyValue: ValueKey('onboarding-pace-${goal.name}'),
            selected: value == goal,
            onTap: () => onChanged(goal),
            title: '${_paceNames[goal] ?? 'Tempo'} · ${goal.paceLabel}',
            subtitle: '${goal.deltaLabel} / Tag',
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

  // Defensiv gegen invertierte Fenster (z.B. „abnehmen" am Gewichts-Minimum):
  // clamp und Slider assertieren lower <= upper.
  int get _hi => max < min ? min : max;

  void _set(int v) => onChanged(v.clamp(min, _hi).toInt());

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(min, _hi).toInt();
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              keyValue: ValueKey('onboarding-$field-dec'),
              icon: Icons.remove_rounded,
              onTap: () => _set(safeValue - 1),
            ),
            const SizedBox(width: 20),
            SizedBox(
              width: 150,
              child: Column(
                children: [
                  Text(
                    '$safeValue',
                    key: ValueKey('onboarding-$field-value'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.6,
                      height: 1,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    unit,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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
              onTap: () => _set(safeValue + 1),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_hi > min)
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: lime,
              inactiveTrackColor: surfaceSoft,
              thumbColor: lime,
              overlayColor: lime.withValues(alpha: 0.15),
              trackHeight: 5,
            ),
            child: Slider(
              key: ValueKey('onboarding-$field-slider'),
              value: safeValue.toDouble(),
              min: min.toDouble(),
              max: _hi.toDouble(),
              onChanged: (v) => _set(v.round()),
            ),
          ),
        if (footnote != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: lime.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(rPill),
            ),
            child: Text(
              footnote!,
              style: const TextStyle(
                color: lime,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
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
    required this.onTap,
  });

  final Key keyValue;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rPill),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: surfaceSoft,
          shape: BoxShape.circle,
          border: Border.all(color: hairline),
        ),
        child: Icon(icon, color: textPrimary, size: 24),
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
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? lime.withValues(alpha: 0.12) : surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(
            color: selected ? lime.withValues(alpha: 0.55) : hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: child,
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
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? lime.withValues(alpha: 0.12) : surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(
            color: selected ? lime.withValues(alpha: 0.55) : hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            if (leadingIcon != null) ...[
              Icon(
                leadingIcon,
                size: 22,
                color: selected ? lime : textMuted,
              ),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
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
                style: TextStyle(
                  color: selected ? lime : textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            if (selected) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check_circle_rounded, color: lime, size: 20),
            ],
          ],
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
    final weeks = const KcalCalculator().weeksToGoal(profile);
    final goal = profile.weightGoal;

    final timeline = switch (goal) {
      WeightGoal.maintain => 'Du hältst dein Gewicht von ${profile.weightKg} kg.',
      _ when weeks != null =>
        '${profile.targetWeightKg} kg in ca. $weeks Wochen erreichbar.',
      _ => 'Dein persönliches Tempo ist gesetzt.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dein Plan steht, $firstName.',
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
            height: 1.08,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Das ist dein empfohlenes Tagesziel.',
          style: TextStyle(
            color: textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        // Hero kcal card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [lime.withValues(alpha: 0.18), surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(rSheet),
            border: Border.all(color: lime.withValues(alpha: 0.35)),
          ),
          child: Column(
            children: [
              const Text(
                'TÄGLICHES KALORIENZIEL',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${targets.kcal}',
                    key: const ValueKey('onboarding-summary-kcal'),
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.8,
                      height: 1,
                      color: lime,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 7),
                    child: Text(
                      'kcal',
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Macros
        Row(
          children: [
            _MacroChip(label: 'Protein', value: '${targets.proteinG} g', color: lime),
            const SizedBox(width: 12),
            _MacroChip(label: 'Carbs', value: '${targets.carbsG} g', color: cyan),
            const SizedBox(width: 12),
            _MacroChip(label: 'Fett', value: '${targets.fatG} g', color: orange),
          ],
        ),
        const SizedBox(height: 16),
        // Breakdown
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: hairline),
          ),
          child: Column(
            children: [
              _BreakdownRow(
                label: 'Grundumsatz (BMR)',
                value: '${targets.bmr} kcal',
              ),
              const _BreakdownDivider(),
              _BreakdownRow(
                label: 'Erhaltungsbedarf · ${profile.activityLevel.label}',
                value: '${targets.maintenanceKcal} kcal',
              ),
              const _BreakdownDivider(),
              _BreakdownRow(
                label: 'Ziel · ${goal.paceLabel}',
                value: goal.deltaLabel,
                highlight: goal.kcalDelta != 0,
                positive: goal.kcalDelta > 0,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.timeline_rounded, color: lime, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                timeline,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'Schätzung nach Mifflin-St Jeor. Werte sind jederzeit unter '
          'Profil › Einstellungen anpassbar.',
          style: TextStyle(
            color: textMuted,
            fontSize: 12,
            height: 1.45,
            fontWeight: FontWeight.w500,
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
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    this.highlight = false,
    this.positive = false,
  });

  final String label;
  final String value;
  final bool highlight;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: highlight ? (positive ? orange : lime) : textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
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
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1, color: hairline),
    );
  }
}
