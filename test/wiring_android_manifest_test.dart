// VERDRAHTUNGS-WAECHTER D1/E1/E4 — das Android-Manifest.
//
// Ausgangslage (Verifizierer V2/V3): ueber alle 107 Testdateien null Treffer
// fuer `manifest`, `gradle`, `signing`, `proguard`; `ScheduledNotificationReceiver`
// kommt in `test/`, `tool/` und den CI-Workflows NULL Mal vor. D1 war ein
// 🔴-CRITICAL — „auf jedem Android-Geraet, an jedem Tag feuert keine geplante
// Benachrichtigung" — und sein Fix ist eine einzelne XML-Zeile, die jeder
// loeschen kann, ohne dass ein Test es merkt. Dasselbe gilt fuer die
// `tools:node="remove"`-Zeilen aus E1 (RECORD_AUDIO, READ/WRITE_EXTERNAL_STORAGE)
// und E4 (HealthDataSdkService).
//
// WAS DIESE DATEI IST UND WAS NICHT
//
// Sie liest die Datei, die in den Build geht, und prueft sie STRUKTURELL:
// XML-Kommentare werden entfernt, Elemente und Attribute werden geparst.
// Attribut-Reihenfolge, Zeilenumbrueche, Einrueckung und Kommentartext sind
// dem Waechter deshalb egal — nur das tatsaechlich deklarierte Manifest zaehlt.
// Was er NICHT kann: beweisen, dass Android den Broadcast zustellt. Dafuer
// braeuchte es einen instrumentierten Geraetetest.
//
// EINSTUFUNG: mittel. Kein Quelltext-`contains` ueber eine Zeile (er ueberlebt
// jede Umformatierung), aber auch keine Wirkungspruefung — er prueft ein
// Build-Artefakt, nicht Laufzeitverhalten.
//
// DER TEIL, DER MEHR IST ALS EINE ZEILENPRUEFUNG
//
// Vier Behauptungen sind ABHAENGIGKEITEN ZWISCHEN DART UND MANIFEST. Sie
// werden rot, wenn jemand NUR die Dart-Seite aendert — genau das Versagen,
// das D1 war:
//
//   * `NotificationDetails.actions` / `dismissIsolate`  ->  ActionBroadcastReceiver
//   * `startForegroundService`                          ->  ForegroundService
//   * `AndroidScheduleMode.exact*` / `.alarmClock`      ->  SCHEDULE_EXACT_ALARM
//
// Welle 4 hat die ersten beiden Komponenten als „nach aktuellem Dart-Code
// unerreichbar" eingestuft und deshalb weggelassen. Diese Einstufung ist eine
// Aussage ueber den Dart-Code — also gehoert sie hier gegen den Dart-Code
// geprueft, nicht als Kommentar ins Manifest.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _manifestPfad = 'android/app/src/main/AndroidManifest.xml';

/// Jede Dart-Datei, die das Notification-Plugin ueberhaupt ansteuern kann.
/// Bewusst dynamisch ermittelt statt fest verdrahtet: ein NEUER Aufrufer
/// (z. B. ein zweiter Service mit Notification-Actions) faellt damit
/// automatisch unter die Abhaengigkeitspruefung unten.
const String _libWurzel = 'lib';
const String _pluginImport = 'flutter_local_notifications';

const String _receiverGeplant =
    'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver';
const String _receiverBoot =
    'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver';
const String _receiverAction =
    'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver';
const String _serviceForeground =
    'com.dexterous.flutterlocalnotifications.ForegroundService';
const String _serviceHealthSdk =
    'androidx.health.platform.client.impl.sdkservice.HealthDataSdkService';

// ---------------------------------------------------------------------------
// Minimal-Parser
//
// Bewusst ohne `package:xml`: das Paket ist nur transitiv aufgeloest, eine
// direkte Nutzung braeuchte einen Eintrag in pubspec.yaml — und diese Runde
// darf keine Produktionsdatei anfassen. Der Manifest-Ausschnitt, um den es
// geht, ist flach genug fuer die 40 Zeilen hier.
// ---------------------------------------------------------------------------

/// Ein geparstes XML-Element: Attribute und (bei Container-Elementen) der
/// unveraenderte innere XML-Text.
class _Element {
  const _Element(this.attribute, this.inhalt);

  final Map<String, String> attribute;
  final String inhalt;

  String? operator [](String name) => attribute[name];

  /// `android:name` — bei praktisch jedem Manifest-Element die Identitaet.
  String get name => attribute['android:name'] ?? '';
}

/// Entfernt XML-Kommentare. Ohne diesen Schritt wuerde der Test die
/// ausfuehrlichen Begruendungs-Kommentare im Manifest fuer Deklarationen
/// halten — und genau die Zeilen, die er absichern soll, aus dem Kommentar
/// darueber „lesen".
String _ohneKommentare(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

final RegExp _attributRegex =
    RegExp(r'([A-Za-z_][\w.:-]*)\s*=\s*"([^"]*)"');

/// Sammelt alle Elemente mit dem Tag [tag] aus [xml] (nicht rekursiv in
/// gleichnamige Kinder hinein — im Manifest gibt es die nicht).
List<_Element> _elemente(String xml, String tag) {
  final treffer = <_Element>[];
  final start = RegExp('<$tag(?=[\\s/>])');
  var pos = 0;
  while (true) {
    final m = start.firstMatch(xml.substring(pos));
    if (m == null) break;
    final tagStart = pos + m.start;

    // Ende des Start-Tags suchen, `>` innerhalb von Attributwerten ignorieren.
    var i = tagStart + tag.length + 1;
    var inString = false;
    while (i < xml.length) {
      final c = xml[i];
      if (c == '"') {
        inString = !inString;
      } else if (c == '>' && !inString) {
        break;
      }
      i++;
    }
    if (i >= xml.length) break;

    final kopf = xml.substring(tagStart, i);
    final selbstschliessend = kopf.trimRight().endsWith('/');
    final attribute = <String, String>{
      for (final a in _attributRegex.allMatches(kopf))
        a.group(1)!: a.group(2)!,
    };

    var inhalt = '';
    var weiter = i + 1;
    if (!selbstschliessend) {
      final ende = xml.indexOf('</$tag>', i);
      if (ende >= 0) {
        inhalt = xml.substring(i + 1, ende);
        weiter = ende + tag.length + 3;
      }
    }
    treffer.add(_Element(attribute, inhalt));
    pos = weiter;
  }
  return treffer;
}

_Element? _mitNamen(List<_Element> elemente, String name) {
  for (final e in elemente) {
    if (e.name == name) return e;
  }
  return null;
}

String _lies(String pfad) {
  final datei = File(pfad);
  if (!datei.existsSync()) {
    fail('$pfad fehlt (aufgeloest von ${Directory.current.path})');
  }
  return datei.readAsStringSync();
}

/// Dart-Quelltext ohne Kommentare — sonst wuerde ein erklaerender Kommentar
/// („actions: setzen wir bewusst nicht") die Abhaengigkeitspruefung ausloesen.
String _dartOhneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

/// Alle Dart-Dateien unter `lib/`, die das Notification-Plugin importieren.
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

bool _irgendwo(List<String> quellen, Pattern muster) =>
    quellen.any((q) => q.contains(muster));

void main() {
  late String manifest;
  late _Element application;
  late List<_Element> receivers;
  late List<_Element> services;
  late List<_Element> berechtigungen;
  late List<String> notificationQuellen;

  setUpAll(() {
    manifest = _ohneKommentare(_lies(_manifestPfad));
    final apps = _elemente(manifest, 'application');
    expect(apps, hasLength(1), reason: 'genau ein <application>-Element');
    application = apps.single;
    receivers = _elemente(application.inhalt, 'receiver');
    services = _elemente(application.inhalt, 'service');
    berechtigungen = _elemente(manifest, 'uses-permission');
    notificationQuellen = _notificationQuellen();
  });

  test('der tools-Namensraum ist deklariert (sonst ist jedes tools:node inert)',
      () {
    final wurzel = _elemente(manifest, 'manifest');
    expect(wurzel, hasLength(1));
    expect(wurzel.single['xmlns:tools'], 'http://schemas.android.com/tools',
        reason: 'ohne diese Deklaration ignoriert der Manifest-Merger die '
            'tools:node="remove"-Zeilen aus E1 und E4 kommentarlos.');
  });

  group('D1 · geplante Benachrichtigungen', () {
    test(
        'ScheduledNotificationReceiver ist deklariert — sonst verwirft Android '
        'JEDEN geplanten Alarm still', () {
      final r = _mitNamen(receivers, _receiverGeplant);
      expect(r, isNotNull,
          reason: 'flutter_local_notifications-22.2.0 liefert KEINE '
              'Komponenten mit (sein Plugin-Manifest hat null Receiver). Ohne '
              'diese Deklaration ist das Ziel jedes zonedSchedule-Alarms '
              '(FlutterLocalNotificationsPlugin.java:590/613/639/721) '
              'unbekannt: kein Crash, keine Benachrichtigung, nie.');
      expect(r!['android:exported'], 'false',
          reason: 'der Receiver wird ausschliesslich vom eigenen AlarmManager-'
              'PendingIntent angesteuert; exported=true machte ihn zum '
              'Fremd-Trigger.');
    });

    test(
        'ScheduledNotificationBootReceiver plant nach einem Neustart neu ein',
        () {
      final r = _mitNamen(receivers, _receiverBoot);
      expect(r, isNotNull,
          reason: 'ohne ihn sind nach jedem Geraete-Neustart alle geplanten '
              'Nudges weg — dieselbe stille Klasse wie D1.');
      expect(r!['android:exported'], 'false');
      final aktionen = _elemente(r.inhalt, 'action').map((a) => a.name);
      expect(aktionen, contains('android.intent.action.BOOT_COMPLETED'),
          reason: 'ohne diesen Intent-Filter triggert der Receiver nie.');
      expect(aktionen, contains('android.intent.action.MY_PACKAGE_REPLACED'),
          reason: 'sonst sind die Nudges nach jedem App-Update weg.');
      expect(berechtigungen.map((p) => p.name),
          contains('android.permission.RECEIVE_BOOT_COMPLETED'),
          reason: 'ohne die Berechtigung stellt Android BOOT_COMPLETED nicht '
              'zu — der Receiver oben waere dann Dekoration.');
    });

    test('POST_NOTIFICATIONS ist deklariert (Android 13+)', () {
      final p = _mitNamen(
          berechtigungen, 'android.permission.POST_NOTIFICATIONS');
      expect(p, isNotNull,
          reason: 'ohne sie kann die App auf Android 13+ den '
              'Runtime-Permission-Dialog nicht ausloesen und zeigt nie eine '
              'Benachrichtigung an.');
      expect(p!['tools:node'], isNull,
          reason: 'die Berechtigung darf nicht wegoptimiert werden.');
    });
  });

  group('D1 · Abhaengigkeit zwischen Dart-Code und Manifest', () {
    // Diese drei Tests sind der eigentliche Zweck der Datei: sie werden rot,
    // wenn jemand NUR die Dart-Seite aendert. Genau so ist D1 entstanden.

    test(
        'wer Notification-Actions oder dismissIsolate nachruestet, MUSS '
        'ActionBroadcastReceiver deklarieren', () {
      final nutztActions = _irgendwo(notificationQuellen, 'actions:') ||
          _irgendwo(notificationQuellen, 'dismissIsolate');
      final deklariert = _mitNamen(receivers, _receiverAction) != null;

      expect(!nutztActions || deklariert, isTrue,
          reason: 'Der Dart-Code steuert jetzt Notification-Actions bzw. '
              'dismissIsolate an (FlutterLocalNotificationsPlugin.java:303/333). '
              'Ohne <receiver android:name="$_receiverAction" '
              'android:exported="false" /> im <application>-Block schlaegt das '
              'genauso still fehl wie D1: der Tap auf die Action tut nichts.');

      if (deklariert) {
        expect(_mitNamen(receivers, _receiverAction)!['android:exported'],
            'false');
      }
    });

    test(
        'wer startForegroundService nachruestet, MUSS ForegroundService '
        'deklarieren', () {
      final nutztVordergrund =
          _irgendwo(notificationQuellen, 'startForegroundService');
      final deklariert = _mitNamen(services, _serviceForeground) != null;

      expect(!nutztVordergrund || deklariert, isTrue,
          reason: 'Der Dart-Code ruft jetzt startForegroundService '
              '(FlutterLocalNotificationsPlugin.java:2342/2364). Ohne '
              '<service android:name="$_serviceForeground" /> wirft Android '
              'beim Start eine ClassNotFoundException bzw. tut nichts.');
    });

    test(
        'wer auf exakte Alarme umstellt, MUSS SCHEDULE_EXACT_ALARM/'
        'USE_EXACT_ALARM deklarieren', () {
      final nutztExakt = _irgendwo(
              notificationQuellen, RegExp(r'AndroidScheduleMode\.exact')) ||
          _irgendwo(
              notificationQuellen, RegExp(r'AndroidScheduleMode\.alarmClock'));
      final namen = berechtigungen.map((p) => p.name).toSet();
      final deklariert = namen.contains('android.permission.SCHEDULE_EXACT_ALARM') ||
          namen.contains('android.permission.USE_EXACT_ALARM');

      expect(!nutztExakt || deklariert, isTrue,
          reason: 'Der Planner nutzt jetzt einen EXAKTEN Alarm-Modus. Ohne die '
              'passende Berechtigung wirft setExactAndAllowWhileIdle auf '
              'Android 12+ eine SecurityException bzw. der Alarm feuert nie — '
              'und die Play-Policy-Sonderpruefung fuer exakte Alarme kommt '
              'ohnehin dazu.');

      // Gegenrichtung: solange inexakt geplant wird, hat die Sonder-
      // Berechtigung nichts im Manifest verloren (Play-Policy-Pruefung).
      if (!nutztExakt) {
        expect(deklariert, isFalse,
            reason: 'inexakte Planung braucht keine Exact-Alarm-Berechtigung; '
                'sie ausweisen zu muessen kostet nur die Play-Sonderpruefung.');
      }
    });
  });

  group('E1 · Berechtigungen, die Plugins mitbringen und Eatova nicht braucht',
      () {
    for (final name in const <String>[
      'android.permission.RECORD_AUDIO',
      'android.permission.WRITE_EXTERNAL_STORAGE',
      'android.permission.READ_EXTERNAL_STORAGE',
    ]) {
      test('$name wird per tools:node="remove" aus dem Merge genommen', () {
        final p = _mitNamen(berechtigungen, name);
        expect(p, isNotNull,
            reason: 'camera_android_camerax deklariert RECORD_AUDIO und '
                'WRITE_EXTERNAL_STORAGE fuer die Video-Aufnahme; aus letzterer '
                'leitet der Merger READ_EXTERNAL_STORAGE OHNE maxSdkVersion ab '
                '(API 29-32: echte Laufzeitberechtigung). Eatova nimmt nur '
                'Standbilder auf. Ohne die remove-Zeile weist der Play-Store '
                'Mikrofon- bzw. Speicherzugriff aus.');
        expect(p!['tools:node'], 'remove');
      });
    }
  });

  group('E4 · exportierte Komponenten', () {
    test('HealthDataSdkService wird aus dem Merge genommen', () {
      final s = _mitNamen(services, _serviceHealthSdk);
      expect(s, isNotNull,
          reason: 'androidx.health.connect:connect-client injiziert diesen '
              'Dienst mit android:exported="true" OHNE android:permission. '
              'Health Connect ist auf Android unerreichbar (jede Methode in '
              'apple_health_service.dart steigt mit `if (!Platform.isIOS) '
              'return` aus) — der Dienst hat keinen Aufrufer.');
      expect(s!['tools:node'], 'remove');
    });

    test(
        'ausser der Launcher-Activity ist KEINE Komponente exportiert '
        '(die Invariante hinter E4)', () {
      final komponenten = <_Element>[
        ..._elemente(application.inhalt, 'activity'),
        ..._elemente(application.inhalt, 'activity-alias'),
        ...services,
        ...receivers,
        ..._elemente(application.inhalt, 'provider'),
      ];
      final exportiert = komponenten
          .where((k) => k['tools:node'] != 'remove')
          .where((k) => k['android:exported'] == 'true')
          .where((k) => k['android:permission'] == null)
          .map((k) => k.name)
          .toList();

      expect(exportiert, ['.MainActivity'],
          reason: 'Jede weitere ungeschuetzt exportierte Komponente ist eine '
              'von aussen ansteuerbare Flaeche. Kommt hier etwas dazu, war es '
              'entweder ein Versehen oder es braucht ein android:permission.');
    });
  });
}
