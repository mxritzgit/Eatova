import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';

// Sentinel finding 1 (2026-08-08): `defaultAuthRepository()` fell back to
// PreviewAuthRepository on ANY error, whose currentUser is never null — so a
// failure inside build() rendered the logged-in view without a login.
//
// Contract: preview stays on debug/test (allowPreview, default kDebugMode —
// flow tests pump `EatovaApp()` without a repository). On the release path an
// error yields no invented user; sign-in fails loudly.
//
// This file never calls Supabase.initialize() on purpose: that is exactly the
// state where Supabase.instance throws and the fallback kicks in.

void main() {
  group('buildDefaultAuthRepository ohne Supabase', () {
    test('Release-Pfad: es gibt KEINEN eingeloggten Nutzer', () {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      expect(repo.currentUser, isNull,
          reason: 'ein erfundener Nutzer rendert die eingeloggte Ansicht '
              'ohne Anmeldung');
    });

    test('Release-Pfad: der Auth-Stream beginnt ausgeloggt', () async {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      expect(await repo.authStateChanges.first, isNull,
          reason: 'AuthGate haengt am ersten Stream-Wert — der muss den '
              'Login zeigen, nicht die Home-Page');
    });

    test('Release-Pfad: Anmeldeversuche scheitern LAUT statt still', () async {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      // Typed, so the auth screen can localize it (fix run 2026-08-27, B).
      await expectLater(repo.signIn(email: 'a@example.com', password: 'pw'),
          throwsA(isA<AuthUnavailableException>()),
          reason: 'ein stiller No-Op liesse den Nutzer endlos auf dem '
              'Login-Button druecken');
      await expectLater(
          repo.signUp(
              email: 'a@example.com', password: 'pw', displayName: 'A'),
          throwsA(isA<AuthUnavailableException>()));
      await expectLater(repo.signInWithOAuth(EatovaOAuthProvider.google),
          throwsA(isA<AuthUnavailableException>()));
    });

    test('Release-Pfad: signOut bleibt gefahrlos', () async {
      // The profile screen calls signOut on error paths too; it must not
      // throw on top of a degraded state.
      await expectLater(
          buildDefaultAuthRepository(allowPreview: false).signOut(),
          completes);
    });

    test('Debug/Test-Pfad: Preview bleibt fuer Widget-Tests erhalten', () {
      expect(buildDefaultAuthRepository(allowPreview: true),
          isA<PreviewAuthRepository>());
      // The default (kDebugMode, always true in tests) is the same path; flow
      // tests pumping EatovaApp() without a repository rely on it.
      expect(defaultAuthRepository(), isA<PreviewAuthRepository>());
    });
  });
}
