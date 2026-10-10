// Client of `analyze-meal` in describe mode. Contract: docs/MEAL-DESCRIBE.md.

import '../models/described_meal.dart';
import '../models/meal_analysis_request.dart';

/// Turns a typed or spoken meal description into [DescribedMeal].
///
/// Failures are the [MealAnalysisException] family of `meal_analyzer.dart`
/// (rate limit, re-auth, cancelled, server error with its code), so the UI
/// can name them like a failed photo scan. `no_food_in_text` arrives as a
/// `MealAnalysisServerError` with that code.
abstract class MealDescriber {
  Future<DescribedMeal> describe(
    String text, {
    required String language,
    MealAnalysisCancellation? cancellation,
  });
}

/// Production [MealDescriber]: the same HTTP client, auth, timeouts and error
/// mapping as `EdgeFunctionMealAnalyzer`.
class EdgeFunctionMealDescriber implements MealDescriber {
  const EdgeFunctionMealDescriber();

  @override
  Future<DescribedMeal> describe(
    String text, {
    required String language,
    MealAnalysisCancellation? cancellation,
  }) {
    throw UnimplementedError('EdgeFunctionMealDescriber.describe');
  }
}
