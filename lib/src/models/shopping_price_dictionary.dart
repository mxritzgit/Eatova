// The curated label -> Open Food Facts category dictionary behind the
// shopping list's price estimate, and the deterministic matcher that reads a
// recipe line against it. Contract and maintenance: docs/SHOPPING-PRICES.md.
//
// Every tag was verified against live Open Prices data before it went in.
// Piece, pack and spoon weights are starting values for review, not facts.
//
// Keys are matching data, not UI text: double-quoted (like
// meal_description_matcher.dart), folded with [foldRecipeSearchText].

import 'fitness_recipe.dart' show foldRecipeSearchText;
import 'shopping_price.dart';

/// Bumped with every change of entries or tags; part of the cache key.
const int kPriceDictionaryVersion = 3;

/// One priceable ingredient: which Open Prices rows describe it and how a
/// recipe amount converts into its price basis.
class PriceEntry {
  const PriceEntry(
    this.id, {
    required this.productTags,
    List<String>? categoryTags,
    this.requireTags = const [],
    this.excludeTags = const [],
    this.excludeWords = const [],
    this.basis = PriceBasis.mass,
    this.categoryPrices = false,
    this.density = 1.0,
    this.units = const {},
    this.tbspGrams,
    this.tspGrams,
    this.spiceWhenSpooned = false,
  }) : _categoryTags = categoryTags;

  final String id;

  /// Product categories, most specific first; sent as one overlap filter.
  final List<String> productTags;
  final List<String>? _categoryTags;

  /// Tags a product row must carry all of, and none of.
  final List<String> requireTags, excludeTags;

  /// Folded words anywhere in a label, also after a comma, in parentheses
  /// or as the end of a compound, that name a product this entry does not
  /// price ("Tomaten, passiert", "Knoblauchgranulat"); see
  /// [priceLabelExcluded].
  final List<String> excludeWords;
  final PriceBasis basis;

  /// Whether loose-goods category prices (`type=CATEGORY`) count: per
  /// kilogram for a mass basis, per piece for a piece basis.
  final bool categoryPrices;

  /// Grams per millilitre.
  final double density;

  /// One unit in grams (mass and piece basis) or millilitres (volume basis).
  final Map<PriceUnit, double> units;
  final double? tbspGrams, tspGrams;

  /// A spoon or pinch of it is the spice (paprika), not the vegetable.
  final bool spiceWhenSpooned;

  /// Category-price tags; the product tags unless set.
  List<String> get categoryTags => _categoryTags ?? productTags;

  /// Whether a product with [categoriesTags] is this entry: one of its
  /// product tags, all required tags and no excluded one.
  bool matchesProduct(List<String> categoriesTags) =>
      productTags.any(categoriesTags.contains) &&
      requireTags.every(categoriesTags.contains) &&
      !excludeTags.any(categoriesTags.contains);
}

/// Every entry by id.
const Map<String, PriceEntry> kPriceEntries = {
  "salami": PriceEntry(
    "salami",
    productTags: ["en:salami"],
    units: {PriceUnit.slice: 10, PriceUnit.pack: 100},
  ),
  "mozzarella": PriceEntry(
    "mozzarella",
    productTags: ["en:mozzarella"],
    units: {PriceUnit.piece: 125, PriceUnit.pack: 125},
  ),
  "pizzaDough": PriceEntry(
    "pizzaDough",
    productTags: ["en:pizza-dough"],
    units: {PriceUnit.pack: 400},
  ),
  "passata": PriceEntry(
    "passata",
    productTags: ["en:strained-tomatoes"],
    density: 1.05,
    units: {PriceUnit.pack: 500, PriceUnit.can: 400, PriceUnit.jar: 500},
  ),
  "tomato": PriceEntry(
    "tomato",
    productTags: ["en:tomatoes"],
    requireTags: ["en:fresh-vegetables"],
    excludeTags: [
      "en:canned-tomatoes",
      "en:tomato-sauces",
      "en:ketchup",
      "en:strained-tomatoes",
    ],
    excludeWords: [
      "passiert", "passierte", "gehackt", "gehackte", "stueckig", //
      "stueckige", "stuecken", "geschaelt", "geschaelte", "getrocknet", //
      "getrocknete", "dose", "dosen", "konserve", "canned", "tinned", //
      "dried", "puree",
    ],
    categoryPrices: true,
    units: {PriceUnit.piece: 100},
  ),
  "onion": PriceEntry(
    "onion",
    productTags: ["en:onions"],
    excludeTags: ["en:fried-onions"],
    categoryPrices: true,
    units: {PriceUnit.piece: 100},
  ),
  "garlic": PriceEntry(
    "garlic",
    productTags: ["en:garlic", "en:garlics"],
    // Fresh bulbs only: granulated garlic and garlic in oil share the tags.
    requireTags: ["en:fresh-vegetables"],
    excludeTags: ["en:pickles", "en:canned-foods"],
    excludeWords: [
      "granuliert", "granulat", "getrocknet", "getrocknete", "pulver", //
      "eingelegt", "eingelegte", "granulated", "dried", "powder", "pickled",
    ],
    categoryPrices: true,
    units: {PriceUnit.clove: 4, PriceUnit.piece: 50},
  ),
  "milk": PriceEntry(
    "milk",
    productTags: ["en:milks"],
    basis: PriceBasis.volume,
    density: 1.03,
    units: {PriceUnit.pack: 1000},
  ),
  "egg": PriceEntry(
    "egg",
    productTags: ["en:eggs"],
    basis: PriceBasis.piece,
    units: {PriceUnit.piece: 60, PriceUnit.pack: 600},
  ),
  "butter": PriceEntry(
    "butter",
    productTags: ["en:butters"],
    units: {PriceUnit.pack: 250},
    tbspGrams: 15,
    tspGrams: 5,
  ),
  "flour": PriceEntry(
    "flour",
    productTags: ["en:wheat-flours"],
    density: 0.55,
    units: {PriceUnit.pack: 1000},
    tbspGrams: 10,
    tspGrams: 3,
  ),
  "rice": PriceEntry(
    "rice",
    productTags: ["en:rices"],
    density: 0.8,
    units: {PriceUnit.pack: 1000},
  ),
  "spaghetti": PriceEntry(
    "spaghetti",
    productTags: ["en:spaghetti"],
    units: {PriceUnit.pack: 500},
  ),
  "chickenBreast": PriceEntry(
    "chickenBreast",
    productTags: ["en:chicken-breasts"],
    excludeTags: [
      "en:cooked-chicken-breast-slices",
      "en:prepared-chicken-meats",
    ],
    units: {PriceUnit.piece: 150, PriceUnit.pack: 400},
  ),
  "mince": PriceEntry(
    "mince",
    productTags: ["en:ground-meats", "en:ground-meat-preparations"],
    units: {PriceUnit.pack: 500},
  ),
  "bellPepper": PriceEntry(
    "bellPepper",
    productTags: ["en:sweet-peppers"],
    categoryPrices: true,
    units: {PriceUnit.piece: 150},
    spiceWhenSpooned: true,
  ),
  "cucumber": PriceEntry(
    "cucumber",
    productTags: ["en:cucumbers"],
    excludeTags: ["en:pickles", "en:pickled-cucumbers", "en:gherkins"],
    excludeWords: [
      "eingelegt", "eingelegte", "eingelegten", "sauer", "saure", "sauren", //
      "glas", "pickled", "gherkin", "gherkins",
    ],
    basis: PriceBasis.piece,
    categoryPrices: true,
    units: {PriceUnit.piece: 400},
  ),
  "banana": PriceEntry(
    "banana",
    productTags: ["en:bananas"],
    categoryPrices: true,
    // Unpeeled, as sold by the kilogram.
    units: {PriceUnit.piece: 170},
  ),
  "apple": PriceEntry(
    "apple",
    productTags: ["en:apples"],
    categoryPrices: true,
    units: {PriceUnit.piece: 150},
  ),
  "oats": PriceEntry(
    "oats",
    productTags: ["en:rolled-oats"],
    density: 0.4,
    units: {PriceUnit.pack: 500},
    tbspGrams: 8,
  ),
  "yogurt": PriceEntry(
    "yogurt",
    productTags: ["en:yogurts"],
    density: 1.03,
    units: {PriceUnit.pack: 500, PriceUnit.tub: 150},
    tbspGrams: 15,
  ),
  "gouda": PriceEntry(
    "gouda",
    productTags: ["en:gouda"],
    units: {PriceUnit.slice: 25, PriceUnit.pack: 400},
  ),
  "oliveOil": PriceEntry(
    "oliveOil",
    productTags: ["en:olive-oils"],
    basis: PriceBasis.volume,
    density: 0.92,
    units: {PriceUnit.pack: 750},
  ),
  "potato": PriceEntry(
    "potato",
    productTags: ["en:potatoes"],
    categoryPrices: true,
    units: {PriceUnit.piece: 150},
  ),
  "salmon": PriceEntry(
    "salmon",
    productTags: ["en:salmons"],
    units: {PriceUnit.piece: 125, PriceUnit.pack: 250},
  ),
  "bread": PriceEntry(
    "bread",
    productTags: ["en:breads"],
    categoryPrices: true,
    units: {PriceUnit.slice: 50, PriceUnit.piece: 500, PriceUnit.pack: 500},
  ),
  "hazelnutSpread": PriceEntry(
    "hazelnutSpread",
    productTags: ["en:hazelnut-spreads"],
    units: {PriceUnit.pack: 450, PriceUnit.jar: 450},
    tbspGrams: 20,
    tspGrams: 7,
  ),
  "breadRoll": PriceEntry(
    "breadRoll",
    productTags: ["en:bread-rolls"],
    basis: PriceBasis.piece,
    categoryPrices: true,
    units: {PriceUnit.piece: 60, PriceUnit.pack: 360},
  ),
  "zucchini": PriceEntry(
    "zucchini",
    productTags: ["en:zucchini"],
    categoryPrices: true,
    units: {PriceUnit.piece: 250},
  ),
};

/// Folded label key to entry id; null blocks a false friend, and as the
/// longer key it beats the shorter one it contains ("kokosmilch").
const Map<String, String?> kPriceKeys = {
  // Entries.
  "salami": "salami",
  "mozzarella": "mozzarella",
  "mozarella": "mozzarella",
  "pizzateig": "pizzaDough",
  "pizza dough": "pizzaDough",
  "passierte tomaten": "passata",
  "tomatenpassata": "passata",
  "passata": "passata",
  "strained tomatoes": "passata",
  "tomate": "tomato",
  "tomaten": "tomato",
  "tomato": "tomato",
  "tomatoes": "tomato",
  "zwiebel": "onion",
  "zwiebeln": "onion",
  "onion": "onion",
  "onions": "onion",
  "knoblauch": "garlic",
  "knoblauchzehe": "garlic",
  "knoblauchzehen": "garlic",
  "garlic": "garlic",
  "garlic clove": "garlic",
  "garlic cloves": "garlic",
  "milch": "milk",
  "vollmilch": "milk",
  "milk": "milk",
  "whole milk": "milk",
  "ei": "egg",
  "eier": "egg",
  "egg": "egg",
  "eggs": "egg",
  "butter": "butter",
  "mehl": "flour",
  "weizenmehl": "flour",
  "dinkelmehl": "flour",
  "flour": "flour",
  "wheat flour": "flour",
  "all purpose flour": "flour",
  "reis": "rice",
  "rice": "rice",
  "spaghetti": "spaghetti",
  "haehnchenbrust": "chickenBreast",
  "huehnerbrust": "chickenBreast",
  "chicken breast": "chickenBreast",
  "chicken breasts": "chickenBreast",
  "hackfleisch": "mince",
  "hack": "mince",
  "ground beef": "mince",
  "minced meat": "mince",
  "minced beef": "mince",
  "mince": "mince",
  "paprika": "bellPepper",
  "paprikaschote": "bellPepper",
  "paprikaschoten": "bellPepper",
  "bell pepper": "bellPepper",
  "bell peppers": "bellPepper",
  "sweet pepper": "bellPepper",
  "sweet peppers": "bellPepper",
  "gurke": "cucumber",
  "gurken": "cucumber",
  "salatgurke": "cucumber",
  "salatgurken": "cucumber",
  "cucumber": "cucumber",
  "cucumbers": "cucumber",
  "banane": "banana",
  "bananen": "banana",
  "banana": "banana",
  "bananas": "banana",
  "apfel": "apple",
  "aepfel": "apple",
  "apple": "apple",
  "apples": "apple",
  "haferflocken": "oats",
  "rolled oats": "oats",
  "oats": "oats",
  "oatmeal": "oats",
  "joghurt": "yogurt",
  "jogurt": "yogurt",
  "naturjoghurt": "yogurt",
  "yogurt": "yogurt",
  "yoghurt": "yogurt",
  "skyr": "yogurt",
  "gouda": "gouda",
  "olivenoel": "oliveOil",
  "olive oil": "oliveOil",
  "kartoffel": "potato",
  "kartoffeln": "potato",
  "potato": "potato",
  "potatoes": "potato",
  "lachs": "salmon",
  "salmon": "salmon",
  "brot": "bread",
  "bread": "bread",
  "nutella": "hazelnutSpread",
  "nussnougatcreme": "hazelnutSpread",
  "haselnusscreme": "hazelnutSpread",
  "hazelnut spread": "hazelnutSpread",
  "broetchen": "breadRoll",
  "semmel": "breadRoll",
  "semmeln": "breadRoll",
  "schrippe": "breadRoll",
  "schrippen": "breadRoll",
  "bread roll": "breadRoll",
  "bread rolls": "breadRoll",
  "zucchini": "zucchini",
  "zucchino": "zucchini",
  "courgette": "zucchini",
  "courgettes": "zucchini",

  // Blocked: milks and drinks.
  "kokosmilch": null,
  "hafermilch": null,
  "mandelmilch": null,
  "sojamilch": null,
  "reismilch": null,
  "buttermilch": null,
  "kondensmilch": null,
  "dosenmilch": null,
  "pflanzenmilch": null,
  "cashewmilch": null,
  "haselnussmilch": null,
  "coconut milk": null,
  "almond milk": null,
  "oat milk": null,
  "soy milk": null,
  "rice milk": null,
  "buttermilk": null,
  "condensed milk": null,
  // Blocked: tomato products.
  "tomatenmark": null,
  "dosentomaten": null,
  "gehackte tomaten": null,
  "stueckige tomaten": null,
  "geschaelte tomaten": null,
  "getrocknete tomaten": null,
  "tomato paste": null,
  "tomato sauce": null,
  "canned tomatoes": null,
  "chopped tomatoes": null,
  "diced tomatoes": null,
  "crushed tomatoes": null,
  "sun dried tomatoes": null,
  // Blocked: powders and spices.
  "knoblauchpulver": null,
  "zwiebelpulver": null,
  "paprikapulver": null,
  "rosenpaprika": null,
  "edelsuesspaprika": null,
  "paprika edelsuess": null,
  "smoked paprika": null,
  "garlic powder": null,
  "onion powder": null,
  // Blocked: butter products.
  "erdnussbutter": null,
  "kraeuterbutter": null,
  "knoblauchbutter": null,
  "butterschmalz": null,
  "kakaobutter": null,
  "mandelbutter": null,
  "nussbutter": null,
  "cashewbutter": null,
  "sheabutter": null,
  "peanut butter": null,
  "almond butter": null,
  // Blocked: apple products.
  "granatapfel": null,
  "granataepfel": null,
  "apfelsaft": null,
  "apfelmus": null,
  "apfelessig": null,
  "apple juice": null,
  "apple sauce": null,
  "apple cider vinegar": null,
  // Blocked: other flours.
  "reismehl": null,
  "paniermehl": null,
  "mandelmehl": null,
  "kokosmehl": null,
  "maismehl": null,
  "kichererbsenmehl": null,
  "johannisbrotkernmehl": null,
  "rice flour": null,
  "almond flour": null,
  "coconut flour": null,
  "potato flour": null,
  "oat flour": null,
  "corn flour": null,
  "chickpea flour": null,
  "buckwheat flour": null,
  // Blocked: pickles and other false friends.
  "essiggurke": null,
  "essiggurken": null,
  "gewuerzgurke": null,
  "gewuerzgurken": null,
  "salzgurke": null,
  "salzgurken": null,
  "senfgurke": null,
  "senfgurken": null,
  "delikatessgurke": null,
  "delikatessgurken": null,
  "cornichons": null,
  "pickles": null,
  "gherkin": null,
  "gherkins": null,
  "sojajoghurt": null,
  "kokosjoghurt": null,
  "suesskartoffel": null,
  "suesskartoffeln": null,
  "fruehlingszwiebel": null,
  "fruehlingszwiebeln": null,
  "lauchzwiebel": null,
  "lauchzwiebeln": null,
  "roestzwiebel": null,
  "roestzwiebeln": null,
  "pizzatomaten": null,
  "sojahack": null,
  "wachteleier": null,
  "sweet potato": null,
  "sweet potatoes": null,
  "spring onion": null,
  "spring onions": null,
  "green onion": null,
  "green onions": null,
};

/// German keys that also match as the end of a compound: "kirschtomaten",
/// "vollkornreis". At least four characters; English keys never do, so
/// "licorice" stays no rice.
const Set<String> kPriceCompoundHeads = {
  "salami",
  "mozzarella",
  "tomate",
  "tomaten",
  "zwiebel",
  "zwiebeln",
  "knoblauch",
  "milch",
  "eier",
  "butter",
  "mehl",
  "reis",
  "spaghetti",
  "haehnchenbrust",
  "hackfleisch",
  "hack",
  "paprika",
  "gurke",
  "gurken",
  "banane",
  "bananen",
  "apfel",
  "aepfel",
  "haferflocken",
  "joghurt",
  "gouda",
  "olivenoel",
  "kartoffel",
  "kartoffeln",
  "lachs",
  "brot",
  "broetchen",
  "semmel",
  "semmeln",
  "zucchini",
};

/// Never estimated: salt, pepper, water. German words also as the end of a
/// compound ("meersalz").
const Set<String> kPriceSkipWords = {
  "salz",
  "pfeffer",
  "wasser",
  "salt",
  "pepper",
  "water",
};
const Set<String> _skipHeads = {"salz", "pfeffer", "wasser"};

/// A line with one of these is seasoning to taste.
const List<String> _skipPhrases = [
  "nach geschmack",
  "nach belieben",
  "nach bedarf",
  "zum abschmecken",
  "to taste",
  "as needed",
];

/// Words that describe, not name, an ingredient; removed before the second
/// match pass.
const Set<String> kPriceDescriptors = {
  "frisch", "frische", "frischer", "frisches", "frischen", //
  "gerieben", "geriebene", "geriebener", "geriebenes", "geriebenen", //
  "gehackt", "gehackte", "gehackter", "gehacktes", "gehackten", //
  "gewuerfelt", "gewuerfelte", "gewuerfelter", "gewuerfeltes", //
  "gewuerfelten", "geschnitten", "geschnittene", "geschnittener", //
  "geschnittenes", "geschnittenen", "fein", "feine", "feiner", "feines", //
  "feinen", "grob", "grobe", "grober", "grobes", "groben", "klein", //
  "kleine", "kleiner", "kleines", "kleinen", "gross", "grosse", "grosser", //
  "grosses", "grossen", "mittelgross", "mittelgrosse", "mittelgrosser", //
  "mittelgrosses", "mittelgrossen", "tk", "tiefgekuehlt", "tiefgekuehlte", //
  "tiefgekuehlter", "tiefgekuehltes", "tiefgekuehlten", "bio", "reif", //
  "reife", "reifer", "reifes", "reifen", "rot", "rote", "roter", "rotes", //
  "roten", "gelb", "gelbe", "gelber", "gelbes", "gelben", "gruen", "gruene", //
  "gruener", "gruenes", "gruenen", "weiss", "weisse", "weisser", "weisses", //
  "weissen", "schwarz", "schwarze", "schwarzer", "schwarzes", "schwarzen", //
  "optional", "zum", "bestreuen", "ca", "etwa", "etwas", "roh", "rohe", //
  "roher", "rohes", "rohen", "gekocht", "gekochte", "gekochter", //
  "gekochtes", "gekochten", "festkochend", "festkochende", "mehligkochend", //
  "mehligkochende", "mager", "magere", "magerer", "mageres", "mageren", //
  "natur", //
  "fresh", "chopped", "grated", "diced", "sliced", "minced", "finely", //
  "large", "small", "medium", "ripe", "red", "green", "yellow", "white", //
  "frozen", "organic", "raw", "cooked", "about", "approx", "some", //
  "boneless", "skinless",
};

/// Nouns that turn a key before them into a modifier of another food:
/// "rice vinegar", "milk chocolate", "garlic bread". Such a key prices
/// nothing; a later key ("bread") still can.
const Set<String> kPriceModifierHeads = {
  "vinegar", "noodle", "noodles", "chocolate", "bean", "beans", "chips", //
  "crisps", "fries", "wedges", "bread", "breadcrumbs", "crumbs", "paste", //
  "sauce", "powder", "flakes", "cake", "cakes", "crackers", "starch", //
  "syrup", "juice", "soup", "stock", "broth", "pudding", "pie", "rings", //
  "seasoning", "salad", "dumplings", "rolls", "spread", "drink", "wine", //
  "flour", "cream", "tortilla", "tortillas", "wraps", "bar", "bars", //
  "puree", "essig", "nudeln", "sosse", "pulver", "flocken", "saft", //
  "suppe", "bruehe", "creme", "schokolade", "mark", "sirup", "aufstrich", //
  "salat",
};

const Set<String> _stopWords = {
  "und", "mit", "von", "vom", "der", "die", "das", "den", "dem", "des", //
  "ein", "eine", "einer", "eines", "einem", "einen", "im", "in", "aus", //
  "fuer", "zur", "am", "an", "auf", "je", "pro", //
  "and", "with", "of", "the", "a", "for", "or", "per",
};

/// Endings of a cut or a portion ("lachsfilet", "knoblauchzehe"); the stem
/// before them is matched again.
const List<String> kPriceFormEndings = [
  "filets",
  "filet",
  "steaks",
  "steak",
  "wuerfel",
  "streifen",
  "scheiben",
  "scheibe",
  "stuecke",
  "stueck",
  "zehen",
  "zehe",
  "schoten",
  "schote",
  "knollen",
  "knolle",
  "fillets",
  "fillet",
];

/// The outcome of reading one label.
class PriceMatch {
  const PriceMatch({
    this.entry,
    this.skipped = false,
    this.blocked = false,
    this.impliedUnit,
  });

  /// No entry: unknown, or [blocked].
  final PriceEntry? entry;

  /// Seasoning, never estimated.
  final bool skipped;

  /// A false friend matched ("Kokosmilch").
  final bool blocked;

  /// The unit a plain count means ("2 Knoblauchzehen" are cloves).
  final PriceUnit? impliedUnit;
}

const PriceMatch _noMatch = PriceMatch();

/// Lower case, umlauts and ß folded, parentheses dropped and cut at the first
/// alternative, list separator or trailing phrase: "Mozzarella, gerieben"
/// -> "mozzarella", "Hähnchenbrust mit Paprika" -> "haehnchenbrust".
String normalizePriceLabel(String label) {
  final text = _foldedWithoutParentheses(label);
  final cut = _separator.firstMatch(text);
  return (cut == null ? text : text.substring(0, cut.start)).trim();
}

final RegExp _separator = RegExp(
  r',|;|/| oder | or | bzw\.? | z\. ?b\.? | e\.g\. '
  r'| mit | ohne | with | without | in | im ',
);
final RegExp _nonLetters = RegExp(r'[^a-zà-ÿ]+');

String _foldedWithoutParentheses(String label) => _folded(
  label,
).replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s+'), ' ');

String _folded(String label) {
  // Decomposed umlauts first: Dart has no NFC normalisation.
  final composed = label
      .toLowerCase()
      .replaceAll("ä", "ä")
      .replaceAll("ö", "ö")
      .replaceAll("ü", "ü");
  return foldRecipeSearchText(composed);
}

/// Reads [label] against the dictionary. [quantity] decides spice and pinch
/// lines ("1 TL Paprika", "1 Prise Salz").
PriceMatch matchPriceEntry(String label, {PriceQuantity? quantity}) {
  if (quantity is PinchQuantity) return const PriceMatch(skipped: true);
  final whole = _foldedWithoutParentheses(label);
  if (_skipPhrases.any(whole.contains)) return const PriceMatch(skipped: true);
  final tokens = normalizePriceLabel(label)
      .split(_nonLetters)
      .where((t) => t.isNotEmpty && !_stopWords.contains(t))
      .toList();
  if (tokens.isEmpty) return _noMatch;

  _Candidate? best;
  var modified = false;
  void consider(_Candidate candidate) {
    // "rice vinegar": the key only describes the food after it.
    if (candidate.modified) {
      modified = true;
      return;
    }
    if (best == null ||
        candidate.length > best!.length ||
        (candidate.length == best!.length && candidate.end > best!.end)) {
      best = candidate;
    }
  }

  // Raw pass first, so "gehackte tomaten" is found before "gehackte" goes.
  _exactNgrams(tokens, consider);
  final cleaned = tokens.where((t) => !kPriceDescriptors.contains(t)).toList();
  _exactNgrams(cleaned, consider);
  for (var i = 0; i < cleaned.length; i++) {
    _compound(cleaned, i, consider);
  }

  final winner = best;
  if (winner == null) {
    if (modified) return const PriceMatch(blocked: true);
    final skipped = cleaned.any(
      (t) =>
          kPriceSkipWords.contains(t) ||
          _skipHeads.any((head) => t.length > head.length && t.endsWith(head)),
    );
    return skipped ? const PriceMatch(skipped: true) : _noMatch;
  }
  final id = kPriceKeys[winner.key];
  if (id == null) return const PriceMatch(blocked: true);
  final entry = kPriceEntries[id]!;
  if (priceLabelExcluded(entry, label)) return const PriceMatch(blocked: true);
  if (entry.spiceWhenSpooned &&
      (quantity is SpoonQuantity || quantity is PinchQuantity)) {
    return const PriceMatch(skipped: true);
  }
  return PriceMatch(entry: entry, impliedUnit: winner.impliedUnit);
}

/// Whether [label] names a product [entry] does not price: one of its
/// excluded words anywhere in the label, as a word of its own or as the end
/// of a compound ("Knoblauchgranulat", "sonnengetrocknet").
bool priceLabelExcluded(PriceEntry entry, String label) {
  if (entry.excludeWords.isEmpty) return false;
  for (final token in _folded(label).split(_nonLetters)) {
    for (final word in entry.excludeWords) {
      if (token == word || (word.length >= 4 && token.endsWith(word))) {
        return true;
      }
    }
  }
  return false;
}

class _Candidate {
  _Candidate(this.key, this.end, List<String> tokens, {this.impliedUnit})
    : modified = tokens.skip(end + 1).any(kPriceModifierHeads.contains);

  /// The matched key; the longest one wins.
  final String key;

  /// Index of the last token; ties go to the rightmost (the head noun).
  final int end;
  final PriceUnit? impliedUnit;

  /// A modifier head follows the key ("rice vinegar").
  final bool modified;

  int get length => key.length;
}

void _exactNgrams(List<String> tokens, void Function(_Candidate) consider) {
  for (var size = 3; size >= 1; size--) {
    for (var start = 0; start + size <= tokens.length; start++) {
      final words = tokens.sublist(start, start + size);
      for (final key in {words.join(' '), words.join()}) {
        if (kPriceKeys.containsKey(key)) {
          consider(
            _Candidate(
              key,
              start + size - 1,
              tokens,
              impliedUnit: _unitOf(key),
            ),
          );
        }
      }
    }
  }
}

/// A compound ending in a head ("kirschtomaten"), or a cut of a known
/// ingredient ("haehnchenbrustfilet", "knoblauchzehe").
void _compound(
  List<String> tokens,
  int index,
  void Function(_Candidate) consider,
) {
  final token = tokens[index];
  void suffix(String word, PriceUnit? unit) {
    for (final head in kPriceCompoundHeads) {
      if (head.length >= 4 &&
          word.length > head.length &&
          word.endsWith(head)) {
        consider(_Candidate(head, index, tokens, impliedUnit: unit));
      }
    }
  }

  suffix(token, null);
  for (final ending in kPriceFormEndings) {
    if (!token.endsWith(ending)) continue;
    final stem = token.substring(0, token.length - ending.length);
    if (stem.length < 3) continue;
    final unit = _unitOf(ending);
    if (kPriceKeys.containsKey(stem)) {
      consider(_Candidate(stem, index, tokens, impliedUnit: unit));
    }
    suffix(stem, unit);
  }
}

PriceUnit? _unitOf(String text) {
  if (text.endsWith("zehe") ||
      text.endsWith("zehen") ||
      text.endsWith("clove") ||
      text.endsWith("cloves")) {
    return PriceUnit.clove;
  }
  if (text.endsWith("scheibe") ||
      text.endsWith("scheiben") ||
      text.endsWith("slice") ||
      text.endsWith("slices")) {
    return PriceUnit.slice;
  }
  return null;
}

/// The entry for an Open Food Facts product's categories, walking from the
/// most specific tag (the end of the list); only tags of the dictionary
/// count, never a broad one such as `en:dairies`. The product must pass the
/// entry's required and excluded tags like a price row, or it has none: a
/// pickle tagged `en:cucumbers` is no cucumber, and no broader tag is tried.
PriceEntry? priceEntryForCategories(List<String> categoriesTags) {
  for (final tag in categoriesTags.reversed) {
    final id = _entryByTag[tag];
    if (id == null) continue;
    final entry = kPriceEntries[id]!;
    return entry.matchesProduct(categoriesTags) ? entry : null;
  }
  return null;
}

final Map<String, String> _entryByTag = {
  for (final entry in kPriceEntries.values)
    for (final tag in entry.productTags) tag: entry.id,
};
