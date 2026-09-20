import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:cryptography/dart.dart' show DartSha256;

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
import '../models/planned_meal.dart';
import '../models/training_plan.dart';
import '../models/training_history.dart';
import '../models/user_profile.dart';
import 'meals_sync.dart' show mealResultFromJson, mealResultToJson;
import 'uuid.dart';

/// DATA-7 write outbox: failed sync writes are persisted as a [SyncOp]
/// instead of rolled back, then replayed idempotently. This file holds only
/// the serializable op model and the pure enqueue logic — replay lives in
/// HomeStore, persistence in LocalCache.

/// Admission limit: an overflowing new transaction fails without dropping
/// any previously confirmed operation.
const int kOutboxMaxOps = 500;

/// Active-rejection thresholds used by the shared failure classifier.
/// Exhausted requests stay durable and require explicit retry.
const int kOutboxMaxAttempts = 8;
const int kOutboxDeleteMaxAttempts = 64;

/// Server effects use stable operation receipts. Meal/weight insert receipts
/// include their counters in the same server transaction. statsIncrement is
/// retained for migration of legacy pending counter bundles.
enum SyncOpKind {
  mealPlanUpsert,
  mealPlanConvert,
  shoppingCheck,
  mealInsert,
  mealUpsert,
  mealDelete,
  weightInsert,
  favoriteUpsert,
  favoriteDelete,
  recipeUpsert,
  recipeDelete,
  trainingPlanUpsert,
  trainingPlanDelete,
  trainingHistoryInsert,
  trainingHistoryDelete,

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
  statsIncrement;

  bool get isDelete => switch (this) {
    mealDelete ||
    favoriteDelete ||
    recipeDelete ||
    trainingPlanDelete ||
    trainingHistoryDelete => true,
    _ => false,
  };
}

/// A persistable, replayable sync operation.
enum SyncBlockedReason {
  capacity,
  backendUnavailable,
  rejected,
  trainingHeadConflict,
}

class SyncOp {
  SyncOp._({
    required this.kind,
    required this.entityId,
    required Map<String, dynamic> payload,
    DateTime? queuedAt,
    this.attempts = 0,
    String? operationId,
    this.expectedRevision,
    this.deliveryStarted = false,
    this.predecessorId,
    this.blockedReason,
    Map<String, dynamic>? wirePayload,
    this.wireSchema,
    // Use the injected clock for deterministic ordering and diagnostics.
  }) : payload = _immutableJson(payload) as Map<String, dynamic>,
       wirePayload = wirePayload == null
           ? null
           : _immutableJson(wirePayload) as Map<String, dynamic>,
       queuedAt = queuedAt ?? clock.now(),
       operationId = operationId ?? uuidV4();

  /// Stable across retries, restarts and background workers.
  final String operationId;
  final int? expectedRevision;
  final bool deliveryStarted;
  final String? predecessorId;
  final SyncBlockedReason? blockedReason;

  /// Normalized server request frozen in the start transaction.
  final Map<String, dynamic>? wirePayload;
  final int? wireSchema;

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
  /// [kOutboxMaxAttempts] automatic delivery stops; the op remains durable.
  final int attempts;

  /// Copy with one delivery attempt spent. Everything else — notably
  /// [queuedAt], the entity's FIFO position — is preserved.
  ///
  /// Deletes have a larger automatic retry budget. Exhaustion never removes
  /// the confirmed intent; explicit retry can resume delivery.
  SyncOp incrementAttempt() => SyncOp._(
    kind: kind,
    entityId: entityId,
    payload: payload,
    queuedAt: queuedAt,
    attempts: attempts + 1,
    operationId: operationId,
    expectedRevision: expectedRevision,
    deliveryStarted: deliveryStarted,
    predecessorId: predecessorId,
    blockedReason: blockedReason,
    wirePayload: wirePayload,
    wireSchema: wireSchema,
  );

  SyncOp markDeliveryStarted() => _copy(deliveryStarted: true);

  SyncOp freezeWirePayload(Map<String, dynamic> value) {
    if (wirePayload != null) return markDeliveryStarted();
    return SyncOp._(
      kind: kind,
      entityId: entityId,
      payload: payload,
      queuedAt: queuedAt,
      attempts: attempts,
      operationId: operationId,
      expectedRevision: expectedRevision,
      deliveryStarted: true,
      predecessorId: predecessorId,
      blockedReason: blockedReason,
      wirePayload: value,
      wireSchema: 1,
    );
  }

  SyncOp withPredecessor(String id) => _copy(predecessorId: id);

  SyncOp withoutPredecessor() => SyncOp._(
    kind: kind,
    entityId: entityId,
    payload: payload,
    queuedAt: queuedAt,
    attempts: attempts,
    operationId: operationId,
    expectedRevision: expectedRevision,
    deliveryStarted: deliveryStarted,
    blockedReason: blockedReason,
    wirePayload: wirePayload,
    wireSchema: wireSchema,
  );

  SyncOp withBlockedReason(SyncBlockedReason? reason) => SyncOp._(
    kind: kind,
    entityId: entityId,
    payload: payload,
    queuedAt: queuedAt,
    attempts: attempts,
    operationId: operationId,
    expectedRevision: expectedRevision,
    deliveryStarted: deliveryStarted,
    predecessorId: predecessorId,
    blockedReason: reason,
    wirePayload: wirePayload,
    wireSchema: wireSchema,
  );

  SyncOp rebaseRecipe({required int revision, String? slug}) {
    if (deliveryStarted || wirePayload != null) {
      throw StateError('A sent operation is immutable');
    }
    return SyncOp._(
      kind: kind,
      entityId: slug ?? entityId,
      payload: {
        ...payload,
        if (slug != null && payload['recipe'] is Map)
          'recipe': {...(payload['recipe'] as Map), 'slug': slug},
      },
      queuedAt: queuedAt,
      attempts: attempts,
      operationId: operationId,
      expectedRevision: revision,
    );
  }

  SyncOp _copy({bool? deliveryStarted, String? predecessorId}) => SyncOp._(
    kind: kind,
    entityId: entityId,
    payload: payload,
    queuedAt: queuedAt,
    attempts: attempts,
    operationId: operationId,
    expectedRevision: expectedRevision,
    deliveryStarted: deliveryStarted ?? this.deliveryStarted,
    predecessorId: predecessorId ?? this.predecessorId,
    blockedReason: blockedReason,
    wirePayload: wirePayload,
    wireSchema: wireSchema,
  );

  factory SyncOp.mealPlanUpsert(PlannedMeal plan) => SyncOp._(
    kind: SyncOpKind.mealPlanUpsert,
    entityId: plan.id,
    payload: {'planned_meal': plan.toJson()},
  );

  factory SyncOp.mealPlanConvert(
    PlannedMeal plan,
    LoggedMeal meal, {
    required bool trackDay,
  }) => SyncOp._(
    kind: SyncOpKind.mealPlanConvert,
    entityId: plan.id,
    payload: {
      'planned_meal': plan.toJson(),
      'meal': loggedMealToJson(meal),
      'track_day': trackDay,
    },
  );

  factory SyncOp.shoppingCheck(ShoppingCheck check) => SyncOp._(
    kind: SyncOpKind.shoppingCheck,
    entityId: check.id,
    payload: {'shopping_check': check.toJson()},
  );

  PlannedMeal? get plannedMeal {
    try {
      final plan = PlannedMeal.fromJson(
        (payload['planned_meal'] as Map).cast<String, dynamic>(),
      );
      return plan.id == entityId ? plan : null;
    } catch (_) {
      return null;
    }
  }

  ShoppingCheck? get shoppingCheckValue {
    try {
      final check = ShoppingCheck.fromJson(
        (payload['shopping_check'] as Map).cast<String, dynamic>(),
      );
      return check.id == entityId ? check : null;
    } catch (_) {
      return null;
    }
  }

  // Conversion is one durable transaction. Neither capacity nor a prolonged
  // outage may discard half of the user's accepted action.
  bool get isMealPlanIntent =>
      kind == SyncOpKind.mealPlanConvert ||
      kind == SyncOpKind.mealPlanUpsert ||
      kind == SyncOpKind.shoppingCheck;

  factory SyncOp.mealInsert(LoggedMeal meal, {required bool trackDay}) =>
      SyncOp._(
        kind: SyncOpKind.mealInsert,
        entityId: meal.id,
        payload: {'meal': loggedMealToJson(meal), 'track_day': trackDay},
      );

  factory SyncOp.mealUpsert(LoggedMeal meal) => SyncOp._(
    kind: SyncOpKind.mealUpsert,
    entityId: meal.id,
    payload: {'meal': loggedMealToJson(meal)},
  );

  factory SyncOp.mealDelete(String id) =>
      SyncOp._(kind: SyncOpKind.mealDelete, entityId: id, payload: const {});

  factory SyncOp.weightInsert({
    required String id,
    required double weightKg,
    required DateTime recordedAt,
  }) => SyncOp._(
    kind: SyncOpKind.weightInsert,
    entityId: id,
    payload: {
      'weight_kg': weightKg,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
    },
  );

  factory SyncOp.favoriteUpsert(FavoriteMeal fav) => SyncOp._(
    kind: SyncOpKind.favoriteUpsert,
    entityId: fav.id,
    payload: {'favorite': favoriteMealToJson(fav)},
  );

  factory SyncOp.favoriteDelete(String favoriteKey) => SyncOp._(
    kind: SyncOpKind.favoriteDelete,
    entityId: favoriteKey,
    payload: const {},
  );

  factory SyncOp.recipeUpsert(FitnessRecipe recipe, {int? expectedRevision}) =>
      SyncOp._(
        kind: SyncOpKind.recipeUpsert,
        entityId: recipe.slug,
        payload: {'recipe': recipe.toRow()},
        expectedRevision: expectedRevision,
      );

  factory SyncOp.recipeDelete(String slug, {int? expectedRevision}) => SyncOp._(
    kind: SyncOpKind.recipeDelete,
    entityId: slug,
    payload: const {},
    expectedRevision: expectedRevision,
  );

  factory SyncOp.trainingHistoryInsert(TrainingHistoryEntry entry) => SyncOp._(
    kind: SyncOpKind.trainingHistoryInsert,
    entityId: entry.id,
    payload: {'training_history': entry.toRow()},
  );
  factory SyncOp.trainingHistoryDelete(String id) => SyncOp._(
    kind: SyncOpKind.trainingHistoryDelete,
    entityId: id,
    payload: const {},
  );

  factory SyncOp.trainingPlanUpsert(
    TrainingPlan plan, {
    bool adoption = false,
  }) => SyncOp._(
    kind: SyncOpKind.trainingPlanUpsert,
    entityId: plan.id,
    payload: {'training_plan': plan.toRow(), if (adoption) 'adoption': true},
  );

  factory SyncOp.trainingPlanDelete(String id, {int incarnation = 0}) =>
      SyncOp._(
        kind: SyncOpKind.trainingPlanDelete,
        entityId: id,
        payload: {if (incarnation != 0) 'incarnation': incarnation},
      );

  bool get trainingAdoption =>
      kind == SyncOpKind.trainingPlanUpsert && payload['adoption'] == true;

  int get trainingIncarnation {
    final container = kind == SyncOpKind.trainingPlanUpsert
        ? payload['training_plan'] as Map?
        : payload;
    if (container == null || !container.containsKey('incarnation')) return 0;
    final raw = container['incarnation'];
    if (raw is! int || raw < 0 || raw > 0x7fffffff) {
      throw const FormatException('Invalid training incarnation');
    }
    return raw;
  }

  SyncOp withTrainingIncarnation(int incarnation) {
    if (deliveryStarted || wirePayload != null) {
      throw StateError('A sent operation is immutable');
    }
    return SyncOp._(
      kind: kind,
      entityId: entityId,
      payload: {
        ...payload,
        if (kind == SyncOpKind.trainingPlanUpsert)
          'training_plan': {
            ...(payload['training_plan'] as Map).cast<String, dynamic>(),
            'incarnation': incarnation,
          }
        else
          'incarnation': incarnation,
      },
      queuedAt: queuedAt,
      attempts: attempts,
      operationId: operationId,
      predecessorId: predecessorId,
      blockedReason: blockedReason,
    );
  }

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
  }) => SyncOp._(
    kind: SyncOpKind.statsIncrement,
    entityId: requestId,
    payload: {
      if (meals > 0) 'meals': meals,
      if (weightLogs > 0) 'weight_logs': weightLogs,
    },
  );

  /// Collision-free entity key across all op families (`meal:<id>`,
  /// `weight:<id>`, `favorite:<key>`, `recipe:<slug>`, `profile:self`,
  /// `tracking:<YYYY-MM-DD>`, `stats:<request-uuid>`).
  String get entityKey => switch (kind) {
    SyncOpKind.mealPlanUpsert ||
    SyncOpKind.mealPlanConvert ||
    SyncOpKind.mealInsert ||
    SyncOpKind.mealUpsert ||
    SyncOpKind.mealDelete => 'meal:$entityId',
    SyncOpKind.shoppingCheck => 'shopping_check:$entityId',
    SyncOpKind.weightInsert => 'weight:$entityId',
    SyncOpKind.favoriteUpsert ||
    SyncOpKind.favoriteDelete => 'favorite:$entityId',
    SyncOpKind.recipeUpsert || SyncOpKind.recipeDelete => 'recipe:$entityId',
    SyncOpKind.trainingPlanUpsert ||
    SyncOpKind.trainingPlanDelete => 'training_plan:$entityId',
    SyncOpKind.trainingHistoryInsert ||
    SyncOpKind.trainingHistoryDelete => 'training_history:$entityId',
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
  /// History is the only copy after its recovery checkpoint is retired.
  bool get isTrainingHistoryIntent =>
      kind == SyncOpKind.trainingHistoryInsert ||
      kind == SyncOpKind.trainingHistoryDelete;

  bool get isDelete => kind.isDelete;

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
      kind == SyncOpKind.trainingPlanUpsert ||
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
    return raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
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

  TrainingHistoryEntry? get trainingHistory {
    final raw = payload['training_history'];
    if (raw is! Map) return null;
    try {
      final entry = TrainingHistoryEntry.fromRow(raw);
      return entry.id == entityId ? entry : null;
    } catch (_) {
      return null;
    }
  }

  TrainingPlan? get trainingPlan {
    final raw = payload['training_plan'];
    if (raw is! Map) return null;
    try {
      final plan = TrainingPlan.fromRow(raw.cast<String, dynamic>());
      return plan.id == entityId ? plan : null;
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
  /// Replay retains invalid payloads for recovery.
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

  /// Durable request metadata is preserved across restarts and workers.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'operation_id': operationId,
    'kind': kind.name,
    'entity_id': entityId,
    'queued_at': queuedAt.toIso8601String(),
    'payload': payload,
    if (attempts > 0) 'attempts': attempts,
    if (expectedRevision != null) 'expected_revision': expectedRevision,
    if (deliveryStarted) 'delivery_started': true,
    if (predecessorId != null) 'predecessor_id': predecessorId,
    if (blockedReason != null) 'blocked_reason': blockedReason!.name,
    if (wirePayload != null) 'wire_payload': wirePayload,
    if (wireSchema != null) 'wire_schema': wireSchema,
  };

  /// Defensive: unknown kinds and broken entries return null, so one corrupt
  /// op does not take the whole queue down.
  static SyncOp? tryFromJson(Map<String, dynamic> json) {
    final wire = json['wire_payload'];
    final schema = json['wire_schema'];
    if ((wire == null) != (schema == null) ||
        (wire != null && (wire is! Map<String, dynamic> || schema != 1))) {
      return null;
    }
    final rawOperationId = json['operation_id'];
    if (rawOperationId != null &&
        (rawOperationId is! String || !isUuidShape(rawOperationId))) {
      return null;
    }
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
    final attempts = rawAttempts is num && rawAttempts > 0
        ? rawAttempts.toInt()
        : 0;
    return SyncOp._(
      kind: kind,
      entityId: entityId,
      payload: payload,
      queuedAt: queuedAt is String ? DateTime.tryParse(queuedAt) : null,
      attempts: attempts,
      operationId:
          json['operation_id'] is String &&
              isUuidShape(json['operation_id'] as String)
          ? json['operation_id'] as String
          : _legacyOperationId(json),
      expectedRevision: json['expected_revision'] is int
          ? json['expected_revision'] as int
          : null,
      deliveryStarted: json['delivery_started'] == true,
      wirePayload: wire as Map<String, dynamic>?,
      wireSchema: schema as int?,
      predecessorId: json['predecessor_id'] as String?,
      blockedReason: SyncBlockedReason.values
          .where((reason) => reason.name == json['blocked_reason'])
          .firstOrNull,
    );
  }

  static String _legacyOperationId(Map<String, dynamic> wire) {
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: canonical(value[key])};
      }
      if (value is List) return value.map(canonical).toList();
      return value;
    }

    final original = {...wire}..remove('attempts');
    final digest = const DartSha256()
        .hashSync(
          utf8.encode('eatova-legacy-op-v1:${jsonEncode(canonical(original))}'),
        )
        .bytes
        .take(16)
        .toList();
    digest[6] = (digest[6] & 15) | 0x50;
    digest[8] = (digest[8] & 63) | 0x80;
    final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

Object? _immutableJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _immutableJson(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJson));
  }
  return value;
}

/// The explicit review covers exactly this unsent same-generation frontier.
/// A sent or different-generation successor requires a separate decision.
List<SyncOp> trainingAdoptionReviewOps(
  Iterable<SyncOp> operations,
  String blockedOperationId, {
  bool requireResolvable = true,
}) {
  final queue = operations.toList();
  final at = queue.indexWhere((op) => op.operationId == blockedOperationId);
  if (at < 0 ||
      !queue[at].trainingAdoption ||
      queue[at].blockedReason != SyncBlockedReason.trainingHeadConflict) {
    throw StateError('Training adoption changed');
  }
  final blocked = queue[at];
  final reviewed = <SyncOp>[blocked];
  for (final op in queue.skip(at + 1)) {
    if (op.entityKey != blocked.entityKey) continue;
    if (op.kind != SyncOpKind.trainingPlanUpsert ||
        op.trainingIncarnation != blocked.trainingIncarnation ||
        op.deliveryStarted ||
        op.wirePayload != null) {
      if (!requireResolvable) break;
      throw StateError('Training adoption has a separate pending change');
    }
    reviewed.add(op);
  }
  return List.unmodifiable(reviewed);
}

/// Keep confirmed follow-up drafts visible while their adoption needs review.
/// These copies are for projection only; durable flags and wire stay intact.
Iterable<SyncOp> trainingProjectionOps(Iterable<SyncOp> operations) sync* {
  final conflicts = <String, int>{};
  for (final op in operations) {
    if (op.trainingAdoption &&
        op.blockedReason == SyncBlockedReason.trainingHeadConflict) {
      conflicts[op.entityKey] = op.trainingIncarnation;
    } else if (conflicts.containsKey(op.entityKey)) {
      if (op.kind == SyncOpKind.trainingPlanUpsert &&
          op.trainingIncarnation == conflicts[op.entityKey] &&
          !op.deliveryStarted &&
          op.wirePayload == null) {
        yield op.withBlockedReason(SyncBlockedReason.trainingHeadConflict);
        continue;
      }
      conflicts.remove(op.entityKey);
    }
    yield op;
  }
}

/// Preview descendants at an acknowledged conflict copy without changing
/// their immutable wire basis before their own predecessor is acknowledged.
Iterable<SyncOp> recipeProjectionOps(Iterable<SyncOp> operations) sync* {
  final projected = <String, SyncOp>{};
  for (final op in operations) {
    final predecessor =
        op.kind == SyncOpKind.recipeUpsert || op.kind == SyncOpKind.recipeDelete
        ? projected[op.predecessorId]
        : null;
    final effective = predecessor != null && predecessor.entityId != op.entityId
        ? op.rebaseRecipe(
            revision: op.expectedRevision ?? 0,
            slug: predecessor.entityId,
          )
        : op;
    projected[op.operationId] = effective;
    yield effective;
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
      final merged =
          existing.kind == SyncOpKind.mealInsert &&
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
    // A COPY, not the input. The outbox replay cursor
    // (home_store_sync.dart `_replayOutbox`) detects a foreign queue change by
    // comparing list IDENTITY, which rests on every write to `_outbox`
    // allocating a fresh list. Handing the input straight back made that true
    // only by luck of the current call sites; one future
    // `_outbox = capOutbox(_outbox).queue` after an in-place edit would skip
    // ops with no test going red. Cheap: this path allocates one list per
    // enqueue.
    return (queue: List<SyncOp>.of(queue), dropped: const <SyncOp>[]);
  }
  var overflow = queue.length - maxOps;
  var kept = <SyncOp>[];
  final dropped = <SyncOp>[];
  // Pass 1: write ops, oldest first.
  for (final op in queue) {
    if (overflow > 0 &&
        !op.isDelete &&
        !op.isMealPlanIntent &&
        !op.isTrainingHistoryIntent) {
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
      if (overflow > 0 && !op.isMealPlanIntent && !op.isTrainingHistoryIntent) {
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
  'logged_at': m.loggedAt.toUtc().toIso8601String(),
  'forced_slot': m.slot.name,
  'local_day': m.effectiveLocalDay,
  'result': mealResultToJson(m.result),
};

LoggedMeal loggedMealFromJson(Map<String, dynamic> j) {
  return LoggedMeal(
    id: j['id'] as String,
    loggedAt: DateTime.parse(j['logged_at'] as String).toLocal(),
    forcedSlot: _parseSlot(j['forced_slot']?.toString()),
    localDay: j['local_day']?.toString(),
    result: mealResultFromJson((j['result'] as Map).cast<String, dynamic>()),
  );
}

Map<String, dynamic> favoriteMealToJson(FavoriteMeal f) => <String, dynamic>{
  'id': f.id,
  'added_at': f.addedAt.toUtc().toIso8601String(),
  'pinned': f.pinned,
  'result': mealResultToJson(f.result),
};

FavoriteMeal favoriteMealFromJson(Map<String, dynamic> j) {
  return FavoriteMeal(
    id: j['id'] as String,
    addedAt: DateTime.parse(j['added_at'] as String).toLocal(),
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
      ActivityLevel.values,
      j['activity_level'],
      ActivityLevel.sedentary,
    ),
    targetWeightKg: targetWeightKg,
    dailyStepsGoal: dailyStepsGoal,
    dailyKcalGoal: dailyKcalGoal,
    dailyWaterGoalMl: dailyWaterGoalMl,
    dailySleepGoalMinutes: dailySleepGoalMinutes,
    proteinGoalG: proteinGoalG,
    carbsGoalG: carbsGoalG,
    fatGoalG: fatGoalG,
    weightGoal: _profileEnum(
      WeightGoal.values,
      j['weight_goal'],
      WeightGoal.maintain,
    ),
    // Counterpart to 'diet_preference' above; unknown or missing values
    // fall back to none.
    diet: _profileEnum(
      DietPreference.values,
      j['diet_preference'],
      DietPreference.none,
    ),
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
