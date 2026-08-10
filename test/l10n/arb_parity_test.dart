import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Wächter der Spec §6: app_en.arb muss exakt die Keys von app_de.arb tragen.
/// Fehlt ein Key, fiele der Text still auf Deutsch zurück — das soll die CI
/// brechen, nicht der Nutzer finden.
void main() {
  Set<String> keysOf(String pfad) {
    final json = jsonDecode(File(pfad).readAsStringSync())
        as Map<String, dynamic>;
    // @-Einträge sind Metadaten (Beschreibungen, Platzhalter), keine Texte.
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
