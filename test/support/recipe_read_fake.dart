import 'dart:convert';

import 'package:http/http.dart' as http;

/// Empty recipe sections for tests whose data concern other export tables.
http.Response? emptyRecipeReadResponse(http.Request request) {
  final Object body;
  if (request.url.path.endsWith('/rpc/load_recipe_page')) {
    body = {'watermark': 0, 'rows': [], 'next_after': null, 'complete': true};
  } else if (request.url.path.endsWith('/rpc/load_recipe_photo_refs')) {
    body = {'watermark': 0, 'refs': [], 'next_after': null, 'complete': true};
  } else if (request.url.path.endsWith('/rpc/load_recipe_history')) {
    body = {
      'current_revision': null,
      'current_deleted': null,
      'versions': [],
      'next_before': null,
    };
  } else {
    return null;
  }
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );
}

/// Snapshot RPC fixture used by integration fakes. CRUD remains owned by each
/// fake; a frozen copy per read watermark prevents moving pagination windows.
class RecipeReadFake {
  int _stamp = 0;
  final _snapshots = <int, List<Map<String, dynamic>>>{};
  int pageCalls = 0;
  int? failPage;
  int photoPageCalls = 0;
  int? failPhotoPage;
  final historicalPhotos = <String>{};
  final _photoSnapshots = <int, List<String>>{};

  Map<String, dynamic> photoPage(http.Request request, Iterable<Map<String, dynamic>> current) {
    photoPageCalls++;
    final params = jsonDecode(request.body) as Map<String, dynamic>;
    final limit = params['p_limit'] as int;
    if (limit < 1 || limit > 200) throw StateError('Unbounded photo query');
    final requested = params['p_watermark'] as int?;
    final stamp = requested ?? ++_stamp;
    if (requested == null) {
      final refs = {...historicalPhotos, ...current.map((row) => row['image_asset']).whereType<String>()}
          .where((value) => value.startsWith('local:')).toList()..sort();
      _photoSnapshots[stamp] = refs;
    }
    final after = params['p_after_ref'] as String?;
    final remaining = _photoSnapshots[stamp]!.where((ref) => after == null || ref.compareTo(after) > 0).toList();
    final selected = remaining.take(limit).toList();
    final complete = remaining.length <= limit;
    return {'watermark': stamp, 'refs': selected, 'complete': complete,
      'next_after': complete ? null : selected.last};
  }

  Map<String, dynamic> page(
    http.Request request,
    Iterable<Map<String, dynamic>> current,
  ) {
    pageCalls++;
    final params = jsonDecode(request.body) as Map<String, dynamic>;
    final limit = params['p_limit'] as int;
    if (limit < 1 || limit > 200) throw StateError('Unbounded recipe query');
    final requested = params['p_watermark'] as int?;
    int stamp;
    if (requested == null) {
      final rows = current.map(Map<String, dynamic>.of).toList()
        ..sort((a, b) => (a['slug'] as String).compareTo(b['slug'] as String));
      for (final row in rows) {
        final revision = row['server_revision'] as int?;
        if (revision != null && revision > _stamp) _stamp = revision;
      }
      stamp = ++_stamp;
      _snapshots[stamp] = [
        for (final row in rows)
          {...row, 'server_revision': row['server_revision'] ?? stamp},
      ];
    } else {
      stamp = requested;
    }
    final snapshot = _snapshots[stamp];
    if (snapshot == null) throw StateError('Unknown recipe watermark');
    final after = params['p_after_slug'] as String?;
    final remaining = snapshot
        .where(
          (row) =>
              after == null || (row['slug'] as String).compareTo(after) > 0,
        )
        .toList();
    final selected = remaining.take(limit).toList();
    final complete = remaining.length <= limit;
    return {
      'watermark': stamp,
      'rows': selected,
      'complete': complete,
      'next_after': complete ? null : selected.last['slug'],
    };
  }
}
