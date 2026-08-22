// Mutation driver for G2 (docs/REVIEW-2026-08-08.md): deleting `.toLocal()`
// in logged_meal.dart:58, meal_totals.dart:23, trend_service.dart:123.
//
// `local_day_bucketing_test.dart` misses it: its meals are already local
// (`isUtc == false`), and `.toLocal()` on a local DateTime is the identity.
// In production `logged_at` arrives as UTC (`timestamptz`), which is where
// those three calls matter.
//
// A child process is needed because on a UTC machine `.toLocal()` is the
// identity for UTC values too, so no in-process input distinguishes the
// variants — and CI runs in UTC. Only the process's zone can be changed, so
// this test re-runs the probe with `TZ` set. The probe refuses to run at
// offset 0, so a silently ineffective zone cannot pass as green.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'wire_local_day_probe.dart' show zonenMarker;

const String _sondenPfad = 'test/wire_local_day_probe.dart';

/// POSIX `TZ` candidates with offset != 0, most robust first. `EST5EDT`
/// exists both as tzdata on Linux/macOS and as a POSIX rule in the Windows
/// CRT; the rest are plain POSIX rules without DST as fallbacks.
const List<String> _zonenKandidaten = <String>['EST5EDT', 'EST5', 'XXX-05'];

/// Path to the `flutter` launcher: `FLUTTER_ROOT` first, else walked up from
/// the running test executable.
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

  // Last resort: the bare name, resolved via PATH.
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
            // Keeps the child from waiting on the startup lock held by the
            // parent `flutter test`.
            'FLUTTER_ALREADY_LOCKED': 'true',
          },
          runInShell: Platform.isWindows,
        );
        final ausgabe = '${ergebnis.stdout}\n${ergebnis.stderr}';
        protokoll
          ..writeln('--- TZ=$zone (exit ${ergebnis.exitCode}) ---')
          ..writeln(ausgabe);

        // Zone did not take effect -> next candidate. A real failure carries
        // the marker and is reported below instead.
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
