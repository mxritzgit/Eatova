import '../l10n/l10n.dart';

/// Foods the user avoids: intolerances, allergies, or simply not eaten.
///
/// A CLOSED list on purpose: the wire code is [Enum.name], and the same codes
/// sit in the `profiles_food_avoidances_check` constraint
/// (`supabase/migrations/20261018100000_profiles_food_preferences.sql`) and
/// in `coach-chat/recipe.ts`. A new code needs all three, or the server
/// rejects the profile operation. Declaration order is the display order.
///
/// The coach considers them; it is no allergy guarantee.
enum FoodAvoidance {
  lactose,
  gluten,
  nuts,
  peanuts,
  egg,
  soy,
  fish,
  shellfish,
  sesame,
  celery,
  mustard,
  pork,
  alcohol,
}

extension FoodAvoidanceLabel on FoodAvoidance {
  String label(AppLocalizations l10n) => switch (this) {
    FoodAvoidance.lactose => l10n.foodPrefsAvoidLactose,
    FoodAvoidance.gluten => l10n.foodPrefsAvoidGluten,
    FoodAvoidance.nuts => l10n.foodPrefsAvoidNuts,
    FoodAvoidance.peanuts => l10n.foodPrefsAvoidPeanuts,
    FoodAvoidance.egg => l10n.foodPrefsAvoidEgg,
    FoodAvoidance.soy => l10n.foodPrefsAvoidSoy,
    FoodAvoidance.fish => l10n.foodPrefsAvoidFish,
    FoodAvoidance.shellfish => l10n.foodPrefsAvoidShellfish,
    FoodAvoidance.sesame => l10n.foodPrefsAvoidSesame,
    FoodAvoidance.celery => l10n.foodPrefsAvoidCelery,
    FoodAvoidance.mustard => l10n.foodPrefsAvoidMustard,
    FoodAvoidance.pork => l10n.foodPrefsAvoidPork,
    FoodAvoidance.alcohol => l10n.foodPrefsAvoidAlcohol,
  };
}

/// Upper bound of `profiles.food_dislikes` in Unicode code points, which is
/// what PostgreSQL's `char_length` counts.
const int kFoodDislikesMaxChars = 120;

/// [avoidances] in display order, so a set always serializes the same way.
List<FoodAvoidance> sortedFoodAvoidances(Iterable<FoodAvoidance> avoidances) =>
    avoidances.toSet().toList()..sort((a, b) => a.index.compareTo(b.index));

/// Wire form: the codes in display order, without duplicates.
List<String> foodAvoidancesToWire(Iterable<FoodAvoidance> avoidances) => [
  for (final a in sortedFoodAvoidances(avoidances)) a.name,
];

/// Lenient reader for a stored or received code list: unknown codes and
/// non-strings are dropped, anything that is not a list reads as empty. A
/// newer build's code must not make an older profile unreadable.
Set<FoodAvoidance> parseFoodAvoidances(Object? raw) {
  if (raw is! List) return const <FoodAvoidance>{};
  final out = <FoodAvoidance>{};
  for (final code in raw) {
    if (code is! String) continue;
    for (final a in FoodAvoidance.values) {
      if (a.name == code) out.add(a);
    }
  }
  return Set<FoodAvoidance>.unmodifiable(out);
}

/// The dislikes text as `profiles_food_dislikes_check` accepts it.
///
/// The server check rejects control characters (U+0001..U+001F,
/// U+007F..U+009F), angle brackets and more than [kFoodDislikesMaxChars] code
/// points. A rejected profile operation is dropped as a whole (class 22), so
/// every write path normalizes here first: controls become spaces, angle
/// brackets and lone surrogates go, whitespace runs collapse, and the text is
/// cut at the cap.
String normalizeFoodDislikes(String raw) {
  final cleaned = StringBuffer();
  for (final rune in raw.runes) {
    if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) {
      cleaned.write(' ');
    } else if (rune == 0x3c || rune == 0x3e) {
      continue;
    } else if (rune >= 0xd800 && rune <= 0xdfff) {
      continue;
    } else {
      cleaned.writeCharCode(rune);
    }
  }
  final collapsed = cleaned.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = collapsed.runes.toList(growable: false);
  if (runes.length <= kFoodDislikesMaxChars) return collapsed;
  // Code points, never UTF-16 units: a cut cannot split a surrogate pair.
  return String.fromCharCodes(runes.take(kFoodDislikesMaxChars)).trimRight();
}
