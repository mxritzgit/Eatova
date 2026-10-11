import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'fixlauf_a_helpers.dart';
import 'flows/flow_test_helpers.dart'
    show FakeProductLookupService, pumpUntil, settleFrames;
import 'support/sync_session_fixture.dart';

// AUTH-4: a completed account deletion ended on the plain login screen, the
// same as an ordinary sign-out. When the app session ended during the local
// cleanup (gotrue's refresh failing for the deleted user), the gate even
// reported an expired session.

/// Ends the app session from inside the deletion's local cleanup once
/// [armed], like gotrue's auto-refresh failing for the just-deleted user.
class _SessionLossDuringCleanup extends NoopNotificationService {
  _SessionLossDuringCleanup(this.auth);

  final InMemoryAuthRepository auth;
  bool armed = false;

  @override
  Future<void> cancelAll() async {
    if (!armed) return;
    armed = false;
    await auth.signOut();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await settleFrames(tester);
  await tester.tap(finder);
  await settleFrames(tester);
}

/// Boots the shell over a fake server, deletes the account through the
/// settings and returns the localized texts.
Future<AppLocalizations> _deleteAccount(
  WidgetTester tester, {
  required String language,
  bool loseSessionDuringCleanup = false,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: kFixlaufUser, email: 'a@example.test'),
  );
  final notifications = _SessionLossDuringCleanup(auth);
  final locale = LocaleController(initial: Locale(language));
  final theme = ThemeModeController(initial: ThemeMode.dark);
  addTearDown(auth.dispose);
  addTearDown(locale.dispose);
  addTearDown(theme.dispose);
  final server = FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile);
  // Not disposed: `SupabaseClient.dispose()` never completes outside the
  // fake-async zone, and the MockClient holds no socket.
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await tester.runAsync(() => signInSyncFixture(client, kFixlaufUser));
  final localData = InMemoryKeyValueStore();
  EatovaSync? sync;
  await tester.pumpWidget(
    EatovaApp(
      authRepository: auth,
      localeController: locale,
      themeModeController: theme,
      notificationService: notifications,
      debugCacheBuilder: (id) => LocalCache(localData, id),
      syncBuilder: (userId) => sync ??= EatovaSync.forUser(client, userId),
      productService: FakeProductLookupService(),
    ),
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('today-profile')).evaluate().isNotEmpty,
    'die Shell nach dem Boot-Load',
  );
  final l10n = lookupAppLocalizations(Locale(language));

  await _tap(tester, find.byKey(const ValueKey('today-profile')));
  await _tap(tester, find.byKey(const ValueKey('profile-open-settings')));
  await _tap(tester, find.byKey(const ValueKey('settings-delete-account')));
  await tester.enterText(
    find.byKey(const ValueKey('settings-delete-confirm-field')),
    l10n.settingsDeleteConfirmWord,
  );
  await settleFrames(tester);
  await _tap(tester, find.text(l10n.settingsDeleteAccountRequestCta));
  await tester.enterText(
    find.byKey(const ValueKey('settings-delete-code-field')),
    '12345678',
  );
  await settleFrames(tester);
  notifications.armed = loseSessionDuringCleanup;
  await _tap(tester, find.text(l10n.settingsDeleteAccountActionLabel));
  expect(auth.verifiedCodes, ['a@example.test:12345678']);
  expect(auth.currentUser, isNull);
  return l10n;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RecipeImageStore.instance = StummerFotoStore();
  });
  tearDown(() {
    RecipeImageStore.resetInstance();
    IntentionalSignOut.clear();
  });

  for (final language in ['de', 'en']) {
    testWidgets('a completed deletion is confirmed on the login ($language)', (
      tester,
    ) async {
      final l10n = await _deleteAccount(tester, language: language);

      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      expect(find.text(l10n.authAccountDeleted), findsOneWidget);
      expect(find.text(l10n.authSessionExpired), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleFrames(tester);
    });
  }

  testWidgets('a session ending during the deletion cleanup is no expiry', (
    tester,
  ) async {
    final l10n = await _deleteAccount(
      tester,
      language: 'de',
      loseSessionDuringCleanup: true,
    );

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(find.text(l10n.authSessionExpired), findsNothing);
    expect(find.text(l10n.authAccountDeleted), findsOneWidget);
    expect(
      IntentionalSignOut.consume(),
      isFalse,
      reason: 'the gate consumed the deletion intent; none may linger',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleFrames(tester);
  });
}
