import 'dart:async';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/recipe_share_receiver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'flow_test_helpers.dart' show settleFrames, storeOf;

const _result = RecipeImportResult(
  status: RecipeImportStatus.ready,
  candidates: [
    RecipeImportCandidate(
      id: 'tofu',
      title: 'Tofu-Pasta',
      ingredients: '200 g Pasta\n150 g Tofu',
      preparation: 'Pasta kochen. Tofu braten. Mischen.',
    ),
  ],
);

class _Receiver extends RecipeShareReceiver {
  final events = StreamController<SharedRecipeSource>.broadcast(sync: true);
  String? cold;
  @override
  Stream<SharedRecipeSource> get shares => events.stream;
  @override
  Future<void> start() async {
    await Future<void>.value();
    if (cold != null) share('cold', cold!);
  }

  void share(String id, String text) =>
      events.add(SharedRecipeSource(id: id, text: text));
  @override
  Future<void> clearPending() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> dispose() => events.close();
}

class _Service implements RecipeImportService {
  Completer<RecipeImportResult>? pending;
  final texts = <String>[];
  @override
  Future<RecipeImportResult> extract(
    String text, {
    required String locale,
  }) async {
    texts.add(text);
    return pending?.future ?? _result;
  }
}

Future<InMemoryAuthRepository> _pump(
  WidgetTester tester,
  _Receiver receiver,
  _Service service,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'a', sessionId: 'session-a'),
  );
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    EatovaApp(
      authRepository: auth,
      syncBuilder: (_) => null,
      recipeShareReceiver: receiver,
      recipeImportService: service,
    ),
  );
  await settleFrames(tester);
  return auth;
}

void main() {
  testWidgets(
    'cold share reaches preview and only explicit save enters own recipes',
    (tester) async {
      final receiver = _Receiver()..cold = 'shared caption';
      final service = _Service();
      await _pump(tester, receiver, service);
      expect(find.byType(RecipeImportSheet), findsOneWidget);
      final store = storeOf(tester);
      expect(store.userRecipes, isEmpty);
      expect(service.texts, ['shared caption']);
      final save = find.byKey(const ValueKey('recipe-import-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settleFrames(tester);
      expect(store.userRecipes.single.title, 'Tofu-Pasta');
      expect(store.userRecipes.single.hasPendingNutrition, isTrue);
      expect(store.selectedTab, 2);
      expect(find.byType(RecipeImportSheet), findsNothing);
      receiver.share('repeat', 'shared caption');
      await settleFrames(tester);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await settleFrames(tester);
      expect(store.userRecipes.length, 1);
      expect(find.byType(RecipeImportSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('auth loss closes import and ignores a late extraction result', (
    tester,
  ) async {
    final receiver = _Receiver();
    final service = _Service()..pending = Completer<RecipeImportResult>();
    final auth = await _pump(tester, receiver, service);
    final store = storeOf(tester);
    receiver.share('warm', 'private caption');
    await settleFrames(tester);
    expect(find.byType(RecipeImportSheet), findsOneWidget);
    await auth.signOut();
    await settleFrames(tester);
    service.pending!.complete(_result);
    await settleFrames(tester);
    expect(find.byType(RecipeImportSheet), findsNothing);
    expect(find.byType(EatovaHomePage), findsNothing);
    expect(store.userRecipes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
