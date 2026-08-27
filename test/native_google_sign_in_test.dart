import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_exceptions.dart';
import 'package:eatova/src/auth/google_id_token_provider.dart';

class _FakeProvider implements GoogleIdTokenProvider {
  _FakeProvider(this._getIdToken);
  final Future<String?> Function() _getIdToken;
  @override
  Future<String?> getIdToken() => _getIdToken();
}

void main() {
  group('runNativeGoogleSignIn', () {
    test('tauscht das ID-Token ein und meldet Erfolg', () async {
      final exchanged = <String>[];
      final ok = await runNativeGoogleSignIn(
        tokenProvider: _FakeProvider(() async => 'token-123'),
        exchangeIdToken: (idToken) async => exchanged.add(idToken),
      );
      expect(ok, isTrue);
      expect(exchanged, ['token-123']);
    });

    test('User-Abbruch wirft den TYP AuthCancelledException, keinen Satz',
        () async {
      var exchangeCalls = 0;
      await expectLater(
        runNativeGoogleSignIn(
          tokenProvider: _FakeProvider(() async => null),
          exchangeIdToken: (_) async => exchangeCalls++,
        ),
        throwsA(
          isA<AuthCancelledException>()
              .having((e) => e.provider, 'provider', 'Google'),
        ),
      );
      expect(exchangeCalls, 0);
    });

    test('technischer Fehler meldet false fuer den Web-Fallback', () async {
      var exchangeCalls = 0;
      final ok = await runNativeGoogleSignIn(
        tokenProvider: _FakeProvider(() async => throw StateError('kaputt')),
        exchangeIdToken: (_) async => exchangeCalls++,
      );
      expect(ok, isFalse);
      expect(exchangeCalls, 0);
    });

    test('Exchange-Fehler propagiert unveraendert, kein stiller Fallback',
        () async {
      await expectLater(
        runNativeGoogleSignIn(
          tokenProvider: _FakeProvider(() async => 'token-123'),
          exchangeIdToken: (_) async =>
              throw const AuthException('audience mismatch'),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
