enum HealthAuthState { unknown, granted, denied, unsupported }

/// Ein einzelnes Gewichts-Sample aus dem Health-Store (Apple Health). Wird fuer
/// den (spaeteren) Import-Pfad gebraucht: beim Connect koennen wir das letzte
/// Gewicht vorbefuellen, statt den User es erneut eintippen zu lassen.
class WeightSample {
  const WeightSample({required this.kg, required this.measuredAt});

  final double kg;
  final DateTime measuredAt;
}

/// Ein zusammengefasster Schlaf-Block (Summe der "asleep"-Phasen) ueber ein
/// Nacht-Fenster. Bewusst minimal — der App-Schlaf-Tracker arbeitet in Minuten.
class SleepSample {
  const SleepSample({required this.minutesAsleep, required this.end});

  final int minutesAsleep;
  final DateTime end;
}

class HealthSnapshot {
  const HealthSnapshot({
    required this.stepsToday,
    required this.fetchedAt,
    this.latestWeightKg,
    this.lastSleepMinutes,
  });

  final int stepsToday;
  final DateTime fetchedAt;

  /// Letztes bekanntes Koerpergewicht (kg) aus dem Health-Store, falls
  /// gelesen/autorisiert. Null = nicht verfuegbar (Default-Verhalten bleibt
  /// damit identisch zum Steps-only-Snapshot von vorher).
  final double? latestWeightKg;

  /// Schlafdauer der letzten Nacht in Minuten, falls verfuegbar. Null = keine
  /// Daten / nicht autorisiert.
  final int? lastSleepMinutes;
}

abstract class HealthService {
  HealthAuthState get authState;

  /// Triggers the system permission prompt. Returns the resulting auth state.
  /// Fragt READ (Steps/Weight/Sleep) UND WRITE (Weight/Workout) in einem Zug an,
  /// sodass der Write-Back-Pfad nach einem erfolgreichen Connect sofort nutzbar
  /// ist — kein zweiter Permission-Dialog spaeter.
  Future<HealthAuthState> requestAuthorization();

  /// Reads today's step count (plus optional weight/sleep). Returns null when
  /// not authorized or no data.
  Future<HealthSnapshot?> readSnapshot();

  /// Schreibt ein Koerpergewicht-Sample (kg) zum Zeitpunkt [when] in den
  /// Health-Store. Liefert true bei Erfolg, false wenn nicht unterstuetzt /
  /// nicht autorisiert / Fehler. Off-iOS immer no-op -> false.
  Future<bool> writeWeight(double kg, DateTime when);

  /// Liest Gewichts-Samples im Fenster [from]..[to] (fuer den Import-Pfad).
  /// Leere Liste wenn nicht unterstuetzt / nicht autorisiert / keine Daten.
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  });

  /// Liest den letzten zusammenhaengenden Schlaf-Block vor [before] (Default:
  /// jetzt). Null wenn nicht unterstuetzt / nicht autorisiert / keine Daten.
  Future<SleepSample?> readLastSleep({DateTime? before});
}

class NoopHealthService implements HealthService {
  const NoopHealthService();

  @override
  HealthAuthState get authState => HealthAuthState.unsupported;

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.unsupported;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}
