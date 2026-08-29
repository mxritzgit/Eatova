import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/favorite_meal.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../services/favorites_view.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'meal_suggestion_item.dart';

// Favorites sheet (feature 2026-08-27): every pinned favorite, searchable,
// stacked above the add-meal sheet.
//
// Own sheet instead of a longer inline section: the add-meal sheet shows only
// the top `kInlineFavoritesCount` pinned so search and recents stay within
// reach; its "All (N)" button opens this one. The slot is not choosable here
// — the add-meal sheet's current slot is passed straight through to `onAdd`.
// The heart is the only way to remove a row (no X), and removal is mirrored
// locally while the parent store does the real toggle.

/// Opens the favorites sheet above the add-meal sheet.
Future<void> showFavoritesSheet(
  BuildContext context, {
  required List<FavoriteMeal> favorites,
  required MealSlot slot,
  required String Function(MealAnalysisResult result, MealSlot slot) onAdd,
  required ValueChanged<MealAnalysisResult> onUnpin,
}) {
  return showEatovaSheet<void>(
    context,
    FavoritesSheet(
      favorites: favorites,
      slot: slot,
      onAdd: onAdd,
      onUnpin: onUnpin,
    ),
  );
}

class FavoritesSheet extends StatefulWidget {
  const FavoritesSheet({
    super.key,
    required this.favorites,
    required this.slot,
    required this.onAdd,
    required this.onUnpin,
  });

  /// The full store list (pinned + auto-recents); only pinned rows are shown.
  final List<FavoriteMeal> favorites;

  /// The slot chosen in the add-meal sheet; only passed on to [onAdd].
  final MealSlot slot;

  /// Same contract as `AddMealSheet.onAdd`; returns the logged meal id.
  final String Function(MealAnalysisResult result, MealSlot slot) onAdd;

  /// The parent toggles the store; the row disappears here locally.
  final ValueChanged<MealAnalysisResult> onUnpin;

  @override
  State<FavoritesSheet> createState() => _FavoritesSheetState();
}

class _FavoritesSheetState extends State<FavoritesSheet> {
  /// Dwell time of the green check — display logic, not motion, so it
  /// deliberately bypasses `motionDuration`.
  static const Duration _justAddedFadeDelay = Duration(seconds: 2);

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Ids unpinned in this sheet; derived from `widget.favorites` on every
  /// build so a parent rebuild cannot resurrect a removed row.
  final Set<String> _unpinnedIds = <String>{};

  String? _expandedItemKey;
  final Set<String> _justAddedKeys = <String>{};
  final Map<String, Timer> _justAddedTimers = <String, Timer>{};

  @override
  void dispose() {
    for (final timer in _justAddedTimers.values) {
      timer.cancel();
    }
    _justAddedTimers.clear();
    _searchController.dispose();
    super.dispose();
  }

  List<FavoriteMeal> get _pinned => pinnedFavoritesByRecency(widget.favorites)
      .where((f) => !_unpinnedIds.contains(f.id))
      .toList(growable: false);

  static String _itemKey(FavoriteMeal favorite) => 'favorite:${favorite.id}';

  void _toggleExpanded(String key) {
    setState(() => _expandedItemKey = _expandedItemKey == key ? null : key);
  }

  void _handleAdd(String itemKey, MealAnalysisResult result) {
    // Same last guard as AddMealSheet._handleAdd: legacy rows with the
    // "0 = unknown" sentinel stay visible but unloggable; a measured 0
    // (explicitZeroKcal) passes.
    if (result.caloriesKcal <= 0 && !result.explicitZeroKcal) {
      showAppSnack(
        context,
        context.l10n.foodSuggestionWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }

    widget.onAdd(result, widget.slot);
    if (!mounted) return;
    final l10n = context.l10n;
    showAppSnack(
      context,
      l10n.commonKcalAddedToSlot(result.caloriesKcal, widget.slot.label(l10n)),
      icon: Icons.check_circle_rounded,
    );
    setState(() {
      _expandedItemKey = null;
      _justAddedKeys.add(itemKey);
    });
    _justAddedTimers.remove(itemKey)?.cancel();
    _justAddedTimers[itemKey] = Timer(_justAddedFadeDelay, () {
      _justAddedTimers.remove(itemKey);
      if (!mounted) return;
      setState(() => _justAddedKeys.remove(itemKey));
    });
  }

  void _handleUnpin(FavoriteMeal favorite) {
    widget.onUnpin(favorite.result);
    if (!mounted) return;
    final key = _itemKey(favorite);
    _justAddedTimers.remove(key)?.cancel();
    setState(() {
      _unpinnedIds.add(favorite.id);
      _justAddedKeys.remove(key);
      if (_expandedItemKey == key) _expandedItemKey = null;
    });
    showAppSnack(
      context,
      context.l10n.commonFavoriteRemoved,
      icon: Icons.favorite_outline_rounded,
      tone: SnackTone.neutral,
    );
  }

  void _onQueryChanged(String value) => setState(() => _query = value);

  void _clearQuery() {
    _searchController.clear();
    _onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final pinned = _pinned;
    final visible = filterFavoritesByQuery(pinned, _query);
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    // showEatovaSheet supplies handle, keyboard inset and the height cap; this
    // is only the inside: header, search, capped scroll area, no footer.
    final body = Column(
      key: const ValueKey('favorites-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sheet title, so rank 1 (P9-06b): the shared widget adds the
              // `header` trait AND the rank the hand-written Semantics here
              // never carried. Type stays display-24 — a11y fix, no redesign.
              HeadingSemantics(
                level: 1,
                child: Text(
                  l10n.foodFavoritesSheetTitle(pinned.length),
                  key: const ValueKey('favorites-sheet-title'),
                  style: AppType.display(24, color: t.ink, height: 1.15),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.foodFavoritesSheetSubtitle,
                style: AppType.ui(12.5, color: t.ink2, height: 1.45),
              ),
            ],
          ),
        ),
        // Nothing to filter without pinned rows: the field would only mislead.
        if (pinned.isNotEmpty) ...[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _SearchField(
              controller: _searchController,
              hasQuery: _query.isNotEmpty,
              onChanged: _onQueryChanged,
              onClear: _clearQuery,
            ),
          ),
        ],
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('favorites-sheet-scroll'),
            padding: EdgeInsets.fromLTRB(20, 12, 20, 28 + bottomInset),
            child: maybeAnimatedSize(
              context,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: _buildList(pinned, visible),
            ),
          ),
        ),
      ],
    );
    // SnackHost: adds and unpins keep the sheet open, so their toasts must
    // land inside it, above the scrim (review F3-02).
    return SnackHost(child: body);
  }

  Widget _buildList(List<FavoriteMeal> pinned, List<FavoriteMeal> visible) {
    final l10n = context.l10n;
    if (pinned.isEmpty) {
      return _Hint(
        key: const ValueKey('favorites-sheet-empty'),
        text: l10n.foodFavoritesEmptyHint,
      );
    }
    if (visible.isEmpty) {
      return _Hint(
        key: const ValueKey('favorites-sheet-no-match'),
        text: l10n.foodFavoritesNoMatchHint,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          _item(visible[i], i),
          if (i != visible.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _item(FavoriteMeal favorite, int index) {
    final key = _itemKey(favorite);
    return MealSuggestionItem(
      key: ValueKey('favorites-sheet-item-$index'),
      result: favorite.result,
      fallbackIcon: Icons.favorite_rounded,
      expanded: _expandedItemKey == key,
      justAdded: _justAddedKeys.contains(key),
      onTap: () => _toggleExpanded(key),
      onAdd: (result) => _handleAdd(key, result),
      addButtonKey: ValueKey('favorites-sheet-add-$index'),
      isFavorite: true,
      onToggleFavorite: (_) => _handleUnpin(favorite),
      favoriteButtonKey: ValueKey('favorites-sheet-fav-$index'),
    );
  }
}

/// Borderless pill on a [FieldCapsule] (rest `field`, focus `fieldFocus`; no
/// hairline, no focus ring). Local filter only — no network, no debounce.
class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.controller,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return FieldCapsule(
      focusNode: _focus,
      shape: SheetFieldShape.pill,
      // Minimum, not fixed: at textScaler 2.0 the hint needs ~56 pt and a
      // fixed 46 let it hang out of the capsule (safe-area test 2026-08-27).
      constraints: const BoxConstraints(minHeight: 46),
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.search_rounded, size: 18, color: t.ink2),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('favorites-sheet-search'),
              controller: widget.controller,
              focusNode: _focus,
              // App-wide rule: discrete blinking, no continuous fade repaint.
              cursorOpacityAnimates: false,
              cursorColor: t.accent,
              onChanged: widget.onChanged,
              textInputAction: TextInputAction.search,
              style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
              decoration: InputDecoration(
                hintText: context.l10n.foodFavoritesSearchHint,
                hintStyle: AppType.ui(
                  14,
                  weight: FontWeight.w500,
                  color: t.ink2,
                ),
                isCollapsed: true,
                // Null the theme borders explicitly: the global
                // inputDecorationTheme carries a hairline and focus ring.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (widget.hasQuery)
            IconButton(
              key: const ValueKey('favorites-sheet-search-clear'),
              // Not the Material "Delete" tooltip: next to a favorites list it
              // reads as "remove favorite". The recipes search key already
              // says exactly what this does.
              tooltip: context.l10n.recipesSearchClearTooltip,
              onPressed: widget.onClear,
              // 44 pt tap floor; compact density would shrink it to 40.
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(Icons.close_rounded, size: 18, color: t.ink2),
            )
          else
            const SizedBox(width: 14),
        ],
      ),
    );
  }
}

/// Quiet centered hint for the two empty states (copy of the add-meal
/// sheet's private `_HintBlock`).
class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppType.ui(
          13,
          weight: FontWeight.w500,
          color: context.t.ink2,
          height: 1.4,
        ),
      ),
    );
  }
}
