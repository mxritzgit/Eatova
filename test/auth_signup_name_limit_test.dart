import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/model_limits.dart';
import 'package:eatova/src/screens/auth_screen.dart';

import 'support/harness.dart';

// BE-2: `profiles_display_name_length_check` allows 80 code points and the
// signup trigger copies the metadata name unclamped, so a longer name made
// GoTrue fail the signup with 500 "Database error saving new user".

class _NameCapture extends InMemoryAuthRepository {
  final List<String> names = <String>[];

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    names.add(displayName);
    return super.signUp(
      email: email,
      password: password,
      displayName: displayName,
    );
  }
}

const int _max = ProfileLimits.displayNameMaxChars;

Future<void> _signUpWithName(
  WidgetTester tester,
  _NameCapture repo,
  String name,
) async {
  await pumpLocalized(
    tester,
    AuthScreen(authRepository: repo),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('auth-name-field')), name);
  await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')), 'neu@example.com');
  await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')), 'eatova123');
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  // The formatter itself is pinned in widgets/common/text_length_limit_test.
  testWidgets('the signup name field stops at the database limit in code '
      'points and keeps emoji whole', (tester) async {
    final repo = _NameCapture();
    addTearDown(repo.dispose);

    // 79 letters + two emoji = 81 code points but 83 UTF-16 units.
    await _signUpWithName(tester, repo, '${'a' * 79}😀😀');

    final sent = repo.names.single;
    expect(sent.runes.length, _max);
    expect(sent, '${'a' * 79}😀');
  });

  test('signUp clamps the metadata name for callers without the field',
      () async {
    Map<String, dynamic>? data;
    final transport = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      data = body['data'] as Map<String, dynamic>?;
      return http.Response(
        jsonEncode({
          'id': 'a',
          'email': 'a@example.invalid',
          'aud': 'authenticated',
          'created_at': '2026-10-11T00:00:00Z',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
        }),
        200,
      );
    });
    final client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final repository = SupabaseAuthRepository(
      client,
      mutationHttpClient: transport,
    );

    await repository.signUp(
      email: 'a@example.invalid',
      password: 'synthetic-password',
      displayName: '  ${'b' * 79}😀😀  ',
    );

    expect(data, {'display_name': '${'b' * 79}😀'});
  });
}
