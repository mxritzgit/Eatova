/// State of the health permission.
///
/// [unverified] (review B3): HealthKit showed the sheet without error, but
/// nothing proves data actually flows — the normal case when the user toggled
/// nothing. It must not pass as [granted], or the app claims it is synced and
/// permanently counts 0 steps.
enum HealthAuthState { unknown, granted, unverified, denied, unsupported }

/// A single weight sample from the health store, used by the import path to
/// prefill the last known weight on connect.
class WeightSample {
  const WeightSample({required this.kg, required this.measuredAt});

  final double kg;
  final DateTime measuredAt;
}

/// One aggregated sleep block (sum of the "asleep" phases) over a night
/// window, in minutes.
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

  /// Last known body weight (kg) from the health store, null if unavailable.
  final double? latestWeightKg;

  /// Last night's sleep in minutes; always null since 2026-08-19 because the
  /// SLEEP scope is no longer requested (see [readLastSleep]). Kept only until
  /// the HealthService test fakes are brought in line.
  final int? lastSleepMinutes;
}

abstract class HealthService {
  HealthAuthState get authState;

  /// Drops the health connection process-locally (logout, account deletion).
  ///
  /// Health state lives in the service object, not the namespaced cache, so
  /// without this user B keeps seeing A's connected state (class of D9). Must
  /// clear ALL surviving state — the verifier AND the cached `_authState`.
  /// Synchronous and non-throwing.
  void reset();

  /// Triggers the system permission prompt. Returns the resulting auth state.
  /// Requests READ (steps/weight) and WRITE (weight) in one go so write-back
  /// works right after connect. Never add scopes no feature reads — the
  /// purpose strings in `ios/Runner/Info.plist` must match every scope.
  Future<HealthAuthState> requestAuthorization();

  /// Reads today's step count (plus optional weight/sleep). Returns null when
  /// not authorized or no data.
  Future<HealthSnapshot?> readSnapshot();

  /// Step total of one local calendar day [day], the backfill path for past
  /// days. Positive values only, else null: without read permission
  /// `getTotalStepsInInterval` sums to 0 instead of failing, so 0 is
  /// indistinguishable from "no access". Always null off iOS.
  Future<int?> readStepsOnDay(DateTime day);

  /// Writes a body weight sample (kg) at [when] to the health store. False if
  /// unsupported, unauthorized or on error; off iOS a no-op.
  Future<bool> writeWeight(double kg, DateTime when);

  /// Weight samples in the window [from]..[to] for the import path; empty if
  /// unsupported, unauthorized or no data.
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  });

  /// Last contiguous sleep block before [before] (default: now).
  ///
  /// Null in EVERY implementation since 2026-08-19: the SLEEP scope is no
  /// longer requested, because Apple rejects unused HealthKit scopes. Kept
  /// only for the test fakes; removing it also removes [SleepSample] and
  /// [HealthSnapshot.lastSleepMinutes].
  Future<SleepSample?> readLastSleep({DateTime? before});
}

class NoopHealthService implements HealthService {
  const NoopHealthService();

  @override
  HealthAuthState get authState => HealthAuthState.unsupported;

  @override
  void reset() {}

  @override
  Future<HealthAuthState> requestAuthorization() async =>
      HealthAuthState.unsupported;

  @override
  Future<HealthSnapshot?> readSnapshot() async => null;

  @override
  Future<int?> readStepsOnDay(DateTime day) async => null;

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
