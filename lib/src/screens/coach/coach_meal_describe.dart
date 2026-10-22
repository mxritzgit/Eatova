import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../services/meal_describer.dart';
import '../../services/meal_description_matcher.dart';
import '../../services/open_food_facts_product_service.dart'
    show ProductLookupService;
import '../../theme/meal_slot_style.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/persistence_action.dart';
import '../../widgets/kcal/meal_describe_sheet.dart';
import '../../widgets/shared/ai_consent_sheet.dart';

/// `/meal` from the Coach (2026-10-22): the Food tab's describe sheet for
/// today, prefilled with [text]. Nothing goes to the coach and no daily
/// question is used; analyze-meal reads the text only once the user submits
/// it, and the sheet's Add logs the meal through [onAdd], the Food tab's
/// path. True once a meal was added.
Future<bool> describeMealFromCoach(
  BuildContext context, {
  required String text,
  required ProductLookupService productService,
  required List<FavoriteMeal> Function() favorites,
  required FutureOr<String> Function(MealAnalysisResult, MealSlot) onAdd,
  required FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal,
  bool Function(MealAnalysisResult)? isFavorite,
  PersistValueChanged<MealAnalysisResult>? onToggleFavorite,
  MealDescriber describer = const EdgeFunctionMealDescriber(),
}) async {
  // AI consent before the sheet: its only purpose is analyze-meal.
  if (!await ensureAiConsent(context) || !context.mounted) return false;
  final outcome = await showMealDescribeSheet(
    context,
    initialSlot: currentMealSlot(),
    describer: describer,
    matcher: ProductMealDescriptionMatcher(
      products: productService,
      favorites: favorites,
    ),
    onAdd: onAdd,
    onUpdateMeal: onUpdateMeal,
    isFavorite: isFavorite,
    onToggleFavorite: onToggleFavorite,
    initialText: text,
  );
  if (outcome == null) return false;
  final result = outcome.result;
  // Logged from the review sheet ("Edit"), which confirmed it already.
  if (result != null && context.mounted) {
    final l10n = context.l10n;
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, outcome.slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
  }
  return true;
}
