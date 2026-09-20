import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'fixlauf_a_helpers.dart';
import 'flows/flow_test_helpers.dart'
    show FakeProductLookupService, settleFrames;

class _FailingLogout extends InMemoryAuthRepository {
  _FailingLogout()
    : super(
        initialUser: const EatovaUser(id: 'logout-a', email: 'a@example.test'),
      );

  bool shouldFail = true;
  int calls = 0;

  @override
  Future<void> signOut() async {
    calls++;
    if (shouldFail) throw StateError('synthetic logout failure');
    await super.signOut();
  }
}

class _FailingCoordinatedLogout extends _FailingLogout
    implements CoordinatedSignOut {
  @override
  Future<void> signOutWithCleanup(Future<void> Function() cleanup) async {
    if (shouldFail) {
      await signOut();
      return;
    }
    await cleanup();
    await signOut();
  }
}

class _ObservedImages extends StummerFotoStore {
  int clearCalls = 0;

  @override
  Future<void> clear({String? expectedUserId, String? expectedSessionId}) async => clearCalls++;
}

Future<void> _tapLogout(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('today-settings')));
  await settleFrames(tester);
  final logout = find.byKey(const ValueKey('settings-sign-out'));
  await tester.ensureVisible(logout);
  await tester.tap(logout);
  await settleFrames(tester);
}

void main() {
  for (final (language, message) in [
    ('de', 'Abmelden fehlgeschlagen. Bitte versuche es erneut.'),
    ('en', 'Sign-out failed. Please try again.'),
  ]) {
    for (final coordinated in [false, true]) {
      testWidgets(
        'logout failure and retry ($language, coordinated=$coordinated)',
        (tester) async {
          tester.view.physicalSize = const Size(1179, 2556);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final images = _ObservedImages();
          RecipeImageStore.instance = images;
          addTearDown(RecipeImageStore.resetInstance);
          addTearDown(IntentionalSignOut.clear);
          final repository = coordinated
              ? _FailingCoordinatedLogout()
              : _FailingLogout();
          final locale = LocaleController(initial: Locale(language));
          final theme = ThemeModeController(initial: ThemeMode.dark);
          addTearDown(repository.dispose);
          addTearDown(locale.dispose);
          addTearDown(theme.dispose);
          await tester.pumpWidget(
            EatovaApp(
              authRepository: repository,
              localeController: locale,
              themeModeController: theme,
              syncBuilder: (_) => null,
              productService: FakeProductLookupService(),
            ),
          );
          await settleFrames(tester);
          final clearedBefore = images.clearCalls;
          await _tapLogout(tester);

          expect(tester.takeException(), isNull);
          if (coordinated) {
            expect(
              images.clearCalls,
              clearedBefore,
              reason: 'Failed preflight must leave the active account usable.',
            );
          }
          expect(repository.calls, 1);
          expect(repository.currentUser?.id, 'logout-a');
          expect(find.byType(TodayScreen), findsOneWidget);
          expect(find.text(message), findsOneWidget);
          expect(IntentionalSignOut.consume(), isFalse);

          repository.shouldFail = false;
          await tester.pump(const Duration(seconds: 5));
          await _tapLogout(tester);
          expect(repository.calls, 2);
          expect(repository.currentUser, isNull);
          expect(images.clearCalls, greaterThan(clearedBefore));
          expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }
}
