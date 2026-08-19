// VERDRAHTUNGS-WAECHTER — das kleine Benachrichtigungs-Icon (Small Icon).
//
// DER FUND (Komplettreview 2026-08-19)
// `AndroidInitializationSettings('@mipmap/ic_launcher')` hat den Launcher als
// Small Icon gesetzt. Android wertet dafuer seit API 21 AUSSCHLIESSLICH den
// Alphakanal aus und faerbt das Ergebnis selbst ein; minSdk ist 26, der Fall
// tritt also auf jedem Geraet ein. Der Launcher ist ein vollflaechig deckendes
// Bitmap (Alpha ueberall 255) — in der Statusleiste kam davon ein weisses
// Quadrat an. Sichtbar wird das erst auf einem echten Geraet, kein Test und
// kein Build haetten es gemeldet: `getIdentifier` loest `@mipmap/ic_launcher`
// sauber auf, die Verdrahtung war also technisch korrekt und trotzdem falsch.
//
// WAS DIESE DATEI IST UND WAS NICHT
// Sie prueft die ABHAENGIGKEIT ZWISCHEN DART UND ANDROID-RESSOURCEN, so wie
// `wiring_android_manifest_test.dart` es fuer das Manifest tut: welchen Namen
// der Dart-Code an das Plugin gibt, ob unter diesem Namen ueberhaupt etwas
// liegt, und ob das, was dort liegt, die Alphakanal-Bedingung erfuellt.
// Quelltext und XML werden vorher entkommentiert — die Begruendungen in beiden
// Dateien nennen den alten Wert (`@mipmap/ic_launcher`) und `android:tint`
// woertlich, ein naives `contains` wuerde also seinen eigenen Kommentar lesen.
//
// Was sie NICHT kann: beweisen, dass SystemUI die Datei zeichnet. Dafuer
// braeuchte es einen Geraetetest mit Blick auf die Statusleiste.
//
// EINSTUFUNG: mittel. Strukturpruefung eines Build-Artefakts plus der
// Kopplung zum Dart-Code, keine Wirkungspruefung.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _dienstPfad = 'lib/src/services/notification_service.dart';
const String _resWurzel = 'android/app/src/main/res';
const String _libWurzel = 'lib';
const String _pluginImport = 'flutter_local_notifications';

/// Bitmap-Endungen, die der Ressourcen-Merger als Drawable akzeptiert. Eine
/// Datei mit diesen Endungen und gleichem Basisnamen in einem dichte-
/// qualifizierten Ordner wuerde das Vektor-Drawable auf dem passenden Geraet
/// verdraengen — und damit genau den Fund zurueckbringen.
const List<String> _bitmapEndungen = <String>[
  '.png',
  '.webp',
  '.jpg',
  '.jpeg',
  '.gif',
];

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
}

/// Dart-Quelltext ohne Kommentare. Ohne diesen Schritt liest die Pruefung
/// unten den Begruendungs-Kommentar mit, in dem der alte Wert steht.
String _dartOhneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

String _xmlOhneKommentare(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// Alle Dart-Dateien unter `lib/`, die das Notification-Plugin ansteuern —
/// dynamisch ermittelt, damit ein NEUER Aufrufer automatisch mitgeprueft wird.
List<String> _notificationQuellen() {
  final wurzel = Directory(_libWurzel);
  if (!wurzel.existsSync()) {
    fail('$_libWurzel fehlt (aufgeloest von ${Directory.current.path})');
  }
  final quellen = <String>[];
  for (final e in wurzel.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final text = e.readAsStringSync();
    if (text.contains(_pluginImport)) quellen.add(_dartOhneKommentare(text));
  }
  return quellen;
}

/// Das Argument von `AndroidInitializationSettings('...')` — der Name, den das
/// Plugin per `Resources.getIdentifier` aufloest.
String _defaultIcon(String quelleOhneKommentare) {
  final m = RegExp(r"AndroidInitializationSettings\(\s*'([^']+)'")
      .firstMatch(quelleOhneKommentare);
  if (m == null) {
    fail('In $_dienstPfad steht kein AndroidInitializationSettings(\'...\') — '
        'ohne diesen Aufruf hat keine Benachrichtigung ein Small Icon.');
  }
  return m.group(1)!;
}

final RegExp _attributRegex = RegExp(r'([A-Za-z_][\w.:-]*)\s*=\s*"([^"]*)"');

/// Alle Attribute des Dokuments als (Name, Wert)-Paare. Reicht fuer die
/// flache Struktur eines VectorDrawable; `package:xml` ist nur transitiv
/// aufgeloest und braeuchte einen pubspec-Eintrag (siehe
/// `wiring_android_manifest_test.dart`).
List<MapEntry<String, String>> _attribute(String xml) =>
    <MapEntry<String, String>>[
      for (final a in _attributRegex.allMatches(xml))
        MapEntry(a.group(1)!, a.group(2)!),
    ];

/// Ob [wert] als Farbe entweder rein weiss oder voellig transparent ist — die
/// beiden einzigen Werte, bei denen die Form ausschliesslich im Alphakanal
/// steckt. Alles andere ist eine Farbflaeche, die Android platt einfaerbt.
bool _weissOderUnsichtbar(String wert) {
  if (wert == '@android:color/white') return true;
  final m = RegExp(r'^#([0-9a-fA-F]{3,8})$').firstMatch(wert);
  if (m == null) return false;
  var hex = m.group(1)!;
  // Kurzformen auf AARRGGBB normalisieren.
  if (hex.length == 3) {
    hex = 'FF${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
  } else if (hex.length == 4) {
    hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}'
        '${hex[2]}${hex[2]}${hex[3]}${hex[3]}';
  } else if (hex.length == 6) {
    hex = 'FF$hex';
  }
  if (hex.length != 8) return false;
  final alpha = int.parse(hex.substring(0, 2), radix: 16);
  final rgb = hex.substring(2).toUpperCase();
  return alpha == 0 || rgb == 'FFFFFF';
}

void main() {
  late String icon;
  late List<String> notificationQuellen;

  setUpAll(() {
    icon = _defaultIcon(_dartOhneKommentare(_lies(_dienstPfad)));
    notificationQuellen = _notificationQuellen();
  });

  group('Kopplung Dart -> Android-Ressource', () {
    test('das Small Icon zeigt auf ein @drawable, nicht auf den Launcher', () {
      expect(icon, startsWith('@drawable/'),
          reason: 'Der Launcher (@mipmap/ic_launcher) ist ein deckendes '
              'Bitmap. Android nutzt fuer das Small Icon ab API 21 nur den '
              'Alphakanal (minSdk 26 — immer), das Ergebnis waere ein weisses '
              'Quadrat in der Statusleiste. Das Small Icon braucht ein eigenes, '
              'monochromes Drawable.');
    });

    test('das benannte Drawable existiert als Vektor unter res/drawable/', () {
      final name = icon.split('/').last;
      final vektor = File('$_resWurzel/drawable/$name.xml');
      expect(vektor.existsSync(), isTrue,
          reason: 'Der Dart-Code gibt "$icon" an das Plugin. Loest '
              'Resources.getIdentifier das nicht auf, bricht schon '
              'initialize() mit INVALID_ICON ab — dann gibt es GAR KEINE '
              'Benachrichtigung mehr, nicht nur ein haessliches Icon '
              '(FlutterLocalNotificationsPlugin.java:1734-1738).');
    });

    test(
        'kein gleichnamiges Bitmap verdraengt den Vektor in einer Dichte',
        () {
      final name = icon.split('/').last;
      final kollisionen = <String>[];
      final res = Directory(_resWurzel);
      for (final e in res.listSync(recursive: true)) {
        if (e is! File) continue;
        // Windows liefert Backslashes, die CI Slashes — beide trennen hier.
        final datei = e.path.split(RegExp(r'[/\\]')).last;
        for (final endung in _bitmapEndungen) {
          if (datei == '$name$endung') kollisionen.add(e.path);
        }
      }
      expect(kollisionen, isEmpty,
          reason: 'Ein dichte-qualifiziertes Bitmap gewinnt gegen '
              'drawable/$name.xml auf genau den Geraeten dieser Dichte. Wer '
              'hier PNGs nachlegt, holt sich den weissen Block auf einem Teil '
              'der Geraete zurueck — waehrend er auf dem Emulator sauber '
              'aussieht.');
    });

    test('kein Aufrufer setzt irgendwo einen @mipmap-Verweis fuers Plugin', () {
      // Gegenrichtung zum ersten Test: AndroidNotificationDetails.icon
      // ueberschreibt den Default pro Benachrichtigung
      // (FlutterLocalNotificationsPlugin.java:499-501). Ein @mipmap dort waere
      // derselbe Fund an anderer Stelle.
      final treffer = notificationQuellen
          .where((q) => q.contains('@mipmap/'))
          .toList();
      expect(treffer, isEmpty,
          reason: 'Launcher-Bitmaps gehoeren nie in eine Notification-Icon-'
              'Angabe — weder als defaultIcon noch als '
              'AndroidNotificationDetails.icon.');
    });
  });

  group('das Drawable erfuellt die Alphakanal-Bedingung', () {
    late String vektor;

    setUp(() {
      final name = icon.split('/').last;
      vektor = _xmlOhneKommentare(_lies('$_resWurzel/drawable/$name.xml'));
    });

    test('es ist ein VectorDrawable, kein verpacktes Bitmap', () {
      expect(vektor, contains('<vector'),
          reason: 'ein <bitmap>/<layer-list> haette wieder einen Alphakanal, '
              'den niemand kontrolliert.');
      expect(vektor.contains('<bitmap'), isFalse);
      expect(vektor.contains('<gradient'), isFalse,
          reason: 'ein Verlauf ist im Small Icon wirkungslos — Android faerbt '
              'die Flaeche ohnehin einfarbig ein — und verschleiert nur, dass '
              'die Form aus dem Alphakanal kommen muss.');
    });

    test('jede Farbe ist weiss oder voellig transparent', () {
      final farben = _attribute(vektor)
          .where((a) => a.key.toLowerCase().endsWith('color'))
          .toList();
      expect(farben, isNotEmpty,
          reason: 'ein Drawable ohne einzige Farbangabe zeichnet nichts.');
      final bunt = farben
          .where((a) => !_weissOderUnsichtbar(a.value))
          .map((a) => '${a.key}="${a.value}"')
          .toList();
      expect(bunt, isEmpty,
          reason: 'Android verwirft die Farbwerte des Small Icons und nutzt '
              'nur den Alphakanal. Jede farbige Flaeche wird damit zu einer '
              'weissen Flaeche — genau der Fund.');
    });

    test('kein eigener android:tint', () {
      expect(_attribute(vektor).any((a) => a.key == 'android:tint'), isFalse,
          reason: 'die Faerbung macht das System (Statusleiste weiss, im Schub '
              'die Akzentfarbe). Ein eigener Tint arbeitet dagegen.');
    });

    test('24dp-Flaeche mit quadratischem Viewport (Material-Vorgabe)', () {
      final attr = Map<String, String>.fromEntries(_attribute(vektor));
      expect(attr['android:width'], '24dp');
      expect(attr['android:height'], '24dp');
      expect(attr['android:viewportWidth'], attr['android:viewportHeight'],
          reason: 'ein nicht-quadratischer Viewport verzerrt die Marke, weil '
              'die Flaeche quadratisch bleibt.');
    });
  });
}
