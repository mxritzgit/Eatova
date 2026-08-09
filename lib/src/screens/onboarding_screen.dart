import 'package:flutter/material.dart';

import '../models/model_limits.dart';
import '../models/user_profile.dart';
import '../services/kcal_calculator.dart';
import '../theme/app_tokens.dart';
import '../widgets/common/motion.dart';
import '../widgets/design/design.dart';
import '../widgets/shared/target_bmi_hint.dart';

/// Verpflichtendes Onboarding: erhebt Körperdaten, Aktivität und Ziel und
/// berechnet daraus ein genaues Tagesziel (Mifflin-St Jeor BMR × Aktivitäts-PAL
/// ± Ziel-Delta). Läuft genau einmal pro User — danach setzt
/// [UserProfile.onboardingCompleted] das Gate auf erledigt.
///
/// Bewusst ohne Texteingaben: Slider + Stepper sind auf dem Phone schneller,
/// vermeiden Tastatur-Sprünge und liefern immer Werte innerhalb der
/// DB-Constraints.
///
/// ## Wertebereiche kommen aus [ProfileLimits], nicht aus Literalen
///
/// Bis Welle 6 standen hier `16..99` Jahre, `40..200` kg und `120..220` cm als
/// Zahlen im Code, während `public.profiles` `16..100` / `30..300` /
/// `100..250` erlaubt — und `model_limits.dart` war gar nicht importiert. Zwei
/// getrennte Probleme:
///
/// * **Rechtlich.** Das Mindestalter 16 ist keine UI-Vorliebe, sondern die
///   Einwilligungsfähigkeit nach Art. 8 DSGVO bei Gesundheitsdaten (Art. 9).
///   Es steht mit eigenem Kommentar in [ProfileLimits.ageYearsMin] und wurde
///   mit Migration `20260807090000` bereits einmal verschoben (13 → 16). Eine
///   gespiegelte Kopie, die beim nächsten Mal nicht mitwandert, ist ein
///   Rechtsverstoß mit Ansage.
/// * **Fachlich.** Die engeren Kopien waren keine bewusste Plausibilitäts-
///   grenze, sondern eine stille Klemme in `initState`: wer 210 kg wog oder
///   115 cm groß ist, konnte sein Onboarding gar nicht wahrheitsgemäß
///   ausfüllen — sein Wert wurde beim Start auf 200 bzw. 120 gezogen, obwohl
///   die Datenbank ihn akzeptiert hätte.
///
/// Es bleibt deshalb **keine** numerische Verengung übrig. Enger als die DB
/// wird nur noch das Wunschgewicht, und zwar dynamisch: [_targetMin] /
/// [_targetMax] halten es auf der Seite der gewählten Richtung. Das ist eine
/// Konsistenz-, keine Wertebereichsgrenze und kann nicht driften.
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
    // Geklemmt wird nur noch auf die DB-Grenze selbst: alles andere hätte dem
    // Nutzer beim Start still einen Wert untergeschoben, den er nie angegeben
    // hat (siehe Klassendoku).
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
    _target = p.targetWeightKg
        .clamp(
          ProfileLimits.targetWeightKgMin,
          ProfileLimits.targetWeightKgMax,
        )
        .toInt();
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
  ///
  /// Das ist die einzige verbliebene Verengung gegenüber der DB — und die
  /// einzige, die sich nicht spiegeln lässt, weil sie am aktuellen Gewicht
  /// hängt statt an einer Konstanten.
  int get _targetMin => _direction == _GoalDirection.gain
      ? _weight + 1
      : ProfileLimits.targetWeightKgMin;
  int get _targetMax => _direction == _GoalDirection.lose
      ? _weight - 1
      : ProfileLimits.targetWeightKgMax;

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

  /// Was [option] mit den bereits erhobenen Körperdaten wirklich ergibt —
  /// Untertitel jeder Zeile im Tempo-Schritt.
  ///
  /// **B2.** Der Tempo-Schritt ist Nummer 9 von 11 ([_Step]: intro, sex, age,
  /// height, weight, activity, goal, target, **pace**, diet, summary). Gewicht,
  /// Größe, Alter, Geschlecht und Aktivität stehen hier alle schon fest —
  /// `calculate` braucht nichts weiter, das Ergebnis ist also ohne jeden
  /// Vorbehalt berechenbar. Vorher stand hier `goal.deltaLabel`, also
  /// „−1100 kcal / Tag": für das Standardprofil (78 kg / 178 cm / 30 J. /
  /// neutral / sitzend, Erhaltung 1997) hebt die 1200er-Sicherheitsklemme das
  /// Ziel aber auf 1200 kcal an — real sind es −797 kcal ≙ −0,72 kg/Woche, und
  /// „Zügig" und „Ambitioniert" landen **beide** dort. Der Picker versprach
  /// damit zwei verschiedene Tempi für denselben Plan, und erst der nächste
  /// Schritt korrigierte.
  ///
  /// Der Titel behält bewusst das gewählte Tempo: er ist der *Name* der Option
  /// („Ambitioniert · −1 kg/Woche"), und zwei Zeilen mit derselben effektiven
  /// Rate wären nicht mehr auseinanderzuhalten. Die Folge gehört in den
  /// Untertitel — Auswahl oben, Konsequenz darunter.
  String _tempoFolge(WeightGoal option) {
    final t = const KcalCalculator()
        .calculate(_draftProfile().copyWith(weightGoal: option));
    return 'Ergibt ${t.kcal} kcal/Tag · ${t.effectivePaceLabel}';
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

  /// Android-Systemzurueck (Button oder Randgeste) — muss dasselbe tun wie der
  /// Header-Pfeil (D4).
  ///
  /// [OnboardingScreen] ist der Inhalt der **Root-Route** (EatovaHomePage im
  /// AuthGate), kein gepushter Screen. Ohne diesen Handler scheitert
  /// `Navigator.maybePop` mangels zweiter Route, die Engine faellt auf
  /// `SystemNavigator.pop()` zurueck und beendet die Activity — mitten im Flow
  /// waren damit alle bereits gegebenen Antworten weg, weil erst `_finish()`
  /// etwas persistiert.
  ///
  /// Ab Schritt 1 wird der Pop deshalb abgefangen und in einen Schritt zurueck
  /// uebersetzt. Auf Schritt 0 (Intro) bleibt `canPop` bewusst `true`: dort hat
  /// der Nutzer nichts investiert, und die Alternative — zurueck zum
  /// Auth-Screen — hiesse abmelden. Eine Randgeste darf keine Session beenden;
  /// „Zurueck auf dem ersten Screen schliesst die App" ist die erwartete
  /// Android-Konvention.
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    _back();
  }

  void _onDirectionChosen(_GoalDirection dir) {
    setState(() {
      _direction = dir;
      // Sinnvolles Default-Wunschgewicht je Richtung setzen.
      if (dir == _GoalDirection.lose) {
        _target = _safeClamp(
          _weight - 5,
          ProfileLimits.targetWeightKgMin,
          _weight - 1,
        );
      } else if (dir == _GoalDirection.gain) {
        _target = _safeClamp(
          _weight + 5,
          _weight + 1,
          ProfileLimits.targetWeightKgMax,
        );
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
    final t = context.t;
    final step = _steps[_index];
    final progress = (_index + 1) / _steps.length;
    final isSummary = step == _Step.summary;

    return PopScope<Object?>(
      // Nur der Intro-Schritt gibt den Pop frei — siehe [_onPopInvoked].
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
                  // Vorher ein FilledButton, jetzt ein blankes InkWell: die
                  // Bibliothek gibt [PrimaryActionButton] kein `isButton` mit,
                  // und ohne dieses Flag kuendigt ein Screenreader den
                  // Weiter-Knopf nur noch als Text an. Gehoert in die
                  // Bibliothek (siehe Bericht) — bis dahin hier.
                  button: true,
                  child: PrimaryActionButton(
                    key: ValueKey(
                      isSummary ? 'onboarding-finish' : 'onboarding-next',
                    ),
                    label: switch (step) {
                      _Step.intro => 'Los geht\'s',
                      _Step.summary => 'Plan aktivieren',
                      _ => 'Weiter',
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
            min: ProfileLimits.ageYearsMin,
            max: ProfileLimits.ageYearsMax,
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
            min: ProfileLimits.heightCmMin,
            max: ProfileLimits.heightCmMax,
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
            min: ProfileLimits.weightKgMin,
            max: ProfileLimits.weightKgMax,
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
    final t = context.t;
    return Row(
      children: [
        SizedBox(
          // Genau die Kantenlaenge von SquareIconButton — der Balken darf
          // beim Wechsel Intro ↔ Schritt 1 nicht springen.
          width: 34,
          child: showBack
              ? SquareIconButton(
                  key: const ValueKey('onboarding-back'),
                  icon: Icons.chevron_left_rounded,
                  onTap: onBack,
                  // Umlaut, kein „ue": ein Semantics-Label ist GESPROCHENER
                  // Text (vgl. PageHeader in widgets/design/rows.dart).
                  semanticLabel: 'Zurück',
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
  const _IntroStep({required this.firstName});

  final String firstName;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
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
          'Willkommen, $firstName.',
          style: AppType.display(30, color: t.ink, height: 1.08),
        ),
        const SizedBox(height: 12),
        Text(
          'In 6 kurzen Schritten berechnen wir dein persönliches Tagesziel — '
          'genau abgestimmt auf deinen Körper und dein Wunschgewicht.',
          style: AppType.ui(
            15,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
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
                    color: value == sex ? t.lime : t.ink2,
                  ),
                  const SizedBox(height: 10),
                  // Die Kachel ist ein Drittel breit, die Beschriftung waechst
                  // mit der Systemschrift — ohne Schrumpfen liefe „Männlich"
                  // bei 2.0 heraus.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      labels[sex]!.$1,
                      maxLines: 1,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: value == sex ? t.onForest : t.ink2,
                      ),
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
    required this.outcomeFor,
    required this.onChanged,
  });

  final List<WeightGoal> options;
  final WeightGoal value;

  /// Untertitel einer Option: der Plan, den sie mit den bisherigen Antworten
  /// ergibt. Siehe `_OnboardingScreenState._tempoFolge`.
  final String Function(WeightGoal) outcomeFor;

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

  // Defensiv gegen invertierte Fenster (z.B. „abnehmen" am Gewichts-Minimum):
  // clamp und Slider assertieren lower <= upper.
  int get _hi => max < min ? min : max;

  void _set(int v) => onChanged(v.clamp(min, _hi).toInt());

  @override
  Widget build(BuildContext context) {
    final t = context.t;
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
            // Abweichung von vorher (SizedBox(width: 150)): bei textScaler 2.0
            // ist die 52er-Ziffernfolge breiter als 150 px. Die Spalte waechst
            // jetzt mit dem verbleibenden Platz, die Zahl schrumpft notfalls.
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
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      unit,
                      maxLines: 1,
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w600,
                        color: t.ink2,
                        letterSpacing: 0.2,
                      ),
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
    required this.onTap,
  });

  final Key keyValue;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
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
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        decoration: BoxDecoration(
          // Ausgewaehlt heisst jetzt: volle Markenflaeche statt getoenter
          // Rand. Das traegt die Auswahl auch dann, wenn der Nutzer den
          // Farbunterschied nicht sieht (Kontrast statt Farbton).
          color: selected ? t.forest : t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(
            color: selected ? t.forest : t.line,
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
    final t = context.t;
    return InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? t.forest : t.surf,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: selected ? t.forest : t.line),
        ),
        child: Row(
          children: [
            if (leadingIcon != null) ...[
              Icon(
                leadingIcon,
                size: 22,
                color: selected ? t.lime : t.ink2,
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
                      color: selected ? t.onForest : t.ink,
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
                          ? t.onForest.withValues(alpha: 0.78)
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
                  color: selected ? t.lime : t.ink2,
                ),
              ),
            ],
            if (selected) ...[
              const SizedBox(width: 10),
              Icon(Icons.check_circle_rounded, color: t.lime, size: 20),
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
    // [targets] ist aus genau diesem Profil berechnet — durchreichen statt
    // `calculate` ein zweites Mal laufen zu lassen.
    final weeks = const KcalCalculator().weeksToGoal(profile, targets: targets);
    final goal = profile.weightGoal;

    // `weeks == null` heisst: es gibt keine ehrliche Prognose (Wunschgewicht
    // erreicht, Rate im Rundungsrauschen, oder die 1200er-Klemme dreht die
    // Richtung um — dann isst der Nutzer trotz „abnehmen" im Ueberschuss).
    // Dann lieber gar keine Zahl als eine erfundene; das Warum steht direkt
    // darueber in [KcalTargets.paceWarning].
    final timeline = switch (goal) {
      WeightGoal.maintain => 'Du hältst dein Gewicht von ${profile.weightKg} kg.',
      _ when weeks != null =>
        '${profile.targetWeightKg} kg in ca. $weeks Wochen erreichbar.',
      _ => 'Für dieses Ziel lässt sich kein verlässlicher Zeitraum schätzen.',
    };

    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dein Plan steht, $firstName.',
          style: AppType.display(28, color: t.ink, height: 1.08),
        ),
        const SizedBox(height: 8),
        Text(
          'Das ist dein empfohlenes Tagesziel.',
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
                      'TÄGLICHES KALORIENZIEL',
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
                            'kcal',
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
        // Macros — auf dem Seitengrund statt auf der Forest-Flaeche: dort
        // haette t.protein im Hellmodus kein lesbares Kontrastverhaeltnis.
        Row(
          children: [
            _MacroChip(
              label: 'Protein',
              value: '${targets.proteinG} g',
              color: t.protein,
            ),
            const SizedBox(width: 12),
            _MacroChip(
              label: 'Carbs',
              value: '${targets.carbsG} g',
              color: t.carbs,
            ),
            const SizedBox(width: 12),
            _MacroChip(
              label: 'Fett',
              value: '${targets.fatG} g',
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
                label: 'Grundumsatz (BMR)',
                value: '${targets.bmr} kcal',
              ),
              const _BreakdownDivider(),
              _BreakdownRow(
                label: 'Erhaltungsbedarf · ${profile.activityLevel.label}',
                value: '${targets.maintenanceKcal} kcal',
                valueKey: const ValueKey('onboarding-summary-maintenance'),
              ),
              const _BreakdownDivider(),
              // B2: hier steht der **Plan**, nicht der Wunsch. `goal.paceLabel`
              // / `goal.deltaLabel` versprechen −1 kg/Woche und −1100 kcal,
              // auch wenn die 1200er-Sicherheitsklemme daraus −0,72 kg/Woche
              // und −797 kcal gemacht hat. Mit der effektiven Rate geht die
              // Karte auch arithmetisch auf: Erhaltung − Tagesziel = Delta.
              _BreakdownRow(
                key: const ValueKey('onboarding-summary-goal-row'),
                label: 'Ziel · ${targets.effectivePaceLabel}',
                value: _signedKcalLabel(targets.effectiveKcalDelta),
                highlight: targets.effectiveKcalDelta != 0,
              ),
            ],
          ),
        ),
        // Sichtbarer Hinweis, wenn Tagesziel und gewaehltes Tempo auseinander
        // liegen — sonst bliebe der Widerspruch unerklaert.
        if (targets.paceWarning != null) ...[
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
                    targets.paceWarning!,
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
          'Schätzung nach Mifflin-St Jeor. Werte sind jederzeit unter '
          'Profil › Einstellungen anpassbar.',
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
            // Die Kachel ist ein Drittel der Zeile breit — bei textScaler 2.0
            // braucht der Inhalt die Notbremse.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style:
                    AppType.display(16, weight: FontWeight.w700, color: color),
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style:
                    AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vorzeichenbehaftetes kcal-Label für eine **berechnete** Differenz, z.B.
/// "−797 kcal" / "+88 kcal" / "±0".
///
/// Gegenstück zu [WeightGoalInfo.deltaLabel], nur eben für
/// [KcalTargets.effectiveKcalDelta] statt für das gewählte Ziel — gleiche
/// Schreibweise inkl. echtem Minuszeichen (U+2212), damit auf der Karte kein
/// Zeichenmix entsteht.
String _signedKcalLabel(int kcal) {
  if (kcal == 0) return '±0';
  final sign = kcal > 0 ? '+' : '−';
  return '$sign${kcal.abs()} kcal';
}

/// Eine Zeile der Aufschluesselung.
///
/// **Genau zwei [Text]-Kinder** — der Test `onboarding_screen_test` liest alle
/// Texte der Ziel-Zeile als Liste und vergleicht sie mit
/// `['Ziel · −0,72 kg/Woche', '−797 kcal']`.
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

  /// Hebt die Zahl in den Marken-Akzent. Frueher unterschied die Farbe
  /// zusaetzlich Defizit (lime) von Ueberschuss (orange) — in der neuen
  /// Sprache traegt der Ton keine Daten mehr, und die Richtung steht ohnehin
  /// als Vorzeichen im Text.
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
        // Kein Expanded/Flexible: die Zeile hat nur zwei Kinder, und der Wert
        // ist immer kurz („1997 kcal"). Der Text darf umbrechen, die Spalte
        // links gibt dafuer nach.
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
