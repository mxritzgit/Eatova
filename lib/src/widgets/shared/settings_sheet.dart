import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/home_store.dart' show ReminderState;
import '../../config/legal_links.dart';
import '../../models/model_limits.dart';
import '../../models/user_profile.dart';
import '../../services/kcal_calculator.dart';
import '../../theme/app_colors.dart';
import 'target_bmi_hint.dart';

/// Oeffnet „Profil & Ziele".
///
/// [reminderState] ist der volle Zustand der Erinnerungen (D11). Aufrufer, die
/// ihn nicht kennen, uebergeben weiterhin nur [notificationsEnabled]; daraus
/// wird [ReminderState.off] bzw. [ReminderState.active] abgeleitet — „vom
/// System blockiert" laesst sich so allerdings nie anzeigen.
///
/// [onOpenSystemSettings] ist der Weg in die System-Benachrichtigungs-
/// einstellungen. Fehlt er, zeigt der blockierte Zustand nur den Hinweistext
/// und KEINEN Button: ein Button, der nichts oeffnet, waere dieselbe Sorte
/// Luege wie der Schalter, der D11 ausgeloest hat. Das Projekt hat aktuell
/// keinen solchen Weg — `url_launcher` startet auf Android ausschliesslich
/// ACTION_VIEW-Intents (url_launcher_android, UrlLauncher.java:88) und erreicht
/// `Settings.ACTION_APP_NOTIFICATION_SETTINGS` damit nicht; dafuer braeuchte es
/// `app_settings`/`permission_handler` oder einen eigenen Platform-Channel.
Future<SettingsResult?> showSettingsSheet(
  BuildContext context, {
  required UserProfile profile,
  bool notificationsEnabled = false,
  ReminderState? reminderState,
  VoidCallback? onOpenSystemSettings,
}) {
  return showModalBottomSheet<SettingsResult>(
    context: context,
    backgroundColor: surface,
    // Ziehen und Barriere-Tap bleiben erlaubt; abgefangen wird erst, wenn
    // wirklich etwas eingetippt ist (D5) — [PopScope] fuer den Barriere-Tap
    // und die Zurueck-Taste, [_DiscardDragGuard] fuer das Ziehen.
    //
    // Den Griff zeichnet deshalb das Sheet selbst ([_SheetGrabber]) statt der
    // Route: der Route-Griff liegt als Stack-Geschwister NEBEN dem
    // `builder`-Kind (bottom_sheet.dart:397-410) und damit ausserhalb des
    // Guards — ein Zug genau am Griff, also die naheliegendste Wegwisch-Geste,
    // liefe sonst weiter ungefragt durch. `enableDrag` bleibt an: ohne
    // Aenderungen soll sich das Sheet wie gewohnt wegziehen lassen.
    showDragHandle: false,
    isScrollControlled: true,
    builder: (context) => _SettingsSheet(
      initial: profile,
      reminderState: reminderState ??
          (notificationsEnabled ? ReminderState.active : ReminderState.off),
      onOpenSystemSettings: onOpenSystemSettings,
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
    required this.reminderState,
    this.onOpenSystemSettings,
  });

  final UserProfile initial;
  final ReminderState reminderState;
  final VoidCallback? onOpenSystemSettings;

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

  /// Lokaler Zustand der Erinnerungen (PROD-1 / D11). Beim Speichern wird
  /// daraus [SettingsResult.notificationsEnabled] — und zwar nur bei
  /// [ReminderState.active], „blockiert" ist kein „an".
  late ReminderState _reminder;

  // --- Ausgangsstand fuer die Verwerf-Rueckfrage (D5) ------------------------
  late final ReminderState _reminderStart;
  late final bool _manualStart;
  late final Map<TextEditingController, String> _textStart;

  @override
  void initState() {
    super.initState();
    _reminder = widget.reminderState;
    _reminderStart = widget.reminderState;
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
    _manualStart = _manualEnergy;
    _textStart = {for (final c in _alleFelder) c: c.text};
  }

  List<TextEditingController> get _alleFelder => [
        _weight,
        _height,
        _age,
        _steps,
        _kcal,
        _water,
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
    _water.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _targetWeight.dispose();
    super.dispose();
  }

  // --- Feldpruefung (C1) ----------------------------------------------------
  //
  // `FilteringTextInputFormatter.digitsOnly` ist ein TYP-Guard, kein
  // WERTEBEREICHS-Guard. Wer „75,5" tippt, verliert das Komma und schickt 755
  // an `profiles.weight_kg` (`between 30 and 300`) — PostgreSQL antwortet mit
  // 23514, und dessen Meldung traegt die komplette fehlgeschlagene Zeile
  // inklusive E-Mail. Genau das war der Ausloeser des Sentry-Leaks C1.
  //
  // Gegen Nutzereingaben ist ABLEHNEN richtig, nicht Klemmen: 755 auf 300 zu
  // klemmen schriebe eine Zahl ins Profil, die der Nutzer nie gemeint hat.
  // Die Grenzen stammen aus den echten SQL-Migrationen (model_limits.dart).

  static const String _bereichKg =
      '${ProfileLimits.weightKgMin}–${ProfileLimits.weightKgMax} kg '
      '(ganze Zahl)';
  static const String _bereichCm =
      '${ProfileLimits.heightCmMin}–${ProfileLimits.heightCmMax} cm';
  static const String _bereichAlter =
      '${ProfileLimits.ageYearsMin}–${ProfileLimits.ageYearsMax} Jahre';
  static const String _bereichSchritte =
      '${ProfileLimits.dailyStepsGoalMin}–${ProfileLimits.dailyStepsGoalMax}';
  static const String _bereichWasser =
      '${ProfileLimits.dailyWaterGoalMlMin}–'
      '${ProfileLimits.dailyWaterGoalMlMax} ml';
  static const String _bereichKcal =
      '${ProfileLimits.dailyKcalGoalMin}–${ProfileLimits.dailyKcalGoalMax} kcal';
  static const String _bereichProtein =
      '${ProfileLimits.proteinGoalGMin}–${ProfileLimits.proteinGoalGMax} g';
  static const String _bereichCarbs =
      '${ProfileLimits.carbsGoalGMin}–${ProfileLimits.carbsGoalGMax} g';
  static const String _bereichFett =
      '${ProfileLimits.fatGoalGMin}–${ProfileLimits.fatGoalGMax} g';

  /// Fehlertext des Feldes oder `null`, wenn der Wert so in die DB darf.
  String? _fehler(
    TextEditingController c,
    bool Function(num) gueltig,
    String bereich,
  ) {
    final text = c.text.trim();
    if (text.isEmpty) return 'Bitte ausfüllen';
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
  String? get _waterError =>
      _fehler(_water, isValidDailyWaterGoalMl, _bereichWasser);

  // Der Manuell-Pfad misst an den DB-Grenzen (800..7000), NICHT an der
  // engeren 1200er-Untergrenze des Rechners: wer bewusst 1000 setzt, darf das.
  String? get _kcalError => _fehler(_kcal, isValidDailyKcalGoal, _bereichKcal);
  String? get _proteinError =>
      _fehler(_protein, isValidProteinGoalG, _bereichProtein);
  String? get _carbsError => _fehler(_carbs, isValidCarbsGoalG, _bereichCarbs);
  String? get _fatError => _fehler(_fat, isValidFatGoalG, _bereichFett);

  /// Versteckte Felder zaehlen nicht: im Live-Modus kommen kcal und Makros aus
  /// der Rechnung, die ihre Grenzen selbst einhaelt.
  bool get _hatFehler => <String?>[
        _weightError,
        _heightError,
        _ageError,
        _targetWeightError,
        _stepsError,
        _waterError,
        if (_manualEnergy) ...[
          _kcalError,
          _proteinError,
          _carbsError,
          _fatError,
        ],
      ].any((f) => f != null);

  /// Der Feldwert, sofern er gueltig ist — sonst [fallback].
  ///
  /// Fuer die Live-Rechnung: waehrend der Nutzer einen ungueltigen Wert stehen
  /// hat, zeigt die Plan-Karte weiter den letzten sinnvollen Plan statt eines
  /// Phantasie-Ziels fuer 755 kg. Auf dem Speicherpfad kann der Fallback nicht
  /// greifen — dort ist [_hatFehler] bereits false.
  int _wertOder(
    TextEditingController c,
    bool Function(num) gueltig,
    int fallback,
  ) {
    final wert = int.tryParse(c.text.trim());
    return (wert != null && gueltig(wert)) ? wert : fallback;
  }

  /// Profil nur mit den kalorien-relevanten Feldern — Basis für die
  /// Live-Berechnung (Energie-Felder fließen NICHT in calculate() ein).
  UserProfile _draftForCalc() {
    final p = widget.initial;
    return p.copyWith(
      weightKg: _wertOder(_weight, isValidProfileWeightKg, p.weightKg),
      heightCm: _wertOder(_height, isValidProfileHeightCm, p.heightCm),
      // Mindestalter 16 (Art. 8 DSGVO, Gesundheitsdaten) — dieselbe Grenze wie
      // Onboarding und DB-Constraint. Frueher wurde hier still auf 16
      // geklemmt; das schrieb einem 12-Jaehrigen ein erfundenes Alter ins
      // Profil. Jetzt lehnt das Feld ab und der Nutzer korrigiert.
      ageYears: _wertOder(_age, isValidProfileAgeYears, p.ageYears),
      sex: _sex,
      activityLevel: _activity,
      targetWeightKg:
          _wertOder(_targetWeight, isValidProfileTargetWeightKg, p.targetWeightKg),
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
      dailyStepsGoal: _wertOder(_steps, isValidDailyStepsGoal, p.dailyStepsGoal),
      dailyWaterGoalMl:
          _wertOder(_water, isValidDailyWaterGoalMl, p.dailyWaterGoalMl),
      dailySleepGoalMinutes: _sleepGoalMinutes,
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

  // --- Verwerf-Rueckfrage (D5) ---------------------------------------------

  /// Hat der Nutzer irgendetwas angefasst? Sieben Zahlenfelder, vier Auswahl-
  /// felder und zwei Schalter — nichts davon darf kommentarlos verschwinden.
  bool get _dirty {
    final p = widget.initial;
    if (_sex != p.sex ||
        _activity != p.activityLevel ||
        _goal != p.weightGoal ||
        _sleepGoalMinutes != p.dailySleepGoalMinutes) {
      return true;
    }
    if (_manualEnergy != _manualStart) return true;
    if (_reminder != _reminderStart) return true;
    return _textStart.entries.any((e) => e.key.text != e.value);
  }

  /// Laeuft fuer JEDEN abgefangenen Dismiss-Versuch: Barriere-Tap und
  /// System-Zurueck kommen ueber [PopScope], das Ziehen ueber
  /// [_DiscardDragGuard]. Mehrfach-Versuche stapeln keine Dialoge.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Der Dialog ist hier bereits gepoppt — oberste Route ist wieder das
    // Sheet. Bewusst ohne Ergebnis: verworfen ist nicht gespeichert.
    Navigator.of(context).pop();
  }

  /// Text zum aktuellen Erinnerungs-Zustand (D11). Drei Zustaende, drei Saetze
  /// — „blockiert" ist ausdruecklich kein Fehler, sondern eine Systemeinstellung.
  String get _reminderText => switch (_reminder) {
        ReminderState.off =>
          'Aus. Schalter umlegen, um lokale Erinnerungen zu aktivieren.',
        ReminderState.active =>
          'Aktiv. Jeden Abend um 20 Uhr, wenn du noch nichts geloggt hast.',
        ReminderState.blocked =>
          'Vom System blockiert. Eatova darf keine Mitteilungen senden — '
              'erlaube sie in den Systemeinstellungen.',
      };

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
        // D11: nur „aktiv" heisst, dass abends wirklich etwas kommt.
        notificationsEnabled: _reminder == ReminderState.active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _liveTargets;
    final heroKcal =
        _manualEnergy ? _wertOder(_kcal, isValidDailyKcalGoal, t.kcal) : t.kcal;
    final heroProtein = _manualEnergy
        ? _wertOder(_protein, isValidProteinGoalG, t.proteinG)
        : t.proteinG;
    final heroCarbs =
        _manualEnergy ? _wertOder(_carbs, isValidCarbsGoalG, t.carbsG) : t.carbsG;
    final heroFat =
        _manualEnergy ? _wertOder(_fat, isValidFatGoalG, t.fatG) : t.fatG;

    return PopScope<SettingsResult>(
      // D5, Weg 1: Barriere-Tap und Zurueck-Taste — beide laufen ueber
      // Navigator.maybePop und fragen damit die Pop-Disposition.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      // D5, Weg 2: das Ziehen. Das laeuft an PopScope vorbei und braucht die
      // Gesten-Arena — siehe [_DiscardDragGuard].
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: Padding(
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
                const _SheetGrabber(),
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
                  targets: t,
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
                              errorText: _weightError,
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
                              errorText: _heightError,
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
                              errorText: _ageError,
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
                              errorText: _targetWeightError,
                              onChanged: (_) => _recompute(),
                            ),
                          ),
                        ],
                      ),
                      // Sanfter, nicht blockierender BMI-Hinweis — gleiche Grenze
                      // wie im Onboarding-Zielschritt (unter 18,5 / über 35).
                      TargetBmiHint(
                        margin: const EdgeInsets.only(top: 10),
                        heightCm: _wertOder(
                          _height,
                          isValidProfileHeightCm,
                          widget.initial.heightCm,
                        ),
                        targetWeightKg: _wertOder(
                          _targetWeight,
                          isValidProfileTargetWeightKg,
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
                              errorText: _kcalError,
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
                                    errorText: _proteinError,
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
                                    errorText: _carbsError,
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
                                    errorText: _fatError,
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
                              errorText: _stepsError,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _SettingsField(
                              label: 'Wasser',
                              suffix: 'ml',
                              controller: _water,
                              keyValue: const ValueKey('settings-water'),
                              errorText: _waterError,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _SleepGoalField(
                        minutes: _sleepGoalMinutes,
                        // Der Time-Picker laesst 0:00 bis 23:59 zu,
                        // `daily_sleep_goal_minutes` nur 180..900. Hier wird
                        // geklemmt statt abgelehnt — der Wert kommt aus einem
                        // Picker, und das Feld zeigt anschliessend genau den Wert,
                        // der gespeichert wird (sichtbar, nicht still).
                        onChanged: (v) => setState(
                          () => _sleepGoalMinutes = clampDailySleepGoalMinutes(v),
                        ),
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
                    value: _reminder == ReminderState.active,
                    // D11: im blockierten Zustand NICHT erneut umlegen lassen. Auf
                    // Android 13+ zeigt das System nach zwei Ablehnungen gar keinen
                    // Dialog mehr — der Schalter spraenge sofort zurueck und die
                    // App saehe wieder aus, als laege es an ihr.
                    onChanged: _reminder == ReminderState.blocked
                        ? null
                        : (v) => setState(
                              () => _reminder =
                                  v ? ReminderState.active : ReminderState.off,
                            ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoNote(
                        _reminderText,
                        key: const ValueKey('settings-reminder-note'),
                        tone: _reminder == ReminderState.blocked
                            ? warning
                            : textMuted,
                        icon: _reminder == ReminderState.blocked
                            ? Icons.notifications_off_outlined
                            : Icons.info_outline_rounded,
                      ),
                      if (_reminder == ReminderState.blocked &&
                          widget.onOpenSystemSettings != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            key: const ValueKey('settings-open-system-settings'),
                            onPressed: widget.onOpenSystemSettings,
                            icon: const Icon(Icons.settings_outlined, size: 17),
                            label: const Text(
                              'Systemeinstellungen öffnen',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: warning,
                              side: BorderSide(
                                color: warning.withValues(alpha: 0.45),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(rControl),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_hatFehler) ...[
                  const SizedBox(height: 12),
                  const _InfoNote(
                    'Bitte die rot markierten Felder korrigieren — solange sie '
                    'außerhalb des erlaubten Bereichs liegen, lässt sich nicht '
                    'speichern.',
                    key: ValueKey('settings-validation-note'),
                    tone: danger,
                    icon: Icons.error_outline_rounded,
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('settings-reset-day'),
                    // Auch dieser Weg schreibt das Profil — er muss an derselben
                    // Feldpruefung haengen wie „Speichern".
                    onPressed: _hatFehler ? null : () => _save(resetDay: true),
                    icon: const Icon(Icons.restart_alt_rounded, size: 17),
                    label: const Text(
                      'Tagesdaten zurücksetzen',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: orange,
                      disabledForegroundColor: textMuted,
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
                    onPressed: _hatFehler ? null : () => _save(resetDay: false),
                    icon: const Icon(Icons.check_rounded, size: 17),
                    label: const Text(
                      'Speichern',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: lime,
                      foregroundColor: bg,
                      disabledBackgroundColor: surfaceSoft,
                      disabledForegroundColor: textMuted,
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
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// D5: Verwerf-Rueckfrage + Drag-Guard
// ---------------------------------------------------------------------------

/// Der Griff des Sheets — bewusst hier statt an der Route gezeichnet.
///
/// Der Route-Griff (`showDragHandle: true`) liegt als Stack-Geschwister neben
/// dem `builder`-Kind und damit ausserhalb von [_DiscardDragGuard]; ein Zug
/// genau am Griff liefe an der Rueckfrage vorbei. Ziehbar bleibt er trotzdem:
/// solange der Guard inaktiv ist, greift der Drag-Detector der Route.
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return const ExcludeSemantics(
      child: Center(
        child: Padding(
          padding: EdgeInsets.only(top: 8, bottom: 14),
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: textMuted,
                borderRadius: BorderRadius.all(Radius.circular(rPill)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// „Aenderungen verwerfen?" — die gemeinsame Bestaetigung fuer JEDEN Weg, ein
/// ausgefuelltes Sheet zu schliessen.
///
/// `barrierDismissible: true` (Default) ist Absicht: ein Tap neben den Dialog
/// ist „Abbrechen", also die harmlose Antwort. Der Dialog liegt auf dem
/// Root-Navigator und damit UEBER der Sheet-Route — sein eigener Barrier
/// schluckt den Tap, das Sheet darunter sieht ihn nie.
///
/// **Doppelt vorhanden:** dieselbe Bestaetigung samt [_DiscardDragGuard] steht
/// in `edit_meal_sheet.dart` und `recipe_create_sheet.dart` (Letzteres ist ein
/// `part of` ohne eigene Imports). Die drei Kopien gehoeren zusammengefuehrt.
///
/// Rueckgabe: `true` = verwerfen, `false`/abgebrochen = offen lassen.
Future<bool> _confirmDiscardChanges(BuildContext context) async {
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: surface,
      title: const Text(
        'Änderungen verwerfen?',
        style: TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
      ),
      content: const Text(
        'Deine Eingaben in „Profil & Ziele" sind noch nicht gespeichert.',
        style: TextStyle(color: textMuted),
      ),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Weiter bearbeiten'),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Verwerfen'),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// Faengt das Nach-unten-Ziehen eines modalen Bottom-Sheets ab.
///
/// **Warum das noetig ist:** ein `PopScope` deckt nur die halbe Miete ab. Die
/// beiden Dismiss-Wege laufen im Framework verschieden:
///
///  * Barriere-Tap → `ModalBarrier.handleDismiss` → `Navigator.maybePop`
///    (`modal_barrier.dart:225-230`) — fragt die Pop-Disposition, also
///    `PopScope`.
///  * Ziehen → `BottomSheet._handleDragEnd` → `onClosing` → **`Navigator.pop`**
///    (`bottom_sheet.dart:769-771`) — fragt sie **nicht**. Ein `PopScope` sieht
///    diesen Weg nie. (Und `enableDrag: false` reicht auch nicht: solange die
///    Route den Griff zeichnet, traegt der Griff selbst einen Drag-Detector,
///    `bottom_sheet.dart:377`.)
///
/// Von innerhalb des Sheets gibt es dafuer genau einen Hebel: die Gesten-Arena.
/// Der `_BottomSheetGestureDetector` sitzt ueber dem `builder`-Kind; ein
/// eigener Vertikal-Drag-Erkenner IM Kind liegt tiefer und gewinnt die Arena —
/// dasselbe Prinzip, aus dem eine ScrollView im Sheet das Ziehen schluckt. Die
/// `SingleChildScrollView` dieses Sheets liegt wiederum tiefer als der Guard
/// und scrollt deshalb weiter normal.
///
/// Ist [active] false (nichts geaendert), wird gar kein Erkenner registriert —
/// das Sheet laesst sich dann wie gewohnt wegziehen.
///
/// **Doppelt vorhanden**, siehe [_confirmDiscardChanges].
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Mindeststrecke nach unten, ab der ein Zug als „zumachen" gilt. Bewusst
  /// klein: der Guard schluckt die Geste ohnehin, die Frage ist nur, ob der
  /// Nutzer dazu eine Antwort bekommt.
  static const double _closeIntentPx = 32;

  /// Flick-Schwelle, gespiegelt an `_kMinFlingVelocity` aus bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Ohne translucent bleiben Luecken zwischen den Kindern unbedeckt.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
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
    required this.targets,
    required this.manual,
  });

  final int kcal;
  final int protein;
  final int carbs;
  final int fat;
  final KcalTargets targets;
  final bool manual;

  /// Ob die Karte das gerechnete Ziel zeigt. Sobald der Nutzer eine eigene
  /// Zahl setzt, beschreibt [targets] nicht mehr das, was gross auf der Karte
  /// steht — Tempo und Hinweis muessen dann von der gezeigten Zahl kommen,
  /// sonst entsteht derselbe Widerspruch nur andersherum.
  bool get _zeigtRechnung => kcal == targets.kcal;

  /// Tempo aus der Zahl, die tatsaechlich auf der Karte steht.
  ///
  /// B2: Hier stand frueher `goal.paceLabel` — das *gewaehlte* Tempo. Fuer das
  /// Standardprofil ergab das „Erhaltung 1997 · −1 kg/Woche" direkt ueber
  /// „1200"; 1997 − 1200 = 797 kcal, also −0,72 kg/Woche. Die 1200er-Klemme
  /// greift fuer jeden sitzenden Nutzer mit einer Erhaltung unter ~2275 kcal.
  String get _paceLabel => _zeigtRechnung
      ? targets.effectivePaceLabel
      : paceLabelForWeeklyRateKg(
          (kcal - targets.maintenanceKcal) * 7 / kcalPerKgBodyMass,
        );

  /// Der fertige Erklaersatz der Sicherheitsklemme — nur wenn die Karte auch
  /// das gerechnete Ziel zeigt.
  String? get _paceWarning => _zeigtRechnung ? targets.paceWarning : null;

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
                      'Erhaltung ${targets.maintenanceKcal} · $_paceLabel',
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
          if (_paceWarning != null) ...[
            const SizedBox(height: 12),
            _InfoNote(
              _paceWarning!,
              key: const ValueKey('settings-pace-warning'),
              tone: warning,
              icon: Icons.health_and_safety_outlined,
            ),
          ],
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

  /// `null` = der Schalter ist gesperrt ([ReminderState.blocked]).
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // A11y: 0.8 skaliert nur die Optik; volle Tap-Flaeche bleibt. Eigenes
    // Semantics-Label fuer Screenreader.
    return Semantics(
      label: onChanged == null
          ? 'Lokale Erinnerungen — vom System blockiert'
          : 'Lokale Erinnerungen aktivieren',
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
  const _InfoNote(
    this.text, {
    super.key,
    this.tone = textMuted,
    this.icon = Icons.info_outline_rounded,
  });

  final String text;

  /// Farbe von Icon und Text. Standard ist der ruhige [textMuted]; [warning]
  /// und [danger] heben Hinweise heraus, die eine Handlung nach sich ziehen.
  final Color tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(
          color: tone == textMuted ? hairline : tone.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: tone,
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
    this.errorText,
    this.onChanged,
  });

  final String label;
  final String suffix;
  final TextEditingController controller;
  final Key keyValue;

  /// C1: Der erlaubte Bereich, sobald der getippte Wert ihn verlaesst. Der
  /// `digitsOnly`-Formatter filtert nur Zeichen — den Wertebereich pruefen
  /// muss dieses Feld.
  final String? errorText;
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
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        errorText: errorText,
        errorMaxLines: 2,
      ),
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
