import 'dart:async';

import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Applies to every test file under test/.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The process-wide photo store binds to the clock of the test that first
  // uses it; a later sign-out in the same file then waits on that dead clock.
  // A fresh store per test keeps tests independent of their order.
  tearDown(RecipeImageStore.resetInstance);
  await testMain();
}
