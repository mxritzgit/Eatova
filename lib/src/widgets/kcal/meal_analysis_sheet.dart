import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_request.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/meal_analyzer.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';

/// Maps an analysis/lookup error to the message shown in the sheet.
///
/// Typed [MealAnalysisException]s carry a language-neutral code that is
/// resolved here, at display time (F4-01/F9-03). Beyond those:
///
///  * [TimeoutException] — the connection was up, only the answer never came,
///    so a "check your connection" message would mislead.
///  * [SocketException] — no route at all: that IS the connection message.
///  * [ProductWithoutNutritionException] — the product was found but carries
///    no loggable energy value, so the "not found" message would be wrong.
///    The error already brings its own message.
String mealAnalysisErrorMessage(
  Object error,
  String fallback,
  AppLocalizations l10n,
) {
  if (error is MealAnalysisException) {
    return _mealAnalysisExceptionMessage(error, fallback, l10n);
  }
  if (error is TimeoutException) {
    return l10n.foodAnalysisTimeoutMessage;
  }
  if (error is SocketException) {
    return l10n.foodAnalysisOfflineMessage;
  }
  if (error is ProductWithoutNutritionException) {
    return error.userMessage(l10n);
  }
  return fallback;
}

String _mealAnalysisExceptionMessage(
  MealAnalysisException error,
  String fallback,
  AppLocalizations l10n,
) {
  return switch (error) {
    MealAnalysisReauthRequired() => l10n.foodReauthRequiredError,
    MealImageTooLarge() => l10n.foodImageTooLargeError,
    MealAnalysisCancelled() => fallback,
    MealAnalysisRateLimited(:final resetAt) =>
      resetAt != null && resetAt.isAfter(clock.now())
          ? l10n.foodAnalysisRateLimitUntilMessage(_clockLabel(resetAt))
          : l10n.foodAnalysisRateLimitError,
    MealAnalysisServerError(:final code) => switch (code) {
        'provider_timeout' => l10n.foodAnalysisTimeoutMessage,
        'provider_error' ||
        'provider_invalid_response' ||
        'provider_invalid_json' ||
        'provider_empty_response' ||
        'invalid_result' =>
          l10n.foodAnalysisProviderErrorMessage,
        'provider_not_configured' ||
        'server_misconfigured' ||
        'rate_limit_unavailable' ||
        'internal_error' =>
          l10n.foodAnalysisServiceUnavailableMessage,
        'missing_image' ||
        'invalid_image_base64' ||
        'image_too_small' =>
          l10n.foodAnalysisImageUnusableMessage,
        // Deliberately unmapped: unsupported_content_type, invalid_json,
        // invalid_body, method_not_allowed are client bugs, not user
        // situations — the flow's fallback is the honest text for them.
        _ => fallback,
      },
  };
}

/// `HH:mm` in local time, without intl: `DateFormat` needs locale data that a
/// context-free caller cannot guarantee is loaded.
String _clockLabel(DateTime at) {
  final local = at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// One finished round of `showWeightAdjustmentSheet`, classified: the new
/// result plus how the user got there. See [mealPortionAdjustment].
class MealPortionAdjustment {
  const MealPortionAdjustment.weight(this.result) : isWeightOnly = true;
  const MealPortionAdjustment.items(this.result) : isWeightOnly = false;

  final MealAnalysisResult result;

  /// True when only a total weight moved, false when the user confirmed or
  /// edited an itemized breakdown. Callers need it for their message; the
  /// result itself already carries everything else.
  final bool isWeightOnly;
}

/// Applies what `showWeightAdjustmentSheet` returned to [current], or null when
/// it was cancelled or carries nothing usable.
///
/// The sheet always pops a `List<MealComponent>`. For a result WITHOUT an
/// itemized breakdown it synthesizes ONE component from the meal itself, so a
/// barcode product comes back as a one-element list even when the user only
/// moved the gram dial. Handing that list to
/// [MealAnalysisResult.adjustedToItems] would give the product an `items` list
/// and make `hasItemizedBreakdown` true: the card then claims "INGREDIENTS · 1"
/// over a row that merely repeats the product name, the portion line says
/// "adjusted via individual items" and the info sheet adds the "components were
/// manually confirmed" paragraph — for a plain weight change. That case is
/// applied as a gram adjustment instead, which leaves `items` empty.
MealPortionAdjustment? mealPortionAdjustment(
  MealAnalysisResult current,
  Object? adjustment,
) {
  if (adjustment is! List<MealComponent> || adjustment.isEmpty) return null;
  final grams = _weightOnlyGrams(current, adjustment);
  if (grams != null) {
    return MealPortionAdjustment.weight(current.adjustedToGrams(grams));
  }
  return MealPortionAdjustment.items(current.adjustedToItems(adjustment));
}

/// The dialed weight when [adjusted] is nothing but the synthesized single
/// component rescaled, else null.
///
/// The comparison is against exactly what the sheet computes for that component
/// (`MealComponent.adjustedToGrams` on [MealAnalysisResult.asSingleComponent]),
/// so a user who removed the synthesized entry and added one of their own —
/// a real, one-item breakdown — does not slip through.
int? _weightOnlyGrams(MealAnalysisResult current, List<MealComponent> adjusted) {
  if (current.hasItemizedBreakdown || adjusted.length != 1) return null;
  final single = adjusted.single;
  final rescaled = current.asSingleComponent.adjustedToGrams(single.grams);
  if (single.name != rescaled.name ||
      single.grams != rescaled.grams ||
      single.caloriesKcal != rescaled.caloriesKcal) {
    return null;
  }
  return single.grams;
}

/// What the sheet was closed with. Null = plain close.
enum MealAnalysisSheetOutcome {
  /// The user chose "enter manually" from the error state; the caller opens
  /// the manual entry sheet.
  manualEntry,
}

/// Sub-sheet for photo/barcode analysis, started by AddMealSheet once an
/// image or barcode is captured. Shows the loading card, then the
/// `MealResultCard` with adjust + add; there is no confirm step.
///
/// [retry] re-creates the analysis future from the bytes the caller still
/// holds; null hides "try again" (barcode lookups). [cancellation] is
/// cancelled when the sheet goes away while a request is in flight.
Future<MealAnalysisSheetOutcome?> showMealAnalysisSheet(
  BuildContext context, {
  required MealSlot slot,
  required Future<MealAnalysisResult> resultFuture,
  required Uint8List? previewImage,
  required String Function(MealAnalysisResult, MealSlot) onAdd,
  required void Function(String id, MealAnalysisResult scaled) onUpdateMeal,
  required String failureMessage,
  bool Function(MealAnalysisResult)? isFavorite,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
  Future<MealAnalysisResult> Function()? retry,
  MealAnalysisCancellation? cancellation,
}) {
  return showModalBottomSheet<MealAnalysisSheetOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
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
        retry: retry,
        cancellation: cancellation,
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
    this.retry,
    this.cancellation,
  });

  /// After this long without an answer the loading card gets a "taking
  /// longer" line plus a cancel button. Well under the 60 s client timeout.
  static const Duration slowAfter = Duration(seconds: 12);

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

  /// Starts a fresh attempt from the same bytes. Null -> no retry button.
  final Future<MealAnalysisResult> Function()? retry;

  /// Cancelled on dispose while a request is still running.
  final MealAnalysisCancellation? cancellation;

  @override
  State<MealAnalysisSheet> createState() => _MealAnalysisSheetState();
}

class _MealAnalysisSheetState extends State<MealAnalysisSheet> {
  MealAnalysisResult? _result;
  Object? _error;
  bool _isLoading = true;
  bool _slowHint = false;
  bool _addedToDailyTotal = false;
  // Client UUID of the logged row; a later re-portion applies to this id.
  String? _addedMealId;
  // Optimistic local favorite state: the sheet lives on its own modal route,
  // so a HomePage setState does not rebuild it and the heart would lag.
  bool? _favoriteOverride;

  Timer? _slowTimer;
  // Attempt counter: a late answer from a superseded attempt is dropped.
  int _attempt = 0;
  // False while an attempt is in flight -> dispose cancels it.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _run(widget.resultFuture);
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    if (!_settled) widget.cancellation?.cancel();
    super.dispose();
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

  Future<void> _run(Future<MealAnalysisResult> future) async {
    final attempt = ++_attempt;
    _settled = false;
    _slowTimer?.cancel();
    _slowTimer = Timer(MealAnalysisSheet.slowAfter, () {
      if (!mounted || attempt != _attempt || !_isLoading) return;
      setState(() => _slowHint = true);
    });
    try {
      final value = await future;
      if (attempt != _attempt) return;
      _settled = true;
      if (!mounted) return;
      setState(() {
        _result = value;
        _isLoading = false;
        _slowHint = false;
      });
    } catch (error) {
      if (attempt != _attempt) return;
      _settled = true;
      if (!mounted) return;
      // Our own cancel (dispose or the cancel button): the sheet is closing
      // and still mounted for the ~250 ms pop animation — an error card
      // would flash. Nothing to show.
      if (error is MealAnalysisCancelled) return;
      setState(() {
        _error = error;
        _isLoading = false;
        _slowHint = false;
      });
    } finally {
      if (attempt == _attempt) _slowTimer?.cancel();
    }
  }

  void _retry() {
    final retry = widget.retry;
    if (retry == null) return;
    setState(() {
      _error = null;
      _isLoading = true;
      _slowHint = false;
    });
    // Future.sync: a synchronous throw inside `retry` lands in the error
    // state instead of escaping the tap handler.
    _run(Future<MealAnalysisResult>.sync(retry));
  }

  void _cancelAndClose() {
    widget.cancellation?.cancel();
    Navigator.of(context).pop();
  }

  void _manualEntry() {
    Navigator.of(context).pop(MealAnalysisSheetOutcome.manualEntry);
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
    if (!mounted) return;

    final applied = mealPortionAdjustment(current, adjustment);
    if (applied == null) return;
    final updated = applied.result;

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

    // The message names the WAY the portion changed; "via individual items"
    // over a product that has none is the very claim this distinction avoids.
    final l10n = context.l10n;
    final grams = updated.estimatedGrams;
    final String message;
    if (applied.isWeightOnly) {
      message = wasAdded
          ? l10n.foodPortionAdjustedUpdated(grams)
          : l10n.foodPortionAdjusted(grams);
    } else {
      message = wasAdded
          ? l10n.foodPortionAdjustedItemsUpdated(grams)
          : l10n.foodPortionAdjustedItems(grams);
    }
    showAppSnack(context, message, icon: Icons.tune_rounded);
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
    final error = _error;

    // No SheetScaffold: that assumes a fixed title plus exactly one footer
    // action. Here a fixed header sits above a capped scroll area and the
    // actions live on the result card.
    final body = Column(
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
                if (_isLoading) ...[
                  const MealLoadingCard(),
                  if (_slowHint) ...[
                    const SizedBox(height: 10),
                    _SlowHint(onCancel: _cancelAndClose),
                  ],
                ] else if (error != null)
                  _AnalysisErrorCard(
                    message: mealAnalysisErrorMessage(
                      error,
                      widget.failureMessage,
                      context.l10n,
                    ),
                    onRetry: widget.retry == null ? null : _retry,
                    onManualEntry: _manualEntry,
                  )
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
    );
    // SnackHost INSIDE the ground color (review I-2): the sheet stays open
    // after add, re-portion and the 0-kcal guard, so their toasts must land
    // above the scrim in a strip the host reserves below the content — not
    // under it on the root messenger, where they read as dead.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        key: const ValueKey('analyse-sheet'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        child: SnackHost(child: body),
      ),
    );
  }
}

/// Error state INSIDE the sheet (F4-02): the preview above stays, the user
/// can retry from the same bytes or switch to manual entry.
class _AnalysisErrorCard extends StatelessWidget {
  const _AnalysisErrorCard({
    required this.message,
    required this.onRetry,
    required this.onManualEntry,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onManualEntry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('analyse-error'),
      radius: rCard,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: t.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.foodAnalysisErrorTitle,
                  style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            key: const ValueKey('analyse-error-message'),
            style: AppType.ui(13, color: t.ink2, height: 1.4),
          ),
          const SizedBox(height: 14),
          if (onRetry != null) ...[
            PrimaryActionButton(
              key: const ValueKey('analyse-retry'),
              label: l10n.foodAnalysisRetryButton,
              icon: Icons.refresh_rounded,
              onTap: onRetry,
              height: 48,
            ),
            const SizedBox(height: 4),
          ],
          SizedBox(
            width: double.infinity,
            child: TextButton(
              key: const ValueKey('analyse-manual-entry'),
              onPressed: onManualEntry,
              child: Text(l10n.foodAnalysisManualEntryButton),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown under the loading card once [MealAnalysisSheet.slowAfter] passed.
class _SlowHint extends StatelessWidget {
  const _SlowHint({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      key: const ValueKey('analyse-slow-hint'),
      children: [
        Expanded(
          child: Text(
            l10n.foodAnalysisSlowHint,
            style: AppType.ui(12.5, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
        TextButton(
          key: const ValueKey('analyse-cancel'),
          onPressed: onCancel,
          child: Text(l10n.commonCancel),
        ),
      ],
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
