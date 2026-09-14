import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/config/supabase_config.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _key = 'audit-session';

String _session(String user, String? sessionId, {int version = 1}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token =
      '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': user, 'session_id': sessionId, 'exp': 4102444800, 'version': version})}.'
      'synthetic-signature';
  return jsonEncode({
    'access_token': token,
    'refresh_token': 'synthetic-refresh-$user-$version',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': user,
      'aud': 'authenticated',
      'email': '$user@example.invalid',
      'created_at': '2026-09-14T10:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

class _SecureStore implements SecureKeyStore {
  final data = <String, String>{};
  bool deleteFails = false;
  int readFailures = 0;

  @override
  Future<String?> read(String key) async {
    if (readFailures > 0) {
      readFailures--;
      throw StateError('synthetic secure-read failure');
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async {
    if (deleteFails) throw StateError('synthetic secure-delete failure');
    data.remove(key);
  }
}

class _JournalStore extends InMemoryKeyValueStore {
  bool readFails = false;
  bool writeFails = false;
  bool dropWrites = false;
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;

  @override
  Future<String?> getString(String key) async {
    if (readFails && key.endsWith('.logout-v1')) {
      throw StateError('synthetic journal-read failure');
    }
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key.endsWith('.logout-v1')) {
      if (writeFails) throw StateError('synthetic journal-write failure');
      if (dropWrites) return;
      final gate = releaseWrite;
      if (gate != null) {
        releaseWrite = null;
        writeStarted!.complete();
        await gate.future;
      }
    }
    await super.setString(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'failed secure delete cannot restore A in a new SDK/storage instance',
    () async {
      final secure = _SecureStore()..deleteFails = true;
      final prefs = InMemoryKeyValueStore();
      SecureSessionLocalStorage freshStorage() => SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: prefs,
      );
      final original = freshStorage();
      await original.persistSession(_session('account-a', 'session-a'));
      await original.removePersistedSession();
      expect(
        secure.data[_key],
        isNotNull,
        reason: 'The simulated fault must really leave session bytes behind.',
      );

      await Supabase.initialize(
        url: 'https://ci.invalid',
        publishableKey: 'ci-dummy-key',
        httpClient: MockClient(
          (request) async => http.Response(
            _session('account-b', 'session-b'),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        authOptions: FlutterAuthClientOptions(
          localStorage: freshStorage(),
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
      );
      addTearDown(() => Supabase.instance.dispose());
      expect(
        Supabase.instance.client.auth.currentSession == null,
        isTrue,
        reason: 'A failed delete must never silently sign A back in.',
      );

      // A genuinely new SDK login may persist even while A's delete still fails.
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'account-b@example.invalid',
        password: 'synthetic-password',
      );
      await Future<void>.delayed(Duration.zero);
      final restored = await freshStorage().accessToken();
      expect(jsonDecode(restored!)['user']['id'], 'account-b');
    },
  );

  test(
    'rotated tokens and late A events cannot reopen its failed logout',
    () async {
      final secure = _SecureStore()..deleteFails = true;
      final prefs = _JournalStore();
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: prefs,
      );
      await storage.persistSession(_session('a', 'session-a'));
      await storage.removePersistedSession();
      await storage.persistSession(_session('a', 'session-a', version: 2));
      expect(await storage.accessToken(), isNull);
      await storage.persistSession(_session('b', 'session-b'));
      await storage.persistSession(_session('a', 'session-a', version: 3));
      expect(jsonDecode((await storage.accessToken())!)['user']['id'], 'b');
      expect(
        prefs.snapshot.values.join(),
        isNot(contains('synthetic-refresh')),
      );
      expect(prefs.snapshot.values.join(), isNot(contains('access_token')));
    },
  );

  test(
    'new session of the same user is distinct from a revoked login',
    () async {
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: _SecureStore()..deleteFails = true,
        legacyStore: _JournalStore(),
      );
      await storage.persistSession(_session('a', 'old-session'));
      await storage.removePersistedSession();
      final next = _session('a', 'new-session');
      await storage.persistSession(next);
      expect(await storage.accessToken(), next);
    },
  );

  for (final missingId in <String?>[null, '']) {
    test(
      'missing/empty session id cannot escape logout by token rotation ($missingId)',
      () async {
        final secure = _SecureStore()..deleteFails = true;
        final prefs = _JournalStore();
        SecureSessionLocalStorage fresh() => SecureSessionLocalStorage(
          persistSessionKey: _key,
          secureStore: secure,
          legacyStore: prefs,
        );
        await fresh().persistSession(_session('a', missingId));
        await fresh().removePersistedSession();
        final restarted = fresh();
        await restarted.persistSession(_session('a', missingId, version: 2));
        expect(await restarted.accessToken(), isNull);
      },
    );
  }

  test(
    'legacy plaintext cannot migrate a revoked session back on restart',
    () async {
      final secure = _SecureStore()..deleteFails = true;
      final prefs = _JournalStore();
      SecureSessionLocalStorage fresh() => SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: prefs,
      );
      final old = _session('a', 'session-a');
      await fresh().persistSession(old);
      await fresh().removePersistedSession();
      secure.data.clear();
      await prefs.setString(_key, old);
      expect(await fresh().accessToken(), isNull);
      expect(await prefs.getString(_key), isNull);
    },
  );

  test(
    'journal read failure and corrupt data deny restore in a new instance',
    () async {
      final secure = _SecureStore();
      final prefs = _JournalStore();
      SecureSessionLocalStorage fresh() => SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: prefs,
      );
      await fresh().persistSession(_session('a', 'session-a'));
      prefs.readFails = true;
      expect(await fresh().accessToken(), isNull);
      prefs.readFails = false;
      await prefs.setString('$_key.logout-v1', 'invalid-journal');
      expect(await fresh().accessToken(), isNull);
    },
  );

  test(
    'ordered logout cannot erase B queued after it; retired A stays blocked',
    () async {
      final secure = _SecureStore();
      final prefs = _JournalStore();
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: prefs,
      );
      await storage.persistSession(_session('a', 'session-a'));
      final gate = Completer<void>();
      prefs.writeStarted = Completer<void>();
      prefs.releaseWrite = gate;
      final logout = storage.removePersistedSession();
      await prefs.writeStarted!.future;
      final login = storage.persistSession(_session('b', 'session-b'));
      gate.complete();
      await Future.wait([logout, login]);
      await storage.persistSession(_session('a', 'session-a', version: 2));
      expect(jsonDecode((await storage.accessToken())!)['user']['id'], 'b');
      expect(jsonDecode(prefs.snapshot['$_key.logout-v1']!), isEmpty);
    },
  );

  test(
    'stale persistence is rejected against the actual current SDK token',
    () async {
      var current = 'none';
      final secure = _SecureStore();
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: _JournalStore(),
        currentAccessToken: () => current,
      );
      final b = _session('b', 'session-b');
      current = jsonDecode(b)['access_token'] as String;
      await storage.persistSession(b);
      await storage.persistSession(_session('a', 'session-a'));
      expect(await storage.accessToken(), b);
    },
  );

  for (final silent in [false, true]) {
    test(
      'unacknowledged journal prevents explicit SDK logout ($silent)',
      () async {
        var logoutCalls = 0;
        final client = SupabaseClient(
          'https://ci.invalid',
          'ci-dummy-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            logoutCalls++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        final a = _session('a', 'session-a');
        await client.auth.setInitialSession(a);
        final prefs = _JournalStore();
        final storage = SecureSessionLocalStorage(
          persistSessionKey: _key,
          secureStore: _SecureStore(),
          legacyStore: prefs,
        );
        await storage.persistSession(a);
        if (silent) {
          prefs.dropWrites = true;
        } else {
          prefs.writeFails = true;
        }
        final repository = SupabaseAuthRepository(
          client,
          sessionStorage: storage,
        );
        await expectLater(repository.signOut(), throwsStateError);
        expect(
          client.auth.currentUser?.id,
          'a',
          reason:
              'Failed logout must not be presented as a cleared SDK session.',
        );
        expect(logoutCalls, 0);
      },
    );
  }

  test(
    'A logout preflight cannot sign out a concurrent new B session',
    () async {
      var logoutCalls = 0;
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          logoutCalls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.dispose);
      await client.auth.setInitialSession(_session('a', 'session-a'));
      final prefs = _JournalStore();
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: _SecureStore(),
        legacyStore: prefs,
      );
      final gate = Completer<void>();
      prefs.writeStarted = Completer<void>();
      prefs.releaseWrite = gate;
      final repository = SupabaseAuthRepository(
        client,
        sessionStorage: storage,
      );
      final logout = repository.signOut();
      final rejected = expectLater(logout, throwsA(isA<AuthException>()));
      await prefs.writeStarted!.future;
      await client.auth.setInitialSession(_session('b', 'session-b'));
      gate.complete();
      await rejected;
      expect(client.auth.currentUser?.id, 'b');
      expect(logoutCalls, 0);
    },
  );

  test('refresh of the same session does not abort logout preflight', () async {
    var logoutCalls = 0;
    final client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        logoutCalls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);
    await client.auth.setInitialSession(_session('a', 'session-a'));
    final prefs = _JournalStore();
    final storage = SecureSessionLocalStorage(
      persistSessionKey: _key,
      secureStore: _SecureStore(),
      legacyStore: prefs,
    );
    final gate = Completer<void>();
    prefs.writeStarted = Completer<void>();
    prefs.releaseWrite = gate;
    final logout = SupabaseAuthRepository(
      client,
      sessionStorage: storage,
    ).signOut();
    await prefs.writeStarted!.future;
    await client.auth.setInitialSession(_session('a', 'session-a', version: 2));
    gate.complete();
    await logout;
    expect(client.auth.currentUser, isNull);
    expect(logoutCalls, 1);
  });

  test('verified slot retirement keeps the durable journal bounded', () async {
    final secure = _SecureStore()..deleteFails = true;
    final prefs = _JournalStore();
    final storage = SecureSessionLocalStorage(
      persistSessionKey: _key,
      secureStore: secure,
      legacyStore: prefs,
    );
    for (var i = 0; i < 32; i++) {
      await storage.persistSession(_session('a', 'session-$i'));
      await storage.removePersistedSession();
      expect(
        (jsonDecode(prefs.snapshot['$_key.logout-v1']!) as List).length,
        1,
      );
    }
    final b = _session('b', 'session-b');
    await storage.persistSession(b);
    await storage.persistSession(_session('a', 'session-0', version: 2));
    expect(await storage.accessToken(), b);
  });

  test(
    'proved legacy removal permits modern A but rejects stale legacy writes',
    () async {
      final secure = _SecureStore();
      String? current;
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: _JournalStore(),
        currentAccessToken: () => current,
      );
      final legacy = _session('a', null);
      current = jsonDecode(legacy)['access_token'] as String;
      await storage.persistSession(legacy);
      current = null;
      await storage.removePersistedSession();
      final modern = _session('a', 'new-session-a');
      current = jsonDecode(modern)['access_token'] as String;
      await storage.persistSession(modern);
      await storage.persistSession(_session('a', null, version: 2));
      expect(await storage.accessToken(), modern);
    },
  );

  test(
    'proved unknown-session erasure permits a subsequent SDK-bound B login',
    () async {
      final secure = _SecureStore();
      final old = _session('a', null);
      secure.data[_key] = old;
      secure.readFailures = 1;
      String? current;
      final storage = SecureSessionLocalStorage(
        persistSessionKey: _key,
        secureStore: secure,
        legacyStore: _JournalStore(),
        currentAccessToken: () => current,
      );
      await storage.removePersistedSession();
      expect(secure.data[_key], isNull);
      final b = _session('b', 'session-b');
      current = jsonDecode(b)['access_token'] as String;
      await storage.persistSession(b);
      await storage.persistSession(old);
      expect(await storage.accessToken(), b);
    },
  );
}
