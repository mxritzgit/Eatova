import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:health/health.dart';

import 'crash_reporter.dart';
import 'health_service.dart';

class AppleHealthService implements HealthService {
  AppleHealthService();

  final Health _health = Health();
  HealthAuthState _authState = HealthAuthState.unknown;
  bool _configured = false;

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

  @override
  Future<HealthAuthState> requestAuthorization() async {
    // Defense-in-depth: HealthKit gibt es nur auf iOS. Die Auswahl Apple-vs-
    // Noop passiert zwar schon beim Aufbau, aber falls diese Instanz doch auf
    // einer anderen Plattform landet, no-op-pen wir hart statt zu crashen.
    if (!Platform.isIOS) {
      _authState = HealthAuthState.unsupported;
      return _authState;
    }
    try {
      await _ensureConfigured();
      final hasPermissions =
          await _health.hasPermissions(_types, permissions: _permissions) ??
          false;
      if (hasPermissions) {
        _authState = HealthAuthState.granted;
        return _authState;
      }
      // Fragt READ + WRITE in einem einzigen HealthKit-Dialog an, damit der
      // Write-Back-Pfad direkt nach dem Connect verfuegbar ist.
      final granted = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      _authState = granted ? HealthAuthState.granted : HealthAuthState.denied;
      return _authState;
    } catch (e, st) {
      _reportError('requestAuthorization', e, st);
      _authState = HealthAuthState.unsupported;
      return _authState;
    }
  }

  /// Verifiziert lazy, dass wir (noch) autorisiert sind. Gibt true zurueck wenn
  /// HealthKit Schreib-/Lese-Zugriff bestaetigt; cached den State.
  Future<bool> _ensureAuthorized() async {
    if (_authState == HealthAuthState.granted) return true;
    final hasPermissions =
        await _health.hasPermissions(_types, permissions: _permissions) ??
        false;
    if (!hasPermissions) return false;
    _authState = HealthAuthState.granted;
    return true;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      if (!await _ensureAuthorized()) return null;

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      final steps = await _health.getTotalStepsInInterval(startOfDay, now);
      if (steps == null) return null;

      // Gewicht/Schlaf sind best-effort — fehlende Daten lassen den Snapshot
      // weiter gueltig (Steps bleiben der Pflicht-Wert).
      double? latestWeight;
      try {
        final weights = await readWeightSamples(
          from: now.subtract(const Duration(days: 90)),
          to: now,
        );
        if (weights.isNotEmpty) latestWeight = weights.last.kg;
      } catch (e, st) {
        _reportError('readSnapshot.weight', e, st);
      }

      int? sleepMinutes;
      try {
        final sleep = await readLastSleep(before: now);
        if (sleep != null) sleepMinutes = sleep.minutesAsleep;
      } catch (e, st) {
        _reportError('readSnapshot.sleep', e, st);
      }

      return HealthSnapshot(
        stepsToday: steps,
        fetchedAt: now,
        latestWeightKg: latestWeight,
        lastSleepMinutes: sleepMinutes,
      );
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
      if (!await _ensureAuthorized()) return false;
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
      if (!await _ensureAuthorized()) return const <WeightSample>[];
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
    } catch (e, st) {
      _reportError('readWeightSamples', e, st);
      return const <WeightSample>[];
    }
  }

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      if (!await _ensureAuthorized()) return null;
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
    } catch (e, st) {
      _reportError('readLastSleep', e, st);
      return null;
    }
  }
}
