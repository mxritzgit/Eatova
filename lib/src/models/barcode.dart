/// Product codes as the scanner and the typed fallback deliver them (FOOD-6).
///
/// The same UPC-A product arrives as 12 digits on Android and as a 13-digit
/// EAN with a leading 0 on iOS. New codes are written in that GTIN-13 form,
/// which is also how Open Food Facts stores UPC-A products. Keys written
/// before FOOD-6 keep their spelling; [canonicalBarcode] lets both meet.
library;

final RegExp _digitsOnly = RegExp(r'^\d+$');
final RegExp _whitespace = RegExp(r'\s+');

/// Whether the last digit of [digits] is its GTIN check digit (mod 10,
/// weights 3 and 1 alternating from the right). Holds for EAN-8, UPC-A and
/// EAN-13 alike.
bool hasValidGtinCheckDigit(String digits) {
  if (digits.length < 2 || !_digitsOnly.hasMatch(digits)) return false;
  var sum = 0;
  var weight = 3;
  for (var i = digits.length - 2; i >= 0; i--) {
    sum += (digits.codeUnitAt(i) - 0x30) * weight;
    weight = 4 - weight;
  }
  final expected = (10 - sum % 10) % 10;
  return digits.codeUnitAt(digits.length - 1) - 0x30 == expected;
}

/// [raw] as an EAN-8 or GTIN-13, or null when it is neither.
///
/// Whitespace is dropped; 8, 12 or 13 digits with a valid check digit pass,
/// and a 12-digit UPC-A gains its leading 0.
String? normalizeBarcode(String raw) {
  final digits = raw.replaceAll(_whitespace, '');
  if (!_digitsOnly.hasMatch(digits)) return null;
  if (digits.length != 8 && digits.length != 12 && digits.length != 13) {
    return null;
  }
  if (!hasValidGtinCheckDigit(digits)) return null;
  return digits.length == 12 ? '0$digits' : digits;
}

/// The spelling two forms of one stored code share: whitespace dropped and a
/// 12-digit code with the leading 0. Compares codes as they were stored, so
/// it does not check the check digit.
String canonicalBarcode(String code) {
  final digits = code.replaceAll(_whitespace, '');
  return digits.length == 12 && _digitsOnly.hasMatch(digits)
      ? '0$digits'
      : digits;
}
