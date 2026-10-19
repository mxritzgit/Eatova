// 2026-10-19 review: the app only ever authenticated with Google. Nothing
// called signOut() on the app's sign-out, so the next Google login silently
// reused the last account, and nothing called disconnect() after a deleted
// account. Both now run best effort, behind GoogleSessionRevoker.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/auth/google_id_token_provider.dart';

/// Records the plugin calls the production provider makes.
class _FakeGooglePlatform extends GoogleSignInPlatform {
  final List<String> calls = <String>[];
  Completer<void>? holdDisconnect;
  Completer<void>? hangSignOut;
  bool failSignOut = false;

  @override
  Future<void> init(InitParameters params) async => calls.add('init');

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) {
    calls.add('restore');
    return Future<AuthenticationResults?>.value();
  }

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) =>
      throw UnimplementedError();

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<void> signOut(SignOutParams params) async {
    calls.add('signOut');
    if (failSignOut) throw StateError('account someone@example.invalid');
    await hangSignOut?.future;
  }

  @override
  Future<void> disconnect(DisconnectParams params) async {
    calls.add('disconnect:start');
    await holdDisconnect?.future;
    calls.add('disconnect:end');
  }
}

/// A provider fake for the repository: counts, and can fail or hang.
class _Revoker implements GoogleIdTokenProvider, GoogleSessionRevoker {
  int signOuts = 0;
  int disconnects = 0;
  Object? error;
  Completer<void>? hang;

  @override
  Future<String?> getIdToken() async => null;

  @override
  Future<void> signOut() async {
    signOuts++;
    if (error case final Object failure) throw failure;
    await hang?.future;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    if (error case final Object failure) throw failure;
    await hang?.future;
  }
}

String _session(String user, Map<String, dynamic> appMetadata) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token =
      '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': user, 'session_id': 'session-$user', 'exp': 4102444800})}.'
      'synthetic-signature';
  return jsonEncode({
    'access_token': token,
    'refresh_token': 'synthetic-refresh-$user',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': user,
      'aud': 'authenticated',
      'email': '$user@example.invalid',
      'created_at': '2026-09-14T10:00:00Z',
      'app_metadata': appMetadata,
      'user_metadata': <String, dynamic>{},
    },
  });
}

const _google = <String, dynamic>{
  'provider': 'google',
  'providers': <String>['google'],
};
const _email = <String, dynamic>{
  'provider': 'email',
  'providers': <String>['email'],
};

Future<(SupabaseAuthRepository, SupabaseClient)> _repository(
  _Revoker revoker,
  Map<String, dynamic> appMetadata, {
  int logoutStatus = 200,
}) async {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(
      (request) async => http.Response('{}', logoutStatus),
    ),
  );
  addTearDown(client.dispose);
  await client.auth.setInitialSession(_session('user-a', appMetadata));
  return (
    SupabaseAuthRepository(client, googleIdTokenProvider: revoker),
    client,
  );
}

void main() {
  group('Abmelden beendet die Google-Anmeldung des Geraets', () {
    test('ein Google-Konto ruft nach dem Abmelden genau einmal signOut',
        () async {
      final revoker = _Revoker();
      final (repository, client) = await _repository(revoker, _google);

      await repository.signOutWithCleanup(() async {
        expect(revoker.signOuts, 0, reason: 'erst nach dem App-Abmelden');
      });
      await pumpEventQueue();

      expect(client.auth.currentSession, isNull);
      expect(revoker.signOuts, 1);
      expect(revoker.disconnects, 0);
    });

    test('ein E-Mail-Konto laesst das Google-Plugin in Ruhe', () async {
      final revoker = _Revoker();
      final (repository, _) = await _repository(revoker, _email);

      await repository.signOut();
      await pumpEventQueue();

      expect(revoker.signOuts, 0);
    });

    test('ein scheiterndes oder haengendes signOut blockiert das Abmelden nie',
        () async {
      final failing = _Revoker()..error = StateError('plugin');
      final (failingRepository, failingClient) =
          await _repository(failing, _google);
      await expectLater(failingRepository.signOut(), completes);
      await pumpEventQueue();
      expect(failingClient.auth.currentSession, isNull);
      expect(failing.signOuts, 1);

      final hanging = _Revoker()..hang = Completer<void>();
      final (hangingRepository, hangingClient) =
          await _repository(hanging, _google);
      await expectLater(hangingRepository.signOut(), completes);
      expect(hangingClient.auth.currentSession, isNull);
      expect(hanging.signOuts, 1);
      hanging.hang!.complete();
    });

    test('scheitert das Abmelden, bevor die Sitzung endet, bleibt Google '
        'angemeldet', () async {
      final revoker = _Revoker();
      final (repository, client) = await _repository(revoker, _google);

      await expectLater(
        repository.signOutWithCleanup(() async {
          // Another login replaced the session during cleanup.
          await client.auth.setInitialSession(_session('user-b', _google));
        }),
        throwsA(isA<AuthException>()),
      );
      await pumpEventQueue();

      expect(client.auth.currentUser?.id, 'user-b');
      expect(revoker.signOuts, 0);
    });
  });

  group('nach der Kontoloeschung wird die Google-Freigabe widerrufen', () {
    test('ein Google-Konto ruft disconnect', () async {
      final revoker = _Revoker();
      final (repository, _) = await _repository(revoker, _google);

      await repository.revokeProviderGrants();

      expect(revoker.disconnects, 1);
    });

    test('ein E-Mail-Konto nicht, ein Fehler nie bis zur Loeschung', () async {
      final email = _Revoker();
      final (emailRepository, _) = await _repository(email, _email);
      await emailRepository.revokeProviderGrants();
      expect(email.disconnects, 0);

      final failing = _Revoker()..error = StateError('plugin');
      final (failingRepository, _) = await _repository(failing, _google);
      await expectLater(failingRepository.revokeProviderGrants(), completes);
      expect(failing.disconnects, 1);
    });
  });

  group('GoogleSignInIdTokenProvider gegen das Plugin', () {
    late _FakeGooglePlatform platform;

    setUp(() {
      final previous = GoogleSignInPlatform.instance;
      platform = _FakeGooglePlatform();
      GoogleSignInPlatform.instance = platform;
      addTearDown(() => GoogleSignInPlatform.instance = previous);
    });

    test('signOut initialisiert bei Bedarf und meldet ab; Fehler bleiben '
        'drinnen', () async {
      const provider = GoogleSignInIdTokenProvider();
      await provider.signOut();
      expect(platform.calls.where((call) => call != 'init'), ['signOut']);

      platform.failSignOut = true;
      await expectLater(provider.signOut(), completes);
    });

    test('ein disconnect laeuft fertig, bevor ein folgendes signOut beginnt',
        () async {
      const provider = GoogleSignInIdTokenProvider();
      platform.holdDisconnect = Completer<void>();
      final disconnect = provider.disconnect();
      final signOut = provider.signOut();
      await pumpEventQueue();
      expect(platform.calls, isNot(contains('signOut')),
          reason: 'sonst verliert das disconnect seinen Nutzer');

      platform.holdDisconnect!.complete();
      await Future.wait(<Future<void>>[disconnect, signOut]);
      final order = platform.calls.where((call) => call != 'init').toList();
      expect(order, ['disconnect:start', 'disconnect:end', 'signOut']);
    });

    test('auf iOS stellt disconnect die Anmeldung erst still wieder her',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const provider = GoogleSignInIdTokenProvider();

      await provider.disconnect();

      expect(platform.calls.where((call) => call != 'init'),
          ['restore', 'disconnect:start', 'disconnect:end']);
    });

    test('auf Android gibt es keine stille Wiederherstellung', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const provider = GoogleSignInIdTokenProvider();

      await provider.disconnect();

      expect(platform.calls, isNot(contains('restore')));
      expect(platform.calls, contains('disconnect:end'));
    });

    test('ein haengendes Plugin gibt nach der Frist den Weg frei', () async {
      // The provider's queue and its one-time initialization are static and
      // belong to the test zone, so a short real bound instead of fake time.
      const frist = Duration(milliseconds: 50);
      final standard = GoogleSignInIdTokenProvider.revokeTimeout;
      GoogleSignInIdTokenProvider.revokeTimeout = frist;
      addTearDown(() => GoogleSignInIdTokenProvider.revokeTimeout = standard);
      const provider = GoogleSignInIdTokenProvider();
      platform.hangSignOut = Completer<void>();
      var disconnected = false;

      final signOut = provider.signOut();
      final disconnect = provider.disconnect().then((_) => disconnected = true);
      await pumpEventQueue();
      expect(disconnected, isFalse, reason: 'wartet auf den Vorgaenger');

      await signOut.timeout(const Duration(seconds: 5));
      await disconnect.timeout(const Duration(seconds: 5));
      expect(disconnected, isTrue,
          reason: 'die Warteschlange haengt nicht am alten Aufruf');
      expect(platform.calls, contains('disconnect:end'));
      platform.hangSignOut!.complete();
    });
  });
}
