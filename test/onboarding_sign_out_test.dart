// AUTH-3 (2026-10-19 review): the onboarding had only a back button, so a
// user who signed in with the wrong (Google) account could not leave it. The
// header now offers "Abmelden" in a quiet overflow menu, behind a decision
// card, through the shell's coordinated sign-out and its account cleanup.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/recipe_image_store.dart';

import 'support/fixlauf_a_helpers.dart' show StummerFotoStore;
import 'support/harness.dart';

const _user = 'user-onboarding-sign-out';

/// Records the coordinated sign-out the shell runs.
class _CoordinatedAuth extends InMemoryAuthRepository
    implements CoordinatedSignOut {
  _CoordinatedAuth()
    : super(initialUser: const EatovaUser(id: _user, email: 'a@example.test'));

  final List<String> calls = <String>[];

  @override
  Future<void> signOutWithCleanup(Future<void> Function() cleanup) async {
    calls.add('cleanup');
    await cleanup();
    await signOut();
    calls.add('signed-out');
  }
}

/// Fixed frames instead of pumpAndSettle: the shell keeps animating while it
/// boots, so it would never settle.
Future<void> _frames(WidgetTester tester, [int count = 30]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _openSignOut(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('onboarding-menu')));
  await _frames(tester);
  await tester.tap(find.byKey(const ValueKey('onboarding-sign-out')));
  await _frames(tester);
}

void main() {
  group('der Abmelde-Weg im Onboarding', () {
    Future<List<int>> pumpScreen(
      WidgetTester tester, {
      bool withSignOut = true,
    }) async {
      final signOuts = <int>[];
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        OnboardingScreen(
          firstName: 'Moritz',
          initialProfile: const UserProfile(),
          onComplete: (_) {},
          onSignOut: withSignOut ? () async => signOuts.add(1) : null,
        ),
        brightness: Brightness.light,
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      return signOuts;
    }

    testWidgets('ein ruhiges Menue, eine Rueckfrage, erst dann abmelden',
        (tester) async {
      final signOuts = await pumpScreen(tester);
      expect(find.byKey(const ValueKey('onboarding-menu')), findsOneWidget);
      expect(find.text('Abmelden'), findsNothing,
          reason: 'die Aktion steht nicht offen im Kopf');

      await _openSignOut(tester);
      expect(find.byKey(const ValueKey('onboarding-sign-out-dialog')),
          findsOneWidget);
      expect(find.text('Abmelden?'), findsOneWidget);
      expect(find.textContaining('nicht gespeichert'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onboarding-sign-out-cancel')));
      await tester.pumpAndSettle();
      expect(signOuts, isEmpty, reason: 'Abbrechen meldet nicht ab');
      expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);

      await _openSignOut(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-sign-out-confirm')));
      await tester.pumpAndSettle();
      expect(signOuts, [1]);
    });

    testWidgets('auf jedem Schritt erreichbar, auch nach Weiter',
        (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('onboarding-goal-lose')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('onboarding-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding-menu')), findsOneWidget);
    });

    testWidgets('ohne Abmelde-Weg gibt es kein Menue', (tester) async {
      await pumpScreen(tester, withSignOut: false);
      expect(find.byKey(const ValueKey('onboarding-menu')), findsNothing);
    });
  });

  testWidgets(
      'die Shell meldet aus dem Onboarding koordiniert ab und raeumt den '
      'Konto-Cache', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(IntentionalSignOut.clear);
    // Device-only recipe photos live on disk; a stub keeps the cleanup in
    // the test's fake time.
    RecipeImageStore.instance = StummerFotoStore();
    addTearDown(RecipeImageStore.resetInstance);
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    // An empty server: no profile, so the account needs the onboarding.
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async {
        final write = req.method != 'GET';
        return http.Response(
          jsonEncode(write ? [<String, dynamic>{}] : const <dynamic>[]),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    // Not disposed, as in home_page_onboarding_pop_test: its dispose never
    // completed inside this widget test's fake time.
    // Another account's cache on the same device must survive A's sign-out.
    final raw = InMemoryKeyValueStore(<String, String>{
      'eatova.v1.stats.user-b': '{"other":"account"}',
    });
    final auth = _CoordinatedAuth();
    addTearDown(auth.dispose);

    await pumpLocalized(
      tester,
      EatovaHomePage(
        sync: EatovaSync.forUser(client, _user),
        debugCache: LocalCache(raw, _user),
        authRepository: auth,
        onSignOut: auth.signOut,
        showWelcome: false,
      ),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
    );
    await _frames(tester, 40);
    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);
    // The boot wrote this account's cache.
    expect(raw.snapshot.keys.where((key) => key.endsWith('.$_user')),
        isNotEmpty);

    await _openSignOut(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-sign-out-confirm')));
    await _frames(tester);

    expect(auth.calls, ['cleanup', 'signed-out'],
        reason: 'derselbe koordinierte Weg wie in den Einstellungen');
    expect(auth.currentUser, isNull);
    expect(IntentionalSignOut.consume(), isTrue,
        reason: 'sonst meldet AuthGate eine abgelaufene Sitzung');
    final remaining = raw.snapshot.keys
        .where((key) => key.endsWith('.$_user'))
        .where((key) => !key.startsWith('eatova.v1.outbox.'))
        .toList();
    expect(remaining, isEmpty,
        reason: 'A\'s cache is purged; only confirmed outbox entries stay');
    expect(raw.snapshot['eatova.v1.stats.user-b'], '{"other":"account"}');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
