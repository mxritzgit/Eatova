import '../models/favorite_meal.dart';
import '../models/logged_meal.dart';

/// Pure view logic for the favorites sheet (feature 2026-08-27). No state, no I/O — the store
/// keeps owning the list, these helpers only order and cut it.

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

/// Order of the favorites sheet's list (lively list, 2026-10-03).
enum FavoriteSort { recent, frequent, alphabetical }

/// How often each favorite was logged since local midnight [days] days
/// before [now], keyed like [FavoriteMeal.idFor] (barcode, else name). Only
/// the meals the store holds count, which covers its boot window.
Map<String, int> favoriteUseCounts(
  Iterable<LoggedMeal> meals, {
  required DateTime now,
  int days = 35,
}) {
  // Calendar arithmetic, not a Duration: the window starts at midnight on
  // both sides of a DST switch.
  final since = DateTime(now.year, now.month, now.day - days);
  final counts = <String, int>{};
  for (final meal in meals) {
    if (meal.loggedAt.isBefore(since)) continue;
    final id = FavoriteMeal.idFor(meal.result);
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

/// [pinnedByRecency] (see [pinnedFavoritesByRecency]) in [sort] order.
///
/// Frequent: most logged first by [useCounts]; A–Z: by [nameOf], ignoring
/// case and diacritics ("Äpfel" sits with "Apfel"). Ties keep the recency
/// order, so the list never shuffles between equal rows.
List<FavoriteMeal> sortFavorites(
  List<FavoriteMeal> pinnedByRecency,
  FavoriteSort sort, {
  Map<String, int> useCounts = const <String, int>{},
  required String Function(FavoriteMeal favorite) nameOf,
}) {
  if (sort == FavoriteSort.recent) return pinnedByRecency;
  final indexed = List<(int, FavoriteMeal)>.generate(
    pinnedByRecency.length,
    (i) => (i, pinnedByRecency[i]),
  );
  final keys = <String, String>{
    if (sort == FavoriteSort.alphabetical)
      for (final f in pinnedByRecency) f.id: _sortKey(nameOf(f)),
  };
  indexed.sort((a, b) {
    final order = sort == FavoriteSort.frequent
        ? (useCounts[b.$2.id] ?? 0).compareTo(useCounts[a.$2.id] ?? 0)
        : keys[a.$2.id]!.compareTo(keys[b.$2.id]!);
    return order != 0 ? order : a.$1.compareTo(b.$1);
  });
  return indexed.map((e) => e.$2).toList(growable: false);
}

const Map<String, String> _folded = <String, String>{
  'ä': 'a', 'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
  'ö': 'o', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o',
  'ü': 'u', 'ú': 'u', 'ù': 'u', 'û': 'u',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ç': 'c', 'ñ': 'n', 'ß': 'ss',
};

String _sortKey(String name) {
  final buffer = StringBuffer();
  for (final char in name.trim().toLowerCase().split('')) {
    buffer.write(_folded[char] ?? char);
  }
  return buffer.toString();
}
