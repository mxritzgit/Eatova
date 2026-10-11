import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/secure_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'fixlauf_a_helpers.dart';
import 'flows/flow_test_helpers.dart';

const _channel = MethodChannel('eatova/secure_screen');
const _user = EatovaUser(id: 'private-screen-a', email: 'a@example.test');

Future<void> _pumpApp(
  WidgetTester tester,
  InMemoryAuthRepository repository, {
  ThemeModeController? themeController,
}) async {
  final locale = LocaleController(initial: const Locale('en'));
  final theme = themeController ?? ThemeModeController(initial: ThemeMode.dark);
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
}

Future<void> _openHistory(WidgetTester tester) async {
  storeOf(tester).setTab(3);
  await settleFrames(tester);
  final button = find.byKey(const ValueKey('training-open-history'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await settleFrames(tester);
  expect(find.byType(TrainingHistoryScreen), findsOneWidget);
}

void main() {
  final calls = <String>[];
  final coverColors = <Object?>[];

  setUp(() {
    expect(SecureScreen.instance.activeCount, 0);
    calls.clear();
    coverColors.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'setCoverColor') {
            coverColors.add(call.arguments);
          } else {
            calls.add(call.method);
          }
          return null;
        });
    RecipeImageStore.instance = StummerFotoStore();
  });

  tearDown(() {
    expect(
      SecureScreen.instance.activeCount,
      0,
      reason: 'app teardown must release every guard',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    RecipeImageStore.resetInstance();
    IntentionalSignOut.clear();
  });

  testWidgetsRobust(
    'restored session protects every tab, pushed history and nested settings',
    (tester) async {
      final repository = InMemoryAuthRepository(initialUser: _user);
      addTearDown(repository.dispose);
      await _pumpApp(tester, repository);

      expect(find.byType(TodayScreen), findsOneWidget);
      expect(calls, [
        'enable',
      ], reason: 'restored sessions need protection before opening a subpage');

      for (final (tab, type) in <(int, Type)>[
        (1, MealAnalysisScreen),
        (2, RecipesScreen),
        (3, TrainingScreen),
        (4, CoachChatScreen),
        (0, TodayScreen),
      ]) {
        storeOf(tester).setTab(tab);
        await settleFrames(tester);
        expect(find.byType(type), findsOneWidget);
        expect(calls, [
          'enable',
        ], reason: 'tab $tab must not release protection');
      }

      // Settings sit behind the avatar's profile page (dark redesign).
      await tester.tap(find.byKey(const ValueKey('today-profile')));
      await settleFrames(tester);
      await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
      await settleFrames(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(SecureScreen.instance.activeCount, greaterThan(1));
      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
      await settleFrames(tester);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('screen-profile'))),
      ).pop();
      await settleFrames(tester);
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(calls, [
        'enable',
      ], reason: 'nested guard must not clear root flag');

      await _openHistory(tester);
      expect(calls, ['enable']);

      // A direct identity change must clear A's pushed route, without exposing
      // either account during the transition. No backend or real credentials.
      await repository.signIn(
        email: 'b@example.test',
        password: 'dummy-password',
      );
      await settleFrames(tester);
      expect(find.byType(TrainingHistoryScreen), findsNothing);
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(calls, ['enable']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(calls, ['enable', 'disable']);
    },
  );

  testWidgetsRobust(
    'login and session loss have no unprotected route transition',
    (tester) async {
      final repository = InMemoryAuthRepository();
      addTearDown(repository.dispose);
      await _pumpApp(tester, repository);
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      expect(calls, ['enable']);

      await repository.signIn(
        email: 'a@example.test',
        password: 'dummy-password',
      );
      await settleFrames(tester);
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(calls, ['enable'], reason: 'removing AuthScreen must not disable');

      await _openHistory(tester);
      await repository.signOut();
      // Check the transition itself, before the outgoing route finishes popping.
      await tester.pump();
      expect(calls, ['enable']);
      await settleFrames(tester);
      expect(find.byType(TrainingHistoryScreen), findsNothing);
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      expect(calls, [
        'enable',
      ], reason: 'login fields remain private after logout');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(calls, ['enable', 'disable']);
    },
  );

  // The iOS snapshot cover is painted natively. It must show the page tone of
  // the theme on screen; an in-app choice can differ from the system one.
  testWidgetsRobust('the snapshot cover takes the page tone of the app theme', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final repository = InMemoryAuthRepository(initialUser: _user);
    addTearDown(repository.dispose);
    final theme = ThemeModeController(initial: ThemeMode.light);
    await _pumpApp(tester, repository, themeController: theme);
    final light = {'color': AppTokens.light.bg.toARGB32()};
    final dark = {'color': AppTokens.dark.bg.toARGB32()};

    expect(calls, ['enable']);
    expect(coverColors, [light], reason: 'light in the app on a dark system');

    theme.setModeSync(ThemeMode.dark);
    await settleFrames(tester);
    expect(coverColors, [light, dark]);

    theme.setModeSync(ThemeMode.system);
    await settleFrames(tester);
    expect(coverColors, [
      light,
      dark,
    ], reason: 'system mode on a dark system stays dark: no second send');

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await settleFrames(tester);
    expect(coverColors, [light, dark, light], reason: 'system mode follows');
    expect(calls, ['enable'], reason: 'the cover tone never touches the guard');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls, ['enable', 'disable']);
  });
}
