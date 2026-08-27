import '../models/favorite_meal.dart';

/// Pure view logic for the favorites sheet and the inline favorites section
/// of the add-meal sheet (feature 2026-08-27). No state, no I/O — the store
/// keeps owning the list, these helpers only order and cut it.

/// How many pinned favorites the add-meal sheet shows inline before the
/// "All (N)" button takes over.
const int kInlineFavoritesCount = 3;

/// Pinned favorites only, most recently used first.
///
/// `addedAt` doubles as "last used": `_rememberRecent` rewrites the entry with
/// a fresh timestamp on every log, pinned or not. Ties keep the incoming
/// order (stable sort), so a list the server already returns by `added_at
/// DESC` does not shuffle.
List<FavoriteMeal> pinnedFavoritesByRecency(List<FavoriteMeal> all) {
  final pinned = all.where((f) => f.pinned).toList();
  // List.sort is not guaranteed stable; decorate with the index instead.
  final indexed = List<(int, FavoriteMeal)>.generate(
      pinned.length, (i) => (i, pinned[i]));
  indexed.sort((a, b) {
    final byTime = b.$2.addedAt.compareTo(a.$2.addedAt);
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });
  return indexed.map((e) => e.$2).toList(growable: false);
}

/// The inline slice of [pinnedFavoritesByRecency].
List<FavoriteMeal> inlineFavorites(List<FavoriteMeal> all) =>
    pinnedFavoritesByRecency(all).take(kInlineFavoritesCount).toList();

/// Local name/brand filter for the favorites sheet's search field.
///
/// Case-insensitive substring match on `mealName` and `brand`; every
/// whitespace-separated term must match somewhere ("hafer alpro" finds
/// "Haferdrink" by Alpro). A blank query returns the input untouched.
List<FavoriteMeal> filterFavoritesByQuery(
    List<FavoriteMeal> favorites, String query) {
  final terms = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (terms.isEmpty) return favorites;
  return favorites.where((f) {
    final haystack =
        '${f.result.mealName} ${f.result.brand ?? ''}'.toLowerCase();
    return terms.every(haystack.contains);
  }).toList(growable: false);
}
