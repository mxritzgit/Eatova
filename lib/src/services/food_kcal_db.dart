import '../models/meal_component.dart';

/// Local kcal database entry: caloric density and default portion size.
typedef FoodEntry = ({double kcalPer100G, int defaultGrams});

/// Local kcal lookup for common German-language foods, used to auto-split a
/// combined meal name the vision model returned as one entry. Numbers are
/// rounded everyday values, not lab-grade.
const Map<String, FoodEntry> _foodDb = {
  // Meat
  'steak': (kcalPer100G: 220.0, defaultGrams: 200),
  'rindersteak': (kcalPer100G: 220.0, defaultGrams: 200),
  'rumpsteak': (kcalPer100G: 215.0, defaultGrams: 200),
  'rinderfilet': (kcalPer100G: 200.0, defaultGrams: 180),
  'rinderhüftsteak': (kcalPer100G: 215.0, defaultGrams: 200),
  'hähnchen': (kcalPer100G: 165.0, defaultGrams: 150),
  'hähnchenbrust': (kcalPer100G: 165.0, defaultGrams: 150),
  'hähnchenschenkel': (kcalPer100G: 215.0, defaultGrams: 180),
  'pute': (kcalPer100G: 135.0, defaultGrams: 150),
  'putenbrust': (kcalPer100G: 135.0, defaultGrams: 150),
  'schwein': (kcalPer100G: 240.0, defaultGrams: 180),
  'schweinefilet': (kcalPer100G: 145.0, defaultGrams: 180),
  'schweinebraten': (kcalPer100G: 260.0, defaultGrams: 200),
  'schnitzel': (kcalPer100G: 215.0, defaultGrams: 180),
  'lamm': (kcalPer100G: 250.0, defaultGrams: 180),
  'lammkotelett': (kcalPer100G: 280.0, defaultGrams: 180),
  'hackfleisch': (kcalPer100G: 215.0, defaultGrams: 150),
  'hack': (kcalPer100G: 215.0, defaultGrams: 150),
  'frikadelle': (kcalPer100G: 250.0, defaultGrams: 100),
  'wurst': (kcalPer100G: 300.0, defaultGrams: 100),
  'bratwurst': (kcalPer100G: 300.0, defaultGrams: 100),
  'currywurst': (kcalPer100G: 290.0, defaultGrams: 150),
  'salami': (kcalPer100G: 350.0, defaultGrams: 60),
  'schinken': (kcalPer100G: 130.0, defaultGrams: 60),
  'speck': (kcalPer100G: 540.0, defaultGrams: 30),
  'bacon': (kcalPer100G: 540.0, defaultGrams: 30),

  // Fish
  'lachs': (kcalPer100G: 200.0, defaultGrams: 150),
  'thunfisch': (kcalPer100G: 145.0, defaultGrams: 150),
  'forelle': (kcalPer100G: 120.0, defaultGrams: 150),
  'kabeljau': (kcalPer100G: 80.0, defaultGrams: 150),
  'seelachs': (kcalPer100G: 80.0, defaultGrams: 150),
  'garnelen': (kcalPer100G: 105.0, defaultGrams: 100),
  'shrimps': (kcalPer100G: 105.0, defaultGrams: 100),
  'sushi': (kcalPer100G: 150.0, defaultGrams: 200),

  // Carbs - potatoes
  'ofenkartoffel': (kcalPer100G: 95.0, defaultGrams: 200),
  'ofenkartoffeln': (kcalPer100G: 95.0, defaultGrams: 220),
  'kartoffel': (kcalPer100G: 87.0, defaultGrams: 200),
  'kartoffeln': (kcalPer100G: 87.0, defaultGrams: 200),
  'salzkartoffeln': (kcalPer100G: 75.0, defaultGrams: 200),
  'bratkartoffeln': (kcalPer100G: 145.0, defaultGrams: 200),
  'kartoffelbrei': (kcalPer100G: 95.0, defaultGrams: 200),
  'kartoffelpüree': (kcalPer100G: 95.0, defaultGrams: 200),
  'pommes': (kcalPer100G: 310.0, defaultGrams: 150),
  'pommes frites': (kcalPer100G: 310.0, defaultGrams: 150),
  'kartoffelsalat': (kcalPer100G: 130.0, defaultGrams: 150),
  'süßkartoffel': (kcalPer100G: 86.0, defaultGrams: 200),
  'süßkartoffeln': (kcalPer100G: 86.0, defaultGrams: 200),

  // Carbs - other
  'reis': (kcalPer100G: 130.0, defaultGrams: 180),
  'wildreis': (kcalPer100G: 115.0, defaultGrams: 180),
  'basmatireis': (kcalPer100G: 145.0, defaultGrams: 180),
  'risotto': (kcalPer100G: 175.0, defaultGrams: 200),
  'nudeln': (kcalPer100G: 160.0, defaultGrams: 200),
  'pasta': (kcalPer100G: 160.0, defaultGrams: 200),
  'spaghetti': (kcalPer100G: 160.0, defaultGrams: 200),
  'penne': (kcalPer100G: 160.0, defaultGrams: 200),
  'tagliatelle': (kcalPer100G: 160.0, defaultGrams: 200),
  'lasagne': (kcalPer100G: 175.0, defaultGrams: 300),
  'couscous': (kcalPer100G: 120.0, defaultGrams: 180),
  'quinoa': (kcalPer100G: 120.0, defaultGrams: 180),
  'bulgur': (kcalPer100G: 115.0, defaultGrams: 180),
  'linsen': (kcalPer100G: 115.0, defaultGrams: 150),
  'kichererbsen': (kcalPer100G: 165.0, defaultGrams: 150),
  'gnocchi': (kcalPer100G: 155.0, defaultGrams: 200),

  // Bread
  'brot': (kcalPer100G: 250.0, defaultGrams: 60),
  'brötchen': (kcalPer100G: 270.0, defaultGrams: 60),
  'baguette': (kcalPer100G: 260.0, defaultGrams: 80),
  'vollkornbrot': (kcalPer100G: 230.0, defaultGrams: 60),
  'toast': (kcalPer100G: 280.0, defaultGrams: 40),
  'wrap': (kcalPer100G: 275.0, defaultGrams: 80),
  'fladenbrot': (kcalPer100G: 290.0, defaultGrams: 100),

  // Vegetables
  'tomate': (kcalPer100G: 18.0, defaultGrams: 80),
  'tomaten': (kcalPer100G: 18.0, defaultGrams: 80),
  'kirschtomaten': (kcalPer100G: 18.0, defaultGrams: 60),
  'paprika': (kcalPer100G: 27.0, defaultGrams: 80),
  'gurke': (kcalPer100G: 16.0, defaultGrams: 80),
  'salat': (kcalPer100G: 15.0, defaultGrams: 80),
  'gemischter salat': (kcalPer100G: 20.0, defaultGrams: 100),
  'kopfsalat': (kcalPer100G: 14.0, defaultGrams: 80),
  'feldsalat': (kcalPer100G: 14.0, defaultGrams: 60),
  'rucola': (kcalPer100G: 27.0, defaultGrams: 50),
  'karotte': (kcalPer100G: 41.0, defaultGrams: 100),
  'karotten': (kcalPer100G: 41.0, defaultGrams: 100),
  'möhren': (kcalPer100G: 41.0, defaultGrams: 100),
  'brokkoli': (kcalPer100G: 34.0, defaultGrams: 100),
  'blumenkohl': (kcalPer100G: 25.0, defaultGrams: 100),
  'spinat': (kcalPer100G: 23.0, defaultGrams: 100),
  'zucchini': (kcalPer100G: 17.0, defaultGrams: 100),
  'aubergine': (kcalPer100G: 25.0, defaultGrams: 100),
  'zwiebel': (kcalPer100G: 40.0, defaultGrams: 60),
  'zwiebeln': (kcalPer100G: 40.0, defaultGrams: 60),
  'champignons': (kcalPer100G: 22.0, defaultGrams: 100),
  'pilze': (kcalPer100G: 22.0, defaultGrams: 100),
  'erbsen': (kcalPer100G: 81.0, defaultGrams: 80),
  'mais': (kcalPer100G: 95.0, defaultGrams: 80),
  'bohnen': (kcalPer100G: 30.0, defaultGrams: 100),
  'grüne bohnen': (kcalPer100G: 30.0, defaultGrams: 100),
  'rote bete': (kcalPer100G: 43.0, defaultGrams: 100),
  'rotkohl': (kcalPer100G: 30.0, defaultGrams: 150),
  'sauerkraut': (kcalPer100G: 20.0, defaultGrams: 150),
  'avocado': (kcalPer100G: 160.0, defaultGrams: 100),
  'oliven': (kcalPer100G: 115.0, defaultGrams: 30),

  // Fruit
  'apfel': (kcalPer100G: 52.0, defaultGrams: 180),
  'banane': (kcalPer100G: 89.0, defaultGrams: 120),
  'orange': (kcalPer100G: 47.0, defaultGrams: 180),
  'erdbeere': (kcalPer100G: 32.0, defaultGrams: 100),
  'erdbeeren': (kcalPer100G: 32.0, defaultGrams: 100),
  'blaubeere': (kcalPer100G: 57.0, defaultGrams: 100),
  'blaubeeren': (kcalPer100G: 57.0, defaultGrams: 100),
  'himbeere': (kcalPer100G: 52.0, defaultGrams: 100),
  'himbeeren': (kcalPer100G: 52.0, defaultGrams: 100),
  'trauben': (kcalPer100G: 69.0, defaultGrams: 100),
  'birne': (kcalPer100G: 57.0, defaultGrams: 180),
  'kiwi': (kcalPer100G: 61.0, defaultGrams: 80),
  'melone': (kcalPer100G: 34.0, defaultGrams: 200),
  'ananas': (kcalPer100G: 50.0, defaultGrams: 150),

  // Dairy and eggs
  'ei': (kcalPer100G: 155.0, defaultGrams: 55),
  'eier': (kcalPer100G: 155.0, defaultGrams: 110),
  'rührei': (kcalPer100G: 170.0, defaultGrams: 100),
  'spiegelei': (kcalPer100G: 195.0, defaultGrams: 60),
  'omelett': (kcalPer100G: 155.0, defaultGrams: 150),
  'quark': (kcalPer100G: 70.0, defaultGrams: 200),
  'skyr': (kcalPer100G: 65.0, defaultGrams: 150),
  'joghurt': (kcalPer100G: 60.0, defaultGrams: 150),
  'käse': (kcalPer100G: 350.0, defaultGrams: 30),
  'mozzarella': (kcalPer100G: 280.0, defaultGrams: 60),
  'feta': (kcalPer100G: 260.0, defaultGrams: 50),
  'parmesan': (kcalPer100G: 400.0, defaultGrams: 15),
  'butter': (kcalPer100G: 720.0, defaultGrams: 10),
  'frischkäse': (kcalPer100G: 230.0, defaultGrams: 30),

  // Sauces and oils (small portions)
  'olivenöl': (kcalPer100G: 880.0, defaultGrams: 10),
  'mayo': (kcalPer100G: 700.0, defaultGrams: 20),
  'mayonnaise': (kcalPer100G: 700.0, defaultGrams: 20),
  'ketchup': (kcalPer100G: 110.0, defaultGrams: 20),
  'senf': (kcalPer100G: 70.0, defaultGrams: 15),
  'sauce': (kcalPer100G: 100.0, defaultGrams: 60),
  'soße': (kcalPer100G: 100.0, defaultGrams: 60),
  'pesto': (kcalPer100G: 450.0, defaultGrams: 20),
  'hummus': (kcalPer100G: 170.0, defaultGrams: 40),
  'guacamole': (kcalPer100G: 160.0, defaultGrams: 50),

  // Fast food / dishes
  'burger': (kcalPer100G: 270.0, defaultGrams: 220),
  'hamburger': (kcalPer100G: 270.0, defaultGrams: 220),
  'cheeseburger': (kcalPer100G: 290.0, defaultGrams: 240),
  'pizza': (kcalPer100G: 270.0, defaultGrams: 250),
  'sandwich': (kcalPer100G: 240.0, defaultGrams: 200),
  'döner': (kcalPer100G: 220.0, defaultGrams: 350),
  'falafel': (kcalPer100G: 330.0, defaultGrams: 100),

  // Nuts
  'mandeln': (kcalPer100G: 580.0, defaultGrams: 30),
  'walnüsse': (kcalPer100G: 650.0, defaultGrams: 30),
  'erdnüsse': (kcalPer100G: 570.0, defaultGrams: 30),
  'cashews': (kcalPer100G: 550.0, defaultGrams: 30),
};

const FoodEntry _defaultEntry = (kcalPer100G: 100.0, defaultGrams: 100);

/// Common German cooking adjectives that should be stripped before DB lookup.
final RegExp _adjectiveStrip = RegExp(
  r'\b(gegrillt|gebraten|gekocht|gedämpft|gebacken|geröstet|frisch|roh|'
  r'mariniert|gegart|geräuchert|gefüllt|paniert|gemischt|gewürzt)'
  r'(e[rmns]?|en)?\b',
  caseSensitive: false,
);

final RegExp _articleStrip = RegExp(
  r'\b(der|die|das|ein|eine|einer|einen|einem)\b',
  caseSensitive: false,
);

String _normalize(String raw) {
  return raw
      .toLowerCase()
      .replaceAll(_adjectiveStrip, '')
      .replaceAll(_articleStrip, '')
      .replaceAll(RegExp(r'[^\wäöüß\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

FoodEntry _lookup(String rawName) {
  final cleaned = _normalize(rawName);
  if (cleaned.isEmpty) return _defaultEntry;

  if (_foodDb.containsKey(cleaned)) return _foodDb[cleaned]!;

  // Try longer DB keys first so "süßkartoffel" matches before "kartoffel".
  final keys = _foodDb.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final key in keys) {
    if (cleaned.contains(key)) return _foodDb[key]!;
  }

  return _defaultEntry;
}

/// Splits a meal name like "Steak mit Ofenkartoffeln, gegrilltem Paprika und
/// Tomate" into ["Steak", "Ofenkartoffeln", "gegrilltem Paprika", "Tomate"].
List<String> splitMealName(String mealName) {
  final replaced = mealName
      .replaceAll(RegExp(r'\bmit\b', caseSensitive: false), ',')
      .replaceAll(RegExp(r'\bund\b', caseSensitive: false), ',')
      .replaceAll('&', ',')
      .replaceAll(RegExp(r'\bsowie\b', caseSensitive: false), ',')
      .replaceAll('+', ',');

  final parts = replaced
      .split(RegExp(r'[,;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // Drop trivial "auf einem Teller", "Beilagen", "Portion" leading bits.
  final filtered = parts.where((p) {
    final n = _normalize(p);
    return n.isNotEmpty &&
        n != 'teller' &&
        n != 'beilage' &&
        n != 'beilagen' &&
        n != 'portion';
  }).toList();

  return filtered;
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Expands a combined meal into per-ingredient MealComponents, or an empty
/// list when the name has < 2 parts or a total is missing (<= 0).
///
/// The maths preserves both totals: the local table only contributes the
/// *ratios* between items, never an absolute number of its own.
List<MealComponent> autoSplitItems({
  required String mealName,
  required int totalGrams,
  required int totalKcal,
}) {
  final names = splitMealName(mealName);
  if (names.length < 2) return const <MealComponent>[];

  // Sentinel rule: 0 means "unknown", not a measurement. Without totals the
  // items would carry the table's unscaled reference values, which look
  // measured once they land in the edit sheet.
  if (totalKcal <= 0 || totalGrams <= 0) return const <MealComponent>[];

  final lookups = names.map(_lookup).toList();
  final defaultGramsSum = lookups.fold<int>(
    0,
    (sum, e) => sum + e.defaultGrams,
  );
  if (defaultGramsSum <= 0) return const <MealComponent>[];

  final gramFactor = totalGrams / defaultGramsSum;

  final scaledGrams = <int>[];
  for (final entry in lookups) {
    final grams = (entry.defaultGrams * gramFactor).round().clamp(1, 5000);
    scaledGrams.add(grams);
  }

  final naiveKcal = List<double>.generate(
    names.length,
    (i) => lookups[i].kcalPer100G * scaledGrams[i] / 100.0,
  );
  final naiveKcalSum = naiveKcal.fold<double>(0, (s, v) => s + v);
  // Without a positive base the AI total cannot be distributed; a factor of
  // 1.0 would silently swallow it to 0.
  if (naiveKcalSum <= 0) return const <MealComponent>[];
  final kcalFactor = totalKcal / naiveKcalSum;

  final items = <MealComponent>[];
  for (var i = 0; i < names.length; i++) {
    final grams = scaledGrams[i];
    final scaledKcal = (naiveKcal[i] * kcalFactor).round().clamp(0, 5000);
    final per100 = grams > 0 ? scaledKcal * 100 / grams : lookups[i].kcalPer100G;
    items.add(MealComponent(
      name: _capitalize(names[i]),
      grams: grams,
      caloriesKcal: scaledKcal,
      kcalPer100G: per100,
    ));
  }
  return items;
}
