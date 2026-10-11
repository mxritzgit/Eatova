// Amounts on the weekly shopping receipt: the leading quantity of a free-text
// ingredient line, parsed so equal units can be summed across meals.
//
// Double-quoted literals are matching data, not UI text (see
// `foldRecipeSearchText`).

/// The units a receipt sums. Mass is kept in grams and volume in millilitres;
/// every other unit counts itself.
enum ShoppingUnit {
  mass,
  volume,
  piece,
  clove,
  slice,
  can,
  jar,
  tub,
  pack,
  bunch,
  sprig,
  handful,
  cup,
  tbsp,
  tsp,
  pinch,
  centimetre,
}

/// An amount of [unit] from [low] to [high]; [high] equals [low] unless the
/// recipe gave a range ("2–3"). [approx] marks "ca."/"about".
class ShoppingAmount {
  const ShoppingAmount(this.unit, this.low, {double? high, this.approx = false})
    : high = high ?? low;

  final ShoppingUnit unit;
  final double low, high;
  final bool approx;

  bool get isRange => high != low;

  /// Spoons and pinches: measured in the kitchen, not bought by that amount.
  bool get isSpoonOrPinch =>
      unit == ShoppingUnit.tbsp ||
      unit == ShoppingUnit.tsp ||
      unit == ShoppingUnit.pinch;

  ShoppingAmount scaled(double factor) =>
      ShoppingAmount(unit, low * factor, high: high * factor, approx: approx);

  /// The sum of two amounts of the same [unit].
  ShoppingAmount operator +(ShoppingAmount other) {
    if (other.unit != unit) throw ArgumentError.value(other, 'other');
    return ShoppingAmount(
      unit,
      low + other.low,
      high: high + other.high,
      approx: approx || other.approx,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShoppingAmount &&
      other.unit == unit &&
      (other.low - low).abs() < 1e-9 &&
      (other.high - high).abs() < 1e-9 &&
      other.approx == approx;

  @override
  int get hashCode => Object.hash(unit, low, high, approx);

  @override
  String toString() =>
      'ShoppingAmount(${unit.name}, $low${isRange ? '–$high' : ''}'
      '${approx ? ', approx' : ''})';
}

/// [amounts] summed per unit, in [ShoppingUnit] order.
List<ShoppingAmount> sumShoppingAmounts(Iterable<ShoppingAmount> amounts) {
  final sums = <ShoppingUnit, ShoppingAmount>{};
  for (final amount in amounts) {
    final previous = sums[amount.unit];
    sums[amount.unit] = previous == null ? amount : previous + amount;
  }
  return [
    for (final unit in ShoppingUnit.values)
      if (sums[unit] case final sum?) sum,
  ];
}

/// [text] ("180 g", "1 1/2 EL", "ca. 2–3", "2 x 150 g", "eine Prise") as an
/// amount, or null when it is not one this receipt can sum. A number such as
/// "1.000" or "1,250" may use either separator for thousands and stays
/// unparsed; with [decimalSeparator] (computed text) it is a decimal.
ShoppingAmount? parseShoppingAmount(String text, {String? decimalSeparator}) {
  final match = _wholeAmount.firstMatch(_plain(text).trim());
  if (match == null) return null;
  final approx = match.namedGroup('approx') != null;
  final low = _number(match.namedGroup('low')!, decimalSeparator);
  final highText = match.namedGroup('high');
  final high = highText == null ? low : _number(highText, decimalSeparator);
  final timesText = match.namedGroup('times');
  final times = timesText == null ? 1 : _number(timesText, decimalSeparator);
  if (low == null || high == null || times == null || high < low) return null;
  final unitText = match.namedGroup('unit');
  final unit = unitText == null
      ? (ShoppingUnit.piece, 1.0)
      : _units[_unitKey(unitText)];
  if (unit == null) return null;
  final factor = unit.$2 * times;
  final value = ShoppingAmount(
    unit.$1,
    low * factor,
    high: high * factor,
    approx: approx,
  );
  return value.low > 0 && value.high.isFinite && value.high <= 1e7
      ? value
      : null;
}

/// A leading amount split off [text]: "1 cm Ingwer" -> ("1 cm", "Ingwer"),
/// "eine Prise Salz" -> ("eine Prise", "Salz"). An amount needs a label after
/// it; a unit is only a unit as a word of its own. Unknown pack words ("2
/// Stangen") stay part of the amount, which then does not parse.
({String? amount, String label}) splitShoppingAmount(String text) {
  final plain = _plain(text).trim();
  final match = _leadingAmount.firstMatch(plain);
  if (match == null) return (amount: null, label: plain);
  final amount = match.namedGroup('amount')!.replaceAll(RegExp(r'\s+'), ' ');
  // "2 cups of flour": the label is the flour.
  final label = match
      .namedGroup('label')!
      .trim()
      .replaceFirst(RegExp(r'^of\s+(?=\S)', caseSensitive: false), '');
  // "ein paar", "a few", "a little": not a number; "200 g": no label.
  if ((_vague.hasMatch(label) && _writtenOnly.hasMatch(amount.trim())) ||
      _units.containsKey(_unitKey(label))) {
    return (amount: null, label: plain);
  }
  return (amount: amount.trim(), label: label);
}

/// An amount after the name, the way captions write it: "Hähnchenbrust
/// 150g", "Skyr: 150 g", "Haferflocken – 40 g", "Hähnchenbrust (ca. 150
/// g)". Without a colon, dash or brackets it needs a unit, so "Mehl Type
/// 405" has none. Null when [text] does not end in an amount that parses.
({String amount, String label})? splitTrailingShoppingAmount(String text) {
  final match = _trailingAmount.firstMatch(_plain(text).trim());
  if (match == null) return null;
  final mark = match.namedGroup('mark')?.trim();
  final closed = match.namedGroup('close') != null;
  if ((mark == '(') != closed) return null;
  if (mark == null && match.namedGroup('unit') == null) return null;
  final amount = match.namedGroup('amount')!.replaceAll(RegExp(r'\s+'), ' ');
  final label = match.namedGroup('label')!.trim();
  if (parseShoppingAmount(amount) == null ||
      !RegExp(r'\p{L}', unicode: true).hasMatch(label)) {
    return null;
  }
  return (amount: amount, label: label);
}

/// Unicode fractions as "1 1/2", like the receipt's own amount column.
String _plain(String text) => text.replaceAllMapped(
  RegExp(r'(\d?)\s*([½¼¾⅓⅔⅛⅜⅝⅞])'),
  (m) => m[1]!.isEmpty ? _fractions[m[2]]! : '${m[1]} ${_fractions[m[2]]}',
);

const _fractions = {
  "½": "1/2",
  "¼": "1/4",
  "¾": "3/4",
  "⅓": "1/3",
  "⅔": "2/3",
  "⅛": "1/8",
  "⅜": "3/8",
  "⅝": "5/8",
  "⅞": "7/8",
};

double? _number(String input, String? decimalSeparator) {
  final text = input.trim().toLowerCase();
  final written = _written[text];
  if (written != null) return written;
  if (text.contains('/')) {
    final pieces = text.split(RegExp(r'\s+'));
    final ratio = pieces.last.split('/');
    final numerator = double.parse(ratio[0]);
    final denominator = double.parse(ratio[1]);
    if (denominator == 0) return null;
    return (pieces.length == 2 ? double.parse(pieces.first) : 0) +
        numerator / denominator;
  }
  final grouped = RegExp(r'^([1-9]\d{0,2})([.,])(\d{3})$').firstMatch(text);
  if (grouped != null && grouped[2] != decimalSeparator) {
    // Thousands in one locale, a decimal in the other: never a guess.
    return null;
  }
  return double.tryParse(text.replaceAll(',', '.'));
}

const _written = <String, double>{
  "ein": 1,
  "eine": 1,
  "einen": 1,
  "einem": 1,
  "einer": 1,
  "eins": 1,
  "zwei": 2,
  "drei": 3,
  "vier": 4,
  "fünf": 5,
  "fuenf": 5,
  "sechs": 6,
  "sieben": 7,
  "acht": 8,
  "neun": 9,
  "zehn": 10,
  "zwölf": 12,
  "halbe": .5,
  "halben": .5,
  "halber": .5,
  "halbes": .5,
  "a": 1,
  "an": 1,
  "one": 1,
  "two": 2,
  "three": 3,
  "four": 4,
  "five": 5,
  "six": 6,
  "seven": 7,
  "eight": 8,
  "nine": 9,
  "ten": 10,
  "twelve": 12,
  "half": .5,
  "half a": .5,
  "half an": .5,
};

/// Unit words (lower case, without a trailing dot) to unit and factor.
const _units = <String, (ShoppingUnit, double)>{
  "g": (ShoppingUnit.mass, 1),
  "gr": (ShoppingUnit.mass, 1),
  "gramm": (ShoppingUnit.mass, 1),
  "gram": (ShoppingUnit.mass, 1),
  "grams": (ShoppingUnit.mass, 1),
  "kg": (ShoppingUnit.mass, 1000),
  "kilo": (ShoppingUnit.mass, 1000),
  "mg": (ShoppingUnit.mass, .001),
  "oz": (ShoppingUnit.mass, 28.349523125),
  "lb": (ShoppingUnit.mass, 453.59237),
  "lbs": (ShoppingUnit.mass, 453.59237),
  "ml": (ShoppingUnit.volume, 1),
  "cl": (ShoppingUnit.volume, 10),
  "dl": (ShoppingUnit.volume, 100),
  "l": (ShoppingUnit.volume, 1000),
  "ltr": (ShoppingUnit.volume, 1000),
  "liter": (ShoppingUnit.volume, 1000),
  "litre": (ShoppingUnit.volume, 1000),
  "el": (ShoppingUnit.tbsp, 1),
  "esslöffel": (ShoppingUnit.tbsp, 1),
  "tbsp": (ShoppingUnit.tbsp, 1),
  "tbs": (ShoppingUnit.tbsp, 1),
  "tablespoon": (ShoppingUnit.tbsp, 1),
  "tablespoons": (ShoppingUnit.tbsp, 1),
  "tl": (ShoppingUnit.tsp, 1),
  "teelöffel": (ShoppingUnit.tsp, 1),
  "tsp": (ShoppingUnit.tsp, 1),
  "teaspoon": (ShoppingUnit.tsp, 1),
  "teaspoons": (ShoppingUnit.tsp, 1),
  "prise": (ShoppingUnit.pinch, 1),
  "prisen": (ShoppingUnit.pinch, 1),
  "msp": (ShoppingUnit.pinch, 1),
  "messerspitze": (ShoppingUnit.pinch, 1),
  "pinch": (ShoppingUnit.pinch, 1),
  "pinches": (ShoppingUnit.pinch, 1),
  "stück": (ShoppingUnit.piece, 1),
  "stk": (ShoppingUnit.piece, 1),
  "piece": (ShoppingUnit.piece, 1),
  "pieces": (ShoppingUnit.piece, 1),
  "pcs": (ShoppingUnit.piece, 1),
  "dose": (ShoppingUnit.can, 1),
  "dosen": (ShoppingUnit.can, 1),
  "can": (ShoppingUnit.can, 1),
  "cans": (ShoppingUnit.can, 1),
  "packung": (ShoppingUnit.pack, 1),
  "packungen": (ShoppingUnit.pack, 1),
  "pck": (ShoppingUnit.pack, 1),
  "päckchen": (ShoppingUnit.pack, 1),
  "pack": (ShoppingUnit.pack, 1),
  "packs": (ShoppingUnit.pack, 1),
  "becher": (ShoppingUnit.tub, 1),
  "glas": (ShoppingUnit.jar, 1),
  "gläser": (ShoppingUnit.jar, 1),
  "jar": (ShoppingUnit.jar, 1),
  "jars": (ShoppingUnit.jar, 1),
  "bund": (ShoppingUnit.bunch, 1),
  "bunch": (ShoppingUnit.bunch, 1),
  "bunches": (ShoppingUnit.bunch, 1),
  "zehe": (ShoppingUnit.clove, 1),
  "zehen": (ShoppingUnit.clove, 1),
  "clove": (ShoppingUnit.clove, 1),
  "cloves": (ShoppingUnit.clove, 1),
  "scheibe": (ShoppingUnit.slice, 1),
  "scheiben": (ShoppingUnit.slice, 1),
  "slice": (ShoppingUnit.slice, 1),
  "slices": (ShoppingUnit.slice, 1),
  "tasse": (ShoppingUnit.cup, 1),
  "tassen": (ShoppingUnit.cup, 1),
  "cup": (ShoppingUnit.cup, 1),
  "cups": (ShoppingUnit.cup, 1),
  "handvoll": (ShoppingUnit.handful, 1),
  "handful": (ShoppingUnit.handful, 1),
  "handfuls": (ShoppingUnit.handful, 1),
  "zweig": (ShoppingUnit.sprig, 1),
  "zweige": (ShoppingUnit.sprig, 1),
  "sprig": (ShoppingUnit.sprig, 1),
  "sprigs": (ShoppingUnit.sprig, 1),
  "cm": (ShoppingUnit.centimetre, 1),
};

String _unitKey(String unit) {
  final key = unit.toLowerCase().trim();
  return key.endsWith('.') ? key.substring(0, key.length - 1) : key;
}

/// Pack and portion words a recipe writes after a number ("2 Stangen Lauch"):
/// part of the amount, but nothing the receipt can sum.
const _otherUnits =
    r'Stangen?|Knollen?|Köpfe|Kopf|Töpfe|Topf|Beutel|Tüten?|Netze?|Schalen?'
    r'|Spritzer|Schuss|Tropfen|Würfel|Blätter|Blatt|Stiele?|Rispen?|Kugeln?'
    r'|Flaschen?|Tafeln?|Riegel|stalks?|sticks?|heads?|bulbs?|bags?|packets?'
    r'|packages?|bottles?|dash(?:es)?|splash(?:es)?|drizzles?|drops?|cubes?'
    r'|leaves|leaf|sheets?|balls?|bars?|ears?';

final String _unitWords = [
  ..._units.keys.toList()..sort((a, b) => b.length.compareTo(a.length)),
].map(RegExp.escape).join('|');

const _numberPattern =
    r'(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?'
    r'|half an?|ein(?:e[nmr]?|s)?|zwei|drei|vier|fünf|fuenf|sechs|sieben|acht'
    r'|neun|zehn|zwölf|halbe[nrs]?|an?|one|two|three|four|five|six|seven'
    r'|eight|nine|ten|twelve|half)';

const _approx = r'(?<approx>(?:ca\.?|circa|etwa|approx\.?|about|~)\s*)?';

final _wholeAmount = RegExp(
  '^$_approx(?<low>$_numberPattern)'
  '(?:\\s*[-–—]\\s*(?<high>$_numberPattern))?'
  '(?:\\s*[x×]\\s*(?<times>$_numberPattern))?'
  '(?:\\s*(?<unit>(?:$_unitWords|$_otherUnits)\\.?))?\$',
  caseSensitive: false,
  unicode: true,
);

final _leadingAmount = RegExp(
  '^(?<amount>$_approx(?:$_numberPattern)'
  '(?:\\s*[-–—]\\s*(?:$_numberPattern))?'
  '(?:\\s*[x×]\\s*(?:$_numberPattern))?'
  '(?:\\s*(?:$_unitWords|$_otherUnits)\\.?(?=\\s))?)'
  '\\s+(?<label>\\S.*)\$',
  caseSensitive: false,
  unicode: true,
);

final _trailingAmount = RegExp(
  '^(?<label>.*?\\S)(?:\\s*(?<mark>:|\\s[-–—]|\\()\\s*|\\s+)'
  '(?<amount>$_approx(?:$_numberPattern)'
  '(?:\\s*[-–—]\\s*(?:$_numberPattern))?'
  '(?:\\s*[x×]\\s*(?:$_numberPattern))?'
  '(?:\\s*(?<unit>$_unitWords)\\.?)?)'
  '\\s*(?<close>\\))?\$',
  caseSensitive: false,
  unicode: true,
);

/// A written number alone ("a", "ein") before a vague word is no amount.
final _writtenOnly = RegExp(r'^(?:an?|ein(?:e[nmr]?)?)$', caseSensitive: false);
final _vague = RegExp(
  r'^(?:paar|wenig|bisschen|few|little|bit|couple|dash of)\b',
  caseSensitive: false,
);
