// WIRING GUARD D1/E1/E4 — the Android manifest.
//
// D1 (no scheduled notification ever fires on Android) is fixed by a single
// XML line that anyone could delete without a test noticing; the same holds
// for the `tools:node="remove"` lines from E1 (RECORD_AUDIO,
// READ/WRITE_EXTERNAL_STORAGE) and E4 (HealthDataSdkService).
//
// The guard reads the file that goes into the build and checks it
// STRUCTURALLY: XML comments stripped, elements and attributes parsed, so
// attribute order, line breaks and comment text are irrelevant. It cannot
// prove that Android delivers the broadcast — that needs a device test.
//
// The core of the file are the DART-TO-MANIFEST dependencies, which turn red
// when only the Dart side changes — exactly how D1 happened:
//
//   * `NotificationDetails.actions` / `dismissIsolate`  ->  ActionBroadcastReceiver
//   * `startForegroundService`                          ->  ForegroundService
//   * `AndroidScheduleMode.exact*` / `.alarmClock`      ->  SCHEDULE_EXACT_ALARM

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _manifestPfad = 'android/app/src/main/AndroidManifest.xml';

/// Every Dart file that can drive the notification plugin. Determined
/// dynamically rather than hardcoded, so a NEW caller automatically falls
/// under the dependency checks below.
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
// Minimal parser
//
// Deliberately without `package:xml`: it is only a transitive dependency and
// direct use would need a pubspec entry. The manifest section in question is
// flat enough for the 40 lines below.
// ---------------------------------------------------------------------------

/// A parsed XML element: attributes and, for containers, the unchanged inner
/// XML text.
class _Element {
  const _Element(this.attribute, this.inhalt);

  final Map<String, String> attribute;
  final String inhalt;

  String? operator [](String name) => attribute[name];

  /// `android:name` — the identity of practically every manifest element.
  String get name => attribute['android:name'] ?? '';
}

/// Strips XML comments; otherwise the test would mistake the manifest's
/// explanatory comments for declarations.
String _ohneKommentare(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

final RegExp _attributRegex =
    RegExp(r'([A-Za-z_][\w.:-]*)\s*=\s*"([^"]*)"');

/// Collects all elements with tag [tag] from [xml] (not recursing into
/// same-named children — the manifest has none).
List<_Element> _elemente(String xml, String tag) {
  final treffer = <_Element>[];
  final start = RegExp('<$tag(?=[\\s/>])');
  var pos = 0;
  while (true) {
    final m = start.firstMatch(xml.substring(pos));
    if (m == null) break;
    final tagStart = pos + m.start;

    // Find the end of the start tag, ignoring `>` inside attribute values.
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

/// Dart source without comments — an explanatory comment mentioning a symbol
/// would otherwise trigger the dependency check.
String _dartOhneKommentare(String quelle) => quelle
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((z) {
      final i = z.indexOf('//');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

/// All Dart files under `lib/` that import the notification plugin.
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
    // These three tests are the purpose of the file: they turn red when only
    // the Dart side changes, which is exactly how D1 happened.

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

      // Other direction: while scheduling stays inexact, the special
      // permission has no business in the manifest (Play policy review).
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

  group('P10-06 · Biometrie-Berechtigungen aus dem Merge', () {
    // androidx.biometric:1.1.0 kommt transitiv ueber
    // google_sign_in_android -> androidx.credentials herein und deklariert
    // beide Berechtigungen in seinem AAR-Manifest. Die App hat keinen
    // Biometrie-Pfad (kein local_auth, flutter_secure_storage ohne
    // setUserAuthenticationRequired), also weist der Play-Store sonst
    // Biometrie- und Fingerabdruck-Hardware aus, die nie benutzt wird.
    //
    // Gemessen am gemergten Release-Manifest (gradlew
    // :app:processReleaseMainManifest): mit den remove-Zeilen verschwinden
    // genau diese zwei Eintraege, alle anderen bleiben.
    for (final name in const <String>[
      'android.permission.USE_BIOMETRIC',
      'android.permission.USE_FINGERPRINT',
    ]) {
      test('$name wird per tools:node="remove" aus dem Merge genommen', () {
        final p = _mitNamen(berechtigungen, name);
        expect(p, isNotNull,
            reason: 'Ohne diese Zeile taucht $name wieder im gemergten '
                'Manifest auf, sobald jemand baut — die Herkunft ist eine '
                'transitive Abhaengigkeit, nicht dieses Manifest.');
        expect(p!['tools:node'], 'remove');
      });
    }

    test('es gibt weiterhin keinen Biometrie-Pfad im Dart-Code', () {
      // The other direction, same idea as the D1 dependency checks: wer
      // Biometrie NACHRUESTET (local_auth, BiometricPrompt ueber einen
      // eigenen Channel, setUserAuthenticationRequired in
      // flutter_secure_storage), braucht USE_BIOMETRIC wieder — und bekaeme
      // sonst eine SecurityException statt eines Prompts.
      final wurzel = Directory(_libWurzel);
      final treffer = <String>[];
      for (final e in wurzel.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final text = _dartOhneKommentare(e.readAsStringSync());
        if (text.contains('local_auth') ||
            text.contains('BiometricPrompt') ||
            text.contains('setUserAuthenticationRequired')) {
          treffer.add(e.path);
        }
      }
      expect(treffer, isEmpty,
          reason: 'Diese Dateien deuten auf einen Biometrie-Pfad hin; dann '
              'muessen die remove-Zeilen fuer USE_BIOMETRIC/USE_FINGERPRINT '
              'raus:\n${treffer.join('\n')}');
    });
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
