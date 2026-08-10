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

/// Die Einstellungen — seit dem Design-Refactor 2026-08-09 eine volle Seite
/// statt eines modalen BottomSheets.
///
/// Der Grund ist nicht Geschmack: das Sheet trug ~20 Einstellungen in sechs
/// Gruppen, mehrere Picker-Sheets zweiter Ebene und einen eigenen Drag-Guard
/// gegen versehentliches Verwerfen. Als Route entfaellt der Drag-Guard (ein
/// [PopScope] deckt Zurueck-Knopf und Systemzurueck vollstaendig ab), die
/// zweite Sheet-Ebene wird zur normalen Navigation, und die Gruppen bekommen
/// den Platz, den sie brauchen.
///
/// Rueckgabe per [Navigator.pop] ist ein [SettingsResult] (oder null bei
/// Abbruch) — identisch zum bisherigen Sheet, damit die Schale unveraendert
/// `applySettings` aufrufen kann.
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({
    super.key,
    required this.profile,
    this.notificationsEnabled = false,
    this.reminderState,
    this.onOpenSystemSettings,
  });

  final UserProfile profile;

  /// Aufrufer, die den vollen Zustand nicht kennen, uebergeben weiterhin nur
  /// dieses Flag; daraus wird [ReminderState.off] bzw. [ReminderState.active]
  /// — „vom System blockiert" laesst sich so allerdings nie anzeigen.
  final bool notificationsEnabled;

  final ReminderState? reminderState;

  /// Der Weg in die System-Benachrichtigungseinstellungen. Fehlt er, zeigt der
  /// blockierte Zustand nur den Hinweistext und KEINEN Knopf: ein Knopf, der
  /// nichts oeffnet, waere dieselbe Sorte Luege wie der Schalter, der D11
  /// ausgeloest hat. Das Projekt hat aktuell keinen solchen Weg —
  /// `url_launcher` startet auf Android ausschliesslich ACTION_VIEW-Intents
  /// und erreicht `Settings.ACTION_APP_NOTIFICATION_SETTINGS` damit nicht.
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
    _water = TextEditingController(text: p.dailyWaterGoalMl.toString());
    _protein = TextEditingController(text: p.proteinGoalG.toString());
    _carbs = TextEditingController(text: p.carbsGoalG.toString());
    _fat = TextEditingController(text: p.fatGoalG.toString());
    _targetWeight = TextEditingController(text: p.targetWeightKg.toString());
    _sex = p.sex;
    _activity = p.activityLevel;
    _sleepGoalMinutes = p.dailySleepGoalMinutes;
    _goal = p.weightGoal;

    // Der Manuell-Schalter wird NICHT persistiert, sondern hier aus dem
    // Vergleich Profil ↔ Rechner rekonstruiert.
    final computed = const KcalCalculator().calculate(p);
    _manualEnergy = p.dailyKcalGoal != computed.kcal ||
        p.proteinGoalG != computed.proteinG ||
        p.carbsGoalG != computed.carbsG ||
        p.fatGoalG != computed.fatG;
    _manualStart = _manualEnergy;
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

  // Alle sechs `_bereichXxx`-Getter interpolieren ihre Zahlen weiterhin aus
  // [ProfileLimits] (bewusst so, NICHT literalisieren — s. Klassendoku) —
  // seit der i18n-Migration (Paket 6) ueber ARB-Keys mit {min}/{max}-
  // Platzhaltern statt `static const String`, damit sie `context.l10n`
  // erreichen. `settings_validation_test.dart` bleibt unter `de` byte-gleich.
  String get _bereichKg => context.l10n
      .settingsRangeErrorKg(ProfileLimits.weightKgMin, ProfileLimits.weightKgMax);
  String get _bereichCm => context.l10n
      .settingsRangeErrorCm(ProfileLimits.heightCmMin, ProfileLimits.heightCmMax);
  String get _bereichAlter => context.l10n.settingsRangeErrorYears(
      ProfileLimits.ageYearsMin, ProfileLimits.ageYearsMax);
  String get _bereichSchritte => context.l10n.settingsRangeErrorSteps(
      ProfileLimits.dailyStepsGoalMin, ProfileLimits.dailyStepsGoalMax);
  String get _bereichWasser => context.l10n.settingsRangeErrorMl(
      ProfileLimits.dailyWaterGoalMlMin, ProfileLimits.dailyWaterGoalMlMax);
  String get _bereichKcal => context.l10n.settingsRangeErrorKcal(
      ProfileLimits.dailyKcalGoalMin, ProfileLimits.dailyKcalGoalMax);
  String get _bereichProtein => context.l10n.settingsRangeErrorGrams(
      ProfileLimits.proteinGoalGMin, ProfileLimits.proteinGoalGMax);
  String get _bereichCarbs => context.l10n.settingsRangeErrorGrams(
      ProfileLimits.carbsGoalGMin, ProfileLimits.carbsGoalGMax);
  String get _bereichFett => context.l10n
      .settingsRangeErrorGrams(ProfileLimits.fatGoalGMin, ProfileLimits.fatGoalGMax);

  /// Fehlertext des Feldes oder `null`, wenn der Wert so in die DB darf.
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
        if (_manualEnergy) ...<String?>[
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
    final p = widget.profile;
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

  // --- Tempo: Auswahl vs. Plan (B2) ----------------------------------------
  //
  // Die Plan-Karte zeigt das effektive Tempo („−0,72 kg/Woche"). Eine Gruppe
  // weiter unten stand im selben Scroll das versprochene („−1 kg/Woche") —
  // derselbe Widerspruch, nur verschoben. Die Regel: **Steht auf einem
  // Bildschirm mehr als eine Tempo-Zeichenkette, muss eine dritte sie
  // verbinden.** Die Auswahl bleibt oben, die Folge steht darunter.

  /// Untertitel einer Option im Gewichtsziel-Picker: der Plan, den sie mit den
  /// Koerperdaten ergibt, die gerade auf der Seite stehen.
  ///
  /// Im Manuell-Modus haengt das Tagesziel nicht mehr am Tempo — dann waere
  /// jede gerechnete Zahl eine Behauptung ueber etwas, das der Schalter gerade
  /// abgeschaltet hat.
  String _zielFolge(WeightGoal option) {
    if (_manualEnergy) return context.l10n.goalsManualNoChangeHint;
    final t = const KcalCalculator()
        .calculate(_draftForCalc().copyWith(weightGoal: option));
    return context.l10n.commonKcalOutcomeLabel(t.kcal, t.effectivePaceLabel);
  }

  /// Die Zeile unter der Gewichtsziel-Zeile — `null`, solange dort dieselbe
  /// Tempo-Beschriftung steht wie auf der Plan-Karte.
  ///
  /// Verglichen werden bewusst die **Zeichenketten**, nicht die Zahlen: der
  /// Nutzer sieht Text, und genau dann, wenn zwei verschiedene Texte auf dem
  /// Bildschirm stehen, braucht es die Erklaerung.
  String? _zielAbweichung({required int tagesziel, required KcalTargets t}) {
    final label = paceLabelForWeeklyRateKg(
      wochenrateKg(tagesziel: tagesziel, erhaltung: t.maintenanceKcal),
    );
    if (label == _goal.paceLabel) return null;
    return context.l10n.commonKcalOutcomeLabel(tagesziel, label);
  }

  UserProfile _buildProfile() {
    final p = widget.profile;
    final t = _liveTargets;
    // copyWith erhält Felder die der Screen nicht anfasst — v.a.
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

  /// Hat der Nutzer irgendetwas angefasst? Zehn Zahlenfelder, vier Auswahl-
  /// felder und zwei Schalter — nichts davon darf kommentarlos verschwinden.
  ///
  /// Der Anzeige-Modus stand hier frueher mit in der Liste. Er ist seit
  /// 2026-08-10 in den Einstellungen zuhause ([SettingsScreen]) — als
  /// Geraeteeinstellung wird er sofort persistiert und liesse sich ohnehin
  /// nicht verwerfen.
  bool get _dirty {
    final p = widget.profile;
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

  /// Laeuft fuer JEDEN abgefangenen Schliess-Versuch — Zurueck-Knopf und
  /// Systemzurueck laufen beide ueber [Navigator.maybePop] und damit durch das
  /// [PopScope]. Mehrfach-Versuche stapeln keine Dialoge.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(context);
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Der Dialog ist hier bereits gepoppt — oberste Route ist wieder die
    // Seite. Bewusst ohne Ergebnis: verworfen ist nicht gespeichert.
    Navigator.of(context).pop();
  }

  /// Text zum aktuellen Erinnerungs-Zustand (D11). Drei Zustaende, drei Saetze
  /// — „blockiert" ist ausdruecklich kein Fehler, sondern eine Systemeinstellung.
  String get _reminderText => switch (_reminder) {
        ReminderState.off => context.l10n.goalsReminderTextOff,
        ReminderState.active => context.l10n.goalsReminderTextActive,
        ReminderState.blocked => context.l10n.goalsReminderTextBlocked,
      };

  /// Bei Live-Modus die Energie-Felder mit der frischen Berechnung füllen,
  /// damit die Seite konsistent bleibt; danach neu zeichnen.
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
        // D11: nur „aktiv" heisst, dass abends wirklich etwas kommt.
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

  Future<void> _pickSleepGoal() async {
    final gewaehlt = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _sleepGoalMinutes ~/ 60,
        minute: _sleepGoalMinutes % 60,
      ),
      helpText: context.l10n.goalsFieldSleep,
    );
    if (gewaehlt == null || !mounted) return;
    // Der Time-Picker laesst 0:00 bis 23:59 zu, `daily_sleep_goal_minutes` nur
    // 180..900. Hier wird geklemmt statt abgelehnt — der Wert kommt aus einem
    // Picker, und die Zeile zeigt anschliessend genau den Wert, der
    // gespeichert wird (sichtbar, nicht still).
    setState(
      () => _sleepGoalMinutes =
          clampDailySleepGoalMinutes(gewaehlt.hour * 60 + gewaehlt.minute),
    );
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
      // D5: Zurueck-Knopf und Systemzurueck laufen beide ueber
      // Navigator.maybePop und fragen damit die Pop-Disposition. Der
      // Drag-Guard des alten Sheets hat als Route kein Gegenstueck mehr — eine
      // Route kennt weder Barriere noch Wegwisch-Geste.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      // Dieselbe Datenklasse wie das Profil (Gewicht, Groesse, Alter,
      // Wunschgewicht) — also derselbe Screenshot-/Recents-Schutz.
      child: SecureScreenGuard(
        child: Scaffold(
          key: const ValueKey('screen-goals'),
          body: SafeArea(
            // Auch unten: diese Route traegt KEINE Navigationsleiste, die den
            // Seitenfuss sonst von der Gestenleiste des Systems freihielte —
            // ohne das lägen „Speichern" und die Rechts-Links am Scroll-Ende
            // unter dem Balken. (Der Profil-Screen macht es genauso.)
            // Bewusst KEINE ListView: die Tests lesen „Speichern" und die
            // Fusszeile, bevor irgendwer scrollt. Eine Lazy-Liste baut beides
            // gar nicht erst.
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
                  // Hier stand bis 2026-08-10 der Knopf `settings-reset-day`
                  // („Tagesdaten zurücksetzen"). Er ist auf Nutzer-Entscheid
                  // ersatzlos entfallen — mit ihm das Feld
                  // `SettingsResult.resetDay`, `HomeStore.resetTodayData` und
                  // der Reset-Zweig in `applySettings`. Der Seitenfuss traegt
                  // damit nur noch „Speichern" und die Rechts-Links.
                  Semantics(
                    // [PrimaryActionButton] ist ein blankes InkWell und traegt
                    // weder `isButton` noch einen Enabled-Zustand — der
                    // FilledButton des alten Sheets tat beides. Ohne diese
                    // Huelle klaenge das gesperrte „Speichern" fuer einen
                    // Screenreader wie ein normaler Knopf, der nichts tut.
                    // (Gehoert eigentlich in die Bibliothek, siehe Bericht.)
                    button: true,
                    enabled: !_hatFehler,
                    child: Opacity(
                      // PrimaryActionButton kann „gesperrt" selbst nicht
                      // ausdruecken; dieselbe Loesung wie SheetScaffold.
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

  // --- Gruppen --------------------------------------------------------------

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
    // Sanfter, nicht blockierender BMI-Hinweis — gleiche Grenze wie im
    // Onboarding-Zielschritt (unter 18,5 / über 35). Die Sichtbarkeit wird
    // hier entschieden, damit SettingsGroup keine Trennlinie um ein leeres
    // Kind zieht.
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
            value: '${_activity.label(l10n)} · ×${_activity.palFactor}',
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
          // Zeile und Zusatzzeile sind EIN Gruppenkind — sonst zoege
          // SettingsGroup eine Trennlinie zwischen die Zeile und ihre eigene
          // Fussnote.
          Column(
            children: <Widget>[
              SettingsRow(
                key: const ValueKey('settings-weight-goal'),
                title: l10n.goalsFieldWeightGoal,
                subtitle: _goal.label(l10n),
                // Bleibt das GEWAEHLTE Tempo: die Zeile muss zeigen, was der
                // Nutzer getippt hat. Was daraus wird, steht darunter.
                value: _goal.paceLabel,
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

  List<Widget> _tageszieleGruppe() {
    final l10n = context.l10n;
    final stunden = _sleepGoalMinutes ~/ 60;
    final rest = _sleepGoalMinutes % 60;
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
          SettingsNumberRow(
            label: l10n.goalsFieldWater,
            suffix: l10n.commonUnitMl,
            controller: _water,
            fieldKey: const ValueKey('settings-water'),
            errorText: _waterError,
            onChanged: (_) => setState(() {}),
          ),
          SettingsRow(
            key: const ValueKey('settings-sleep-goal'),
            title: l10n.goalsFieldSleep,
            value: l10n.goalsSleepGoalValue(
              stunden,
              rest.toString().padLeft(2, '0'),
            ),
            onTap: _pickSleepGoal,
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
            trailing: AppToggle(
              key: const ValueKey('settings-notifications'),
              value: _reminder == ReminderState.active,
              // D11: im blockierten Zustand NICHT erneut umlegen lassen. Auf
              // Android 13+ zeigt das System nach zwei Ablehnungen gar
              // keinen Dialog mehr — der Schalter spraenge sofort zurueck
              // und die App saehe wieder aus, als laege es an ihr.
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
// D5: Verwerf-Rueckfrage
// ---------------------------------------------------------------------------

/// „Aenderungen verwerfen?" — die gemeinsame Bestaetigung fuer jeden Weg, eine
/// ausgefuellte Seite zu verlassen.
///
/// `barrierDismissible: true` (Default) ist Absicht: ein Tap neben den Dialog
/// ist „Abbrechen", also die harmlose Antwort.
///
/// **Mehrfach vorhanden:** dieselbe Bestaetigung steht in
/// `edit_meal_sheet.dart` und `recipe_create_sheet.dart` (dort jeweils noch
/// mit `_DiscardDragGuard`, weil beide Sheets geblieben sind). Die Kopien
/// gehoeren in die gemeinsame Bibliothek zusammengefuehrt — das geht nur
/// paketuebergreifend.
///
/// Rueckgabe: `true` = verwerfen, `false`/abgebrochen = offen lassen.
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
