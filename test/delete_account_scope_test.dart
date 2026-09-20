import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/atomic_store_faults.dart';

String _token(String owner, String sid, {bool recovery = false}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256'})}.'
      '${encode({
        'sub': owner,
        'session_id': sid,
        'exp': 4102444800,
        if (recovery) 'amr': [
            {'method': 'otp', 'timestamp': 1790000000},
          ],
      })}.fixture-signature';
}

String _session(String sid, {String owner = 'owner', bool recovery = false}) =>
    jsonEncode({
      'access_token': _token(owner, sid, recovery: recovery),
      'refresh_token': 'fixture-$sid',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': owner,
        'email': '$owner@example.invalid',
        'aud': 'authenticated',
        'created_at': '2026-09-20T00:00:00Z',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
      },
    });

class _Fixture {
  _Fixture({Duration? deadline}) {
    transport = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/verify')) {
        if (!entered.isCompleted) entered.complete();
        await verifyGate?.future;
        return http.Response(
          _session('recovery', owner: verifiedOwner, recovery: true),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.endsWith('/rpc/delete_account')) {
        if (!rpcEntered.isCompleted) rpcEntered.complete();
        await rpcGate?.future;
        return rejectDeletion
            ? http.Response(
                '{"code":"28000","message":"EX_REAUTH_REQUIRED"}',
                403,
                request: request,
                headers: {'content-type': 'application/json'},
              )
            : http.Response('', 204, request: request);
      }
      throw StateError('Unexpected request ${request.url.path}');
    });
    client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.implicit,
      ),
      postgrestOptions: PostgrestClientOptions(requestTimeout: deadline),
    );
    repo = SupabaseAuthRepository(client, mutationHttpClient: transport);
    addTearDown(client.dispose);
  }
  late final MockClient transport;
  late final SupabaseClient client;
  late final SupabaseAuthRepository repo;
  final requests = <http.Request>[];
  final entered = Completer<void>();
  final rpcEntered = Completer<void>();
  Completer<void>? verifyGate;
  Completer<void>? rpcGate;
  String verifiedOwner = 'owner';
  bool rejectDeletion = false;
  Iterable<http.Request> get deletes =>
      requests.where((r) => r.url.path.endsWith('/rpc/delete_account'));
  Future<void> login(String sid, {String owner = 'owner'}) =>
      client.auth.setInitialSession(_session(sid, owner: owner));
  Future<void> delete(ScopedAccountDeleteAction action) =>
      repo.withAccountDeletionCode(
        userId: 'owner',
        sessionId: 'initial',
        email: 'owner@example.invalid',
        code: '12345678',
        performDeletion: action,
      );
}

class _Notifications extends NoopNotificationService {
  int cancellations = 0;
  @override
  Future<void> cancelAll() async {
    cancellations++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'timed-out verification cannot delete after a late OTP response',
    () async {
      final f = _Fixture(deadline: const Duration(milliseconds: 30))
        ..verifyGate = Completer<void>();
      await f.login('initial');
      var callbacks = 0;
      await expectLater(
        f
            .delete((request, _) async {
              callbacks++;
              await request();
            })
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      f.verifyGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(callbacks, 0);
      expect(f.deletes, isEmpty);
      expect(f.repo.currentUser?.sessionId, 'initial');
    },
  );

  test(
    'silent deletion aborts at the configured deadline and cannot complete late',
    () async {
      final lateResponse = Completer<http.StreamedResponse>();
      var aborted = false;
      var deleted = false;
      final transport = MockClient.streaming((request, body) async {
        await body.drain<void>();
        if (request.url.path.endsWith('/verify')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(_session('recovery', recovery: true))),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        expect(request.url.path, '/rest/v1/rpc/delete_account');
        final abort = (request as http.AbortableRequest).abortTrigger!;
        return Future.any([
          lateResponse.future,
          abort.then<http.StreamedResponse>((_) {
            aborted = true;
            throw http.RequestAbortedException(request.url);
          }),
        ]);
      });
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        postgrestOptions: const PostgrestClientOptions(
          requestTimeout: Duration(milliseconds: 30),
        ),
      );
      addTearDown(client.dispose);
      await client.auth.setInitialSession(_session('initial'));
      final repo = SupabaseAuthRepository(
        client,
        mutationHttpClient: transport,
      );
      await expectLater(
        repo.withAccountDeletionCode(
          userId: 'owner',
          sessionId: 'initial',
          email: 'owner@example.invalid',
          code: '12345678',
          performDeletion: (request, _) async {
            await request();
            deleted = true;
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(aborted, isTrue);
      lateResponse.complete(http.StreamedResponse(const Stream.empty(), 204));
      await Future<void>.delayed(Duration.zero);
      expect(deleted, isFalse);
      expect(repo.currentUser?.sessionId, 'initial');
    },
    timeout: const Timeout(Duration(seconds: 3)),
  );

  test(
    'confirmed deletion permits sign-out even when the local purge fails',
    () async {
      final f = _Fixture();
      await f.login('initial');
      final faults = AtomicStoreFaults(InMemoryKeyValueStore());
      final cache = LocalCache(faults, 'owner');
      addTearDown(cache.close);
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
      var failedPurge = false;
      faults.beforeWrite = (changes) async {
        if (changes.entries.any(
          (entry) => entry.key.contains('.stats.') && entry.value == null,
        )) {
          failedPurge = true;
          throw StateError('fixture purge failure');
        }
      };
      final store = HomeStore(
        sync: EatovaSync.forUser(f.client, 'owner'),
        health: const NoopHealthService(),
        notificationService: _Notifications(),
        initialUserName: 'Fixture',
        debugCache: cache,
        emitSnack:
            (
              message, {
              icon = Icons.info_outline_rounded,
              tone = SnackTone.positive,
              duration,
              action,
            }) {},
      );
      addTearDown(store.dispose);
      var signOutAllowed = false;
      await f.delete((request, current) async {
        final deleted = await store.deleteAccount(
          deleteRemote: request,
          isCurrentSession: current,
        );
        signOutAllowed = deleted && current();
      });
      expect(f.deletes, hasLength(1));
      expect(failedPurge, isTrue);
      expect(signOutAllowed, isTrue);
    },
  );
  test(
    'delete uses only the recovery bearer and never adopts its session',
    () async {
      final f = _Fixture();
      await f.login('initial');
      final events = <String?>[];
      final sub = f.repo.authStateChanges.listen(
        (u) => events.add(u?.sessionId),
      );
      addTearDown(sub.cancel);
      await f.delete((deleteRemote, current) async {
        expect(current(), isTrue);
        expect(f.repo.currentUser?.sessionId, 'initial');
        await deleteRemote();
        expect(current(), isTrue);
      });
      expect(f.deletes, hasLength(1));
      expect(
        f.deletes.single.headers['authorization'],
        'Bearer ${_token('owner', 'recovery', recovery: true)}',
      );
      expect(f.repo.currentUser?.sessionId, 'initial');
      expect(events, isNot(contains('recovery')));
      expect(f.requests.where((r) => r.url.path.endsWith('/token')), isEmpty);
    },
  );

  test(
    'a verified token for another owner cannot delete either account',
    () async {
      final f = _Fixture()..verifiedOwner = 'other';
      await f.login('initial');
      await expectLater(
        f.delete((request, _) => request()),
        throwsA(isA<AuthException>()),
      );
      expect(f.deletes, isEmpty);
      expect(f.repo.currentUser?.id, 'owner');
    },
  );

  for (final mode in ['other owner', 'same owner login', 'ABA']) {
    test(
      '$mode during verification invalidates deletion permanently',
      () async {
        final f = _Fixture()..verifyGate = Completer<void>();
        await f.login('initial');
        var callbacks = 0;
        final outcome = expectLater(
          f.delete((request, _) async {
            callbacks++;
            await request();
          }),
          throwsA(isA<AuthException>()),
        );
        await f.entered.future;
        await f.login(
          'replacement',
          owner: mode == 'same owner login' ? 'owner' : 'other',
        );
        if (mode == 'ABA') await f.login('initial');
        f.verifyGate!.complete();
        await outcome;
        expect(callbacks, 0);
        expect(f.deletes, isEmpty);
      },
    );
  }

  test(
    'a switch after verification but before delete fails before HTTP',
    () async {
      final f = _Fixture();
      await f.login('initial');
      await expectLater(
        f.delete((request, current) async {
          await f.login('replacement');
          expect(current(), isFalse);
          await request();
        }),
        throwsA(isA<AuthException>()),
      );
      expect(f.deletes, isEmpty);
    },
  );

  test(
    'ABA after the server request prevents global cleanup and logout',
    () async {
      final f = _Fixture()..rpcGate = Completer<void>();
      await f.login('initial');
      var globalCleanup = 0;
      final deletion = f.delete((request, current) async {
        await request();
        if (current()) globalCleanup++;
      });
      await f.rpcEntered.future;
      await f.login('replacement', owner: 'other');
      await f.login('initial');
      f.rpcGate!.complete();
      await deletion;
      expect(f.deletes, hasLength(1));
      expect(globalCleanup, 0);
      expect(f.repo.currentUser?.sessionId, 'initial');
    },
  );

  test(
    'HomeStore retains local state when its deletion session changed in flight',
    () async {
      final f = _Fixture()..rpcGate = Completer<void>();
      await f.login('initial');
      final cache = LocalCache(InMemoryKeyValueStore(), 'owner');
      addTearDown(cache.close);
      await cache.writeLifetimeStats(LifetimeStats(mealsLogged: 12));
      final notifications = _Notifications();
      final store = HomeStore(
        sync: EatovaSync.forUser(f.client, 'owner'),
        health: const NoopHealthService(),
        notificationService: notifications,
        initialUserName: 'Fixture',
        debugCache: cache,
        emitSnack:
            (
              message, {
              icon = Icons.info_outline_rounded,
              tone = SnackTone.positive,
              duration,
              action,
            }) {},
      );
      addTearDown(store.dispose);
      var logout = false;
      final deletion = f.delete((request, current) async {
        final deleted = await store.deleteAccount(
          deleteRemote: request,
          isCurrentSession: current,
        );
        if (deleted && current()) logout = true;
      });
      await f.rpcEntered.future;
      await f.login('replacement', owner: 'other');
      await f.login('initial');
      f.rpcGate!.complete();
      await deletion;
      expect(logout, isFalse);
      expect(notifications.cancellations, 0);
      expect((await cache.readLifetimeStats())?.mealsLogged, 12);
    },
  );

  test(
    'server rejection preserves the app session and has no success callback',
    () async {
      final f = _Fixture()..rejectDeletion = true;
      await f.login('initial');
      var cleaned = false;
      await expectLater(
        f.delete((request, _) async {
          await request();
          cleaned = true;
        }),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '28000'),
        ),
      );
      expect(cleaned, isFalse);
      expect(f.repo.currentUser?.sessionId, 'initial');
      expect(f.deletes, hasLength(1));
    },
  );

  test(
    'a deletion capability cannot be replayed or retained after its scope',
    () async {
      final f = _Fixture();
      await f.login('initial');
      late Future<void> Function() retained;
      late bool Function() current;
      await f.delete((request, guard) async {
        retained = request;
        current = guard;
        await request();
        await expectLater(request(), throwsA(isA<AuthException>()));
      });
      expect(current(), isFalse);
      await expectLater(retained(), throwsA(isA<AuthException>()));
      expect(f.deletes, hasLength(1));
    },
  );
}
