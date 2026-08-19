import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:health/health.dart';

import 'crash_reporter.dart';
import 'health_service.dart';

/// Rohsignale eines HealthKit-Zugriffs — bewusst plugin-frei (nur Zahlen und
/// Bools), damit die Entscheidungslogik in [HealthAuthVerifier] ohne den
/// MethodChannel testbar bleibt.
class HealthAuthEvidence {
  const HealthAuthEvidence({
    required this.writeGrant,
    this.steps,
    this.latestWeightKg,
  });

  /// Wahrheitsgemaesser WRITE-Status fuer Gewicht.
  ///
  /// Einziges ehrliche Berechtigungssignal, das `health` 13.3.1 auf iOS
  /// durchreicht: `hasPermission(type:access:)`
  /// (`ios/Classes/HealthDataOperations.swift:91-105`) gibt fuer `case 0`
  /// (READ) und `default` (READ_WRITE) hart `nil` zurueck und nur fuer
  /// `case 1` (WRITE) `status == HKAuthorizationStatus.sharingAuthorized`.
  /// Apple obfuskiert bewusst nur den READ-Status; der Share-Status ist echt.
  ///
  /// `null` = unbekannt (Plugin/Plattform hat nichts geliefert).
  final bool? writeGrant;

  /// Heutige Schritte. `0` beweist NICHTS: `getTotalStepsInInterval`
  /// (`ios/Classes/HealthDataReader.swift:872-881`) summiert eine
  /// `HKStatisticsCollectionQuery` und liefert `Int(totalSteps)` — ohne
  /// Leseberechtigung eine leere Collection ohne Fehler, also 0, nie null.
  final int? steps;

  /// Juengstes gelesenes Gewicht (kg), falls vorhanden.
  final double? latestWeightKg;

  /// Positives LESE-Signal: irgendein Datum ist tatsaechlich angekommen.
  ///
  /// Bewusst eine Disjunktion ueber beide gelesenen Quellen — ein einzelner
  /// Ruhetag mit 0 Schritten ist real, „0 Schritte UND kein Gewicht" ist
  /// dagegen der Fingerabdruck eines fehlenden Lesezugriffs.
  ///
  /// Der Schlafwert war hier bis 2026-08-19 die dritte Quelle. Er ist raus,
  /// weil kein Feature ihn nutzt und der SLEEP-Scope deshalb gar nicht mehr
  /// angefragt wird (s. [AppleHealthService._types]) — ein Signal aus einem
  /// nie erteilten Scope waere dauerhaft null gewesen.
  bool get hasReadEvidence => (steps ?? 0) > 0 || (latestWeightKg ?? 0) > 0;
}

/// Leitet aus [HealthAuthEvidence] den [HealthAuthState] ab und haelt die
/// „Klebrigkeit" der Verifikation (Ruhetags-Toleranz + Verfall).
///
/// Warum ueberhaupt: Apples `requestAuthorization(toShare:read:)` meldet
/// `success == true`, sobald das Sheet fehlerfrei ANGEZEIGT wurde — das Plugin
/// reicht genau diesen Bool durch (`HealthDataOperations.swift:180-185`). Ein
/// Nutzer, der „Erlauben" tippt, ohne einen Schalter umzulegen, sieht damit ein
/// gruenes „Synchronisiert", waehrend dauerhaft 0 Schritte in `burnedKcal` und
/// `adjustedGoal` laufen.
class HealthAuthVerifier {
  HealthAuthVerifier({this.evidenceTtl = const Duration(days: 3)});

  /// Wie lange eine einmal gesehene Lese-Evidenz ohne neue Evidenz weiter
  /// traegt. Deckt Ruhetage/Urlaub ab, ohne einen echten Entzug ewig zu
  /// kaschieren. Gilt fuer ALLE Nutzer, auch fuer die mit erteiltem WRITE:
  /// der Share-Status sagt nichts ueber den Lesepfad, ein nachtraeglich
  /// entzogener Lesezugriff darf nicht am Schreib-Schalter haengenbleiben.
  final Duration evidenceTtl;

  DateTime? _lastReadEvidenceAt;
  bool _writeGrantSeen = false;
  HealthAuthState _state = HealthAuthState.unknown;

  HealthAuthState get state => _state;

  /// Wann zuletzt echte Health-Daten ankamen (null = noch nie in diesem Lauf).
  DateTime? get lastReadEvidenceAt => _lastReadEvidenceAt;

  /// Bewertet einen Zugriff. Die Reihenfolge der Regeln ist die Aussage:
  ///  1. echte Lesedaten schlagen alles,
  ///  2. ein wahrheitsgemaess ENTZOGENES WRITE ist der einzige harte Beweis
  ///     fuer [HealthAuthState.denied],
  ///  3. frische Evidenz traegt ueber Ruhetage,
  ///  4. sonst: [HealthAuthState.unverified] — wir wissen es schlicht nicht.
  ///
  /// Was hier bewusst NICHT (mehr) steht: „WRITE ist erteilt" allein ergibt
  /// kein [HealthAuthState.granted]. Das HealthKit-Sheet fuehrt Schreiben und
  /// Lesen als zwei unabhaengige Abschnitte — wer nur den Gewichts-Schreib-
  /// schalter umlegt, hat zum Lesen nichts freigegeben und bekaeme sonst
  /// dauerhaft 0 Schritte unter einem gruenen „Synchronisiert". Der
  /// Schreibpfad haengt nicht daran: `writeWeight` gated am Share-Status
  /// selbst, nicht am hier abgeleiteten Gesamtzustand.
  HealthAuthState resolve(HealthAuthEvidence e, {required DateTime now}) {
    final write = e.writeGrant;
    if (write == true) _writeGrantSeen = true;

    // 1) Es kommen echte Daten an — damit ist der Lesepfad bewiesen, egal was
    //    das Sheet oder der Share-Status behaupten.
    if (e.hasReadEvidence) {
      _lastReadEvidenceAt = now;
      return _state = HealthAuthState.granted;
    }

    // 2) WRITE war schon einmal bestaetigt und ist jetzt weg: der Nutzer hat in
    //    den iOS-Einstellungen abgeschaltet. Das ist der einzige Pfad, auf dem
    //    `denied` auf iOS ueberhaupt wahrheitsgemaess entstehen kann — alte
    //    Evidenz verfaellt hier sofort.
    if (_writeGrantSeen && write == false) {
      _lastReadEvidenceAt = null;
      return _state = HealthAuthState.denied;
    }

    // 3) Ruhetags-Toleranz: vor kurzem kamen Daten an, heute nicht — ein
    //    einzelner leerer Tag kippt die Verifikation nicht. Bewusst OHNE
    //    Sonderweg fuer WRITE == true: sonst haelt ein Nutzer, der spaeter nur
    //    den Lesezugriff entzieht, den granted-Zustand mit dem verbliebenen
    //    Schreib-Schalter unbegrenzt am Leben.
    final last = _lastReadEvidenceAt;
    if (last != null) {
      if (now.difference(last) <= evidenceTtl) {
        return _state = HealthAuthState.granted;
      }
      // TTL abgelaufen: die Evidenz verfaellt, der Zustand faellt zurueck.
      _lastReadEvidenceAt = null;
    }

    // 4) Nichts spricht fuer einen funktionierenden Zugriff. „Sheet lief durch"
    //    ist kein Beweis, eine reine Schreib-Freigabe genauso wenig — also
    //    unverifiziert statt granted.
    return _state = HealthAuthState.unverified;
  }

  /// Bewertet [e] und baut daraus NUR dann einen Snapshot, wenn der Zustand
  /// verifiziert ist. Der Null-Fall ist der Kern des Fixes: ein unverifizierter
  /// Zugriff darf nie `stepsToday: 0` liefern, sonst rechnet der Food-Tab
  /// `burnedKcal = 0` und `adjustedGoal = goal + 0` — dauerhaft und still.
  HealthSnapshot? verifiedSnapshot(
    HealthAuthEvidence e, {
    required DateTime now,
  }) {
    if (resolve(e, now: now) != HealthAuthState.granted) return null;
    return HealthSnapshot(
      stepsToday: e.steps ?? 0,
      fetchedAt: now,
      latestWeightKg: e.latestWeightKg,
    );
  }

  /// Setzt die Verifikation zurueck (z. B. Logout / Kontowechsel).
  void reset() {
    _lastReadEvidenceAt = null;
    _writeGrantSeen = false;
    _state = HealthAuthState.unknown;
  }
}

class AppleHealthService implements HealthService {
  /// [health] und [debugIsIOS] sind Test-Naehte: das Plugin haengt sonst am
  /// MethodChannel und der Plattform-Gate am Test-Runner-OS — die
  /// Fehlerzweige von [requestAuthorization] waeren unpruefbar (und genau
  /// dort sass der Sentinel, s. test/services/apple_health_request_auth_test).
  AppleHealthService({
    HealthAuthVerifier? verifier,
    Health? health,
    bool? debugIsIOS,
  })  : _verifier = verifier ?? HealthAuthVerifier(),
        _health = health ?? Health(),
        _isIOS = debugIsIOS ?? Platform.isIOS;

  final Health _health;
  final bool _isIOS;
  final HealthAuthVerifier _verifier;
  bool _configured = false;
  HealthAuthState _authState = HealthAuthState.unknown;

  // Typen + per-Typ-Permission laufen als PARALLELE Listen (package:health
  // erwartet permissions[i] passend zu types[i]) — ein Eintrag darf also nie
  // einzeln entfernt werden, sonst verrutscht die Autorisierung still.
  // Steps sind READ-only, Gewicht ist READ_WRITE (Import vorbefuellen
  // + Write-Back nach dem Wiegen).
  //
  // Die Liste ist die Anspruchsgrundlage fuer den Zwecktext in
  // `ios/Runner/Info.plist` (NSHealthShareUsageDescription /
  // NSHealthUpdateUsageDescription). Wer hier einen Scope ergaenzt, muss dort
  // nachziehen UND ein Feature vorweisen koennen, das ihn benutzt — Apple
  // lehnt im Review sowohl Scopes ohne sichtbaren Nutzen als auch Zwecktexte
  // ab, die mehr versprechen als die App tut (Guideline 5.1.1).
  //
  // WORKOUT ist bewusst NICHT dabei: geschrieben haben wir nie ein Workout
  // (es gab und gibt keinen writeWorkout-Pfad), und seit dem Aus des
  // Training-Tabs (a267e15) kann es auch keinen mehr geben.
  //
  // SLEEP_ASLEEP ist seit 2026-08-19 aus demselben Grund raus: der Wert wurde
  // gelesen, floss aber in kein einziges Feature — weder Food-Tab noch Trends
  // noch Coach lesen `HealthSnapshot.lastSleepMinutes`. Das Schlafziel in den
  // Einstellungen (`profiles.daily_sleep_goal_minutes`) ist ein reiner
  // Profilwert und hat mit HealthKit nichts zu tun.
  static const List<HealthDataType> _types = [
    HealthDataType.STEPS,
    HealthDataType.WEIGHT,
  ];
  static const List<HealthDataAccess> _permissions = [
    HealthDataAccess.READ,
    HealthDataAccess.READ_WRITE,
  ];

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// HealthKit-Fehler bleiben fuer den USER weiterhin still (die Aufrufer
  /// liefern Fallback-Werte), gehen aber an dev.log + CrashReporter, statt
  /// spurlos zu verschwinden (Muster wie home_store._reportSyncError).
  static void _reportError(String operation, Object e, StackTrace st) {
    dev.log(
      'health.$operation failed',
      error: e,
      stackTrace: st,
      name: 'health',
    );
    unawaited(CrashReporter.capture(e, st, context: 'health.$operation'));
  }

  @override
  HealthAuthState get authState => _authState;

  /// Uebernimmt einen frisch abgeleiteten Zustand in den Cache und gibt ihn
  /// zurueck. Einziger Schreibpfad auf [_authState].
  HealthAuthState _adopt(HealthAuthState state) => _authState = state;

  /// Beide ueberlebenden Zustaende raeumen — der Verifier UND der Cache.
  /// `refreshHealthSteps` liest [authState], ein reiner Verifier-Reset bliebe
  /// also unsichtbar und Nutzer B saehe weiter As „Synchronisiert".
  ///
  /// [HealthAuthState.unknown], nicht `denied`: wir wissen ueber den naechsten
  /// Nutzer nichts. Der erste Refresh verifiziert ohnehin neu.
  @override
  void reset() {
    _verifier.reset();
    _adopt(HealthAuthState.unknown);
  }

  /// Fragt den EINZIGEN wahrheitsgemaessen Berechtigungs-Bool ab, den das
  /// Plugin auf iOS durchreicht: den Share-Status fuer Gewicht.
  ///
  /// `hasPermissions` mappt `HealthDataAccess.index` 1:1 auf den nativen
  /// `access`-Int (`lib/src/health_plugin.dart:112-133`), und
  /// `HealthDataAccess { READ, WRITE, READ_WRITE }` gibt WRITE den Index 1 —
  /// genau den `case 1`, der nativ `status == .sharingAuthorized` liefert.
  /// Mit der vollen Typenliste (READ / READ_WRITE) war das Ergebnis auf iOS
  /// dagegen IMMER `null`.
  Future<bool?> _readWriteGrant() async {
    try {
      return await _health.hasPermissions(
        const [HealthDataType.WEIGHT],
        permissions: const [HealthDataAccess.WRITE],
      );
    } catch (e, st) {
      _reportError('writeGrant', e, st);
      return null;
    }
  }

  /// Sammelt alle Signale eines Zugriffs in einem Rutsch. Bewusst OHNE
  /// Auth-Gate: die Signale sind ja gerade das, woraus der Auth-Zustand
  /// abgeleitet wird — ein Gate waere zirkulaer.
  Future<HealthAuthEvidence> _gatherEvidence(DateTime now) async {
    final writeGrant = await _readWriteGrant();

    int? steps;
    try {
      final startOfDay = DateTime(now.year, now.month, now.day);
      steps = await _health.getTotalStepsInInterval(startOfDay, now);
    } catch (e, st) {
      _reportError('readSteps', e, st);
    }

    double? latestWeight;
    try {
      final weights = await _rawWeightSamples(
        from: now.subtract(const Duration(days: 90)),
        to: now,
      );
      if (weights.isNotEmpty) latestWeight = weights.last.kg;
    } catch (e, st) {
      _reportError('readSnapshot.weight', e, st);
    }

    return HealthAuthEvidence(
      writeGrant: writeGrant,
      steps: steps,
      latestWeightKg: latestWeight,
    );
  }

  @override
  Future<HealthAuthState> requestAuthorization() async {
    // Defense-in-depth: HealthKit gibt es nur auf iOS. Die Auswahl Apple-vs-
    // Noop passiert zwar schon beim Aufbau, aber falls diese Instanz doch auf
    // einer anderen Plattform landet, no-op-pen wir hart statt zu crashen.
    if (!_isIOS) return _adopt(HealthAuthState.unsupported);
    try {
      await _ensureConfigured();

      // hasPermissions ueber die volle Typenliste ist auf iOS nutzlos (READ und
      // READ_WRITE liefern nativ `nil`), also fragen wir immer an. Das ist
      // gefahrlos: HealthKit zeigt das Sheet nur beim ersten Mal, danach ist
      // der Aufruf ein stiller No-op — und genau deshalb taugt er als
      // „Pruefen"-Aktion, nachdem der Nutzer in den Einstellungen war.
      final sheetShown = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      if (!sheetShown) {
        // Apples `success == false` heisst: die Anfrage selbst ist gescheitert
        // (HealthKit nicht verfuegbar / Fehler) — kein Nutzer-Nein. Frueher
        // wurde hier `denied` uebernommen, und die Karte schickte den Nutzer
        // mit „Zugriff entzogen — wieder freigeben" in Einstellungen, in
        // denen nichts zu finden ist. Ein Fehler ist keine Antwort: unknown.
        return _adopt(HealthAuthState.unknown);
      }

      // `sheetShown` beweist NUR, dass das Sheet fehlerfrei lief. Der Zustand
      // kommt aus echten Signalen, nicht aus Apples Optimismus.
      final now = DateTime.now();
      return _adopt(_verifier.resolve(await _gatherEvidence(now), now: now));
    } catch (e, st) {
      _reportError('requestAuthorization', e, st);
      // Sentinel-Rest, Cluster B: hier stand `unsupported` — eine positive
      // Geraete-Behauptung aus einem Fehler, und die Health-Karte versteckt
      // bei `unsupported` den Verbinden-Button („Auf diesem Geraet nicht
      // aktiv"): Sackgasse bis zum App-Neustart. `unsupported` ist dem
      // echten Plattform-Fakt oben vorbehalten; ein Fehler ist `unknown`,
      // der Verbinden-Weg bleibt offen, der Grund steht im CrashReporter.
      return _adopt(HealthAuthState.unknown);
    }
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      final now = DateTime.now();
      // Verifiziert bei JEDEM Refresh neu — kein „einmal granted, fuer immer
      // granted"-Cache mehr. Nicht verifiziert => null, damit der Store
      // dailySteps/healthLastFetch gar nicht erst auf einen Scheinwert setzt.
      final snap =
          _verifier.verifiedSnapshot(await _gatherEvidence(now), now: now);
      _adopt(_verifier.state);
      return snap;
    } catch (e, st) {
      _reportError('readSnapshot', e, st);
      return null;
    }
  }

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      final start = DateTime(day.year, day.month, day.day);
      // Kalenderarithmetik statt Duration(days: 1): ueber eine DST-Kante ist
      // der Tag nicht 24 h lang (Begruendung: durationUntilNextLocalMidnight
      // in home_store.dart). Dart normalisiert den Tages-Ueberlauf selbst.
      var end = DateTime(day.year, day.month, day.day + 1);
      final now = DateTime.now();
      if (!start.isBefore(now)) return null;
      if (end.isAfter(now)) end = now;
      final steps = await _health.getTotalStepsInInterval(start, end);
      // 0 beweist nichts (s. HealthAuthEvidence.steps): ohne Leseberechtigung
      // kommt eine leere Summe zurueck, nie ein Fehler. Nur positive Werte
      // duerfen als Tageswert gespeichert werden.
      return (steps ?? 0) > 0 ? steps : null;
    } catch (e, st) {
      _reportError('readStepsOnDay', e, st);
      return null;
    }
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async {
    if (!Platform.isIOS) return false;
    if (kg <= 0) return false;
    try {
      await _ensureConfigured();
      // Gate am wahrheitsgemaessen Share-Status statt am (moeglicherweise
      // unverifizierten) Gesamtzustand: wer nur WRITE freigegeben hat, darf
      // schreiben, auch wenn der Lesepfad nichts liefert.
      if (await _readWriteGrant() == false) return false;
      return await _health.writeHealthData(
        value: kg,
        type: HealthDataType.WEIGHT,
        startTime: when,
        endTime: when,
        recordingMethod: RecordingMethod.manual,
      );
    } catch (e, st) {
      _reportError('writeWeight', e, st);
      return false;
    }
  }

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!Platform.isIOS) return const <WeightSample>[];
    try {
      await _ensureConfigured();
      return await _rawWeightSamples(from: from, to: to);
    } catch (e, st) {
      _reportError('readWeightSamples', e, st);
      return const <WeightSample>[];
    }
  }

  /// Ungegateter Lesepfad fuer Gewicht — Basis von [readWeightSamples] UND von
  /// [_gatherEvidence] (dort waere ein Auth-Gate zirkulaer).
  Future<List<WeightSample>> _rawWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async {
    final points = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.WEIGHT],
      startTime: from,
      endTime: to,
    );
    final samples = <WeightSample>[];
    for (final p in points) {
      final v = p.value;
      if (v is NumericHealthValue) {
        samples.add(
          WeightSample(kg: v.numericValue.toDouble(), measuredAt: p.dateTo),
        );
      }
    }
    samples.sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
    return samples;
  }

  /// Immer `null`: Der SLEEP-Scope wird seit 2026-08-19 nicht mehr angefragt
  /// (s. [_types]), also gaebe eine HealthKit-Abfrage hier ohnehin nur eine
  /// leere Antwort — und ein Lesezugriff auf einen nie erteilten Scope hat in
  /// einer App nichts zu suchen, die Apple genau darauf prueft.
  ///
  /// Die Methode bleibt vorerst am Interface, weil sie in mehreren
  /// HealthService-Fakes der Testsuite ueberschrieben wird; ihr Abbau samt
  /// [SleepSample] und `HealthSnapshot.lastSleepMinutes` gehoert in einen
  /// eigenen Schritt.
  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}
