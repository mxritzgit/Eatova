import 'package:clock/clock.dart';

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
import '../models/user_profile.dart';
import 'meals_sync.dart' show mealResultFromJson, mealResultToJson;

/// DATA-7 write outbox: failed sync writes are persisted as a [SyncOp]
/// instead of rolled back, then replayed idempotently. This file holds only
/// the serializable op model and the pure enqueue logic — replay lives in
/// HomeStore, persistence in LocalCache.

/// Hard cap of the persisted outbox.
///
/// Under a systemic failure (e.g. a check constraint rejecting every write)
/// each action queues its own entity, coalescing never kicks in, and the
/// SharedPreferences blob grows without bound.
///
/// Why 500: a meal op is ~0.3–1 kB JSON, so the blob stays in the low
/// hundreds of kB and still writes in milliseconds — while 500 pending
/// writes far exceed any realistic offline phase. Hitting the cap means a
/// systemic failure, not offline use.
const int kOutboxMaxOps = 500;

/// Max delivery attempts per op before it is dropped for good.
///
/// Counts only active server rejections (5xx, 429, unclear codes); network
/// errors are free (classifyOutboxFailure), otherwise an offline weekend
/// would burn the budget and destroy valid user data. Deletes use the much
/// larger [kOutboxDeleteMaxAttempts] instead.
///
/// Why 8: backoff runs 30s → 1m → 2m → 4m (cap), so eight counted attempts
/// outlive a half-hour outage and several app starts, yet a truly unwritable
/// op does not burn battery and traffic for months.
const int kOutboxMaxAttempts = 8;

/// Max delivery attempts for a DELETE op ([SyncOp.isDelete]).
///
/// Deletes get their own budget because dropping one is worse than dropping a
/// write: the next cold start does not merely fail to heal it, it undoes it —
/// the server row survives, the local state does not, and the deleted meal is
/// back and counts again.
///
/// Why a budget at all: an op without one is immortal — the retry timer fires
/// forever, the outbox never empties (so `signOutCleanup` pins
/// `preserveOutbox` to true, breaking audit M-1), and [capOutbox] can no
/// longer shed an all-delete overflow. Tolerable only because the store
/// restores a dropped delete locally and reports it (`_restoreDroppedDeletes`).
///
/// Why 64 (8x the write budget): only active server rejections count and the
/// backoff sits at 4 minutes, so 64 means at least half a working day of
/// continuous rejection. It only bites together with `kOutboxDeleteMinAge`
/// (AND condition in the store), since lifecycle churn inflates the counter.
const int kOutboxDeleteMaxAttempts = 64;

/// Kind of pending operation. Every op is idempotently repeatable:
///  * mealInsert/mealUpsert -> upsert on the client UUID (onConflict:'id').
///  * weightInsert -> upsert on the client UUID.
///  * favoriteUpsert -> upsert on (user_id, favorite_key).
///  * recipeUpsert -> upsert on (user_id, slug).
///  * profileUpsert -> upsert on the user id.
///  * *Delete -> inherently idempotent (0 rows on retry).
/// mealInsert vs. mealUpsert: only a replayed first insert counts lifetime
/// stats; update/restore run as mealUpsert without counting, as online. The
/// counting itself happens via a separate [SyncOpKind.statsIncrement] entry
/// that replay creates atomically with removing the source op.
enum SyncOpKind {
  mealInsert,
  mealUpsert,
  mealDelete,
  weightInsert,
  favoriteUpsert,
  favoriteDelete,
  recipeUpsert,
  recipeDelete,

  /// Gap D: profile/goals (weight, kcal goal, diet, onboarding flag). Without
  /// it, an offline `applySettings`/`completeOnboarding` was silently
  /// overwritten by the stale server row on the next boot.
  profileUpsert,

  /// A tracked logging day (`record_tracking_day`), added 2026-08-10.
  ///
  /// Previously the RPC was fire-and-forget: on failure the optimistic local
  /// day was overwritten ~600 ms later by the fresh server row, so the streak
  /// broke silently with nothing able to repair it.
  trackingDay,

  /// Fix 3 (PR #40): the lifetime counter of a replayed counting op as its
  /// own idempotent entry. [SyncOp.entityId] IS the server request id
  /// (`increment_lifetime_stats(p_request_id)`), derived deterministically
  /// from the source UUID so every repetition books as one event. Created
  /// only in the replay loop, atomically with removing the source op — that
  /// closes the kill window that could push meals_logged permanently +1.
  statsIncrement,
}

/// A persistable, replayable sync operation.
class SyncOp {
  SyncOp._({
    required this.kind,
    required this.entityId,
    required this.payload,
    DateTime? queuedAt,
    this.attempts = 0,
    // clock.now(), not DateTime.now(): [queuedAt] is half the drop deadline
    // (kOutboxMinAgeBeforeDrop / kOutboxDeleteMinAge) and must be testable.
  }) : queuedAt = queuedAt ?? clock.now();

  final SyncOpKind kind;

  /// Raw entity key (meal UUID, weight_log UUID, favorite_key, recipe slug).
  /// Queue logic must use [entityKey], which is collision-free across
  /// op families.
  final String entityId;
  final DateTime queuedAt;
  final Map<String, dynamic> payload;

  /// How often the server actively rejected THIS payload. Factories start at
  /// 0; only the replay loop increments, and only on a counted verdict
  /// (classifyOutboxFailure) — network errors are free. At
  /// [kOutboxMaxAttempts] the op is dropped.
  final int attempts;

  /// Copy with one delivery attempt spent. Everything else — notably
  /// [queuedAt], the entity's FIFO position — is preserved.
  ///
  /// Applies to [isDelete] ops too: not counting them made an op immortal
  /// (queue never empties, retry timer runs forever, `preserveOutbox` pinned
  /// true, [capOutbox] unable to shed). Deletes count against the much larger
  /// [kOutboxDeleteMaxAttempts].
  ///
  /// Price: the counter is persisted for deletes, so a downgrade to a build
  /// without the delete rule reads it as a write budget and drops earlier —
  /// acceptable, since that build would drop after eight passes anyway.
  SyncOp incrementAttempt() => SyncOp._(
        kind: kind,
        entityId: entityId,
        payload: payload,
        queuedAt: queuedAt,
        attempts: attempts + 1,
      );

  factory SyncOp.mealInsert(LoggedMeal meal, {required bool trackDay}) =>
      SyncOp._(kind: SyncOpKind.mealInsert, entityId: meal.id, payload: {
        'meal': loggedMealToJson(meal),
        'track_day': trackDay,
      });

  factory SyncOp.mealUpsert(LoggedMeal meal) =>
      SyncOp._(kind: SyncOpKind.mealUpsert, entityId: meal.id, payload: {
        'meal': loggedMealToJson(meal),
      });

  factory SyncOp.mealDelete(String id) => SyncOp._(
      kind: SyncOpKind.mealDelete, entityId: id, payload: const {});

  factory SyncOp.weightInsert({
    required String id,
    required double weightKg,
    required DateTime recordedAt,
  }) =>
      SyncOp._(kind: SyncOpKind.weightInsert, entityId: id, payload: {
        'weight_kg': weightKg,
        'recorded_at': recordedAt.toIso8601String(),
      });

  factory SyncOp.favoriteUpsert(FavoriteMeal fav) =>
      SyncOp._(kind: SyncOpKind.favoriteUpsert, entityId: fav.id, payload: {
        'favorite': favoriteMealToJson(fav),
      });

  factory SyncOp.favoriteDelete(String favoriteKey) => SyncOp._(
      kind: SyncOpKind.favoriteDelete, entityId: favoriteKey,
      payload: const {});

  factory SyncOp.recipeUpsert(FitnessRecipe recipe) =>
      SyncOp._(kind: SyncOpKind.recipeUpsert, entityId: recipe.slug, payload: {
        'recipe': recipe.toRow(),
      });

  factory SyncOp.recipeDelete(String slug) => SyncOp._(
      kind: SyncOpKind.recipeDelete, entityId: slug, payload: const {});

  /// The profile is ONE row per user (public.profiles.id = auth user), so a
  /// fixed [entityId]: all profile ops share an [entityKey], coalesce into a
  /// single entry, and the last change wins.
  static const String profileEntityId = 'self';

  factory SyncOp.profileUpsert(UserProfile profile) => SyncOp._(
        kind: SyncOpKind.profileUpsert,
        entityId: profileEntityId,
        payload: {'profile': userProfileToJson(profile)},
      );

  /// A tracked logging day ([LifetimeStatsSync.recordTrackingDay]).
  ///
  /// [localDay] (`YYYY-MM-DD`) is also the [entityId], so all attempts for the
  /// same day coalesce into one op. The payload is empty — the day is the
  /// whole information.
  ///
  /// Idempotent both ways: the RPC counts a day once and is a no-op for days
  /// before the last counted one, so replay can neither double-count nor
  /// rewind the streak.
  factory SyncOp.trackingDay(String localDay) => SyncOp._(
        kind: SyncOpKind.trackingDay,
        entityId: localDay,
        payload: const <String, dynamic>{},
      );

  /// Counter follow-up of a replayed counting op
  /// ([SyncOpKind.statsIncrement]).
  ///
  /// [requestId] MUST come from `deriveStatsRequestId` — stability across
  /// repetitions is the whole idempotency guarantee — and becomes the
  /// [entityId]. Payload values are ints although always 1 today.
  factory SyncOp.statsIncrement({
    required String requestId,
    int meals = 0,
    int weightLogs = 0,
  }) =>
      SyncOp._(kind: SyncOpKind.statsIncrement, entityId: requestId, payload: {
        if (meals > 0) 'meals': meals,
        if (weightLogs > 0) 'weight_logs': weightLogs,
      });

  /// Collision-free entity key across all op families (`meal:<id>`,
  /// `weight:<id>`, `favorite:<key>`, `recipe:<slug>`, `profile:self`,
  /// `tracking:<YYYY-MM-DD>`, `stats:<request-uuid>`).
  String get entityKey => switch (kind) {
        SyncOpKind.mealInsert ||
        SyncOpKind.mealUpsert ||
        SyncOpKind.mealDelete =>
          'meal:$entityId',
        SyncOpKind.weightInsert => 'weight:$entityId',
        SyncOpKind.favoriteUpsert ||
        SyncOpKind.favoriteDelete =>
          'favorite:$entityId',
        SyncOpKind.recipeUpsert ||
        SyncOpKind.recipeDelete =>
          'recipe:$entityId',
        SyncOpKind.profileUpsert => 'profile:$entityId',
        SyncOpKind.trackingDay => 'tracking:$entityId',
        SyncOpKind.statsIncrement => 'stats:$entityId',
      };

  /// True for the three delete families.
  ///
  /// Special in the drop path: losing a delete is the only loss a cold start
  /// actively UNDOES (server row survives, local state does not). So a delete
  /// is the last choice everywhere: no immediate drop from an error code, a
  /// far larger attempt budget ([kOutboxDeleteMaxAttempts]), a wall-clock
  /// deadline in the store, and at the queue cap it falls only once no write
  /// op is left. Not undroppable though — that would be an immortal op; where
  /// it falls, the store restores the entry locally and reports it.
  bool get isDelete =>
      kind == SyncOpKind.mealDelete ||
      kind == SyncOpKind.favoriteDelete ||
      kind == SyncOpKind.recipeDelete;

  /// True for upsert-like ops — only those may be coalesced (payload
  /// replaced) on enqueue.
  ///
  /// [SyncOpKind.trackingDay] counts although it is no row upsert: its
  /// payload is empty, so replacing equals keeping, and without coalescing
  /// every further log of the same day appended an identical op.
  ///
  /// [SyncOpKind.statsIncrement] deliberately does NOT count: each entry is
  /// its own idempotent unit with its own request id and is always appended.
  /// Replacing would swallow a counter the server may already have booked.
  bool get isUpsert =>
      kind == SyncOpKind.mealInsert ||
      kind == SyncOpKind.mealUpsert ||
      kind == SyncOpKind.favoriteUpsert ||
      kind == SyncOpKind.recipeUpsert ||
      kind == SyncOpKind.profileUpsert ||
      kind == SyncOpKind.trackingDay;

  // ---- Payload accessors (defensive: corrupt -> null) ----------------------

  LoggedMeal? get meal {
    final raw = payload['meal'];
    if (raw is! Map) return null;
    try {
      return loggedMealFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Only relevant for [SyncOpKind.mealInsert]: did the day count for the
  /// streak when logged (a meal for today, not a backfill)?
  bool get trackDay => payload['track_day'] == true;

  double? get weightKg {
    final raw = payload['weight_kg'];
    return raw is num ? raw.toDouble() : null;
  }

  DateTime? get recordedAt {
    final raw = payload['recorded_at'];
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  FavoriteMeal? get favorite {
    final raw = payload['favorite'];
    if (raw is! Map) return null;
    try {
      return favoriteMealFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  FitnessRecipe? get recipe {
    final raw = payload['recipe'];
    if (raw is! Map) return null;
    try {
      return FitnessRecipe.fromRow(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// The numbers of a [SyncOpKind.statsIncrement] entry; missing or
  /// non-numeric -> 0. An entry that then counts nothing is undeliverable and
  /// takes the A8 drop path — a 0/0 call would only burn a request id.
  int get statsMeals {
    final raw = payload['meals'];
    return raw is num ? raw.toInt() : 0;
  }

  int get statsWeightLogs {
    final raw = payload['weight_logs'];
    return raw is num ? raw.toInt() : 0;
  }

  /// The op's profile — null if the payload is unreadable or incomplete.
  /// Incomplete counts as unreadable on purpose (see [userProfileFromJson]):
  /// an op on half-invented numbers would overwrite a real server row.
  /// Replay throws and drops the op (A8 path).
  UserProfile? get profile {
    final raw = payload['profile'];
    if (raw is! Map) return null;
    try {
      return userProfileFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  // ---- Wire format ---------------------------------------------------------

  /// [attempts] is written only when > 0, so a freshly queued op stays
  /// byte-identical to the old 4-key format: a downgrade still reads the
  /// queue, and the blob does not grow without need.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'entity_id': entityId,
        'queued_at': queuedAt.toIso8601String(),
        'payload': payload,
        if (attempts > 0) 'attempts': attempts,
      };

  /// Defensive: unknown kinds and broken entries return null, so one corrupt
  /// op does not take the whole queue down.
  static SyncOp? tryFromJson(Map<String, dynamic> json) {
    final rawKind = json['kind'];
    if (rawKind is! String) return null;
    SyncOpKind? kind;
    for (final k in SyncOpKind.values) {
      if (k.name == rawKind) {
        kind = k;
        break;
      }
    }
    if (kind == null) return null;
    final entityId = json['entity_id'];
    if (entityId is! String || entityId.isEmpty) return null;
    final rawPayload = json['payload'];
    final payload = rawPayload is Map
        ? rawPayload.cast<String, dynamic>()
        : <String, dynamic>{};
    final queuedAt = json['queued_at'];
    // Missing (legacy entry), non-numeric or negative -> 0: the safe
    // direction, since a low counter costs a few extra attempts while an
    // inflated one would drop valid user writes immediately.
    final rawAttempts = json['attempts'];
    final attempts =
        rawAttempts is num && rawAttempts > 0 ? rawAttempts.toInt() : 0;
    return SyncOp._(
      kind: kind,
      entityId: entityId,
      payload: payload,
      queuedAt:
          queuedAt is String ? DateTime.tryParse(queuedAt) : null,
      attempts: attempts,
    );
  }
}

/// Enqueues [op] FIFO. Coalescing keeps the queue short without breaking
/// per-entity order:
///  * If the last op of the same entity is also an upsert, its payload is
///    replaced instead of appended. A pending mealInsert keeps its kind and
///    track_day so replay still counts the stats.
///  * Everything else (deletes, upsert after delete, other entities) is
///    appended — strict FIFO preserves insert -> update -> delete.
/// [appendOnly] MUST be set while a replay runs: it may be replaying exactly
/// the op whose payload would be replaced and then lost on removal.
///
/// Coalescing resets [SyncOp.attempts] to 0 — the counter measures rejections
/// of THAT payload, and the payload just changed. Otherwise correcting a
/// rejected 200000 kcal entry to 500 would drop the valid correction at once.
/// [SyncOp.queuedAt] is kept: it is the FIFO position, unrelated to payload
/// validity.
///
/// Accepted trade-off: a permanently broken entity the user keeps editing is
/// never dropped. Fine — coalescing holds it at exactly one slot. Do not
/// "fix" that by carrying the counter over.
List<SyncOp> enqueueCoalesced(
  List<SyncOp> queue,
  SyncOp op, {
  bool appendOnly = false,
}) {
  if (op.isUpsert && !appendOnly) {
    for (var i = queue.length - 1; i >= 0; i--) {
      final existing = queue[i];
      if (existing.entityKey != op.entityKey) continue;
      if (!existing.isUpsert) break; // Delete in between -> append.
      final merged = existing.kind == SyncOpKind.mealInsert &&
              op.kind == SyncOpKind.mealUpsert
          ? SyncOp._(
              kind: SyncOpKind.mealInsert,
              entityId: op.entityId,
              payload: {...op.payload, 'track_day': existing.trackDay},
              queuedAt: existing.queuedAt,
              // attempts stays at the default 0 — NOT existing.attempts,
              // see docs above.
            )
          : op; // comes from a factory, so attempts == 0 as well.
      final next = [...queue];
      next[i] = merged;
      return next;
    }
  }
  return [...queue, op];
}

/// Caps the outbox at [maxOps] and returns queue and dropped ops separately.
///
/// A separate pure function rather than a flag on [enqueueCoalesced]: the
/// caller MUST see what was lost (it reports and logs it), and the cap must
/// also run on the hydration path, where a queue grown by an older, uncapped
/// build comes back from cache without ever passing through enqueue.
///
/// Dropped are the oldest ops (head of the queue), WRITE ops first;
/// [SyncOp.isDelete] only once no write op is left, so the cap stays hard
/// even for an all-delete queue. Tolerable only because the store restores a
/// dropped delete locally and reports it (`_restoreDroppedDeletes`,
/// `outboxDeleteLossHint`). Why this order:
///  (a) Drop-newest would turn a full queue into a permanent write outage —
///      a full queue is by definition not draining.
///  (b) The newest op is what the user is looking at; local state is mutated
///      before the write, so drop-newest loses the just-entered meal.
///  (c) The oldest ops of a full queue have failed longest, so they are the
///      likeliest poison ops.
///  (d) Writes survive a head trim per entity: each is a FULL row upsert on a
///      client UUID (no deltas); only the stats/streak side effect is lost —
///      a counter, not user content (same for a capped statsIncrement entry,
///      which IS the counter). Not so for deletes: "idempotent" only means a
///      retry is harmless, not that a drop is. They also cost almost nothing
///      (~120 bytes), so they fall LAST — but they do fall, or an all-delete
///      queue grows without bound.
({List<SyncOp> queue, List<SyncOp> dropped}) capOutbox(
  List<SyncOp> queue, {
  int maxOps = kOutboxMaxOps,
}) {
  if (queue.length <= maxOps) {
    return (queue: queue, dropped: const <SyncOp>[]);
  }
  var overflow = queue.length - maxOps;
  var kept = <SyncOp>[];
  final dropped = <SyncOp>[];
  // Pass 1: write ops, oldest first.
  for (final op in queue) {
    if (overflow > 0 && !op.isDelete) {
      dropped.add(op);
      overflow--;
    } else {
      kept.add(op);
    }
  }
  // Pass 2: only deletes are left and the queue is still over the cap;
  // oldest first again.
  if (overflow > 0) {
    final survivors = <SyncOp>[];
    for (final op in kept) {
      if (overflow > 0) {
        dropped.add(op);
        overflow--;
      } else {
        survivors.add(op);
      }
    }
    kept = survivors;
  }
  return (queue: kept, dropped: dropped);
}

// ---- (De)serialization LoggedMeal / FavoriteMeal ----------------------------
// Here rather than on the models (same pattern as mealResultTo/FromJson): the
// domain models stay persistence-free, the outbox owns its versioned wire
// format. Also used by LocalCache for the diary/favorites snapshots.

Map<String, dynamic> loggedMealToJson(LoggedMeal m) => <String, dynamic>{
      'id': m.id,
      'logged_at': m.loggedAt.toIso8601String(),
      'forced_slot': m.forcedSlot?.name,
      'local_day': m.effectiveLocalDay,
      'result': mealResultToJson(m.result),
    };

LoggedMeal loggedMealFromJson(Map<String, dynamic> j) {
  return LoggedMeal(
    id: j['id'] as String,
    loggedAt: DateTime.parse(j['logged_at'] as String),
    forcedSlot: _parseSlot(j['forced_slot']?.toString()),
    localDay: j['local_day']?.toString(),
    result: mealResultFromJson((j['result'] as Map).cast<String, dynamic>()),
  );
}

Map<String, dynamic> favoriteMealToJson(FavoriteMeal f) => <String, dynamic>{
      'id': f.id,
      'added_at': f.addedAt.toIso8601String(),
      'pinned': f.pinned,
      'result': mealResultToJson(f.result),
    };

FavoriteMeal favoriteMealFromJson(Map<String, dynamic> j) {
  return FavoriteMeal(
    id: j['id'] as String,
    addedAt: DateTime.parse(j['added_at'] as String),
    pinned: j['pinned'] == true,
    result: mealResultFromJson((j['result'] as Map).cast<String, dynamic>()),
  );
}

MealSlot? _parseSlot(String? raw) {
  if (raw == null) return null;
  for (final v in MealSlot.values) {
    if (v.name == raw) return v;
  }
  return null;
}

// ---- (De)serialization UserProfile ------------------------------------------
// Lives here, not in LocalCache, because the profile has TWO persistence
// paths since gap D (cache slot and outbox op); two copies of the mapping
// would let a new field land in only one. Key names are unchanged (they sit
// on every existing install) and follow the public.profiles columns.

Map<String, dynamic> userProfileToJson(UserProfile p) => <String, dynamic>{
      'weight_kg': p.weightKg,
      'height_cm': p.heightCm,
      'age_years': p.ageYears,
      'sex': p.sex.name,
      'activity_level': p.activityLevel.name,
      'target_weight_kg': p.targetWeightKg,
      'daily_steps_goal': p.dailyStepsGoal,
      'daily_kcal_goal': p.dailyKcalGoal,
      'daily_water_goal_ml': p.dailyWaterGoalMl,
      'daily_sleep_goal_minutes': p.dailySleepGoalMinutes,
      'protein_goal_g': p.proteinGoalG,
      'carbs_goal_g': p.carbsGoalG,
      'fat_goal_g': p.fatGoalG,
      'weight_goal': p.weightGoal.name,
      // A7: MUST be written. The cache is the first hydration source and sets
      // the clobber lock (_hydratedFromRealSource); without this key `diet`
      // silently fell back to none on cold start and the next profile.save()
      // wrote that none to the server for good. Key name mirrors the column
      // profiles.diet_preference.
      'diet_preference': p.diet.name,
      'onboarding_completed': p.onboardingCompleted,
      // F7-01: the manual/live switch must survive the cache and the outbox,
      // or an offline goal edit would be healed back to the calculator on the
      // next load. Mirrors profiles.manual_energy.
      'manual_energy': p.manualEnergy,
    };

/// Sentinel finding 3 (2026-08-08): missing numeric fields used to be filled
/// with invented values, which set the clobber lock and let the next
/// profile.save() write that fiction to the server. A blob missing numbers
/// (old build, corrupt row) is therefore no hydration source AT ALL: null.
/// The cache gets truth from the server load right after; an outbox op takes
/// the drop path (A8). Enum fields stay lenient (A7) — they fall back to a
/// classification, not to a measurement.
UserProfile? userProfileFromJson(Map<String, dynamic> j) {
  final weightKg = _profileInt(j['weight_kg']);
  final heightCm = _profileInt(j['height_cm']);
  final ageYears = _profileInt(j['age_years']);
  final targetWeightKg = _profileInt(j['target_weight_kg']);
  final dailyStepsGoal = _profileInt(j['daily_steps_goal']);
  final dailyKcalGoal = _profileInt(j['daily_kcal_goal']);
  final dailyWaterGoalMl = _profileInt(j['daily_water_goal_ml']);
  final dailySleepGoalMinutes = _profileInt(j['daily_sleep_goal_minutes']);
  final proteinGoalG = _profileInt(j['protein_goal_g']);
  final carbsGoalG = _profileInt(j['carbs_goal_g']);
  final fatGoalG = _profileInt(j['fat_goal_g']);
  if (weightKg == null ||
      heightCm == null ||
      ageYears == null ||
      targetWeightKg == null ||
      dailyStepsGoal == null ||
      dailyKcalGoal == null ||
      dailyWaterGoalMl == null ||
      dailySleepGoalMinutes == null ||
      proteinGoalG == null ||
      carbsGoalG == null ||
      fatGoalG == null) {
    return null;
  }
  return UserProfile(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: ageYears,
    sex: _profileEnum(BiologicalSex.values, j['sex'], BiologicalSex.neutral),
    activityLevel: _profileEnum(
        ActivityLevel.values, j['activity_level'], ActivityLevel.sedentary),
    targetWeightKg: targetWeightKg,
    dailyStepsGoal: dailyStepsGoal,
    dailyKcalGoal: dailyKcalGoal,
    dailyWaterGoalMl: dailyWaterGoalMl,
    dailySleepGoalMinutes: dailySleepGoalMinutes,
    proteinGoalG: proteinGoalG,
    carbsGoalG: carbsGoalG,
    fatGoalG: fatGoalG,
    weightGoal:
        _profileEnum(WeightGoal.values, j['weight_goal'], WeightGoal.maintain),
    // Counterpart to 'diet_preference' above; unknown or missing values
    // fall back to none.
    diet: _profileEnum(
        DietPreference.values, j['diet_preference'], DietPreference.none),
    onboardingCompleted: j['onboarding_completed'] == true,
    // Missing (blob from an older build) counts as live, like the column
    // default — never reconstructed from the numbers.
    manualEnergy: j['manual_energy'] == true,
  );
}

int? _profileInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

T _profileEnum<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}
