import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/user_recipe_reads.dart';
import 'package:eatova/src/services/data_export.dart';
import '../support/recipe_read_fake.dart';

Map<String, dynamic> _row(int index, {int? revision}) => {
  'slug': 'user_${index.toString().padLeft(4, '0')}',
  'title': 'Recipe $index',
  'ingredients': 'Rice',
  'preparation': 'Cook',
  'calories_kcal': 500,
  'protein_g': 30,
  'carbs_g': 40,
  'fat_g': 15,
  'estimated_g': 300,
  'created_at': '2026-09-20T10:00:00Z',
  'server_revision': revision ?? index + 1,
};

({UserRecipeReads reads, SupabaseClient client}) _reader(
  Future<http.Response> Function(http.Request) handler,
) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'fixture-anon',
    httpClient: MockClient(handler),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return (reads: UserRecipeReads(client, 'user-a'), client: client);
}

http.Response _answer(http.Request request, Object body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );

/// The fake stores immutable journal snapshots. Each request must seek after
/// the last slug, bind the same watermark, and obey the bounded page contract.
class _Journal {
  _Journal(int count) : current = List.generate(count, _row);
  List<Map<String, dynamic>> current;
  final snapshots = <int, List<Map<String, dynamic>>>{};
  final requests = <Map<String, dynamic>>[];
  void Function(int)? afterPage;
  int? failPage;
  int serverPageSize = UserRecipeReads.pageSize;

  Future<http.Response> handle(http.Request request) async {
    expect(request.method, 'POST');
    expect(request.url.path, endsWith('/rpc/load_recipe_page'));
    final params = jsonDecode(request.body) as Map<String, dynamic>;
    expect(
      params.keys,
      unorderedEquals(['p_watermark', 'p_after_slug', 'p_limit']),
    );
    expect(params['p_limit'], UserRecipeReads.pageSize);
    // Identity is the pinned bearer, never an arbitrary user-id RPC argument.
    expect(request.headers['authorization'], 'Bearer ');
    requests.add(params);
    if (requests.length == failPage) {
      return _answer(request, {
        'code': 'XX000',
        'message': 'fixture',
      }, status: 500);
    }
    final stamp = params['p_watermark'] as int? ?? 10000;
    final rows = snapshots.putIfAbsent(stamp, () => [...current]);
    final after = params['p_after_slug'] as String?;
    final remaining = rows
        .where(
          (r) => after == null || (r['slug'] as String).compareTo(after) > 0,
        )
        .toList();
    final selected = remaining.take(serverPageSize).toList();
    final complete = remaining.length <= selected.length;
    final result = {
      'watermark': stamp,
      'rows': selected,
      'next_after': complete ? null : selected.last['slug'],
      'complete': complete,
    };
    afterPage?.call(requests.length);
    return _answer(request, result);
  }
}

void main() {
  test(
    '451 historical photo references use a complete immutable snapshot',
    () async {
      final fake = RecipeReadFake();
      fake.historicalPhotos.addAll(
        List.generate(
          451,
          (i) => 'local:img_${i.toString().padLeft(4, '0')}.jpg',
        ),
      );
      final requests = <Map<String, dynamic>>[];
      final reader = _reader((request) async {
        expect(request.url.path, endsWith('/rpc/load_recipe_photo_refs'));
        final params = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(params);
        final page = fake.photoPage(request, []);
        if (fake.photoPageCalls == 1) {
          fake.historicalPhotos.add('local:img_later.jpg');
        }
        return _answer(request, page);
      }).reads;
      final refs = await reader.loadPhotoReferences();
      expect(refs, hasLength(451));
      expect(refs, isNot(contains('local:img_later.jpg')));
      expect(requests, hasLength(3));
      expect(requests.every((r) => r['p_limit'] == 200), isTrue);
      expect(requests.skip(1).map((r) => r['p_watermark']).toSet(), {
        requests[1]['p_watermark'],
      });
      expect(() => refs.clear(), throwsUnsupportedError);
    },
  );

  test(
    'photo page failure returns no partial result and retry restarts snapshot',
    () async {
      final fake = RecipeReadFake();
      fake.historicalPhotos.addAll(
        List.generate(201, (i) => 'local:img_$i.jpg'),
      );
      var fail = true;
      final reader = _reader((request) async {
        if (fail && fake.photoPageCalls == 1) {
          return _answer(request, {'message': 'unavailable'}, status: 500);
        }
        return _answer(request, fake.photoPage(request, []));
      }).reads;
      await expectLater(
        reader.loadPhotoReferences(),
        throwsA(isA<PostgrestException>()),
      );
      fail = false;
      expect(await reader.loadPhotoReferences(), hasLength(201));
    },
  );

  test(
    'non-local photo reference cannot authorize garbage collection',
    () async {
      final reader = _reader(
        (request) async => _answer(request, {
          'watermark': 1,
          'refs': ['https://private.invalid/photo'],
          'next_after': null,
          'complete': true,
        }),
      ).reads;
      await expectLater(reader.loadPhotoReferences(), throwsFormatException);
    },
  );

  test(
    '451 recipes with equal timestamps use bounded stable cursor pages',
    () async {
      final journal = _Journal(451);
      final reader = _reader(journal.handle).reads;
      final rows = await reader.load();
      expect(rows, hasLength(451));
      expect(rows.map((r) => r.slug).toSet(), hasLength(451));
      expect(journal.requests, hasLength(3));
      expect(journal.requests[0]['p_watermark'], isNull);
      expect(journal.requests[1]['p_watermark'], 10000);
      expect(journal.requests[1]['p_after_slug'], 'user_0199');
      expect(journal.requests[2]['p_after_slug'], 'user_0399');
      expect(rows.last.title, 'Recipe 450');
    },
  );

  test(
    'concurrent inserts and deletes cannot move the snapshot membership',
    () async {
      final journal = _Journal(401);
      journal.afterPage = (page) {
        if (page != 1) return;
        journal.current.removeWhere((r) => r['slug'] == 'user_0205');
        journal.current.add(_row(4999));
      };
      final rows = await _reader(journal.handle).reads.load();
      expect(rows, hasLength(401));
      expect(rows.map((r) => r.slug), contains('user_0205'));
      expect(rows.map((r) => r.slug), isNot(contains('user_4999')));
    },
  );

  test('a short server page is not confused with completion', () async {
    final journal = _Journal(201)..serverPageSize = 73;
    final rows = await _reader(journal.handle).reads.load();
    expect(rows, hasLength(201));
    expect(journal.requests, hasLength(3));
  });

  test(
    'second-page failure returns no partial list and retry starts anew',
    () async {
      final journal = _Journal(401)..failPage = 2;
      final reads = _reader(journal.handle).reads;
      List<Object>? published;
      await expectLater(
        reads.load().then((rows) => published = rows),
        throwsA(isA<PostgrestException>()),
      );
      expect(published, isNull);
      journal.failPage = null;
      journal.snapshots.clear();
      journal.current.add(_row(4999));
      final retried = await reads.load();
      expect(journal.requests[2]['p_watermark'], isNull);
      expect(journal.requests[2]['p_after_slug'], isNull);
      expect(retried, hasLength(402));
    },
  );

  for (final malformed in [
    'watermark',
    'duplicate',
    'cursor',
    'oversize',
    'revision',
  ]) {
    test('rejects malformed $malformed without partial publication', () async {
      var requestCount = 0;
      final reads = _reader((request) async {
        requestCount++;
        final page = <String, dynamic>{
          'watermark': 100,
          'rows': [_row(requestCount - 1)],
          'next_after': 'user_0000',
          'complete': false,
        };
        if (requestCount == 2 ||
            malformed == 'oversize' ||
            malformed == 'revision') {
          page['complete'] = true;
          page['next_after'] = null;
          switch (malformed) {
            case 'watermark':
              page['watermark'] = 101;
            case 'duplicate':
              page['rows'] = [_row(0)];
            case 'cursor':
              page['complete'] = false;
              page['next_after'] = 'wrong';
            case 'oversize':
              page['rows'] = List.generate(201, _row);
            case 'revision':
              page['rows'] = [_row(0, revision: 101)];
          }
        }
        return _answer(request, page);
      }).reads;
      await expectLater(reads.load(), throwsFormatException);
      expect(requestCount, lessThanOrEqualTo(2));
    });
  }

  test(
    'history seeks by owner-global revision and preserves deleted content',
    () async {
      final requests = <Map<String, dynamic>>[];
      final reads = _reader((request) async {
        expect(request.url.path, endsWith('/rpc/load_recipe_history'));
        final params = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(params);
        return _answer(request, {
          'current_revision': params['p_slug'] == null ? null : 8,
          'current_deleted': params['p_slug'] == null ? null : true,
          'versions': [
            {
              'revision': 8,
              'deleted': true,
              'recorded_at': '2026-09-20T10:00:00Z',
              'source': 'legacy',
              'recipe': _row(0, revision: 8),
            },
          ],
          'next_before': 8,
        });
      }).reads;
      final page = await reads.loadHistory();
      expect(page.versions.single.recipe.title, 'Recipe 0');
      expect(page.versions.single.deleted, isTrue);
      expect(page.currentRevision, isNull);
      final head = await reads.loadHistory(slug: 'user_0000');
      expect(head.currentRevision, 8);
      expect(head.currentDeleted, isTrue);
      expect(requests.first['p_limit'], 30);
      expect(requests.last['p_slug'], 'user_0000');
    },
  );

  test('history rejects a nonexclusive cursor or a different recipe', () async {
    final reads = _reader(
      (request) async => _answer(request, {
        'current_revision': 8,
        'current_deleted': false,
        'versions': [
          {
            'revision': 8,
            'deleted': false,
            'recorded_at': '2026-09-20T10:00:00Z',
            'recipe': _row(0),
          },
        ],
        'next_before': null,
      }),
    ).reads;
    await expectLater(
      reads.loadHistory(slug: 'user_0000', beforeRevision: 8),
      throwsFormatException,
    );
    await expectLater(
      reads.loadHistory(slug: 'user_other'),
      throwsFormatException,
    );
  });

  test(
    'changing accounts aborts the next page before issuing a request',
    () async {
      late SupabaseClient client;
      var calls = 0;
      final reader = _reader((request) async {
        calls++;
        final payload = base64Url
            .encode(utf8.encode(jsonEncode({'exp': 4102444800})))
            .replaceAll('=', '');
        await client.auth.recoverSession(
          jsonEncode({
            'access_token': 'e30.$payload.signature',
            'refresh_token': 'fixture',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': 'user-b',
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'fixture@example.invalid',
              'app_metadata': {},
              'user_metadata': {},
              'created_at': '2026-09-20T10:00:00Z',
            },
          }),
        );
        return _answer(request, {
          'watermark': 2,
          'rows': [_row(0)],
          'next_after': 'user_0000',
          'complete': false,
        });
      });
      client = reader.client;
      await expectLater(reader.reads.load(), throwsA(isA<AuthException>()));
      expect(calls, 1);
    },
  );
  for (final failHistory in [false, true]) {
    test(
      'export paginates recipe contents and history (failure=$failHistory)',
      () async {
        final journal = _Journal(451);
        var historyPages = 0;
        final reader = _reader((request) async {
          if (request.url.path.endsWith('/rpc/load_recipe_page')) {
            return journal.handle(request);
          }
          if (request.url.path.endsWith('/rpc/load_recipe_history')) {
            historyPages++;
            if (failHistory && historyPages == 2) {
              return _answer(request, {
                'code': 'XX000',
                'message': 'fixture',
              }, status: 500);
            }
            final params = jsonDecode(request.body) as Map<String, dynamic>;
            expect(params['p_limit'], 30);
            final before = params['p_before_revision'] as int? ?? 66;
            final remaining = List.generate(
              65,
              (i) => 65 - i,
            ).where((r) => r < before).toList();
            final revisions = remaining.take(30).toList();
            return _answer(request, {
              'current_revision': null,
              'current_deleted': null,
              'versions': [
                for (final revision in revisions)
                  {
                    'revision': revision,
                    'deleted': revision.isEven,
                    'recorded_at': '2026-09-20T10:00:00Z',
                    'source': 'legacy',
                    'recipe': _row(0, revision: revision),
                  },
              ],
              'next_before': remaining.length > 30 ? revisions.last : null,
            });
          }
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {
              'content-type': 'application/json',
              'content-range': '*/0',
            },
          );
        });
        final result =
            jsonDecode(
                  await DataExportService(
                    reader.client,
                    'user-a',
                  ).buildExportJson(),
                )
                as Map;
        expect(result['user_recipes'], hasLength(451));
        expect(
          (result['user_recipes'] as List).last['created_at'],
          '2026-09-20T10:00:00Z',
        );
        expect(journal.requests, hasLength(3));
        if (failHistory) {
          expect(result.containsKey('user_recipe_history'), isFalse);
          expect(result['unvollstaendig'], ['user_recipe_history']);
        } else {
          expect(result['user_recipe_history'], hasLength(65));
          expect(
            (result['user_recipe_history'] as List).first['source'],
            'legacy',
          );
          expect((result['user_recipe_history'] as List)[1]['deleted'], isTrue);
          expect(historyPages, 3);
          expect(result.containsKey('unvollstaendig'), isFalse);
        }
      },
    );
  }
}
