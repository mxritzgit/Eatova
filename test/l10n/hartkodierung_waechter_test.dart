import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Schrumpfender Hartkodierungs-Wächter (i18n-design.md §6).
///
/// Pendant zu `test/theme/hell_modus_audit_test.dart`, nur umgekehrt: dort
/// schrumpft eine AUSNAHMEliste auf leer (Sterbe-Muster von
/// `app_colors.dart`), hier WÄCHST eine DECKUNGSliste — jedes fertig
/// migrierte i18n-Paket (docs/I18N_PAKETE.md) hängt sein Verzeichnis unten an
/// [_migriertePfade]. Am Ende der Migration deckt die Liste `lib/` komplett.
///
/// HEURISTIK (bewusst einfach, s. Bericht des ersten Pakets):
///   * Nur EINFACH gequotete String-Literale (`'...'`) — deckt den
///     durchgängigen Code-Stil dieses Repos: `"..."` kommt für UI-Text nicht
///     vor, ebenso wenig Raw- oder Triple-Quoted-Strings für Texte.
///   * Kommentare (`//`, `///`, `/* */`) werden vorher entfernt — sonst
///     schlägt ein erklärender Kommentar mit einem deutschen Wort die
///     Prüfung los (dieselbe Falle wie im Hell-Modus-Audit).
///   * Ein FUND ist ein Literal, das mindestens eines der Zeichen
///     ä/ö/ü/Ä/Ö/Ü/ß/„ trägt. Diese Zeichen kommen in diesem Repo NUR in
///     echtem deutschem Fließtext vor: ValueKeys, Asset-Pfade, Importe und
///     Log-/Sentry-Texte sind hier durchgängig ASCII-kebab-case bzw. reines
///     Englisch und fallen deshalb schon durch den Zeichenfilter — eine
///     separate ValueKey-/Pfad-Erkennung ist nicht nötig. Trüge ein Key
///     jemals eines dieser Zeichen, wäre das ohnehin ein eigener Fehler
///     (Keys sind sprachneutral und bleiben unverändert, Spec §4).
///
/// Was die Heuristik NICHT fängt (bewusste Lücke, s. Bericht): deutsche
/// Wörter ganz ohne Umlaut/ß (z. B. „Hallo", „Fett", „Makros"). Die
/// vollständige Extraktion ist Handarbeit pro Paket — dieser Test ist ein
/// Rückfallnetz, kein Ersatz dafür.
///
/// Paket 1 (Heute, 2026-08-10) ist der erste Eintrag. Spätere Pakete hängen
/// hier einfach an (docs/I18N_PAKETE.md, Paketzuschnitt-Tabelle) — NICHT
/// ersetzen, nur ergänzen.
const List<String> _migriertePfade = <String>[
  'lib/src/screens/today/',
];

void main() {
  final RegExp literal = RegExp(r"'[^'\n]*'");
  final RegExp deutschesZeichen = RegExp('[äöüÄÖÜß„]');

  String ohneKommentare(String quelle) => quelle
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((zeile) {
        final i = zeile.indexOf('//');
        return i < 0 ? zeile : zeile.substring(0, i);
      })
      .join('\n');

  List<File> dartDateien(String pfad) {
    final dir = Directory(pfad);
    if (!dir.existsSync()) {
      fail('$pfad fehlt (aufgelöst von ${Directory.current.path}) — '
          'Tippfehler in _migriertePfade?');
    }
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  test('die migrierten Pfade tragen keine deutschen Hartkodierungen mehr',
      () {
    final funde = <String>[];
    for (final pfad in _migriertePfade) {
      for (final datei in dartDateien(pfad)) {
        final relativ = datei.path.replaceAll(r'\', '/');
        final quelle = ohneKommentare(datei.readAsStringSync());
        for (final match in literal.allMatches(quelle)) {
          final text = match.group(0)!;
          if (deutschesZeichen.hasMatch(text)) {
            funde.add('$relativ: $text');
          }
        }
      }
    }
    expect(
      funde,
      isEmpty,
      reason: 'Diese String-Literale tragen noch deutsche Hartkodierungen '
          '(Umlaut/ß/„) unter einem als migriert gemeldeten Pfad — entweder '
          'fehlt die ARB-Extraktion, oder der Pfad wurde zu früh '
          'eingetragen:\n${funde.join('\n')}',
    );
  });

  test('die migrierten Pfade existieren wirklich (kein Tippfehler)', () {
    for (final pfad in _migriertePfade) {
      expect(Directory(pfad).existsSync(), isTrue, reason: pfad);
    }
  });
}
