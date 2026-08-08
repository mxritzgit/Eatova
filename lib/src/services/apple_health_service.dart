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
    this.sleepMinutes,
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

  /// Schlafminuten der letzten Nacht, falls vorhanden.
  final int? sleepMinutes;

  /// Positives LESE-Signal: irgendein Datum ist tatsaechlich angekommen.
  ///
  /// Bewusst eine Disjunktion ueber drei Quellen — ein einzelner Ruhetag mit
  /// 0 Schritten ist real, „0 Schritte UND kein Gewicht UND kein Schlaf" ist
  /// dagegen der Fingerabdruck eines fehlenden Lesezugriffs.
  bool get hasReadEvidence =>
      (steps ?? 0) > 0 || (latestWeightKg ?? 0) > 0 || (sleepMinutes ?? 0) > 0;
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
  /// kaschieren. Nur relevant fuer Nutzer, die WRITE nie freigegeben haben —
  /// mit WRITE == true gibt es ein dauerhaftes ehrliches Signal.
  final Duration evidenceTtl;

  DateTime? _lastReadEvidenceAt;
  bool _writeGrantSeen = false;
  HealthAuthState _state = HealthAuthState.unknown;

  HealthAuthState get state => _state;

  /// Wann zuletzt echte Health-Daten ankamen (null = noch nie in diesem Lauf).
  DateTime? get lastReadEvidenceAt => _lastReadEvidenceAt;

  /// Bewertet einen Zugriff. Die Reihenfolge der Regeln ist die Aussage:
  ///  1. echte Lesedaten schlagen alles,
  ///  2. wahrheitsgemaess erteiltes WRITE haelt die Verbindung am Leben,
  ///  3. ein wahrheitsgemaess ENTZOGENES WRITE ist der einzige harte Beweis
  ///     fuer [HealthAuthState.denied],
  ///  4. frische Evidenz traegt ueber Ruhetage,
  ///  5. sonst: [HealthAuthState.unverified] — wir wissen es schlicht nicht.
  HealthAuthState resolve(HealthAuthEvidence e, {required DateTime now}) {
    final write = e.writeGrant;
    if (write == true) _writeGrantSeen = true;

    // 1) Es kommen echte Daten an — damit ist der Lesepfad bewiesen, egal was
    //    das Sheet oder der Share-Status behaupten.
    if (e.hasReadEvidence) {
      _lastReadEvidenceAt = now;
      return _state = HealthAuthState.granted;
    }

    // 2) Kein Lesesignal, aber HealthKit bestaetigt den Schreibzugriff auf
    //    Gewicht. Der Nutzer hat also im Sheet etwas eingeschaltet — ein
    //    0-Schritte-Tag ist dann ein echter Ruhetag, kein Berechtigungsloch.
    if (write == true) return _state = HealthAuthState.granted;

    // 3) WRITE war schon einmal bestaetigt und ist jetzt weg: der Nutzer hat in
    //    den iOS-Einstellungen abgeschaltet. Das ist der einzige Pfad, auf dem
    //    `denied` auf iOS ueberhaupt wahrheitsgemaess entstehen kann — alte
    //    Evidenz verfaellt hier sofort.
    if (_writeGrantSeen && write == false) {
      _lastReadEvidenceAt = null;
      return _state = HealthAuthState.denied;
    }

    // 4) Ruhetags-Toleranz fuer Nur-Lesen-Nutzer: vor kurzem kamen Daten an,
    //    heute nicht — ein einzelner leerer Tag kippt die Verifikation nicht.
    final last = _lastReadEvidenceAt;
    if (last != null) {
      if (now.difference(last) <= evidenceTtl) {
        return _state = HealthAuthState.granted;
      }
      // TTL abgelaufen: die Evidenz verfaellt, der Zustand faellt zurueck.
      _lastReadEvidenceAt = null;
    }

    // 5) Nichts spricht fuer einen funktionierenden Zugriff. „Sheet lief durch"
    //    ist kein Beweis — also unverifiziert statt granted.
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
      lastSleepMinutes: e.sleepMinutes,
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
  AppleHealthService({HealthAuthVerifier? verifier})
      : _verifier = verifier ?? HealthAuthVerifier();

  final Health _health = Health();
  final HealthAuthVerifier _verifier;
  bool _configured = false;
  HealthAuthState _authState = HealthAuthState.unknown;

  // Typen + per-Typ-Permission laufen als PARALLELE Listen (package:health
  // erwartet permissions[i] passend zu types[i]) — ein Eintrag darf also nie
  // einzeln entfernt werden, sonst verrutscht die Autorisierung still.
  // Steps + Sleep sind READ-only, Gewicht ist READ_WRITE (Import vorbefuellen
  // + Write-Back nach dem Wiegen).
  //
  // WORKOUT ist bewusst NICHT mehr dabei: geschrieben haben wir nie ein
  // Workout (es gab und gibt keinen writeWorkout-Pfad), und seit dem Aus des
  // Training-Tabs (a267e15) kann es auch keinen mehr geben. Der HealthKit-
  // Dialog fragt damit keinen Scope mehr an, den die App nie nutzt.
  static const List<HealthDataType> _types = [
    HealthDataType.STEPS,
    HealthDataType.WEIGHT,
    HealthDataType.SLEEP_ASLEEP,
  ];
  static const List<HealthDataAccess> _permissions = [
    HealthDataAccess.READ,
    HealthDataAccess.READ_WRITE,
    HealthDataAccess.READ,
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
  /// Mit der bisherigen Liste (READ / READ_WRITE / READ) war das Ergebnis auf
  /// iOS dagegen IMMER `null`.
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

    int? sleepMinutes;
    try {
      final sleep = await _rawLastSleep(before: now);
      if (sleep != null) sleepMinutes = sleep.minutesAsleep;
    } catch (e, st) {
      _reportError('readSnapshot.sleep', e, st);
    }

    return HealthAuthEvidence(
      writeGrant: writeGrant,
      steps: steps,
      latestWeightKg: latestWeight,
      sleepMinutes: sleepMinutes,
    );
  }

  @override
  Future<HealthAuthState> requestAuthorization() async {
    // Defense-in-depth: HealthKit gibt es nur auf iOS. Die Auswahl Apple-vs-
    // Noop passiert zwar schon beim Aufbau, aber falls diese Instanz doch auf
    // einer anderen Plattform landet, no-op-pen wir hart statt zu crashen.
    if (!Platform.isIOS) return _adopt(HealthAuthState.unsupported);
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
        // (HealthKit nicht verfuegbar / Fehler) — kein Nutzer-Nein.
        return _adopt(HealthAuthState.denied);
      }

      // `sheetShown` beweist NUR, dass das Sheet fehlerfrei lief. Der Zustand
      // kommt aus echten Signalen, nicht aus Apples Optimismus.
      final now = DateTime.now();
      return _adopt(_verifier.resolve(await _gatherEvidence(now), now: now));
    } catch (e, st) {
      _reportError('requestAuthorization', e, st);
      return _adopt(HealthAuthState.unsupported);
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

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      return await _rawLastSleep(before: before);
    } catch (e, st) {
      _reportError('readLastSleep', e, st);
      return null;
    }
  }

  /// Ungegateter Lesepfad fuer Schlaf — siehe [_rawWeightSamples].
  Future<SleepSample?> _rawLastSleep({DateTime? before}) async {
    final to = before ?? DateTime.now();
    final from = to.subtract(const Duration(hours: 36));
    final points = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.SLEEP_ASLEEP],
      startTime: from,
      endTime: to,
    );
    if (points.isEmpty) return null;
    // Gruppiere alle "asleep"-Phasen, die zur letzten Nacht gehoeren: wir
    // nehmen das spaeteste End-Datum und summieren alle Phasen, deren Start
    // innerhalb von 18h davor liegt (ein zusammenhaengender Schlaf).
    points.sort((a, b) => a.dateTo.compareTo(b.dateTo));
    final lastEnd = points.last.dateTo;
    final windowStart = lastEnd.subtract(const Duration(hours: 18));
    var minutes = 0;
    for (final p in points) {
      if (p.dateFrom.isBefore(windowStart)) continue;
      minutes += p.dateTo.difference(p.dateFrom).inMinutes;
    }
    if (minutes <= 0) return null;
    return SleepSample(minutesAsleep: minutes, end: lastEnd);
  }
}
