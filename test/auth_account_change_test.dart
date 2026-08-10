import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';

// Konto-Aenderungen aus der App heraus (2026-08-10):
//
//   * Passwort aendern  -> ein Code an die hinterlegte Adresse
//   * E-Mail aendern    -> je ein Code an die ALTE und die NEUE Adresse
//
// Beide Wege laufen ueber GoTrue-Bordmittel, nicht ueber selbstgebaute
// Token: `reauthenticate()` + `updateUser(nonce:)` fuer das Passwort,
// `updateUser(email:)` + zweimal `verifyOTP(emailChange)` fuer die Adresse.
// Serverseitig ist dafuer `mailer_secure_email_change_enabled` an (deshalb
// ZWEI Mails) und `security_update_password_require_reauthentication` an
// (deshalb ist der Code Pflicht und nicht Zierde) — s. supabase/AUTH_EMAIL_OTP.md.
//
// Diese Tests pruefen den Vertrag am [InMemoryAuthRepository]. Der echte
// Supabase-Pfad ist duenne Delegation; ihn hier zu spiegeln hiesse, das SDK
// zu testen.

void main() {
  group('Passwort aendern', () {
    test('fordert einen Code an die hinterlegte Adresse an', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();

      expect(repo.reauthRequests, <String>['alt@eatova.de']);
    });

    test('setzt das Passwort NUR zusammen mit dem Code', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();
      await repo.confirmPasswordChange(code: '123456', newPassword: 'geheim99');

      expect(repo.passwordUpdates, <String>['geheim99']);
      expect(repo.usedNonces, <String>['123456']);
    });

    test('ein falscher Code aendert nichts', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startPasswordChange();
      repo.verifyFails = true;

      await expectLater(
        repo.confirmPasswordChange(code: '000000', newPassword: 'geheim99'),
        throwsA(isA<Exception>()),
      );
      expect(repo.passwordUpdates, isEmpty,
          reason: 'ein abgelehnter Code darf kein Passwort setzen');
    });
  });

  group('E-Mail aendern', () {
    test('stoesst die Aenderung an und merkt sich die Zieladresse', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');

      expect(repo.emailChangeRequests, <String>['neu@eatova.de']);
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'vor der doppelten Bestaetigung aendert sich nichts');
    });

    test('erst NACH beiden Codes traegt das Konto die neue Adresse', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');

      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');
      expect(repo.currentUser?.email, 'alt@eatova.de',
          reason: 'ein einzelner Code genuegt nicht — sonst reichte der '
              'Zugriff auf EIN Postfach');

      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      expect(repo.currentUser?.email, 'neu@eatova.de');
    });

    test('die Reihenfolge der beiden Codes ist egal', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');
      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      expect(repo.currentUser?.email, 'alt@eatova.de');
      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');

      expect(repo.currentUser?.email, 'neu@eatova.de');
    });

    test('ein falscher Code laesst die Adresse stehen', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      await repo.startEmailChange('neu@eatova.de');
      repo.verifyFails = true;

      await expectLater(
        repo.confirmEmailChange(email: 'alt@eatova.de', code: '000000'),
        throwsA(isA<Exception>()),
      );
      expect(repo.currentUser?.email, 'alt@eatova.de');
    });

    test('der Adresswechsel meldet sich am authStateChanges-Strom', () async {
      final repo = InMemoryAuthRepository(
        initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
      );
      addTearDown(repo.dispose);

      final gesehen = <String?>[];
      final sub = repo.authStateChanges.listen((u) => gesehen.add(u?.email));

      await repo.startEmailChange('neu@eatova.de');
      await repo.confirmEmailChange(email: 'alt@eatova.de', code: '111111');
      await repo.confirmEmailChange(email: 'neu@eatova.de', code: '222222');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(gesehen.last, 'neu@eatova.de',
          reason: 'die Schale zeigt die Adresse in den Einstellungen an — '
              'sie muss den Wechsel mitbekommen');
    });
  });
}
