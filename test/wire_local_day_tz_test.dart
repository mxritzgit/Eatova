// Treiber fuer Schalter 4 aus docs/REVIEW-2026-08-08.md (G2):
// `.toLocal()` an drei Stellen loeschen (logged_meal.dart:58,
// meal_totals.dart:23, trend_service.dart:123).
//
// WARUM `local_day_bucketing_test.dart` DIESEN SCHALTER NICHT FAENGT
//
// Der bestehende Test baut seine Mahlzeiten mit `DateTime(2026, 6, 4, 23, 45)`
// — einem Wert, der bereits LOKAL ist (`isUtc == false`). `.toLocal()` auf
// einem lokalen DateTime ist per Definition die Identitaet. Der Test kann die
// Loeschung deshalb in KEINER Zeitzone sehen: er hat nie einen UTC-Wert in der
// Hand. Produktiv kommt `loggedAt`/`logged_at` aber genau als UTC-Instanz vom
// Server (`timestamptz` -> `2026-06-04T21:45:00Z`) — die drei `.toLocal()`
// sind die Stelle, an der daraus wieder Ortszeit wird.
//
// WARUM DIESER TEST EINEN KINDPROZESS BRAUCHT
//
// Auf einer UTC-Maschine ist `.toLocal()` auch fuer UTC-Werte die Identitaet:
// gleicher Instant, gleiche Wanduhr, gleicher Kalendertag. Es gibt dort
// nachweislich KEINEN Eingabewert, der die drei Stellen mit und ohne
// `.toLocal()` unterscheidet — alle drei muenden in `localDayKey`, das nur
// Jahr/Monat/Tag liest. Die CI laeuft in UTC. Ein in-process-Test waere dort
// also garantiert gruen, egal was in der Produktion steht.
//
// Der einzige portable Ausweg ist, die Zone des PROZESSES zu setzen. Deshalb
// startet dieser Test `flutter test test/wire_local_day_probe.dart` mit
// gesetztem `TZ` neu. Die Sonde weigert sich zu laufen, wenn der Offset dort
// 0 ist — eine stillschweigend wirkungslose Zonen-Setzung kann also nicht als
// gruen durchgehen.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'wire_local_day_probe.dart' show zonenMarker;

const String _sondenPfad = 'test/wire_local_day_probe.dart';

/// POSIX-`TZ`-Kandidaten mit Offset != 0, in der Reihenfolge der Robustheit.
/// `EST5EDT` liegt sowohl als tzdata-Datei auf Linux/macOS als auch als
/// POSIX-Regel im Windows-CRT vor (verifiziert: Offset -4 h im Juni). Die
/// weiteren sind reine POSIX-Regeln ohne Sommerzeit als Rueckfallebene.
const List<String> _zonenKandidaten = <String>['EST5EDT', 'EST5', 'XXX-05'];

/// Pfad zur `flutter`-Startdatei. Bevorzugt `FLUTTER_ROOT` (setzt das
/// flutter-Tool fuer seine Kindprozesse), sonst aus dem laufenden
/// Test-Executable hochgelaufen (`.../flutter/bin/cache/...`).
String? _flutterBinary() {
  final name = Platform.isWindows ? 'flutter.bat' : 'flutter';

  final ausUmgebung = Platform.environment['FLUTTER_ROOT'];
  if (ausUmgebung != null && ausUmgebung.isNotEmpty) {
    final kandidat = File('$ausUmgebung${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}$name');
    if (kandidat.existsSync()) return kandidat.path;
  }

  var verzeichnis = File(Platform.resolvedExecutable).parent;
  for (var tiefe = 0; tiefe < 10; tiefe++) {
    final kandidat = File('${verzeichnis.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}$name');
    if (kandidat.existsSync()) return kandidat.path;
    final eltern = verzeichnis.parent;
    if (eltern.path == verzeichnis.path) break;
    verzeichnis = eltern;
  }

  // Letzte Rueckfallebene: der blanke Name, aufgeloest ueber PATH.
  return name;
}

void main() {
  test(
    'Tages-Bucketing haelt in einer Zone ungleich UTC (Kindprozess mit TZ)',
    () async {
      expect(
        File(_sondenPfad).existsSync(),
        isTrue,
        reason: 'Sonde fehlt: $_sondenPfad (cwd: ${Directory.current.path})',
      );

      final flutter = _flutterBinary();
      expect(
        flutter,
        isNotNull,
        reason:
            'flutter-Startdatei nicht gefunden. FLUTTER_ROOT='
            '${Platform.environment['FLUTTER_ROOT']}, executable='
            '${Platform.resolvedExecutable}',
      );

      final protokoll = StringBuffer();
      for (final zone in _zonenKandidaten) {
        final ergebnis = await Process.run(
          flutter!,
          <String>['test', '--reporter=expanded', _sondenPfad],
          environment: <String, String>{
            'TZ': zone,
            // Verhindert, dass der Kindprozess auf das Startup-Lock des
            // laufenden `flutter test` wartet (das Lock haelt der Elternteil).
            'FLUTTER_ALREADY_LOCKED': 'true',
          },
          runInShell: Platform.isWindows,
        );
        final ausgabe = '${ergebnis.stdout}\n${ergebnis.stderr}';
        protokoll
          ..writeln('--- TZ=$zone (exit ${ergebnis.exitCode}) ---')
          ..writeln(ausgabe);

        // Die Zone hat nicht gegriffen -> naechster Kandidat. Ein FACHLICHER
        // Fehlschlag traegt den Marker und faellt deshalb NICHT in diesen
        // Zweig; er wird unten hart gemeldet.
        if (!ausgabe.contains(zonenMarker)) continue;

        expect(
          ergebnis.exitCode,
          0,
          reason:
              'Die Sonde ist in TZ=$zone rot geworden. Genau das passiert, '
              'wenn eines der drei `.toLocal()` fehlt.\n$protokoll',
        );
        expect(
          ausgabe,
          isNot(contains('offset=0:00')),
          reason: 'Die Sonde lief doch in UTC — sie belegt dann nichts.',
        );
        return;
      }

      fail(
        'Keiner der TZ-Kandidaten $_zonenKandidaten hat im Kindprozess einen '
        'Offset ungleich UTC ergeben — Schalter 4 ist auf dieser Maschine '
        'nicht pruefbar.\n$protokoll',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
