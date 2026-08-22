import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for spec §6: app_en.arb must carry exactly the keys of app_de.arb.
/// A missing key would silently fall back to German — CI should catch that,
/// not the user.
void main() {
  Set<String> keysOf(String pfad) {
    final json = jsonDecode(File(pfad).readAsStringSync())
        as Map<String, dynamic>;
    // @ entries are metadata (descriptions, placeholders), not texts.
    return json.keys.where((k) => !k.startsWith('@')).toSet();
  }

  test('app_en.arb traegt exakt die Keys von app_de.arb', () {
    final de = keysOf('lib/l10n/app_de.arb');
    final en = keysOf('lib/l10n/app_en.arb');
    expect(de, isNotEmpty, reason: 'app_de.arb ist die Vorlage');
    expect(en.difference(de), isEmpty,
        reason: 'app_en.arb hat Keys, die die Vorlage nicht kennt');
    expect(de.difference(en), isEmpty,
        reason: 'Diese Keys sind noch nicht uebersetzt');
  });
}
