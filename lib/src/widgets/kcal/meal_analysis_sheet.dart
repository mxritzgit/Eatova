import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';

/// Maps an analysis/lookup error to the snack message shown to the user.
///
/// Two cases are more precise than the flow's generic [fallback]:
///
///  * [TimeoutException] — the connection was up, only the answer never came,
///    so a "check your connection" message would mislead.
///  * [ProductWithoutNutritionException] — the product was found but carries
///    no loggable energy value, so the "not found" message would be wrong.
///    The error already brings its own message.
String mealAnalysisErrorMessage(
  Object error,
  String fallback,
  AppLocalizations l10n,
) {
  if (error is TimeoutException) {
    return l10n.foodAnalysisTimeoutMessage;
  }
  if (error is ProductWithoutNutritionException) {
    return error.userMessage(l10n);
  }
  return fallback;
}

/// Sub-sheet for photo/barcode analysis, started by AddMealSheet once an
/// image or barcode is captured. Shows the loading card, then the
/// `MealResultCard` with adjust + add; there is no confirm step.
Future<void> showMealAnalysisSheet(
  BuildContext context, {
  required MealSlot slot,
  required Future<MealAnalysisResult> resultFuture,
  required Uint8List? previewImage,
  required String Function(MealAnalysisResult, MealSlot) onAdd,
  required void Function(String id, MealAnalysisResult scaled) onUpdateMeal,
  required String failureMessage,
  bool Function(MealAnalysisResult)? isFavorite,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // No token on purpose: the scrim behind a sheet darkens in both modes —
    // a light scrim would dim nothing.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) {
      return MealAnalysisSheet(
        slot: slot,
        resultFuture: resultFuture,
        previewImage: previewImage,
        onAdd: onAdd,
        onUpdateMeal: onUpdateMeal,
        failureMessage: failureMessage,
        isFavorite: isFavorite,
        onToggleFavorite: onToggleFavorite,
      );
    },
  );
}

class MealAnalysisSheet extends StatefulWidget {
  const MealAnalysisSheet({
    super.key,
    required this.slot,
    required this.resultFuture,
    required this.previewImage,
    required this.onAdd,
    required this.onUpdateMeal,
    required this.failureMessage,
    this.isFavorite,
    this.onToggleFavorite,
  });

  final MealSlot slot;
  final Future<MealAnalysisResult> resultFuture;
  final Uint8List? previewImage;

  /// Logs the result into the daily total and returns the client UUID of the
  /// new row. The sheet keeps that id so a later re-portion hits exactly it.
  final String Function(MealAnalysisResult, MealSlot) onAdd;

  /// Replaces the already logged row [id] with the rescaled [scaled] (kcal
  /// AND macros). Fixes the earlier bug where only a kcal delta flowed and
  /// the wrong meal was hit.
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;
  final String failureMessage;

  /// Whether the current meal is pinned as a favorite (filled heart).
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favorite toggle. Null -> no heart button.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;

  @override
  State<MealAnalysisSheet> createState() => _MealAnalysisSheetState();
}

class _MealAnalysisSheetState extends State<MealAnalysisSheet> {
  MealAnalysisResult? _result;
  bool _isLoading = true;
  bool _addedToDailyTotal = false;
  // Client UUID of the logged row; a later re-portion applies to this id.
  String? _addedMealId;
  // Optimistic local favorite state: the sheet lives on its own modal route,
  // so a HomePage setState does not rebuild it and the heart would lag.
  bool? _favoriteOverride;

  @override
  void initState() {
    super.initState();
    _loadResult();
  }

  bool get _isFavoriteNow {
    final result = _result;
    if (result == null) return false;
    return _favoriteOverride ?? widget.isFavorite?.call(result) ?? false;
  }

  void _handleToggleFavorite(MealAnalysisResult result) {
    final next = !_isFavoriteNow;
    widget.onToggleFavorite?.call(result);
    setState(() => _favoriteOverride = next);
  }

  Future<void> _loadResult() async {
    try {
      final value = await widget.resultFuture;
      if (!mounted) return;
      setState(() {
        _result = value;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      showAppSnack(
          context,
          mealAnalysisErrorMessage(
              error, widget.failureMessage, context.l10n),
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
          duration: kSnackError);
      Navigator.of(context).maybePop();
    }
  }

  void _addToDaily() {
    final result = _result;
    if (result == null || _addedToDailyTotal) return;

    // Last guard before the diary (B7). Search and barcode already throw
    // [ProductWithoutNutritionException] in the service, but the photo AI path
    // bypasses that filter, and a 0 kcal entry is indistinguishable from a
    // real meal without calories — it skews the daily total silently.
    //
    // Deliberately no silent abort and no disabled button: the user learns
    // the reason and the way out ("adjust" -> enter components).
    //
    // explicitZeroKcal: a MEASURED 0 (water, zero drinks) carries its marker
    // from the product database and may be logged — the guard targets the
    // sentinel "0 = unknown", not the product.
    if (result.caloriesKcal <= 0 && !result.explicitZeroKcal) {
      showAppSnack(
        context,
        context.l10n.foodMealWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }

    final id = widget.onAdd(result, widget.slot);
    setState(() {
      _addedToDailyTotal = true;
      _addedMealId = id;
    });
    final l10n = context.l10n;
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, widget.slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
  }

  Future<void> _adjustPortion() async {
    final current = _result;
    if (current == null) return;

    final adjustment = await showWeightAdjustmentSheet(context, current);
    if (!mounted || adjustment == null) return;

    MealAnalysisResult? candidate;
    if (adjustment is int && adjustment > 0) {
      candidate = current.adjustedToGrams(adjustment);
    } else if (adjustment is List<MealComponent>) {
      candidate = current.adjustedToItems(adjustment);
    }
    if (candidate == null) return;
    final updated = candidate;

    final wasAdded = _addedToDailyTotal;
    final loggedId = _addedMealId;

    setState(() {
      _result = updated;
    });

    // If already logged, hand the COMPLETE scaled result (kcal AND macros) to
    // exactly that row; a kcal-only delta froze macros and hit the wrong meal.
    if (wasAdded && loggedId != null) {
      widget.onUpdateMeal(loggedId, updated);
    }

    if (adjustment is int && adjustment > 0) {
      final l10n = context.l10n;
      final message = wasAdded
          ? l10n.foodPortionAdjustedUpdated(adjustment)
          : l10n.foodPortionAdjusted(adjustment);
      showAppSnack(context, message, icon: Icons.tune_rounded);
    } else if (adjustment is List<MealComponent>) {
      final l10n = context.l10n;
      final message = wasAdded
          ? l10n.foodPortionAdjustedItemsUpdated(updated.estimatedGrams)
          : l10n.foodPortionAdjustedItems(updated.estimatedGrams);
      showAppSnack(context, message, icon: Icons.tune_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final mediaQuery = MediaQuery.of(context);
    // Safe-area and keyboard aware instead of a fixed 92 % (sheetMaxHeight):
    // same cap as the add-meal sheet, so the fixed header never slides under
    // the status bar or Dynamic Island.
    final maxHeight = sheetMaxHeightOf(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // No SheetScaffold: that assumes a fixed title plus exactly one footer
    // action. Here a fixed header sits above a capped scroll area and the
    // actions live on the result card.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            _Header(slot: widget.slot, onClose: () => Navigator.of(context).pop()),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  28 + mediaQuery.viewPadding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.previewImage != null) ...[
                      MealPreviewCard(imageBytes: widget.previewImage),
                      const SizedBox(height: 14),
                    ],
                    if (_isLoading)
                      const MealLoadingCard()
                    else if (_result != null)
                      MealResultCard(
                        result: _result!,
                        addedToDailyTotal: _addedToDailyTotal,
                        onAdjustRequested: _adjustPortion,
                        onAddToDailyRequested: _addToDaily,
                        isFavorite: _isFavoriteNow,
                        onToggleFavorite: widget.onToggleFavorite == null
                            ? null
                            : _handleToggleFavorite,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.slot, required this.onClose});

  final MealSlot slot;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final color = slot.accentIn(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
      child: Row(
        children: [
          MealAvatar(letter: slot.initial(l10n), color: color, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  slot.label(l10n),
                  style: AppType.display(18, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.foodReviewAnalysisSubtitle,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('analyse-sheet-close'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
