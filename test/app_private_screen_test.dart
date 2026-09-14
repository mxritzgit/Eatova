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
import 'package:eatova/src/theme/theme_mode_controller.dart';

import 'fixlauf_a_helpers.dart';
import 'flows/flow_test_helpers.dart';

const _channel = MethodChannel('eatova/secure_screen');
const _user = EatovaUser(id: 'private-screen-a', email: 'a@example.test');

Future<void> _pumpApp(
  WidgetTester tester,
  InMemoryAuthRepository repository,
) async {
  final locale = LocaleController(initial: const Locale('en'));
  final theme = ThemeModeController(initial: ThemeMode.dark);
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

  setUp(() {
    expect(SecureScreen.instance.activeCount, 0);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
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

      await tester.tap(find.byKey(const ValueKey('today-settings')));
      await settleFrames(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(SecureScreen.instance.activeCount, greaterThan(1));
      Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
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
}
