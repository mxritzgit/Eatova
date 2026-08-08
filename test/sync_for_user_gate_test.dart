import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';

// Sentinel-Rest A2 (Sweep 2026-08-08): `_syncFor` fing JEDEN Fehler und gab
// `null` zurueck — den Zustand, der sonst „Test/Preview, absichtlich ohne
// Backend" bedeutet. Fuer einen EINGELOGGTEN Nutzer laeuft die App damit
// still im Datenlos-Modus: kein LocalCache, kein Server-Load, keine Outbox;
// jeder Log-Pfad endet in `if (s == null) return;`. Mahlzeiten und Gewichte
// leben nur im RAM und sind beim Neustart weg — ohne jede Meldung.
//
// Neuer Vertrag (Muster von buildDefaultAuthRepository): der null-Komfort
// bleibt auf Debug/Test beschraenkt. Im Release-Pfad fliegt der Fehler —
// sichtbar via globale Handler + Sentry — statt still Daten zu verlieren.
//
// WICHTIG: dieses File ruft bewusst NIE Supabase.initialize().

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
