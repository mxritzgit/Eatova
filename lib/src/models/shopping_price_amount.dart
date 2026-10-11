// Reads the amount a shopping line printed ("180 g", "1 1/2 EL", "ca. 2–3",
// "2 x 150 g", "1 Dose") as a quantity the price estimate can convert.
//
// Its own grammar, deliberately separate from the display split in
// shopping_list.dart: a unit missing here degrades to null ("k. A."), never
// to a wrong price. test/shopping_prices/price_amount_test.dart feeds every
// unit the display split knows through this parser.
//
// Unit words are matching data, not UI text: double-quoted, like
// meal_description_matcher.dart.

import 'shopping_price.dart';

const String _number = r'(\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?)';

final RegExp _amountPattern = RegExp(
  '^$_number(?:\\s*[-–]\\s*$_number)?(?:\\s*[x×]\\s*$_number)?'
  r'\s*([^\d\s.][^\s.]*)?\.?$',
  caseSensitive: false,
  unicode: true,
);

final RegExp _approx = RegExp(
  r'^(?:ca\.|approx\.|etwa)\s*',
  caseSensitive: false,
);

/// "1.000" or "1,250": a thousands separator or a decimal comma; no guess.
final RegExp _ambiguous = RegExp(r'^[1-9]\d{0,2}[.,]\d{3}$');

/// Unit word (lower case, trailing dot removed) to the quantity it makes.
final Map<String, PriceQuantity Function(double value)> _units = {
  "g": (v) => MassQuantity(v),
  "gramm": (v) => MassQuantity(v),
  "kg": (v) => MassQuantity(v * 1000),
  "mg": (v) => MassQuantity(v / 1000),
  "oz": (v) => MassQuantity(v * 28.35),
  "lb": (v) => MassQuantity(v * 453.6),
  "lbs": (v) => MassQuantity(v * 453.6),
  "ml": (v) => VolumeQuantity(v),
  "cl": (v) => VolumeQuantity(v * 10),
  "dl": (v) => VolumeQuantity(v * 100),
  "l": (v) => VolumeQuantity(v * 1000),
  "liter": (v) => VolumeQuantity(v * 1000),
  "cup": (v) => VolumeQuantity(v * 240),
  "cups": (v) => VolumeQuantity(v * 240),
  "tasse": (v) => VolumeQuantity(v * 240),
  "tassen": (v) => VolumeQuantity(v * 240),
  "el": (v) => SpoonQuantity(v, tablespoon: true),
  "esslöffel": (v) => SpoonQuantity(v, tablespoon: true),
  "tbsp": (v) => SpoonQuantity(v, tablespoon: true),
  "tl": (v) => SpoonQuantity(v, tablespoon: false),
  "teelöffel": (v) => SpoonQuantity(v, tablespoon: false),
  "tsp": (v) => SpoonQuantity(v, tablespoon: false),
  "msp": (_) => const PinchQuantity(),
  "prise": (_) => const PinchQuantity(),
  "prisen": (_) => const PinchQuantity(),
  "pinch": (_) => const PinchQuantity(),
  "pinches": (_) => const PinchQuantity(),
  "stück": (v) => CountQuantity(v, PriceUnit.piece),
  "stk": (v) => CountQuantity(v, PriceUnit.piece),
  "piece": (v) => CountQuantity(v, PriceUnit.piece),
  "pieces": (v) => CountQuantity(v, PriceUnit.piece),
  "pcs": (v) => CountQuantity(v, PriceUnit.piece),
  "zehe": (v) => CountQuantity(v, PriceUnit.clove),
  "zehen": (v) => CountQuantity(v, PriceUnit.clove),
  "clove": (v) => CountQuantity(v, PriceUnit.clove),
  "cloves": (v) => CountQuantity(v, PriceUnit.clove),
  "scheibe": (v) => CountQuantity(v, PriceUnit.slice),
  "scheiben": (v) => CountQuantity(v, PriceUnit.slice),
  "slice": (v) => CountQuantity(v, PriceUnit.slice),
  "slices": (v) => CountQuantity(v, PriceUnit.slice),
  "dose": (v) => CountQuantity(v, PriceUnit.can),
  "dosen": (v) => CountQuantity(v, PriceUnit.can),
  "can": (v) => CountQuantity(v, PriceUnit.can),
  "cans": (v) => CountQuantity(v, PriceUnit.can),
  "packung": (v) => CountQuantity(v, PriceUnit.pack),
  "packungen": (v) => CountQuantity(v, PriceUnit.pack),
  "pck": (v) => CountQuantity(v, PriceUnit.pack),
  "pack": (v) => CountQuantity(v, PriceUnit.pack),
  "packs": (v) => CountQuantity(v, PriceUnit.pack),
  "becher": (v) => CountQuantity(v, PriceUnit.tub),
  "glas": (v) => CountQuantity(v, PriceUnit.jar),
  "gläser": (v) => CountQuantity(v, PriceUnit.jar),
  "jar": (v) => CountQuantity(v, PriceUnit.jar),
  "jars": (v) => CountQuantity(v, PriceUnit.jar),
  "bund": (v) => CountQuantity(v, PriceUnit.bunch),
  "bunch": (v) => CountQuantity(v, PriceUnit.bunch),
  "bunches": (v) => CountQuantity(v, PriceUnit.bunch),
};

/// The quantity in a line's split-off [amount], or null when there is none
/// or it cannot be converted (a handful, a sprig, "1.000 g").
PriceQuantity? parsePriceQuantity(String? amount) {
  if (amount == null) return null;
  final text = amount.trim().replaceFirst(_approx, '');
  final match = _amountPattern.firstMatch(text);
  if (match == null) return null;
  final first = _value(match[1]!);
  final upper = match[2] == null ? first : _value(match[2]!);
  final times = match[3] == null ? 1.0 : _value(match[3]!);
  if (first == null || upper == null || times == null) return null;
  final value = upper * times;
  if (!value.isFinite || value <= 0) return null;
  final unit = match[4]?.toLowerCase();
  if (unit == null) return CountQuantity(value, PriceUnit.piece);
  return _units[unit]?.call(value);
}

double? _value(String raw) {
  final text = raw.trim();
  if (_ambiguous.hasMatch(text)) return null;
  final parts = text.split(RegExp(r'\s+'));
  var total = 0.0;
  for (final part in parts) {
    final slash = part.indexOf('/');
    if (slash >= 0) {
      final numerator = double.tryParse(part.substring(0, slash));
      final denominator = double.tryParse(part.substring(slash + 1));
      if (numerator == null || denominator == null || denominator == 0) {
        return null;
      }
      total += numerator / denominator;
    } else {
      final value = double.tryParse(part.replaceAll(',', '.'));
      if (value == null) return null;
      total += value;
    }
  }
  return total;
}
