import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';

import 'support/harness.dart';

class _NoPhotos extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId, {String? sessionId}) async {}
}

String _session(String sid) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token':
        '${encode({'alg': 'HS256'})}.'
        '${encode({'session_id': sid, 'exp': 4102444800})}.synthetic-signature',
    'refresh_token': 'synthetic-$sid',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': 'owner',
      'email': 'owner@example.invalid',
      'aud': 'authenticated',
      'created_at': '2026-09-20T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

void main() {
  testWidgets('verified deletion continues through same-owner OTP rotation', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    RecipeImageStore.instance = _NoPhotos();
    addTearDown(RecipeImageStore.resetInstance);
    var verifyCalls = 0;
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/verify')) verifyCalls++;
      return http.Response(
        request.url.path.endsWith('/verify') ? _session('recovery') : '{}',
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = (await tester.runAsync(
      () async => SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: transport,
        authOptions: const AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.implicit,
        ),
      ),
    ))!;
    addTearDown(() async {
      await tester.runAsync(client.dispose);
    });
    await tester.runAsync(
      () => client.auth.setInitialSession(_session('initial')),
    );
    final repo = SupabaseAuthRepository(client, mutationHttpClient: transport);
    var deletions = 0;
    await pumpLocalized(
      tester,
      AuthGate(
        authRepository: repo,
        builder: (context, user, _) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                email: user.email,
                authRepository: repo,
                onDeleteAccount: (deleteRemote, isCurrent) async {
                  await deleteRemote();
                  expect(isCurrent(), isTrue);
                  deletions++;
                },
              ),
            ),
          ),
          child: const Text('open settings'),
        ),
      ),
      settle: true,
    );
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tap(find.text('open settings'));
    await tap(find.byKey(const ValueKey('settings-delete-account')));
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-confirm-field')),
      'L\u00d6SCHEN',
    );
    await tester.pumpAndSettle();
    await tap(find.text('Code anfordern'));
    await tester.enterText(
      find.byKey(const ValueKey('settings-delete-code-field')),
      '12345678',
    );
    await tester.pumpAndSettle();
    await tap(find.text('Konto endg\u00fcltig l\u00f6schen'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(verifyCalls, 1);
    expect(repo.currentUser?.sessionId, 'initial');
    expect(
      deletions,
      1,
      reason:
          'A successfully verified deletion must not be discarded by AuthGate.',
    );
  });
}
