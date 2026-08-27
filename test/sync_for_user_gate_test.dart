import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/services/crash_reporter.dart';

// Sentinel A2: `_syncFor` caught EVERY error and returned `null`, the state
// that otherwise means "test/preview, deliberately without backend". For a
// logged-in user the app then ran silently data-less — every log path ends in
// `if (s == null) return;`, so meals and weights lived only in RAM.
//
// New contract (like buildDefaultAuthRepository): the null convenience stays
// limited to debug/test. On the release path the error is thrown — visible via
// the global handlers and Sentry — instead of losing data silently.
//
// IMPORTANT: this file deliberately never calls Supabase.initialize().

void main() {
  test('Release-Pfad: ohne Supabase fliegt der Fehler statt sync == null',
      () {
    // The throw is only half the contract. `buildSyncForUser` CATCHES first,
    // reports to Sentry and rethrows only then — an unreported throw would
    // leave the release build failing invisibly. `debugSentrySink` sits
    // before the DSN gate and is called synchronously inside `capture`, so
    // the report is observable in the same turn as the throw.
    final meldungen = <String?>[];
    CrashReporter.debugSentrySink =
        (Object error, StackTrace stack, String? context) =>
            meldungen.add(context);
    addTearDown(() => CrashReporter.debugSentrySink = null);

    expect(() => buildSyncForUser('user-1', allowPreview: false),
        throwsA(isA<Object>()),
        reason: 'sync == null heisst „bewusst ohne Backend" — ein Fehler '
            'heisst das nicht: er wuerde jeden Log des Nutzers still im RAM '
            'versanden lassen');
    expect(meldungen, <String?>['sync-for-user'],
        reason: 'genau EINE Meldung unter diesem Kontext — ohne sie steht der '
            'Fehler in keinem Sentry-Issue, mit zweien zaehlt jeder Boot '
            'doppelt');
  });

  test('Debug/Test-Pfad meldet NICHT — sonst rauscht jeder Widget-Test in '
      'Sentry', () {
    final meldungen = <String?>[];
    CrashReporter.debugSentrySink =
        (Object error, StackTrace stack, String? context) =>
            meldungen.add(context);
    addTearDown(() => CrashReporter.debugSentrySink = null);

    expect(buildSyncForUser('user-1', allowPreview: true), isNull);
    expect(meldungen, isEmpty);
  });

  test('Debug/Test-Pfad: null bleibt fuer Widget-Tests erhalten', () {
    expect(buildSyncForUser('user-1', allowPreview: true), isNull);
  });
}
