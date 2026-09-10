/// State of the health permission.
///
/// [unverified] (review B3): HealthKit showed the sheet without error, but
/// nothing proves data actually flows — the normal case when the user toggled
/// nothing. It must not pass as [granted], or the app claims it is synced and
/// permanently counts 0 steps.
enum HealthAuthState {
  unknown,
  granted,
  unverified,
  denied,
  unsupported,

  /// Health Connect is authorized but has no step records for today.
  noData,

  /// The Android device cannot provide Health Connect.
  unavailable,

  /// Health Connect must be installed or updated before requesting access.
  updateRequired,

  /// Availability, permission verification or reading temporarily failed.
  error,
}

/// Optional Android recovery actions; iOS keeps its existing integration.
abstract interface class HealthConnectAccess {
  Future<bool> openSettings();

  /// Restores this account's previously persisted opt-in, never OS permission.
  void restoreConnection();
}

/// A single weight sample from the health store, used by the import path to
/// prefill the last known weight on connect.
class WeightSample {
  const WeightSample({required this.kg, required this.measuredAt});

  final double kg;
  final DateTime measuredAt;
}

class HealthSnapshot {
  const HealthSnapshot({
    required this.stepsToday,
    required this.fetchedAt,
    this.latestWeightKg,
  });

  final int stepsToday;
  final DateTime fetchedAt;

  /// Last known body weight (kg) from the health store, null if unavailable.
  final double? latestWeightKg;
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
  /// Android requests steps READ only; iOS reads steps/weight and writes
  /// weight. Never add scopes no feature reads.
  Future<HealthAuthState> requestAuthorization();

  /// Reads today's step count (plus optional weight). Returns null when
  /// not authorized or no data.
  Future<HealthSnapshot?> readSnapshot();

  /// Step total of one local calendar day [day], the backfill path for past
  /// days. Null means unavailable. Android preserves measured zero; iOS
  /// returns positive values only because HealthKit hides read permission.
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
  }) async => const <WeightSample>[];
}
