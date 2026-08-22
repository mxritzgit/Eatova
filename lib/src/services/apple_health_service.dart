import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:health/health.dart';

import 'crash_reporter.dart';
import 'health_service.dart';

/// Raw signals of one HealthKit access — deliberately plugin-free (numbers
/// and bools only) so [HealthAuthVerifier] stays testable without the
/// MethodChannel.
class HealthAuthEvidence {
  const HealthAuthEvidence({
    required this.writeGrant,
    this.steps,
    this.latestWeightKg,
  });

  /// Truthful WRITE status for weight.
  ///
  /// The only honest permission signal iOS passes through:
  /// `hasPermission(type:access:)` returns `nil` for READ and READ_WRITE and
  /// only reports `sharingAuthorized` for WRITE. Apple obfuscates the READ
  /// status; the share status is real.
  ///
  /// `null` = unknown (plugin/platform delivered nothing).
  final bool? writeGrant;

  /// Steps today. `0` proves NOTHING: without read access
  /// `getTotalStepsInInterval` sums an empty collection without error, so it
  /// yields 0, never null.
  final int? steps;

  /// Most recent weight read (kg), if any.
  final double? latestWeightKg;

  /// Positive READ signal: some datum actually arrived.
  ///
  /// A disjunction over both sources on purpose — a rest day with 0 steps is
  /// real, but "0 steps AND no weight" is the fingerprint of missing read
  /// access. Sleep is no longer a source: the SLEEP scope is not requested
  /// any more (see [AppleHealthService._types]).
  bool get hasReadEvidence => (steps ?? 0) > 0 || (latestWeightKg ?? 0) > 0;
}

/// Derives [HealthAuthState] from [HealthAuthEvidence] and keeps the
/// verification sticky (rest-day tolerance + expiry).
///
/// Needed because Apple's `requestAuthorization(toShare:read:)` reports
/// `success == true` as soon as the sheet was SHOWN without error. Without
/// this a user who grants nothing would still see a green "synced" while 0
/// steps feed `burnedKcal` and `adjustedGoal`.
class HealthAuthVerifier {
  HealthAuthVerifier({this.evidenceTtl = const Duration(days: 3)});

  /// How long read evidence carries without fresh evidence. Covers rest days
  /// without masking a real revocation forever. Applies even with WRITE
  /// granted: the share status says nothing about the read path.
  final Duration evidenceTtl;

  DateTime? _lastReadEvidenceAt;
  bool _writeGrantSeen = false;
  HealthAuthState _state = HealthAuthState.unknown;

  HealthAuthState get state => _state;

  /// When real health data last arrived (null = never in this run).
  DateTime? get lastReadEvidenceAt => _lastReadEvidenceAt;

  /// Evaluates one access. The rule order is the statement:
  ///  1. real read data beats everything,
  ///  2. a truthfully REVOKED write is the only hard proof of
  ///     [HealthAuthState.denied],
  ///  3. fresh evidence carries over rest days,
  ///  4. otherwise [HealthAuthState.unverified].
  ///
  /// Granted WRITE alone never yields [HealthAuthState.granted]: the sheet
  /// lists reading and writing separately, so a write-only grant would mean
  /// permanent 0 steps under a green "synced". `writeWeight` gates on the
  /// share status itself, not on this derived state.
  HealthAuthState resolve(HealthAuthEvidence e, {required DateTime now}) {
    final write = e.writeGrant;
    if (write == true) _writeGrantSeen = true;

    // 1) Real data arrived — the read path is proven, whatever the sheet or
    //    the share status claim.
    if (e.hasReadEvidence) {
      _lastReadEvidenceAt = now;
      return _state = HealthAuthState.granted;
    }

    // 2) WRITE was confirmed once and is gone now: switched off in iOS
    //    settings. The only path where `denied` can truthfully arise on iOS,
    //    so old evidence expires immediately.
    if (_writeGrantSeen && write == false) {
      _lastReadEvidenceAt = null;
      return _state = HealthAuthState.denied;
    }

    // 3) Rest-day tolerance: a single empty day does not flip the
    //    verification. No exception for WRITE == true, otherwise a leftover
    //    write switch would keep `granted` alive forever after read access
    //    was revoked.
    final last = _lastReadEvidenceAt;
    if (last != null) {
      if (now.difference(last) <= evidenceTtl) {
        return _state = HealthAuthState.granted;
      }
      // TTL over: the evidence expires and the state falls back.
      _lastReadEvidenceAt = null;
    }

    // 4) Nothing indicates a working access — a shown sheet is no proof, and
    //    neither is a write-only grant.
    return _state = HealthAuthState.unverified;
  }

  /// Evaluates [e] and builds a snapshot ONLY if the state is verified. An
  /// unverified access must never yield `stepsToday: 0`, otherwise the food
  /// tab silently computes `burnedKcal = 0`.
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

  /// Resets the verification (logout / account switch).
  void reset() {
    _lastReadEvidenceAt = null;
    _writeGrantSeen = false;
    _state = HealthAuthState.unknown;
  }
}

class AppleHealthService implements HealthService {
  /// [health] and [debugIsIOS] are test seams: otherwise the plugin hangs off
  /// the MethodChannel and the platform gate off the runner OS, leaving the
  /// error branches of [requestAuthorization] untestable.
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

  // Types and per-type permissions are PARALLEL lists (package:health expects
  // permissions[i] to match types[i]), so never remove one entry alone —
  // authorization would silently shift. Steps are READ-only, weight is
  // READ_WRITE (import prefill + write-back after a weigh-in).
  //
  // This list is the basis for the purpose strings in `ios/Runner/Info.plist`
  // (NSHealthShareUsageDescription / NSHealthUpdateUsageDescription). Adding a
  // scope means updating those AND shipping a feature that uses it; Apple
  // rejects unused scopes and over-promising purpose strings (guideline
  // 5.1.1). WORKOUT and SLEEP_ASLEEP are out for exactly that reason.
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

  /// HealthKit errors stay silent for the user (callers return fallbacks) but
  /// go to dev.log + CrashReporter instead of vanishing.
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

  /// Adopts a freshly derived state into the cache and returns it. The only
  /// write path to [_authState].
  HealthAuthState _adopt(HealthAuthState state) => _authState = state;

  /// Clears both surviving states — verifier AND cache. `refreshHealthSteps`
  /// reads [authState], so a verifier-only reset would leave user B seeing
  /// A's "synced". [HealthAuthState.unknown], not `denied`: nothing is known
  /// about the next user, and the first refresh re-verifies anyway.
  @override
  void reset() {
    _verifier.reset();
    _adopt(HealthAuthState.unknown);
  }

  /// Queries the ONLY truthful permission bool iOS passes through: the share
  /// status for weight.
  ///
  /// `hasPermissions` maps `HealthDataAccess.index` onto the native `access`
  /// int, and WRITE has index 1 — the one case that natively reports
  /// `sharingAuthorized`. With the full type list the result is always null.
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

  /// Collects all signals of one access in a single pass. No auth gate: the
  /// signals are what the auth state is derived from, so a gate would be
  /// circular.
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
    // Defense in depth: HealthKit is iOS-only. The Apple-vs-noop choice
    // happens at construction, but no-op hard instead of crashing.
    if (!_isIOS) return _adopt(HealthAuthState.unsupported);
    try {
      await _ensureConfigured();

      // hasPermissions over the full type list is useless on iOS (READ and
      // READ_WRITE return `nil` natively), so always ask. Harmless: HealthKit
      // shows the sheet once and is a silent no-op afterwards, which also
      // makes this usable as the "check" action after a settings trip.
      final sheetShown = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      if (!sheetShown) {
        // Apple's `success == false` means the request itself failed
        // (HealthKit unavailable / error), not a user "no". An error is not
        // an answer: unknown, never denied.
        return _adopt(HealthAuthState.unknown);
      }

      // `sheetShown` only proves the sheet ran without error; the state comes
      // from real signals.
      final now = DateTime.now();
      return _adopt(_verifier.resolve(await _gatherEvidence(now), now: now));
    } catch (e, st) {
      _reportError('requestAuthorization', e, st);
      // `unsupported` is reserved for the real platform fact above: the card
      // hides the connect button on it, which would be a dead end until
      // restart. An error is `unknown`; the reason goes to CrashReporter.
      return _adopt(HealthAuthState.unknown);
    }
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    if (!Platform.isIOS) return null;
    try {
      await _ensureConfigured();
      final now = DateTime.now();
      // Re-verified on EVERY refresh. Unverified => null, so the store never
      // sets dailySteps/healthLastFetch to a bogus value.
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
      // Calendar arithmetic instead of Duration(days: 1): across a DST edge a
      // day is not 24 h. Dart normalises the day overflow itself.
      var end = DateTime(day.year, day.month, day.day + 1);
      final now = DateTime.now();
      if (!start.isBefore(now)) return null;
      if (end.isAfter(now)) end = now;
      final steps = await _health.getTotalStepsInInterval(start, end);
      // 0 proves nothing (see HealthAuthEvidence.steps): without read access
      // an empty sum comes back, never an error. Store positives only.
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
      // Gate on the truthful share status, not the (possibly unverified)
      // overall state: a write-only grant may still write.
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

  /// Ungated weight read path — basis of [readWeightSamples] AND
  /// [_gatherEvidence], where an auth gate would be circular.
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

  /// Always `null`: the SLEEP scope is no longer requested (see [_types]), so
  /// a query would return nothing anyway. Kept on the interface for now
  /// because several HealthService fakes override it; removing it along with
  /// [SleepSample] and `HealthSnapshot.lastSleepMinutes` is its own step.
  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}
