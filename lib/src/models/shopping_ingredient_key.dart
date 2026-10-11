// Which ingredient a shopping line names: the identity rows merge by, and
// whether the pantry usually has it.
//
// When in doubt this does not merge: a missed merge costs one extra line, a
// wrong merge makes the user buy the wrong thing. Compounds stay whole
// ("Kokosmilch" is not "Milch"), and words that make another product stay in
// the key (colours, frozen, cooked, dried, canned, whole grain, ...).
//
// Double-quoted literals are matching data, not UI text (see
// `foldRecipeSearchText`).

import 'shopping_amount.dart';

/// What a receipt row is to the pantry.
enum ShoppingStaple {
  /// Bought for the week.
  none,

  /// At home as a rule: salt, pepper, dry spices and herbs, stock, baking
  /// agents, starch.
  always,

  /// At home in small amounts: spoons, pinches or up to 50 g or ml.
  small,

  /// Oils and vinegars: at home up to 100 g or ml.
  oil,

  /// Plain water: never listed.
  water,
}

/// The identity of one ingredient line.
class ShoppingIngredientKey {
  const ShoppingIngredientKey({
    required this.id,
    required this.staple,
    this.languages = const {},
    this.known = false,
    this.ambiguous = false,
  });

  /// Rows merge by this id. Locale-neutral; never shown.
  final String id;

  final ShoppingStaple staple;

  /// The app languages ('de', 'en') of the synonym that matched, if any.
  final Set<String> languages;

  /// Named by the synonym table or a staple rule (salt, a spice, an oil...).
  final bool known;

  /// Read from a word that names two things (German "Paprika", "Chili").
  final bool ambiguous;

  bool get isWater => staple == ShoppingStaple.water;

  @override
  String toString() => 'ShoppingIngredientKey($id, ${staple.name})';
}

/// The key of an ingredient [label] (without its amount). [unit] decides the
/// ambiguous ones (German "Paprika": spooned it is the spice, counted the
/// vegetable). [seasoning] marks a component of a list of seasonings ("Salz,
/// Pfeffer, Paprika"), where an ambiguous word without amount is the spice.
ShoppingIngredientKey shoppingIngredientKey(
  String label, {
  ShoppingUnit? unit,
  bool seasoning = false,
}) {
  // A pure function of its arguments, asked several times per line and
  // again on every rebuild: remembered, within a bound.
  final remembered = (label, unit, seasoning);
  if (_keys[remembered] case final key?) return key;
  if (_keys.length >= 4096) _keys.clear();
  return _keys[remembered] = _key(label, unit, seasoning);
}

final _keys = <(String, ShoppingUnit?, bool), ShoppingIngredientKey>{};

ShoppingIngredientKey _key(String label, ShoppingUnit? unit, bool seasoning) {
  final analysis = _analyze(label);
  if (analysis.complex) {
    return ShoppingIngredientKey(
      id: '~${analysis.whole}',
      staple: ShoppingStaple.none,
    );
  }
  final products = {
    ...analysis.products,
    // "1 Dose Tomaten" are not fresh tomatoes; "400 g gehackte Tomaten" come
    // in a can, two counted ones are diced at home.
    if (unit == ShoppingUnit.can ||
        unit == ShoppingUnit.jar ||
        (analysis.cannedForm &&
            (unit == null ||
                unit == ShoppingUnit.mass ||
                unit == ShoppingUnit.volume)))
      "canned",
  };
  // The most product words a synonym names ("lean ground beef" is lean
  // "ground beef"); the rest stay in the key.
  _Entry? entry;
  for (final subset in _subsets(products)) {
    entry = _lookup(_join(subset, analysis.noun));
    if (entry != null) {
      products.removeAll(subset);
      break;
    }
  }
  if (entry == null) {
    final staple = _patternStaple(analysis.raw, analysis.noun);
    return ShoppingIngredientKey(
      id: _join(products, analysis.noun),
      staple: staple,
      known: staple != ShoppingStaple.none,
    );
  }
  var id = entry.id;
  var staple = entry.staple;
  final spooned =
      unit == ShoppingUnit.tbsp ||
      unit == ShoppingUnit.tsp ||
      unit == ShoppingUnit.pinch;
  final dry = products.contains("ground") || products.contains("dried");
  final fresh = analysis.fresh || analysis.chopped;
  // Without an amount or a list of seasonings around it, a bare "Paprika"
  // names either; it stays apart from both rather than guess.
  final undecided =
      unit == null &&
      !seasoning &&
      !fresh &&
      !dry &&
      !products.any(const {"red", "yellow", "green", "smoked"}.contains);
  switch (entry.kind) {
    case _Kind.paprika:
      final spice =
          !fresh &&
          (dry ||
              products.contains("smoked") ||
              spooned ||
              (unit == null && (seasoning || analysis.garnish)));
      (id, staple) = spice
          ? ("paprika_powder", ShoppingStaple.always)
          : (undecided ? "paprika?" : "bell_pepper", ShoppingStaple.none);
    case _Kind.pepper:
      final vegetable =
          !dry &&
          !products.contains("black") &&
          !products.contains("white") &&
          unit != null &&
          !spooned;
      if (vegetable) {
        // British "peppers" are bell peppers.
        (id, staple) = ("bell_pepper", ShoppingStaple.none);
      } else {
        products.removeAll(const {"black", "ground"});
        (id, staple) = ("pepper", ShoppingStaple.always);
      }
    case _Kind.chili:
      final spice =
          !fresh &&
          (dry ||
              spooned ||
              (unit == null && (seasoning || analysis.sprinkled)));
      (id, staple) = spice
          ? ("chili_spice", ShoppingStaple.always)
          : (undecided ? "chili?" : "chili", ShoppingStaple.none);
    case _Kind.ginger || _Kind.coriander:
      final ginger = entry.kind == _Kind.ginger;
      // Grated or pressed ginger is the fresh root, also by the spoon.
      final spice =
          !fresh && (dry || (spooned && !(ginger && analysis.grated)));
      (id, staple) = spice
          ? (
              ginger ? "ginger_ground" : "coriander_ground",
              ShoppingStaple.always,
            )
          : (ginger ? "ginger" : "coriander_leaf|fresh", ShoppingStaple.none);
      products.removeAll(const {"ground", "dried"});
    case _Kind.driedHerb || _Kind.freshHerb:
      final markedFresh =
          fresh ||
          unit == ShoppingUnit.sprig ||
          unit == ShoppingUnit.bunch ||
          unit == ShoppingUnit.handful ||
          products.contains("frozen");
      final dried =
          products.contains("dried") ||
          (entry.kind == _Kind.driedHerb && !markedFresh);
      products.remove("dried");
      id = '${entry.id}|${dried ? 'dried' : 'fresh'}';
      staple = dried ? ShoppingStaple.always : ShoppingStaple.none;
    case _Kind.plain:
      // Corn, chickpeas or coconut milk come in a can whether or not the
      // line says so: "80 g Mais" and "1 Dose Mais" are one row.
      if (_cannedAnyway.contains(id)) products.remove("canned");
  }
  // "gemahlener Kreuzkümmel" is Kreuzkümmel.
  if (staple == ShoppingStaple.always) products.remove("ground");
  if (staple == ShoppingStaple.water && products.isNotEmpty) {
    staple = ShoppingStaple.none;
  }
  return ShoppingIngredientKey(
    id: _join(products, id),
    staple: staple,
    languages: entry.languages,
    known: true,
    ambiguous: const {
      _Kind.paprika,
      _Kind.chili,
      _Kind.ginger,
      _Kind.coriander,
    }.contains(entry.kind),
  );
}

const _cannedAnyway = {
  "corn", "chickpeas", "kidney_beans", "beans", "coconut_milk", "passata", //
  "lentils",
};

/// Subsets of [products], largest first; the empty set last. Only the first
/// eight words take part: a label with many more would cost seconds, and a
/// synonym is never that long.
List<Set<String>> _subsets(Set<String> products) {
  final list = (products.toList()..sort()).take(8).toList();
  final subsets = [
    for (var mask = (1 << list.length) - 1; mask >= 0; mask--)
      {
        for (var i = 0; i < list.length; i++)
          if (mask & (1 << i) != 0) list[i],
      },
  ]..sort((a, b) => b.length.compareTo(a.length));
  return subsets;
}

/// Lower case with umlauts and ß folded like `foldRecipeSearchText`; also
/// folds decomposed umlauts and strips other accents.
String foldShoppingText(String text) {
  var folded = text
      .replaceAllMapped(
        RegExp('([aouAOU])\u0308'),
        (m) => '${m[1]!.toLowerCase()}e',
      )
      .toLowerCase()
      .replaceAll("ä", "ae")
      .replaceAll("ö", "oe")
      .replaceAll("ü", "ue")
      .replaceAll("ß", "ss")
      .replaceAll(RegExp('[\u0300-\u036f]'), '');
  for (final MapEntry(:key, :value) in _accents.entries) {
    if (folded.contains(key)) folded = folded.replaceAll(key, value);
  }
  return folded;
}

const _accents = {
  "à": "a", "á": "a", "â": "a", "ã": "a", "å": "a", "æ": "ae", "ç": "c", //
  "è": "e", "é": "e", "ê": "e", "ë": "e", "ì": "i", "í": "i", "î": "i", //
  "ï": "i", "ñ": "n", "ò": "o", "ó": "o", "ô": "o", "õ": "o", "ø": "o", //
  "œ": "oe", "ù": "u", "ú": "u", "û": "u", "ý": "y", "ÿ": "y",
};

String _join(Set<String> products, String id) =>
    products.isEmpty ? id : '${(products.toList()..sort()).join('+')}+$id';

// ---------------------------------------------------------------------------
// Analysis: products, noun and markers of a label.

class _Analysis {
  _Analysis({
    required this.products,
    required this.noun,
    required this.raw,
    required this.whole,
    this.fresh = false,
    this.chopped = false,
    this.grated = false,
    this.cannedForm = false,
    this.garnish = false,
    this.sprinkled = false,
    this.complex = false,
  });

  /// Words that make another product ("red", "frozen", "canned"), normalised.
  final Set<String> products;

  /// The noun, singular, letters only ("haehnchenbrustfilet", "tomat").
  final String noun;

  /// The noun before singularisation, for staple patterns.
  final String raw;

  /// The whole label, folded, for keys that only merge identical text.
  final String whole;
  final bool fresh, chopped;

  /// Grated, pressed or crushed: fresh ginger root.
  final bool grated;

  /// Chopped, diced or peeled tomatoes: canned when weighed or measured.
  final bool cannedForm;

  /// For garnish or to serve ("Paprika, for garnish"); [sprinkled] only for
  /// sprinkling or dusting ("Chili zum Bestreuen").
  final bool garnish, sprinkled;

  /// The label lists more than one thing ("Sesam, Frühlingszwiebel").
  final bool complex;

  String get full => _join(products, noun);
}

/// The descriptive words of [label] are all it has ("optional", "fein
/// gehackt", "frisch gemahlen", "ca. 50 g"): it describes the line before.
bool isShoppingModifier(String label) {
  final analysis = _analyze(label, modifierCheck: true);
  return analysis.noun.isEmpty;
}

_Analysis _analyze(String label, {bool modifierCheck = false}) {
  // Fat levels and flour types make another product, also in brackets
  // ("Joghurt (3,5 %)", "Mehl Type 405", "00 flour").
  final folded = foldShoppingText(label)
      .replaceAllMapped(
        RegExp(r'(\d+(?:[.,]\d+)?)\s*%'),
        (m) => ' pct${m[1]!.replaceAll(',', 'x').replaceAll('.', 'x')} ',
      )
      .replaceAllMapped(
        RegExp(r'\b(?:type|typ|tipo)\s*(\d+)\b'),
        (m) => ' type${m[1]} ',
      )
      .replaceAll(
        RegExp(r'(?<![\d.,])\b00\s+(?=(?:mehl|flour|farina)\b)'),
        ' type00 ',
      );
  // Brackets are notes ("ca. 200 g"), except for a product word ("(TK)").
  final bracketed = [
    for (final note in RegExp(r'\(([^)]*)\)|\[([^\]]*)\]').allMatches(folded))
      for (final word in _words(note[1] ?? note[2]!))
        if (_product(word) case final product?) product,
  ];
  var text = folded
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'whole[\s-]*(?:grain|wheat|meal)'), ' wholegrain ')
      .replaceAll(RegExp(r'(?:low|reduced)[\s-]*fat'), ' lowfat ')
      // An example is an alternative: "Nudeln, z. B. Spaghetti" is pasta.
      .replaceAll(
        RegExp(
          r'(?<=\S)\s+(?:(?:z\.?\s?b|e\.?\s?g|bspw)\.?|beispielsweise'
          r'|such as)(?=\s|$)',
        ),
        ' oder ',
      )
      .replaceAll(
        RegExp(r'(?:^|\s)(?:z\.?\s?b|e\.?\s?g|n\.?\s?b)\.?(?=\s|$)'),
        ' ',
      );
  for (final phrase in _ignoredPhrases) {
    text = text.replaceAll(phrase, ' ');
  }
  // "Thunfisch in Öl", "tuna in olive oil": a product of its own, not oil.
  text = text.replaceAll(
    RegExp(
      r'(?:^|\s)in\s+(?:extra\s+virgin\s+)?(?:[a-z]*oel|(?:[a-z]+\s+)?oil)\b',
    ),
    ' inoil ',
  );
  final garnish = _garnish.hasMatch(text);
  final sprinkled = _sprinkled.hasMatch(text);
  final whole = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  var head = text;
  var tail = '';
  final cut = _separator.firstMatch(text);
  if (cut != null && !text.substring(0, cut.start).trimRight().endsWith('-')) {
    head = text.substring(0, cut.start);
    // A list separator or "mit"/"with" leaves a tail to check ("Frischkäse
    // mit Kräutern" is not plain cream cheese); "oder"/"für"/"to" drop the
    // rest.
    if (RegExp(r'^(?:[,;:]|\s(?:mit|with)\s)$').hasMatch(cut[0]!)) {
      tail = text.substring(cut.end);
    }
  }
  final products = <String>{...bracketed};
  var fresh = false, chopped = false, grated = false, complex = false;

  void mark(String word) {
    if (_freshWords.contains(word)) fresh = true;
    if (_choppedWords.contains(word)) chopped = true;
    if (_gratedWords.contains(word)) grated = true;
  }

  // The tail may describe the head ("roh", "in Scheiben", "frisch oder TK",
  // "2%") or name something else ("Frühlingszwiebel"). Only a describing
  // tail lets the head decide.
  for (final segment in tail.split(RegExp(r'(?<!\d),|,(?!\d)|[;:]'))) {
    final described = _cutAlternative(segment);
    for (final word in _words(described)) {
      if (RegExp(r'^\d').hasMatch(word) || _units.contains(word)) continue;
      mark(word);
      final product = _product(word);
      if (product != null) {
        products.add(product);
      } else if (!_isDescriptor(word) && !_stopWords.contains(word)) {
        complex = true;
      }
    }
  }

  final nouns = <String>[];
  final modifiers = <String>[];
  var minced = false;
  for (final word in _words(head)) {
    if (word == "minced") minced = true;
    if (RegExp(r'^\d').hasMatch(word)) continue;
    mark(word);
    if (_stopWords.contains(word) || _units.contains(word)) continue;
    final product = _product(word);
    if (product != null) {
      products.add(product);
      modifiers.add(word);
    } else if (_isDescriptor(word)) {
      modifiers.add(word);
    } else {
      final prefix = _prefixes.entries
          .where(
            (p) => word.startsWith(p.key) && word.length - p.key.length >= 3,
          )
          .firstOrNull;
      if (prefix != null) {
        if (prefix.value.isNotEmpty) products.add(prefix.value);
        nouns.add(word.substring(prefix.key.length));
      } else {
        nouns.add(word);
      }
    }
  }
  // Chopped or crushed tomatoes by weight come in a can ("Tomaten, stückig"
  // too); the caller decides by the unit.
  final cannedForm =
      RegExp(r'^tomat(?:o|oes|e|en)?$').hasMatch(nouns.join()) &&
      _words('$head $tail').any(_cannedTomato.contains);
  // "minced beef" is ground beef; "minced garlic" is garlic.
  if (minced &&
      RegExp(
        r'(?:beef|pork|lamb|turkey|chicken|meat|veal)s?$',
      ).hasMatch(nouns.join())) {
    products.add("ground");
  }
  if (modifierCheck) {
    return _Analysis(
      products: products,
      noun: complex ? 'x' : nouns.join(),
      raw: '',
      whole: whole,
    );
  }
  if (nouns.isEmpty && modifiers.isNotEmpty) {
    // "mixed greens", "egg whites" are nouns after all.
    final last = modifiers.last;
    products.remove(_product(last));
    nouns.add(last);
  }
  if (nouns.isEmpty) {
    return _Analysis(
      products: const {},
      noun: '',
      raw: '',
      whole: whole,
      complex: true,
    );
  }
  final raw = nouns.join();
  final stems = [
    for (var i = 0; i < nouns.length; i++)
      i == nouns.length - 1 ? _singular(nouns[i]) : _deinflect(nouns[i]),
  ];
  return _Analysis(
    products: products,
    noun: stems.join(),
    raw: raw,
    whole: whole,
    fresh: fresh,
    chopped: chopped,
    grated: grated,
    cannedForm: cannedForm,
    garnish: garnish,
    sprinkled: sprinkled,
    complex: complex,
  );
}

final _garnish = RegExp(
  r'(?:^|\s)(?:for|to)\s+(?:garnish|sprinkl|dust|serv|top)\w*'
  r'|(?:^|\s)zum\s+(?:garnieren|bestreuen|bestaeuben|servieren|dekorieren)\b',
);

final _sprinkled = RegExp(
  r'(?:^|\s)(?:for|to)\s+(?:sprinkl|dust)\w*'
  r'|(?:^|\s)zum\s+(?:bestreuen|bestaeuben)\b',
);

/// The first list separator, or an alternative/purpose word after which the
/// rest is no longer the ingredient ("oder", "für", "to taste").
final _separator = RegExp(
  r'(?<!\d),|,(?!\d)|[;:]|(?<!\d)/(?!\d)'
  r'|\s(?:oder|or|zum|zur|fuer|for|to|nach|mit|with)\s',
);

String _cutAlternative(String segment) {
  final match = RegExp(
    r'(?<!\d)/(?!\d)|(?:^|\s)(?:oder|or|zum|zur|fuer|for|to|nach)(?:\s|$)',
  ).firstMatch(segment);
  return match == null ? segment : segment.substring(0, match.start);
}

/// Words of [text]: hyphenated words joined ("Hähnchen-Brustfilet"), unless
/// the first part is a product or descriptive word ("TK-Spinat",
/// "Bio-Zitrone"); letters only, except percentage tokens.
Iterable<String> _words(String text) sync* {
  for (final token in text.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    final parts = token.split('-').map(_letters).where((p) => p.isNotEmpty);
    if (parts.isEmpty) continue;
    final first = parts.first;
    if (parts.length > 1 && (_product(first) != null || _isDescriptor(first))) {
      yield first;
      yield parts.skip(1).join();
    } else {
      yield parts.join();
    }
  }
}

String _letters(String word) => word.replaceAll(RegExp(r'[^a-z0-9]'), '');

/// German adjective endings ("frischer", "rote", "gekochten").
Iterable<String> _forms(String word) sync* {
  yield word;
  for (final ending in const ["em", "en", "er", "es", "e", "s"]) {
    if (word.length > ending.length + 2 && word.endsWith(ending)) {
      yield word.substring(0, word.length - ending.length);
    }
  }
}

String? _product(String word) {
  if (RegExp(r'^(?:pct|type)\d').hasMatch(word)) return word;
  for (final form in _forms(word)) {
    final product = _products[form];
    if (product != null) return product;
  }
  return null;
}

bool _isDescriptor(String word) => _forms(word).any(_descriptors.contains);

String _deinflect(String word) {
  if (word.length < 6) return word;
  for (final ending in const ["em", "en", "er", "es", "e"]) {
    if (word.endsWith(ending)) {
      return word.substring(0, word.length - ending.length);
    }
  }
  return word;
}

/// One singular for both forms ("tomaten", "tomate" -> "tomat"; "eggs" ->
/// "egg"). Not a dictionary form; only ever compared with itself.
String _singular(String word) {
  var w = word;
  for (final MapEntry(:key, :value) in _irregular.entries) {
    if (w.endsWith(key)) {
      w = w.substring(0, w.length - key.length) + value;
      break;
    }
  }
  if (w.length >= 5 && w.endsWith("ies")) {
    w = '${w.substring(0, w.length - 3)}y';
  }
  if (w.length >= 4 &&
      w.endsWith("s") &&
      !w.endsWith("ss") &&
      !w.endsWith("us") &&
      !w.endsWith("is")) {
    w = w.substring(0, w.length - 1);
  }
  if (w.length >= 5 &&
      (w.endsWith("en") || w.endsWith("ln") || w.endsWith("rn"))) {
    w = w.substring(0, w.length - 1);
  }
  if (w.length >= 4 && w.endsWith("e")) w = w.substring(0, w.length - 1);
  return w;
}

const _irregular = {
  "eier": "ei",
  "aepfel": "apfel",
  "nuesse": "nuss",
  "kraeuter": "kraut",
  "blaetter": "blatt",
  "leaves": "leaf",
  "halves": "half",
  "loaves": "loaf",
  "tomatoes": "tomato",
  "potatoes": "potato",
  "mangoes": "mango",
};

/// Compound prefixes that are a product word or noise ("Vollkornreis",
/// "TK-Erbsen" written together, "Bioeier").
const _prefixes = {
  "vollkorn": "wholegrain",
  "wholegrain": "wholegrain",
  "tiefkuehl": "frozen",
  "tk": "frozen",
  "bio": "",
};

const _cannedTomato = {
  "gehackt", "gehackte", "gehackten", "stueckig", "stueckige", //
  "stueckigen", "chopped", "diced", "crushed", "geschaelte", "peeled",
};

const _ignoredPhrases = [
  "im eigenen saft",
  "in eigenem saft",
  "in its own juice",
  "in own juice",
  "in wasser",
  "in water",
  "in brine",
  "naturell",
  "trocken getupft",
  "trocken tupfen",
  "trockengetupft",
  "patted dry",
  "pat dry",
  "aus der muehle",
  "from the mill",
  "nach belieben",
  "nach geschmack",
  "to taste",
  "as needed",
  "bei bedarf",
];

const _freshWords = {
  "frisch", "frische", "frischer", "frischen", "frisches", "fresh", //
  "freshly", "bund", "bunch", "bunches", "zweig", "zweige", "sprig", //
  "sprigs", "stiel", "stiele",
};

const _choppedWords = {
  "gehackt", "gehackte", "gehackter", "gehackten", "gehacktes", //
  "chopped", "minced",
};

/// Ginger only: grated, pressed or crushed root, never the powder.
const _gratedWords = {
  "gerieben", "geriebene", "geriebener", "geriebenen", "geriebenes", //
  "grated", "gepresst", "gepresste", "gepresster", "gepressten", //
  "pressed", "zerdrueckt", "zerdrueckte", "zerdrueckter", "zerdrueckten", //
  "crushed",
};

const _units = {
  "g", "gr", "gramm", "kg", "mg", "ml", "cl", "dl", "l", "ltr", "liter", //
  "litre", "el", "tl", "essloeffel", "teeloeffel", "tbsp", "tbs", "tsp", //
  "tablespoon", "tablespoons", "teaspoon", "teaspoons", "cup", "cups", //
  "tasse", "tassen", "stueck", "stk", "piece", "pieces", "pcs", "prise", //
  "prisen", "msp", "messerspitze", "pinch", "pinches", "packung", //
  "packungen", "pck", "pkg", "paeckchen", "pack", "packs", "package", //
  "packet", "becher", "tub", "tuete", "beutel", "bag", "netz", "schale", //
  "stange", "stangen", "stick", "sticks", "stalk", "stalks", "knolle", //
  "knollen", "bulb", "kopf", "koepfe", "head", "heads", "topf", "pot", //
  "spritzer", "splash", "dash", "schuss", "tropfen", "drop", "drops", //
  "drizzle", "drizzles", //
  "handvoll", "handful", "handfuls", "scheibe", "slice", "cm", "mm", //
  "bund", "bunch", "bunches", "zweig", "zweige", "sprig", "sprigs", //
  "blatt", "blaetter", "stiel", "stiele", "stem", "stems", "groesse", //
  "size", "s", "m", "xl",
};

const _stopWords = {
  "und", "and", "oder", "or", "der", "die", "das", "den", "dem", "des", //
  "ein", "eine", "einen", "einem", "einer", "eines", "a", "an", "the", //
  "of", "von", "vom", "aus", "in", "im", "ins", "mit", "with", "for", //
  "fuer", "zum", "zur", "to", "nach", "je", "pro", "per", "plus", //
  "etwas", "some", "einige", "wenig", "wenige", "paar", "few", "little", //
  "bit", "bisschen", "etwa", "ca", "circa", "approx", "about", //
  "optional", "opt", "evtl", "eventuell", "ggf", "belieben", "geschmack", //
  "taste", "sehr", "very", "moeglichst", "possible", "as", "if", //
  "needed", "bei", "bedarf", "more", "mehr", "zusaetzlich", "extra", //
  "additional", "weitere", "also", "auch", "garnish", "garnieren", //
  "deko", "dekoration", "decoration", "serving", "servieren", "choice", //
  "wahl", "beliebig", "favorite", "favourite", "your", "nb", "ohne", "on", //
  "off",
};

/// Preparation and quality words that never make another product. German
/// forms are matched with their adjective endings.
const _descriptors = {
  "frisch", "fresh", "freshly", "gehackt", "chopped", "gewuerfelt", //
  "diced", "geschnitten", "sliced", "cut", "gerieben", "grated", "fein", //
  "finely", "fine", "grob", "roughly", "coarsely", "coarse", "klein", //
  "small", "gross", "large", "big", "mittelgross", "medium", "mittel", //
  "reif", "ripe", "bio", "organic", "roh", "raw", "ganz", "whole", //
  "geschaelt", "peeled", "shelled", "abgetropft", "drained", "rinsed", //
  "abgespuelt", "gewaschen", "washed", "entkernt", "pitted", "seeded", //
  "deseeded", "halbiert", "halved", "geviertelt", "quartered", //
  "zerdrueckt", "crushed", "gepresst", "pressed", "minced", "zerkleinert", //
  "nativ", "virgin", "zart", "natur", "plain", "natural", "kalt", "cold", //
  "warm", "heiss", "lauwarm", "lukewarm", "kochend", "boiling", "eiskalt", //
  "zimmerwarm", "weich", "softened", "melted", "geschmolzen", "fest", //
  "firm", "edelsuess", "entgraetet", "boneless", "skinless", "hautlos", //
  "enthaeutet", "entdarmt", "deveined", "geputzt", "trimmed", "cleaned", //
  "gestrichen", "level", "gehaeuft", "heaped", "heaping", "streifen", //
  "strips", "spalten", "wedges", "wedge", "wuerfel", "wuerfeln", "cubes", //
  "cubed", "scheiben", "ringe", "ringen", "rings", "baendern", "ribbons", //
  "roeschen", "florets", "stuecke", "stuecken", "chunks", "thin", //
  "thinly", "duenn", "geraspelt", "shredded", "aufgetaut", "thawed", //
  "angetaut", "gekuehlt", "chilled", "into", "stueckig", "gekoernt", //
  "jodiert", "bunt", "glatt", "kraus", "zerbroeselt", "crumbled", //
  "entsteint", "getupft", "vergine", "juiced", "zested", "pounded", //
  "bitesized", "mundgerecht", "vorwiegend", "beaten", "verquirlt", //
  "ausgepresst", "abgerieben", "gehobelt", "shaved", "gezupft", "torn", //
  "cored", "haut", "knochen", "graeten", "skin", "skinned", "removed", //
  "bone", "bones", "fett", "fat",
};

/// Words that make another product, normalised across languages.
const _products = {
  "rot": "red", "red": "red", "gelb": "yellow", "yellow": "yellow", //
  "gruen": "green", "green": "green", "weiss": "white", "white": "white", //
  "schwarz": "black", "black": "black", "braun": "brown", "brown": "brown", //
  "violett": "purple", "lila": "purple", "purple": "purple", //
  "tk": "frozen", "tiefgekuehlt": "frozen", "tiefkuehl": "frozen", //
  "gefroren": "frozen", "frozen": "frozen", "gekocht": "cooked", //
  "gegart": "cooked", "vorgekocht": "cooked", "cooked": "cooked", //
  "precooked": "cooked", "getrocknet": "dried", "gerebelt": "dried", //
  "dried": "dried", "dry": "dried", "geraeuchert": "smoked", //
  "smoked": "smoked", "vollkorn": "wholegrain", //
  "wholegrain": "wholegrain", "light": "light", "lowfat": "lowfat", //
  "fettarm": "lowfat", "fettreduziert": "lowfat", "mager": "lean", //
  "lean": "lean", "dose": "canned", "dosen": "canned", //
  "konserve": "canned", "konserven": "canned", "canned": "canned", //
  "tinned": "canned", "tin": "canned", "can": "canned", "glas": "canned", //
  "jar": "canned", "jarred": "canned", "passiert": "strained", //
  "strained": "strained", "gemischt": "mixed", "mixed": "mixed", //
  "gemahlen": "ground", "ground": "ground", "festkochend": "waxy", //
  "waxy": "waxy", "mehligkochend": "floury", "floury": "floury", //
  "starchy": "floury", "gesalzen": "salted", "salted": "salted", //
  "ungesalzen": "unsalted", "unsalted": "unsalted", //
  "geroestet": "roasted", "roasted": "roasted", "toasted": "roasted", //
  "rosenscharf": "hot", "scharf": "hot", "inoil": "inoil", //
  "griechisch": "greek", "greek": "greek", "instant": "instant", //
  "eingelegt": "pickled", "pickled": "pickled",
};

// ---------------------------------------------------------------------------
// Synonyms: one id per ingredient, German and English names.

enum _Kind {
  plain,
  paprika,
  pepper,
  chili,
  ginger,
  coriander,
  driedHerb,
  freshHerb,
}

class _Entry {
  const _Entry(this.id, this.staple, this.kind, this.languages);
  final String id;
  final ShoppingStaple staple;
  final _Kind kind;
  final Set<String> languages;
}

/// "id staple | German names | English names". Staple codes: "-" none, "a"
/// always, "s" small, "o" oil, "w" water; kinds: "?p" paprika, "?pe" pepper,
/// "?c" chili, "?g" ginger, "?k" coriander, "hd" dried herb, "hf" fresh herb.
const _synonyms = [
  "chicken_breast - | Hähnchenbrust, Hähnchenbrustfilet, Hühnerbrust, Hühnerbrustfilet, Hähnchenfilet, Hühnchenbrust, Hähnchenbrustfilets | chicken breast, chicken breast fillet, chicken fillet, chicken breasts",
  "turkey_breast - | Putenbrust, Putenbrustfilet, Putenbruststeak, Truthahnbrust | turkey breast, turkey breast fillet, turkey breast steak",
  "ground_beef - | Rinderhack, Rinderhackfleisch, Hackfleisch vom Rind, Rindergehacktes | ground beef, minced beef, beef mince",
  "mixed_mince - | Hackfleisch gemischt, gemischtes Hackfleisch, gemischtes Hack, Hack gemischt | mixed mince, mixed ground meat",
  "ground_turkey - | Putenhack, Putenhackfleisch | ground turkey, turkey mince, minced turkey",
  "salmon - | Lachs, Lachsfilet | salmon, salmon fillet",
  "tuna - | Thunfisch | tuna",
  "tuna_steak - | Thunfischsteak, Thunfischfilet | tuna steak, tuna fillet",
  "shrimp - | Garnelen, Shrimps, Crevetten | shrimp, shrimps, prawns",
  "cod - | Kabeljau, Kabeljaufilet, Dorsch | cod, cod fillet",
  "egg - | Ei, Eier | egg",
  "egg_white - | Eiklar, Eiweiß | egg white",
  "milk - | Milch, Vollmilch | milk, whole milk",
  "butter s | Butter | butter",
  "yogurt - | Joghurt, Naturjoghurt | yogurt, yoghurt, natural yogurt",
  "greek_yogurt - | griechischer Joghurt, Joghurt griechischer Art | Greek yogurt, Greek yoghurt, Greek-style yogurt",
  "quark - | Quark, Speisequark | quark",
  "quark_lowfat - | Magerquark | low-fat quark, lean quark",
  "skyr - | Skyr | skyr",
  "cottage_cheese - | Hüttenkäse, körniger Frischkäse | cottage cheese, grainy cream cheese",
  "cream_cheese - | Frischkäse | cream cheese",
  "feta - | Feta, Fetakäse | feta, feta cheese",
  "mozzarella - | Mozzarella | mozzarella",
  "parmesan - | Parmesan, Parmigiano | parmesan, parmesan cheese",
  "cream - | Sahne, Schlagsahne | cream, heavy cream, whipping cream",
  "onion - | Zwiebel, Speisezwiebel, gelbe Zwiebel | onion, yellow onion, brown onion",
  "red_onion - | rote Zwiebel | red onion",
  "spring_onion - | Frühlingszwiebel, Lauchzwiebel | spring onion, scallion, green onion",
  "garlic - | Knoblauch, Knoblauchzehe, Zehe | garlic, garlic clove, clove of garlic",
  "potato - | Kartoffel | potato",
  "sweet_potato - | Süßkartoffel | sweet potato",
  "tomato - | Tomate | tomato",
  "cherry_tomato - | Cherrytomate, Kirschtomate, Cocktailtomate, Cherry-Tomate | cherry tomato",
  "passata - | passierte Tomaten, Passata | strained tomatoes, passata, tomato passata",
  "tomato_paste s | Tomatenmark | tomato paste, tomato puree",
  "bell_pepper - | Paprikaschote, Gemüsepaprika | bell pepper, sweet pepper, capsicum",
  "carrot - | Karotte, Möhre, Mohrrübe | carrot",
  "broccoli - | Brokkoli, Broccoli | broccoli",
  "cauliflower - | Blumenkohl | cauliflower",
  "spinach - | Spinat, Blattspinat, Babyspinat | spinach, baby spinach",
  "cucumber - | Gurke, Salatgurke | cucumber",
  "zucchini - | Zucchini, Zucchino | zucchini, courgette",
  "mushroom - | Champignon, Champignons, Pilze | mushroom, button mushroom",
  "leek - | Lauch, Porree | leek",
  "asparagus - | Spargel | asparagus",
  "corn - | Mais, Zuckermais | corn, sweet corn, sweetcorn",
  "peas - | Erbsen | peas",
  "beans - | Bohnen | beans",
  "kidney_beans - | Kidneybohnen | kidney beans",
  "chickpeas - | Kichererbsen | chickpeas, garbanzo beans",
  "lentils - | Linsen | lentils",
  "edamame - | Edamame | edamame",
  "tofu - | Tofu | tofu",
  "lemon - | Zitrone | lemon",
  "lime - | Limette | lime",
  "avocado - | Avocado | avocado",
  "banana - | Banane | banana",
  "apple - | Apfel | apple",
  "berries - | Beeren | berries",
  "nuts - | Nüsse | nuts",
  "pine_nuts - | Pinienkerne | pine nuts",
  "eggplant - | Aubergine | eggplant, aubergine",
  "oats - | Haferflocken | oats, rolled oats, oat flakes, porridge oats",
  "rice - | Reis | rice",
  "brown_rice - | Naturreis, Vollkornreis, brauner Reis | brown rice, whole-grain rice",
  "basmati_rice - | Basmatireis, Basmati-Reis, Basmati | basmati rice, basmati",
  "quinoa - | Quinoa | quinoa",
  "couscous - | Couscous | couscous",
  "spaghetti - | Spaghetti | spaghetti",
  "pasta - | Nudeln, Pasta | pasta",
  "wholegrain_pasta - | Vollkornnudeln, Vollkornpasta | whole-grain pasta",
  "tortilla - | Tortilla, Wrap, Tortilla-Wrap | tortilla, wrap, tortilla wrap",
  "bread - | Brot | bread",
  "lettuce_romaine - | Römersalat | romaine lettuce, romaine",
  "lettuce_iceberg - | Eisbergsalat | iceberg lettuce",
  "arugula - | Rucola, Rauke | arugula, rocket",
  "nori - | Nori, Noriblätter | nori, nori sheets",
  "honey s | Honig | honey",
  "maple_syrup s | Ahornsirup | maple syrup",
  "olive_oil o | Olivenöl | olive oil",
  "oil o | Öl, Pflanzenöl, neutrales Öl, Speiseöl | oil, vegetable oil, neutral oil, cooking oil",
  "sesame_oil o | Sesamöl | sesame oil",
  "coconut_milk - | Kokosmilch | coconut milk",
  "lemon_juice s | Zitronensaft | lemon juice",
  "lime_juice s | Limettensaft | lime juice",
  "soy_sauce s | Sojasauce, Sojasoße, Sojasosse | soy sauce",
  "mustard s | Senf | mustard",
  "grainy_mustard s | körniger Senf | grainy mustard, wholegrain mustard",
  "sugar s | Zucker | sugar",
  "flour s | Mehl, Weizenmehl | flour, all-purpose flour, plain flour",
  "sesame s | Sesam, Sesamsamen, Sesamsaat | sesame seeds, sesame",
  "chia s | Chiasamen | chia seeds",
  "flax s | Leinsamen | flaxseed, flax seeds, linseed",
  "salt a | Salz, Meersalz, Speisesalz | salt, sea salt, table salt",
  "pepper a | Pfeffer, schwarzer Pfeffer, Pfeffer aus der Mühle | black pepper, ground black pepper",
  "white_pepper a | weißer Pfeffer | white pepper",
  "paprika_powder a | Paprikapulver, Paprika edelsüß | paprika powder, sweet paprika, sweet paprika powder",
  "garlic_powder a | Knoblauchpulver, Knoblauchgranulat | garlic powder, granulated garlic",
  "cumin a | Kreuzkümmel, Cumin | cumin, ground cumin",
  "cinnamon a | Zimt | cinnamon",
  "turmeric a | Kurkuma | turmeric",
  "curry_powder a | Currypulver, Curry | curry powder, curry",
  "curry_paste - | Currypaste | curry paste",
  "garam_masala a | Garam Masala | garam masala",
  "nutmeg a | Muskat, Muskatnuss | nutmeg",
  "chili_flakes a | Chiliflocken | chili flakes, chilli flakes, red pepper flakes",
  "chili_spice a | Chilipulver | chili powder, chilli powder",
  "italian_herbs a | italienische Kräuter, Kräuter der Provence | Italian herbs, Italian seasoning, herbes de Provence",
  "baking_powder a | Backpulver | baking powder",
  "baking_soda a | Natron | baking soda",
  "vegetable_broth a | Gemüsebrühe, Gemüsefond | vegetable broth, vegetable stock",
  "chicken_broth a | Hühnerbrühe, Geflügelbrühe | chicken broth, chicken stock",
  "water w | Wasser, Leitungswasser, Eiswasser, Trinkwasser | water, tap water, ice water, hot water",
  "paprika ?p | Paprika | paprika",
  "pepper ?pe | - | pepper",
  "chili ?c | Chili, Chilischote, Peperoni | chili, chilli, chili pepper",
  "ginger ?g | Ingwer | ginger",
  "ginger_ground a | Ingwerpulver, gemahlener Ingwer | ground ginger, ginger powder",
  "coriander_ground a | Koriandersamen, gemahlener Koriander | ground coriander, coriander seeds",
  "coriander ?k | Koriander | coriander",
  "oregano hd | Oregano | oregano",
  "thyme hd | Thymian | thyme",
  "rosemary hd | Rosmarin | rosemary",
  "marjoram hd | Majoran | marjoram",
  "bay_leaf hd | Lorbeer, Lorbeerblatt | bay leaf, bay leaves",
  "sage hd | Salbei | sage",
  "tarragon hd | Estragon | tarragon",
  "herbs hd | Kräuter | herbs",
  "parsley hf | Petersilie, glatte Petersilie, krause Petersilie | parsley, flat-leaf parsley",
  "basil hf | Basilikum | basil",
  "coriander_leaf hf | Koriandergrün | cilantro, coriander leaves",
  "chives hf | Schnittlauch | chives",
  "dill hf | Dill | dill",
  "mint hf | Minze, Pfefferminze | mint",
];

final Map<String, _Entry> _aliases = () {
  final map = <String, _Entry>{};
  for (final line in _synonyms) {
    final [head, de, en] = line.split('|');
    final [id, code] = head.trim().split(' ');
    final (staple, kind) = switch (code) {
      "a" => (ShoppingStaple.always, _Kind.plain),
      "s" => (ShoppingStaple.small, _Kind.plain),
      "o" => (ShoppingStaple.oil, _Kind.plain),
      "w" => (ShoppingStaple.water, _Kind.plain),
      "?p" => (ShoppingStaple.none, _Kind.paprika),
      "?pe" => (ShoppingStaple.none, _Kind.pepper),
      "?c" => (ShoppingStaple.none, _Kind.chili),
      "?g" => (ShoppingStaple.none, _Kind.ginger),
      "?k" => (ShoppingStaple.none, _Kind.coriander),
      "hd" => (ShoppingStaple.always, _Kind.driedHerb),
      "hf" => (ShoppingStaple.none, _Kind.freshHerb),
      _ => (ShoppingStaple.none, _Kind.plain),
    };
    for (final (language, names) in [("de", de), ("en", en)]) {
      for (final name in names.split(',')) {
        if (name.trim() == '-') continue;
        final key = _analyze(name.trim()).full;
        final previous = map[key];
        map[key] = _Entry(id, staple, kind, {
          if (previous?.id == id) ...previous!.languages,
          language,
        });
      }
    }
  }
  return map;
}();

/// The app languages a name is written in when it is one of the synonym
/// table's spellings ("Sesam" German, "sesame" English, "Feta" both); null
/// for any other name.
Set<String>? shoppingNameLanguages(String name) =>
    _spellings[foldShoppingText(name).trim()];

final Map<String, Set<String>> _spellings = () {
  final map = <String, Set<String>>{};
  for (final line in _synonyms) {
    final [_, de, en] = line.split('|');
    for (final (language, names) in [("de", de), ("en", en)]) {
      for (final name in names.split(',')) {
        if (name.trim() == '-') continue;
        (map[foldShoppingText(name.trim())] ??= {}).add(language);
      }
    }
  }
  return map;
}();

_Entry? _lookup(String key) {
  final entry = _aliases[key];
  if (entry != null || key.isEmpty) return entry;
  // Cut endings: "Lachsfilet" is "Lachs", "chicken breast fillet" is
  // "chicken breast".
  for (final cut in const ["filet", "fillet"]) {
    if (key.endsWith(cut) && key.length - cut.length >= 3) {
      return _aliases[_singular(key.substring(0, key.length - cut.length))];
    }
  }
  return null;
}

/// Staples the synonym table does not name, by their (unsingularised) noun.
ShoppingStaple _patternStaple(String raw, String noun) {
  bool any(RegExp pattern) => pattern.hasMatch(raw) || pattern.hasMatch(noun);
  if (any(_alwaysPattern)) return ShoppingStaple.always;
  if (any(_oilPattern)) return ShoppingStaple.oil;
  if (any(_smallPattern)) return ShoppingStaple.small;
  return ShoppingStaple.none;
}

final _alwaysPattern = RegExp(
  r'(?:pulver|powder|salz|salt|pfeffer|peppercorns?|pfefferkoerner'
  r'|gewuerz|gewuerze|gewuerzmischung|wuerzmischung|seasoning|spicemix'
  r'|spiceblend|spices?|bruehe|bruehwuerfel|bouillon|broth|stock'
  r'|stockcubes?|bouilloncubes?|fond|hefe|yeast|staerke|starch|cornflour'
  r'|chiliflocken?|chilliflocken?|paprikaflocken?|chiliflakes?'
  r'|pepperflakes?|kreuzkuemmel|kuemmel|cumin|kurkuma|turmeric|zimt'
  r'|cinnamon|muskat|muskatnuss|nutmeg|piment|allspice|kardamom|cardamom'
  r'|garammasala|raselhanout|zaatar|sumach?|sumac|cayenne|cayennepepper'
  r'|sternanis|staranise|anis|fenchelsamen|fennelseeds?|senfsaat'
  r'|senfkoerner|mustardseeds?|koriandersamen|corianderseeds?|safran'
  r'|saffron|nelken?|gewuerznelken?|cloves?|natron|bakingsoda'
  r'|vanillezucker|vanilleextrakt|vanillearoma|vanillasugar'
  r'|vanillaextract|vanillaessence)$',
);

final _oilPattern = RegExp(
  r'(?:oel|oil|essig|vinegar|balsamico|balsamicoessig)$',
);

final _smallPattern = RegExp(
  r'(?:zucker|sugar|mehl|flour|sirup|syrup|honig|honey|agavendicksaft'
  r'|senf|mustard|ketchup|mayonnaise|mayo|tomatenmark|tomatopaste'
  r'|paniermehl|semmelbroesel|breadcrumbs?|panko|sojasauce|sojasosse'
  r'|soysauce|fischsauce|fishsauce|austernsauce|oystersauce'
  r'|worcestershiresauce|worcestersauce|worcestershire|sriracha|tabasco'
  r'|hotsauce|chilisauce|zitronensaft|limettensaft|lemonjuice|limejuice)$',
);
