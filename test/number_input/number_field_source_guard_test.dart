import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Every typed number in a screen or widget goes through `NumberInput.parse`.
// The two patterns this replaced each corrupted input silently:
//
//  * `FilteringTextInputFormatter.digitsOnly` drops the separator, so "3,5"
//    becomes 35. It stays only where a value is a digit code, never a
//    quantity.
//  * `double.tryParse(text.replaceAll(',', '.'))` reads "1.000" as 1.
//
// A new numeric field that brings either pattern back turns this red.

/// Digit codes, not quantities: sign-in / account codes and barcodes.
const Set<String> _codeFelder = <String>{
  'lib/src/screens/auth_code_screen.dart',
  'lib/src/screens/barcode_scanner_sheet.dart',
  'lib/src/screens/settings/account_change_sheets.dart',
};

/// `int.tryParse` on server text, not on a field: the retry seconds inside a
/// GoTrue rate-limit message.
const Set<String> _serverText = <String>{
  'lib/src/screens/settings/account_change_messages.dart',
};

String _ohneKommentare(String quelle) => quelle
    .split('\n')
    .map((zeile) {
      final i = zeile.indexOf('//');
      return i < 0 ? zeile : zeile.substring(0, i);
    })
    .join('\n');

Map<String, String> _oberflaeche() => <String, String>{
  for (final wurzel in <String>['lib/src/screens', 'lib/src/widgets'])
    for (final datei in Directory(wurzel).listSync(recursive: true))
      if (datei is File && datei.path.endsWith('.dart'))
        datei.path.replaceAll(r'\', '/'): _ohneKommentare(
          datei.readAsStringSync(),
        ),
};

void main() {
  late Map<String, String> quellen;
  setUpAll(() => quellen = _oberflaeche());

  test('digitsOnly nur an Code-Feldern', () {
    final treffer = <String>{
      for (final MapEntry(:key, :value) in quellen.entries)
        if (value.contains('FilteringTextInputFormatter.digitsOnly')) key,
    };
    expect(treffer, _codeFelder);
  });

  test('keine eigene Dezimal-Zerlegung in Screens und Widgets', () {
    for (final MapEntry(:key, :value) in quellen.entries) {
      expect(value.contains("replaceAll(',', '.')"), isFalse, reason: key);
      expect(value.contains('double.tryParse'), isFalse, reason: key);
      expect(value.contains('double.parse'), isFalse, reason: key);
      expect(
        value.contains('int.tryParse') || value.contains('int.parse('),
        _serverText.contains(key),
        reason: key,
      );
    }
  });

  test('die Pruefung sieht die Felder ueberhaupt', () {
    // Guards the guard: an empty scan would pass every rule above.
    expect(quellen, contains('lib/src/widgets/kcal/manual_meal_sheet.dart'));
    expect(
      quellen['lib/src/widgets/kcal/manual_meal_sheet.dart'],
      contains('NumberInput.parse'),
    );
  });
}
