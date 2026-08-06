import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_colors.dart';
import 'target_bmi_hint.dart';

Future<SettingsResult?> showSettingsSheet(
  BuildContext context, {
  required UserProfile profile,
  bool notificationsEnabled = false,
}) {
  return showModalBottomSheet<SettingsResult>(
    context: context,
    backgroundColor: surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _SettingsSheet(
      initial: profile,
      notificationsEnabled: notificationsEnabled,
    ),
  );
}

class SettingsResult {
  const SettingsResult({
    required this.profile,
    required this.resetDay,
    required this.notificationsEnabled,
  });

  final UserProfile profile;
  final bool resetDay;

  /// Zustand des Erinnerungen-Schalters beim Speichern. Der Aufrufer vergleicht
  /// mit dem vorigen Stand und ruft requestPermission()/reschedule bzw.
  /// cancelAll auf (PROD-1).
  final bool notificationsEnabled;
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.initial,
    required this.notificationsEnabled,
  });

  final UserProfile initial;
  final bool notificationsEnabled;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _weight;
  late final TextEditingController _height;
  late final TextEditingController _age;
  late final TextEditingController _steps;
  late final TextEditingController _kcal;
  late final TextEditingController _water;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _targetWeight;
  late BiologicalSex _sex;
  late ActivityLevel _activity;
  late int _sleepGoalMinutes;
  late WeightGoal _goal;

  /// True wenn der User kcal/Makros von Hand übersteuert hat. Standardmäßig
  /// rechnen wir live aus Körper + Aktivität + Ziel — nur wenn die
  /// gespeicherten Werte davon abweichen (oder der User den Schalter umlegt),
  /// bleiben manuelle Werte erhalten.
  late bool _manualEnergy;

  /// Lokaler Schalterzustand fuer die Erinnerungen (PROD-1). Beim Speichern
  /// landet er in [SettingsResult.notificationsEnabled].
  late bool _notificationsEnabled;

  @override
  void initState() {
    super.initState();
    _notificationsEnabled = widget.notificationsEnabled;
    final p = widget.initial;
    _weight = TextEditingController(text: p.weightKg.toString());
    _height = TextEditingController(text: p.heightCm.toString());
    _age = TextEditingController(text: p.ageYears.toString());
    _steps = TextEditingController(text: p.dailyStepsGoal.toString());
    _kcal = TextEditingController(text: p.dailyKcalGoal.toString());
    _water = TextEditingController(text: p.dailyWaterGoalMl.toString());
    _protein = TextEditingController(text: p.proteinGoalG.toString());
    _carbs = TextEditingController(text: p.carbsGoalG.toString());
    _fat = TextEditingController(text: p.fatGoalG.toString());
    _targetWeight = TextEditingController(text: p.targetWeightKg.toString());
    _sex = p.sex;
    _activity = p.activityLevel;
    _sleepGoalMinutes = p.dailySleepGoalMinutes;
    _goal = p.weightGoal;

    final computed = const KcalCalculator().calculate(p);
    _manualEnergy = p.dailyKcalGoal != computed.kcal ||
        p.proteinGoalG != computed.proteinG ||
        p.carbsGoalG != computed.carbsG ||
        p.fatGoalG != computed.fatG;
  }

  @override
  void dispose() {
    _weight.dispose();
    _height.dispose();
    _age.dispose();
    _steps.dispose();
    _kcal.dispose();
    _water.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _targetWeight.dispose();
    super.dispose();
  }

  int _parseInt(TextEditingController c, int fallback) {
    return int.tryParse(c.text.trim()) ?? fallback;
  }

  /// Profil nur mit den kalorien-relevanten Feldern — Basis für die
  /// Live-Berechnung (Energie-Felder fließen NICHT in calculate() ein).
  /// Alter wird auf 16–100 geclampt: Mindestalter 16 (Art. 8 DSGVO,
  /// Gesundheitsdaten) — dieselbe Grenze wie Onboarding und DB-Constraint.
  UserProfile _draftForCalc() {
    final p = widget.initial;
    return p.copyWith(
      weightKg: _parseInt(_weight, p.weightKg),
      heightCm: _parseInt(_height, p.heightCm),
      ageYears: _parseInt(_age, p.ageYears).clamp(16, 100).toInt(),
      sex: _sex,
      activityLevel: _activity,
      targetWeightKg: _parseInt(_targetWeight, p.targetWeightKg),
      weightGoal: _goal,
    );
  }

  KcalTargets get _liveTargets =>
      const KcalCalculator().calculate(_draftForCalc());

  UserProfile _buildProfile() {
    final p = widget.initial;
    final t = _liveTargets;
    // copyWith erhält Felder die der Sheet nicht anfasst — v.a.
    // onboardingCompleted (sonst landet der User beim Speichern wieder im
    // Onboarding).
    return _draftForCalc().copyWith(
      dailyStepsGoal: _parseInt(_steps, p.dailyStepsGoal),
      dailyWaterGoalMl: _parseInt(_water, p.dailyWaterGoalMl),
      dailySleepGoalMinutes: _sleepGoalMinutes,
      dailyKcalGoal: _manualEnergy ? _parseInt(_kcal, t.kcal) : t.kcal,
      proteinGoalG: _manualEnergy ? _parseInt(_protein, t.proteinG) : t.proteinG,
      carbsGoalG: _manualEnergy ? _parseInt(_carbs, t.carbsG) : t.carbsG,
      fatGoalG: _manualEnergy ? _parseInt(_fat, t.fatG) : t.fatG,
    );
  }

  /// Bei Live-Modus die Energie-Felder mit der frischen Berechnung füllen,
  /// damit das Sheet konsistent bleibt; danach neu zeichnen.
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

  void _save({required bool resetDay}) {
    Navigator.pop(
      context,
      SettingsResult(
        profile: _buildProfile(),
        resetDay: resetDay,
        notificationsEnabled: _notificationsEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _liveTargets;
    final heroKcal = _manualEnergy ? _parseInt(_kcal, t.kcal) : t.kcal;
    final heroProtein = _manualEnergy ? _parseInt(_protein, t.proteinG) : t.proteinG;
    final heroCarbs = _manualEnergy ? _parseInt(_carbs, t.carbsG) : t.carbsG;
    final heroFat = _manualEnergy ? _parseInt(_fat, t.fatG) : t.fatG;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Profil & Ziele',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                height: 1.08,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Wir berechnen dein Tagesziel aus Körper, Aktivität und Ziel.',
              style: TextStyle(
                color: textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 18),
            _PlanHero(
              kcal: heroKcal,
              protein: heroProtein,
              carbs: heroCarbs,
              fat: heroFat,
              maintenanceKcal: t.maintenanceKcal,
              goal: _goal,
              manual: _manualEnergy,
            ),
            const SizedBox(height: 14),
            _GroupCard(
              icon: Icons.straighten_rounded,
              title: 'Körper',
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _SettingsField(
                          label: 'Gewicht',
                          suffix: 'kg',
                          controller: _weight,
                          keyValue: const ValueKey('settings-weight'),
                          onChanged: (_) => _recompute(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SettingsField(
                          label: 'Größe',
                          suffix: 'cm',
                          controller: _height,
                          keyValue: const ValueKey('settings-height'),
                          onChanged: (_) => _recompute(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _SettingsField(
                          label: 'Alter',
                          suffix: 'J.',
                          controller: _age,
                          keyValue: const ValueKey('settings-age'),
                          onChanged: (_) => _recompute(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SexField(
                          value: _sex,
                          onChanged: (v) {
                            _sex = v;
                            _recompute();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _GroupCard(
              icon: Icons.flag_rounded,
              title: 'Aktivität & Ziel',
              subtitle: 'Bestimmt deinen Kalorienbedarf.',
              child: Column(
                children: [
                  _ActivityField(
                    value: _activity,
                    onChanged: (v) {
                      _activity = v;
                      _recompute();
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _SettingsField(
                          label: 'Wunschgewicht',
                          suffix: 'kg',
                          controller: _targetWeight,
                          keyValue: const ValueKey('settings-target-weight'),
                          onChanged: (_) => _recompute(),
                        ),
                      ),
                    ],
                  ),
                  // Sanfter, nicht blockierender BMI-Hinweis — gleiche Grenze
                  // wie im Onboarding-Zielschritt (unter 18,5 / über 35).
                  TargetBmiHint(
                    margin: const EdgeInsets.only(top: 10),
                    heightCm:
                        _parseInt(_height, widget.initial.heightCm),
                    targetWeightKg: _parseInt(
                      _targetWeight,
                      widget.initial.targetWeightKg,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _WeightGoalField(
                    value: _goal,
                    onChanged: (v) {
                      _goal = v;
                      _recompute();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _GroupCard(
              icon: Icons.local_fire_department_rounded,
              title: 'Energie & Makros',
              trailing: _ManualToggle(
                value: _manualEnergy,
                onChanged: _toggleManual,
              ),
              child: _manualEnergy
                  ? Column(
                      children: [
                        _SettingsField(
                          label: 'Kcal Ziel',
                          suffix: 'kcal',
                          controller: _kcal,
                          keyValue: const ValueKey('settings-kcal'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _SettingsField(
                                label: 'Protein',
                                suffix: 'g',
                                controller: _protein,
                                keyValue: const ValueKey('settings-protein'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SettingsField(
                                label: 'Carbs',
                                suffix: 'g',
                                controller: _carbs,
                                keyValue: const ValueKey('settings-carbs'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SettingsField(
                                label: 'Fett',
                                suffix: 'g',
                                controller: _fat,
                                keyValue: const ValueKey('settings-fat'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : const _InfoNote(
                      'Automatisch aus deinem Ziel berechnet. Schalter umlegen, '
                      'um kcal und Makros von Hand zu setzen.',
                    ),
            ),
            const SizedBox(height: 12),
            _GroupCard(
              icon: Icons.track_changes_rounded,
              title: 'Tagesziele',
              subtitle: 'Nur fürs Tracking – ändert deine Kalorien nicht.',
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _SettingsField(
                          label: 'Schritte',
                          suffix: '/Tag',
                          controller: _steps,
                          keyValue: const ValueKey('settings-steps-goal'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SettingsField(
                          label: 'Wasser',
                          suffix: 'ml',
                          controller: _water,
                          keyValue: const ValueKey('settings-water'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _SleepGoalField(
                    minutes: _sleepGoalMinutes,
                    onChanged: (v) => setState(() => _sleepGoalMinutes = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _GroupCard(
              icon: Icons.notifications_active_rounded,
              title: 'Erinnerungen',
              subtitle: 'Tägliche Streak-Erinnerung am Abend — lokal, '
                  'ohne Server.',
              trailing: _NotificationsToggle(
                value: _notificationsEnabled,
                onChanged: (v) => setState(() => _notificationsEnabled = v),
              ),
              child: _InfoNote(
                _notificationsEnabled
                    ? 'Aktiv. Du bekommst gezielte Nudges zur passenden Zeit. '
                        'Erteile beim ersten Mal die Mitteilungs-Berechtigung.'
                    : 'Aus. Schalter umlegen, um lokale Erinnerungen zu '
                        'aktivieren.',
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('settings-reset-day'),
                onPressed: () => _save(resetDay: true),
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: const Text(
                  'Tagesdaten zurücksetzen',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: orange,
                  side: BorderSide(color: orange.withValues(alpha: 0.45)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('settings-save'),
                onPressed: () => _save(resetDay: false),
                icon: const Icon(Icons.check_rounded, size: 17),
                label: const Text(
                  'Speichern',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: bg,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // DSGVO Art. 13 / § 5 DDG / App-Store: Rechtsseiten auch in den
            // Settings erreichbar (nach dem Login), nicht nur auf dem
            // Auth-Screen. Alle drei liegen auf eatova.de.
            const Center(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _LegalLink(
                    key: ValueKey('settings-privacy-link'),
                    label: 'Datenschutz',
                    url: kPrivacyUrl,
                  ),
                  _LegalDot(),
                  _LegalLink(
                    key: ValueKey('settings-terms-link'),
                    label: 'AGB',
                    url: kTermsUrl,
                  ),
                  _LegalDot(),
                  _LegalLink(
                    key: ValueKey('settings-imprint-link'),
                    label: 'Impressum',
                    url: kImprintUrl,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rechts-Links (Datenschutz / AGB / Impressum -> eatova.de)
// ---------------------------------------------------------------------------

class _LegalLink extends StatelessWidget {
  const _LegalLink({super.key, required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ),
      style: TextButton.styleFrom(
        foregroundColor: textMuted,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _LegalDot extends StatelessWidget {
  const _LegalDot();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '·',
      style: TextStyle(color: textMuted, fontSize: 12),
    );
  }
}

// ---------------------------------------------------------------------------
// Live-Plan-Hero
// ---------------------------------------------------------------------------

class _PlanHero extends StatelessWidget {
  const _PlanHero({
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.maintenanceKcal,
    required this.goal,
    required this.manual,
  });

  final int kcal;
  final int protein;
  final int carbs;
  final int fat;
  final int maintenanceKcal;
  final WeightGoal goal;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [lime.withValues(alpha: 0.16), surface],
        ),
        borderRadius: BorderRadius.circular(rSheet),
        border: Border.all(color: lime.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: lime.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(
                  manual ? Icons.edit_rounded : Icons.auto_awesome_rounded,
                  color: lime,
                  size: 17,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manual ? 'DEIN TAGESZIEL · MANUELL' : 'DEIN TAGESZIEL',
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Erhaltung $maintenanceKcal · ${goal.paceLabel}',
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$kcal',
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.6,
                  height: 1,
                  color: lime,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 5),
              const Padding(
                padding: EdgeInsets.only(bottom: 5),
                child: Text(
                  'kcal',
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _MacroChip(label: 'Protein', value: '$protein g', color: lime),
              const SizedBox(width: 8),
              _MacroChip(label: 'Carbs', value: '$carbs g', color: cyan),
              const SizedBox(width: 8),
              _MacroChip(label: 'Fett', value: '$fat g', color: orange),
            ],
          ),
        ],
      ),
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: hairline),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: -0.2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Group card + shared bits
// ---------------------------------------------------------------------------

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ManualToggle extends StatelessWidget {
  const _ManualToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Manuell',
          style: TextStyle(
            color: textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 4),
        // A11y: 0.8 skaliert nur die Optik; volle 48er Tap-Flaeche bleibt
        // (padded statt shrinkWrap). Label fuer Screenreader ergaenzt.
        Semantics(
          label: 'Energie & Makros manuell setzen',
          child: Transform.scale(
            scale: 0.8,
            child: Switch(
              key: const ValueKey('settings-manual-energy'),
              value: value,
              onChanged: onChanged,
              thumbColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.selected) ? bg : null,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.selected) ? lime : null,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationsToggle extends StatelessWidget {
  const _NotificationsToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // A11y: 0.8 skaliert nur die Optik; volle Tap-Flaeche bleibt. Eigenes
    // Semantics-Label fuer Screenreader.
    return Semantics(
      label: 'Lokale Erinnerungen aktivieren',
      child: Transform.scale(
        scale: 0.8,
        child: Switch(
          key: const ValueKey('settings-notifications'),
          value: value,
          onChanged: onChanged,
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? bg : null,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? lime : null,
          ),
        ),
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 15, color: textMuted),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: textMuted,
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsField extends StatelessWidget {
  const _SettingsField({
    required this.label,
    required this.suffix,
    required this.controller,
    required this.keyValue,
    this.onChanged,
  });

  final String label;
  final String suffix;
  final TextEditingController controller;
  final Key keyValue;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: keyValue,
      cursorOpacityAnimates: false,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label, suffixText: suffix),
    );
  }
}

class _SexField extends StatelessWidget {
  const _SexField({required this.value, required this.onChanged});

  final BiologicalSex value;
  final ValueChanged<BiologicalSex> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('settings-sex'),
      onTap: () async {
        final picked = await showModalBottomSheet<BiologicalSex>(
          context: context,
          backgroundColor: surface,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in BiologicalSex.values)
                  ListTile(
                    key: ValueKey('settings-sex-${option.name}'),
                    title: Text(option.label),
                    trailing: value == option
                        ? const Icon(Icons.check_rounded, color: lime)
                        : null,
                    onTap: () => Navigator.pop(sheetContext, option),
                  ),
              ],
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Geschlecht',
              style: TextStyle(
                color: textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value.label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityField extends StatelessWidget {
  const _ActivityField({required this.value, required this.onChanged});

  final ActivityLevel value;
  final ValueChanged<ActivityLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('settings-activity'),
      onTap: () async {
        final picked = await showModalBottomSheet<ActivityLevel>(
          context: context,
          backgroundColor: surface,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in ActivityLevel.values)
                  ListTile(
                    key: ValueKey('settings-activity-${option.name}'),
                    title: Text(option.label),
                    subtitle: Text('${option.description} · ×${option.palFactor}'),
                    trailing: value == option
                        ? const Icon(Icons.check_rounded, color: lime)
                        : null,
                    onTap: () => Navigator.pop(sheetContext, option),
                  ),
              ],
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Aktivitätslevel',
                    style: TextStyle(
                      color: textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '×${value.palFactor}',
              style: const TextStyle(
                color: textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeightGoalField extends StatelessWidget {
  const _WeightGoalField({required this.value, required this.onChanged});

  final WeightGoal value;
  final ValueChanged<WeightGoal> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('settings-weight-goal'),
      onTap: () async {
        final picked = await showModalBottomSheet<WeightGoal>(
          context: context,
          backgroundColor: surface,
          showDragHandle: true,
          builder: (sheetContext) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 6, 20, 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Gewichtsziel & Tempo',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ),
                  for (final option in WeightGoal.values)
                    ListTile(
                      key: ValueKey('settings-weight-goal-${option.name}'),
                      title: Text(option.menuLabel),
                      subtitle: Text(option.deltaLabel),
                      trailing: value == option
                          ? const Icon(Icons.check_rounded, color: lime)
                          : null,
                      onTap: () => Navigator.pop(sheetContext, option),
                    ),
                ],
              ),
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Gewichtsziel',
                    style: TextStyle(
                      color: textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              value.paceLabel,
              style: TextStyle(
                color: value.kcalDelta == 0
                    ? textMuted
                    : (value.kcalDelta < 0 ? lime : warning),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SleepGoalField extends StatelessWidget {
  const _SleepGoalField({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    final label = '${hours}h ${rest.toString().padLeft(2, '0')}m';

    return InkWell(
      key: const ValueKey('settings-sleep-goal'),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: hours, minute: rest),
          helpText: 'Schlafziel',
        );
        if (picked != null) {
          onChanged(picked.hour * 60 + picked.minute);
        }
      },
      borderRadius: BorderRadius.circular(rCard),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceSoft,
          borderRadius: BorderRadius.circular(rCard),
          border: Border.all(color: hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Schlafziel',
              style: TextStyle(
                color: textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
