import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/account_change_sheets.dart';

import 'support/harness.dart';

void main() {
  for (final language in const ['de', 'en']) {
    for (final email in const ['account@example.test', null]) {
      testWidgets('$language password sheet explains recent-session exception '
          'with ${email == null ? 'default' : 'explicit'} address', (
        tester,
      ) async {
        pinPhoneViewport(tester);
        final repo = InMemoryAuthRepository(
          initialUser: const EatovaUser(
            id: 'user',
            email: 'account@example.test',
          ),
        );
        addTearDown(repo.dispose);
        await pumpLocalized(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showPasswordChangeSheet(
                context,
                authRepository: repo,
                email: email,
              ),
              child: const Text('Open'),
            ),
          ),
          locale: Locale(language),
          textScale: 2,
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // These security claims must stay visible in both localized variants.
        final explanation = language == 'de'
            ? 'Bei einer Anmeldung innerhalb der letzten 24 Stunden kann das '
                  'Passwort auch ohne erneute E-Mail-Bestätigung geändert werden.'
            : 'If you signed in within the last 24 hours, your password can also '
                  'be changed without another email confirmation.';
        expect(find.textContaining(explanation), findsOneWidget);
        expect(
          find.textContaining(
            language == 'de'
                ? 'ohne ihn lässt sich das Passwort nicht ändern'
                : "without it, the password can't be changed",
          ),
          findsNothing,
        );
        expect(repo.reauthRequests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
