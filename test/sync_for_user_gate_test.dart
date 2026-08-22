import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';

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
    expect(() => buildSyncForUser('user-1', allowPreview: false),
        throwsA(isA<Object>()),
        reason: 'sync == null heisst „bewusst ohne Backend" — ein Fehler '
            'heisst das nicht: er wuerde jeden Log des Nutzers still im RAM '
            'versanden lassen');
  });

  test('Debug/Test-Pfad: null bleibt fuer Widget-Tests erhalten', () {
    expect(buildSyncForUser('user-1', allowPreview: true), isNull);
  });
}
