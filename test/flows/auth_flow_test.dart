// The OAuth button on the auth screen of the real app shell. Register, code
// confirmation, login and logout run end to end in
// auth_onboarding_journey_test.dart; the typed credentials reaching the
// repository are pinned in auth_entry_regression_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';

import 'flow_test_helpers.dart';

/// Records WHICH provider the button asks for: [InMemoryAuthRepository] signs
/// the user in for any provider, so landing on the home page alone proves
/// nothing about the wiring.
class _RecordingAuthRepository extends InMemoryAuthRepository {
  final List<EatovaOAuthProvider> oauthCalls = <EatovaOAuthProvider>[];

  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) {
    oauthCalls.add(provider);
    return super.signInWithOAuth(provider);
  }
}

void main() {
  testWidgetsRobust('Auth screen supports OAuth buttons', (WidgetTester tester) async {
    final authRepository = _RecordingAuthRepository();
    addTearDown(authRepository.dispose);

    await tester.pumpWidget(EatovaApp(authRepository: authRepository));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    // A mis-wired button would open an Apple sheet on the device and still
    // land on the home page here.
    expect(authRepository.oauthCalls, <EatovaOAuthProvider>[
      EatovaOAuthProvider.google,
    ], reason: 'der Google-Knopf startet genau einen Google-OAuth');
  });
}
