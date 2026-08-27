import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';

// Fix run 2026-08-27, package B (F2-05): the first-name fallback is no
// Fitpilot relic any more and comes from the ARB — German by default for
// context-free callers, the active language when one is passed. Nothing here
// is persisted, so a localized fallback is safe.
void main() {
  group('EatovaUser.firstName', () {
    test('Anzeigename vor Mailbox-Teil', () {
      const user = EatovaUser(
          id: 'u', email: 'mira@example.com', displayName: 'Mira Muster');
      expect(user.firstName, 'Mira');
    });

    test('ohne Anzeigename der Mailbox-Teil', () {
      const user = EatovaUser(id: 'u', email: 'mira@example.com');
      expect(user.firstName, 'mira');
    });

    test('ohne beides der neutrale ARB-Fallback, nie "Pilot"', () {
      const user = EatovaUser(id: 'u');
      expect(user.firstName, deL10n.authFallbackFirstName);
      expect(user.firstName, isNot(contains('Pilot')));
      expect(user.firstNameFor(enL10n), enL10n.authFallbackFirstName);
      expect(enL10n.authFallbackFirstName,
          isNot(deL10n.authFallbackFirstName));
    });
  });

  test('UnavailableAuthRepository wirft einen TYP, keinen deutschen Satz',
      () async {
    const repo = UnavailableAuthRepository('boot failed');
    await expectLater(
      repo.signIn(email: 'a@b.de', password: 'x'),
      throwsA(isA<AuthUnavailableException>()),
    );
    await expectLater(
      repo.signInWithOAuth(EatovaOAuthProvider.google),
      throwsA(isA<AuthUnavailableException>()),
    );
  });

  test('Test-Fakes tragen keinen Fitpilot-Namen mehr', () async {
    final repo = InMemoryAuthRepository();
    addTearDown(repo.dispose);
    await repo.signIn(email: 'a@b.de', password: 'x');
    expect(repo.currentUser?.displayName, isNot(contains('Pilot')));
    await repo.signInWithOAuth(EatovaOAuthProvider.google);
    expect(repo.currentUser?.displayName, isNot(contains('Pilot')));
  });
}
