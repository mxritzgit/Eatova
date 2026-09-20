import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:supabase/supabase.dart';

/// Stateful wire fixture for apply_sync_operation. The real SQL suite proves
/// database behavior; this fixture makes store tests observe canonical receipts,
/// stable replay identity, conflict copies and tombstones instead of blind 201s.
class SyncOperationFake {
  SyncOperationFake({
    required this.meals,
    required this.weights,
    required this.favorites,
    required this.recipes,
    required this.readProfile,
    required this.writeProfile,
    required this.readStats,
    required this.incrementStats,
    required this.recordDay,
    this.keepPhoto,
    Map<String, Map<String, dynamic>>? trainingPlans,
    Map<String, Map<String, dynamic>>? trainingHistory,
    Map<String, Map<String, dynamic>>? mealPlans,
    Map<String, bool>? shoppingChecks,
  }) : trainingPlans = trainingPlans ?? {},
       trainingHistory = trainingHistory ?? {},
       mealPlans = mealPlans ?? {},
       shoppingChecks = shoppingChecks ?? {};

  final Map<String, Map<String, dynamic>> meals, weights, favorites, recipes;
  final Map<String, Map<String, dynamic>> trainingPlans,
      trainingHistory,
      mealPlans;
  final Map<String, bool> shoppingChecks;
  final Map<String, dynamic>? Function() readProfile;
  final void Function(Map<String, dynamic>) writeProfile;
  final Map<String, dynamic> Function() readStats;
  final void Function(String requestId, int meals, int weights) incrementStats;
  final void Function(String) recordDay;
  final void Function(String)? keepPhoto;
  final _fingerprints = <String, Map<String, dynamic>>{};
  final receipts = <String, Map<String, dynamic>>{};
  final deleted = <String>{};
  final recipeHeads = <String, int>{};
  final trainingHeads = <String, Map<String, dynamic>>{};
  int _recipeRevision = 0;

  static Map<String, dynamic> _copy(Map<String, dynamic> row) =>
      (jsonDecode(jsonEncode(row)) as Map).cast<String, dynamic>();

  void seedRecipeHeads() {
    for (final entry in recipes.entries) {
      final existing = entry.value['server_revision'] as int?;
      if (existing != null && existing > _recipeRevision) {
        _recipeRevision = existing;
      }
      final revision = existing ?? ++_recipeRevision;
      entry.value['server_revision'] = revision;
      recipeHeads[entry.key] = revision;
      _keepPhoto(entry.value);
    }
  }

  void _keepPhoto(Map<String, dynamic>? row) {
    final photo = row?['image_asset'];
    if (photo is String && photo.startsWith('local:')) keepPhoto?.call(photo);
  }

  static String? _trainingSource(String id) =>
      RegExp(r'^coach_[A-Za-z0-9_-]{1,94}$').hasMatch(id)
      ? id.substring(6)
      : null;

  void _seedTrainingHeads() {
    for (final row in trainingPlans.values) {
      final id = row['id'] as String;
      final source = row['source_id'] as String? ?? _trainingSource(id);
      if (source == null) continue;
      trainingHeads.putIfAbsent(
        source,
        () => {
          'source_id': source,
          'plan_id': id,
          'incarnation': row['incarnation'] ?? 0,
          'deleted': false,
        },
      );
    }
    for (final key in deleted.where(
      (key) => key.startsWith('training_plan:'),
    )) {
      final id = key.substring('training_plan:'.length);
      final source = _trainingSource(id);
      if (source == null) continue;
      trainingHeads.putIfAbsent(
        source,
        () => {
          'source_id': source,
          'plan_id': id,
          'incarnation': 0,
          'deleted': true,
        },
      );
    }
  }

  Map<String, dynamic>? readTrainingHead(String sourceId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,94}$').hasMatch(sourceId)) {
      throw const PostgrestException(
        message: 'EX_INVALID_TRAINING_SOURCE',
        code: '22023',
      );
    }
    _seedTrainingHeads();
    final head = trainingHeads[sourceId];
    if (head == null) return null;
    final plan = trainingPlans[head['plan_id']];
    return _copy({
      ...head,
      'plan':
          head['deleted'] == false &&
              (plan?['incarnation'] ?? 0) == head['incarnation']
          ? plan
          : null,
    });
  }

  static int _trainingIncarnation(Map row) {
    if (!row.containsKey('incarnation')) return 0;
    final value = row['incarnation'];
    if (value is! int || value < 0 || value > 2147483647) {
      throw const PostgrestException(
        message: 'EX_INVALID_TRAINING_INCARNATION',
        code: '22023',
      );
    }
    return value;
  }

  Map<String, dynamic> _applyTrainingPlan(
    String kind,
    String id,
    Map<String, dynamic> body,
  ) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const PostgrestException(
        message: 'EX_INVALID_TRAINING_ID',
        code: '22023',
      );
    }
    _seedTrainingHeads();
    var source = _trainingSource(id);
    var generation = 0;
    var outcome = 'applied';
    if (kind == 'trainingPlanUpsert') {
      final raw = body['row'];
      if (raw is! Map || raw['id'] != id) {
        throw const PostgrestException(
          message: 'EX_INVALID_TRAINING_ID',
          code: '22023',
        );
      }
      final row = raw.cast<String, dynamic>();
      generation = _trainingIncarnation(row);
      if (body.containsKey('adoption') && body['adoption'] is! bool) {
        throw const PostgrestException(
          message: 'EX_INVALID_TRAINING_ADOPTION',
          code: '22023',
        );
      }
      final adoption = body['adoption'] == true;
      final explicitSource = row['source_id'];
      if (explicitSource != null &&
          (explicitSource is! String || explicitSource != source)) {
        throw const PostgrestException(
          message: 'EX_INVALID_TRAINING_SOURCE',
          code: '22023',
        );
      }
      source = explicitSource as String? ?? source;
      if (source == null && (generation != 0 || adoption)) {
        throw const PostgrestException(
          message: 'EX_INVALID_TRAINING_SOURCE',
          code: '22023',
        );
      }
      final head = source == null ? null : trainingHeads[source];
      final known = head?['incarnation'] as int?;
      final wasDeleted = head?['deleted'] == true;
      if ((known != null &&
              (generation < known || generation == known && wasDeleted)) ||
          (head == null && deleted.contains('training_plan:$id'))) {
        outcome = adoption ? 'headConflict' : 'deleted';
      } else if ((head == null && generation != 0) ||
          (known != null &&
              generation > known &&
              (!adoption || !wasDeleted || generation != known + 1))) {
        outcome = 'headConflict';
      } else {
        trainingPlans[id] = _copy({
          ...row,
          'source_id': source,
          'incarnation': generation,
        });
        if (source != null) {
          trainingHeads[source] = {
            'source_id': source,
            'plan_id': id,
            'incarnation': generation,
            'deleted': false,
          };
        }
      }
    } else {
      generation = _trainingIncarnation(body);
      final head = source == null ? null : trainingHeads[source];
      final known = head?['incarnation'] as int?;
      if ((head == null && generation != 0) ||
          (known != null &&
              generation > known &&
              (generation != known + 1 || head!['deleted'] != true))) {
        throw const PostgrestException(
          message: 'EX_TRAINING_SOURCE_CHANGED',
          code: '22023',
        );
      }
      if (source != null && (head == null || generation > known!)) {
        trainingHeads[source] = {
          'source_id': source,
          'plan_id': id,
          'incarnation': generation,
          'deleted': true,
        };
      }
      final row = trainingPlans[id];
      if (row != null && (row['incarnation'] ?? 0) == generation) {
        trainingPlans.remove(id);
        if (source != null &&
            trainingHeads[source]?['incarnation'] == generation) {
          trainingHeads[source]!['deleted'] = true;
        }
      }
      deleted.add('training_plan:$id');
      outcome = 'deleted';
    }
    final current = trainingPlans[id];
    return {
      'training_mutation': {'outcome': outcome, 'incarnation': generation},
      'entity_deleted':
          current == null || (current['incarnation'] ?? 0) != generation,
    };
  }

  Map<String, dynamic>? readReceipt(String operationId) {
    final receipt = receipts[operationId];
    return receipt == null ? null : _withCurrentState(receipt);
  }

  Map<String, dynamic> apply(Map<String, dynamic> params) {
    final operationId = params['p_operation_id'];
    final kind = params['p_kind'];
    final entity = params['p_entity_id'];
    final payload = params['p_payload'];
    if (operationId is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(operationId) ||
        kind is! String ||
        entity is! String ||
        entity.isEmpty ||
        payload is! Map) {
      throw const PostgrestException(
        message: 'EX_INVALID_SYNC_OPERATION',
        code: '22023',
      );
    }
    final protocol = params.containsKey('p_training_protocol')
        ? params['p_training_protocol']
        : 1;
    final training =
        kind == 'trainingPlanUpsert' || kind == 'trainingPlanDelete';
    if ((protocol != 1 && protocol != 2) || protocol == 2 && !training) {
      throw const PostgrestException(
        message: 'EX_INVALID_TRAINING_PROTOCOL',
        code: '22023',
      );
    }
    if (protocol == 1 &&
        training &&
        (payload.containsKey('adoption') ||
            payload.containsKey('incarnation') ||
            payload['row'] is Map &&
                (payload['row'] as Map).containsKey('incarnation'))) {
      throw const PostgrestException(
        message: 'EX_TRAINING_PROTOCOL_REQUIRED',
        code: '22023',
      );
    }
    // Feature negotiation is excluded from the immutable SQL fingerprint.
    final fingerprint = _copy(params)..remove('p_training_protocol');
    final previous = receipts[operationId];
    if (previous != null) {
      if (!const DeepCollectionEquality().equals(
        _fingerprints[operationId],
        fingerprint,
      )) {
        throw const PostgrestException(
          message: 'EX_OPERATION_ID_REUSED',
          code: '22023',
        );
      }
      return _withCurrentState(previous);
    }
    final body = payload.cast<String, dynamic>();
    Map<String, dynamic> row(String field) {
      final value = body[field];
      if (value is! Map) {
        throw const PostgrestException(
          message: 'EX_INVALID_ROW',
          code: '22023',
        );
      }
      return _copy(value.cast<String, dynamic>());
    }

    var result = <String, dynamic>{};
    switch (kind) {
      case 'recipeUpsert':
      case 'recipeDelete':
        seedRecipeHeads();
        final current = recipes[entity];
        final revision = recipeHeads[entity] ?? 0;
        final expected = body['expected_revision'] as int?;
        final conflict = revision == 0
            ? (expected ?? 0) != 0
            : expected != revision;
        final outcome = conflict
            ? (kind == 'recipeDelete' ? 'deleteConflict' : 'conflictSaved')
            : 'applied';
        Map<String, dynamic>? saved;
        if (kind == 'recipeUpsert') {
          final candidate = row('recipe');
          if (candidate['slug'] != entity) {
            throw const PostgrestException(
              message: 'EX_INVALID_RECIPE',
              code: '22023',
            );
          }
          final target = conflict ? 'user_conflict_$operationId' : entity;
          _keepPhoto(current);
          saved = {
            ...candidate,
            'slug': target,
            'server_revision': ++_recipeRevision,
            'conflict_of': conflict ? entity : current?['conflict_of'],
          };
          recipes[target] = saved;
          recipeHeads[target] = _recipeRevision;
          _keepPhoto(saved);
        } else if (!conflict) {
          _keepPhoto(current);
          recipes.remove(entity);
          recipeHeads[entity] = ++_recipeRevision;
        }
        result = {
          'recipe_mutation': {
            'outcome': outcome,
            'saved_recipe': saved,
            'current_recipe': recipes[entity],
            'current_revision': recipeHeads[entity] ?? 0,
            'current_deleted': !recipes.containsKey(entity),
          },
        };
      case 'mealInsert':
      case 'mealUpsert':
        final meal = row('row');
        if (meal['id'] != entity) {
          throw const PostgrestException(
            message: 'EX_INVALID_MEAL',
            code: '22023',
          );
        }
        if (deleted.contains('meal:$entity')) {
          result = {'entity_deleted': true};
        } else {
          if (kind == 'mealUpsert' || !meals.containsKey(entity)) {
            meals[entity] = meal;
          }
          if (kind == 'mealInsert') {
            incrementStats(_statsId(entity), 1, 0);
            if (body['track_day'] == true) {
              recordDay(meal['local_day'] as String);
            }
            result = {'lifetime_stats': readStats()};
          }
        }
      case 'mealDelete':
        meals.remove(entity);
        deleted.add('meal:$entity');
        result = {'entity_deleted': true};
      case 'weightInsert':
        weights.putIfAbsent(entity, () => row('row'));
        incrementStats(_statsId(entity), 0, 1);
        result = {'lifetime_stats': readStats()};
      case 'favoriteUpsert':
        favorites[entity] = row('row');
      case 'favoriteDelete':
        favorites.remove(entity);
      case 'profileUpsert':
        writeProfile({...?readProfile(), ...row('row')});
      case 'trainingPlanUpsert':
      case 'trainingPlanDelete':
        result = _applyTrainingPlan(kind, entity, body);
      case 'trainingHistoryInsert':
        final removed = deleted.contains('training_history:$entity');
        if (!removed) trainingHistory.putIfAbsent(entity, () => row('row'));
        result = {'entity_deleted': removed};
      case 'trainingHistoryDelete':
        trainingHistory.remove(entity);
        deleted.add('training_history:$entity');
        result = {'entity_deleted': true};
      case 'mealPlanUpsert':
        final existing = mealPlans[entity];
        if (existing?['removed'] == true || existing?['eaten_at'] != null) {
          result = {
            'planned_meal': existing,
            if (existing?['removed'] == true) 'entity_deleted': true,
          };
        } else {
          mealPlans[entity] = row('plan');
          result = {'planned_meal': mealPlans[entity]};
        }
      case 'mealPlanConvert':
        final existing = mealPlans[entity];
        if (existing?['removed'] == true) {
          result = {'entity_deleted': true, 'planned_meal': existing};
        } else if (deleted.contains('meal:$entity')) {
          mealPlans[entity] = existing?['eaten_at'] == null
              ? row('plan')
              : existing!;
          result = {
            'meal_plan_conversion': {
              'plan': mealPlans[entity],
              'meal': null,
              'stats': readStats(),
              'created': false,
            },
          };
        } else {
          final created = !meals.containsKey(entity);
          if (created) {
            mealPlans[entity] = row('plan');
            meals[entity] = row('meal');
            incrementStats(entity, 1, 0);
            if (body['track_day'] == true) {
              recordDay(meals[entity]!['local_day'] as String);
            }
          }
          result = {
            'meal_plan_conversion': {
              'plan': mealPlans[entity],
              'meal': meals[entity],
              'stats': readStats(),
              'created': created,
            },
          };
        }
      case 'shoppingCheck':
        shoppingChecks[entity] = body['checked'] as bool;
      case 'trackingDay':
        recordDay(entity);
        result = {'lifetime_stats': readStats()};
      case 'statsIncrement':
        incrementStats(
          entity,
          body['meals'] as int? ?? 0,
          body['weight_logs'] as int? ?? 0,
        );
        result = {'lifetime_stats': readStats()};
      default:
        throw PostgrestException(
          message: 'Unknown operation $kind',
          code: '22023',
        );
    }
    final receipt = <String, dynamic>{
      'operation_id': operationId,
      'kind': kind,
      'entity_id': entity,
      'result': result,
    };
    _fingerprints[operationId] = fingerprint;
    receipts[operationId] = _copy(receipt);
    return _withCurrentState(receipt);
  }

  Map<String, dynamic> _withCurrentState(Map<String, dynamic> receipt) {
    final response = _copy(receipt);
    final kind = receipt['kind'] as String;
    final entity = receipt['entity_id'] as String;
    final result = receipt['result'] as Map;
    final conversion = result['meal_plan_conversion'] as Map?;
    final state = <String, dynamic>{
      if (result['lifetime_stats'] != null || conversion?['stats'] != null)
        'lifetime_stats': readStats(),
    };
    if (kind.startsWith('recipe')) {
      Map<String, dynamic> recipeState(String slug) => {
        'slug': slug,
        'revision': recipeHeads[slug] ?? 0,
        'deleted': !recipes.containsKey(slug),
        'recipe': recipes[slug],
      };
      state['recipe'] = recipeState(entity);
      final result = receipt['result'] as Map;
      final mutation = result['recipe_mutation'] as Map?;
      final saved = mutation?['saved_recipe'] as Map?;
      if (saved != null) {
        state['saved_recipe'] = recipeState(saved['slug'] as String);
      }
    } else if (kind.startsWith('mealPlan')) {
      state['planned_meal'] = mealPlans[entity];
      state['entity_deleted'] =
          mealPlans[entity] == null || mealPlans[entity]?['removed'] == true;
      if (kind == 'mealPlanConvert') {
        state['meal_deleted'] = !meals.containsKey(entity);
      }
    } else if (kind.startsWith('meal')) {
      state['entity_deleted'] = !meals.containsKey(entity);
    } else if (kind.startsWith('trainingPlan')) {
      final requested =
          (result['training_mutation'] as Map?)?['incarnation'] ?? 0;
      final plan = trainingPlans[entity];
      final source = _trainingSource(entity);
      state['entity_deleted'] =
          plan == null || (plan['incarnation'] ?? 0) != requested;
      state['training_head'] = source == null ? null : readTrainingHead(source);
      state['training_plan'] = plan;
    } else if (kind.startsWith('trainingHistory')) {
      state['entity_deleted'] = !trainingHistory.containsKey(entity);
    }
    response['current_state'] = _copy(state);
    return response;
  }

  static String _statsId(String source) {
    final compact = source.replaceAll('-', '');
    final mask = utf8.encode('eatova-stats-rid');
    if (compact.length != 32) {
      throw const FormatException('Invalid source UUID');
    }
    final hex = List.generate(
      16,
      (i) =>
          (int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16) ^ mask[i])
              .toRadixString(16)
              .padLeft(2, '0'),
    ).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
