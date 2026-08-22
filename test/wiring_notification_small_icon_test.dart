// Wiring guard for the notification small icon.
//
// Android evaluates ONLY the alpha channel of a small icon since API 21 and
// tints the result itself (minSdk is 26, so always). Pointing it at the fully
// opaque launcher bitmap produced a white square in the status bar — and no
// test or build reported it, because `getIdentifier` resolved the name fine.
//
// This file checks the COUPLING between Dart and Android resources: which
// name the Dart code hands the plugin, whether anything exists under it, and
// whether that satisfies the alpha-channel condition. Source and XML are
// stripped of comments first — the rationales quote the old value and
// `android:tint` verbatim, so a naive `contains` would read its own comment.
//
// It cannot prove that SystemUI draws the file; that needs a device test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _dienstPfad = 'lib/src/services/notification_service.dart';
const String _resWurzel = 'android/app/src/main/res';
const String _libWurzel = 'lib';
const String _pluginImport = 'flutter_local_notifications';

/// Bitmap extensions the resource merger accepts as a drawable. A file with
/// one of these and the same base name in a density-qualified folder would
/// displace the vector drawable on matching devices.
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

/// Dart source without comments. Without this the checks below would read the
/// rationale comment that still names the old value.
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

/// All Dart files under `lib/` that drive the notification plugin, discovered
/// dynamically so a NEW caller is covered automatically.
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

/// The argument of `AndroidInitializationSettings('...')` — the name the
/// plugin resolves via `Resources.getIdentifier`.
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

/// All attributes of the document as (name, value) pairs. Enough for the flat
/// structure of a VectorDrawable; `package:xml` is only a transitive
/// dependency and would need a pubspec entry.
List<MapEntry<String, String>> _attribute(String xml) =>
    <MapEntry<String, String>>[
      for (final a in _attributRegex.allMatches(xml))
        MapEntry(a.group(1)!, a.group(2)!),
    ];

/// Whether [wert] is pure white or fully transparent — the only two values
/// that keep the shape entirely in the alpha channel. Anything else is a
/// colored area that Android flattens into one tint.
bool _weissOderUnsichtbar(String wert) {
  if (wert == '@android:color/white') return true;
  final m = RegExp(r'^#([0-9a-fA-F]{3,8})$').firstMatch(wert);
  if (m == null) return false;
  var hex = m.group(1)!;
  // Normalise short forms to AARRGGBB.
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
        // Windows yields backslashes, CI slashes — split on both.
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
      // Counterpart to the first test: AndroidNotificationDetails.icon
      // overrides the default per notification, so a @mipmap there would be
      // the same finding in a different place.
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
