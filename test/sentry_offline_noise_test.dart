import 'dart:io';

import 'package:http/http.dart' show ClientException;

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

// Befund aus dem Sentry-Feed (2026-08-10): Drei Issues „SanitizedError:
// _ClientSocketException" innerhalb einer halben Stunde, alle vom Geraet des
// Nutzers, alle aus demselben Pfad — RecipeDetailScreen._add ->
// addResultToDailyTotal -> _syncOrQueue -> MealsSync.insertLoggedMeal ->
// postgrest -> Socket weg.
//
// Entstanden beim Testen im FLUGMODUS. Also genau der Fall, fuer den die App
// seit heute eine Warteschlange hat: der Write ist eingereiht, der Nutzer ist
// informiert, nichts ist verloren. Ein Sentry-Issue mit Prioritaet „hoch"
// behauptet das Gegenteil.
//
// Die Folge waere nicht nur Laerm: Wer in der U-Bahn eine Mahlzeit eintraegt,
// erzeugt einen Crash-Report. Bei genug Nutzern verschwinden echte Fehler
// zwischen Tausenden erwarteter Netzausfaelle — und das Sentry-Kontingent ist
// verbraucht, bevor der erste echte Absturz ankommt.
//
// Regel, die diese Tests festhalten: **Ein reiner Netzfehler auf dem
// Sync-Pfad geht NICHT an Sentry. Alles andere schon.**

void main() {
  final gemeldet = <Object>[];

  setUp(() {
    gemeldet.clear();
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
    };
  });

  tearDown(() => CrashReporter.debugSentrySink = null);

  group('Netzfehler sind kein Crash', () {
    test('ein SocketException aus dem Sync-Pfad geht NICHT an Sentry',
        () async {
      // Genau der Fehler aus dem Feed: der Socket bricht weg, waehrend
      // PostgREST schreibt.
      await CrashReporter.captureSyncFailure(
        const SocketException('Connection failed'),
        StackTrace.current,
        context: 'meal-insert',
      );

      expect(gemeldet, isEmpty,
          reason: 'die Op liegt in der Warteschlange — das ist kein Vorfall');
    });

    test('auch ein ClientException (http-Paket) zaehlt als Netzfehler',
        () async {
      // Der Klassifizierer prueft TYPEN, nicht Meldungstexte — deshalb hier
      // der echte Typ aus package:http und keine Exception mit passendem Text.
      await CrashReporter.captureSyncFailure(
        ClientException('Failed host lookup'),
        StackTrace.current,
        context: 'recipe-upsert',
      );

      expect(gemeldet, isEmpty);
    });

    test('ein ECHTER Serverfehler geht weiterhin an Sentry', () async {
      // 500er, Constraint-Verletzungen, kaputte Antworten: dort liegt ein
      // Fehler VOR, den niemand sonst bemerkt.
      await CrashReporter.captureSyncFailure(
        Exception('PostgrestException: 42501 permission denied'),
        StackTrace.current,
        context: 'meal-insert',
      );

      // Die Senke bekommt bewusst den SANITISIERTEN Fehler, nie das rohe
      // Objekt (es koennte eine halbe profiles-Zeile mitschleppen) — geprueft
      // wird deshalb, DASS gemeldet wurde, nicht die Identitaet.
      expect(gemeldet, hasLength(1));
    });

    test('die Klassifizierung ist dieselbe wie fuer die Nutzer-Meldung', () {
      // Ein zweiter Schwellenwert waere ein zweiter Ort zum Auseinanderlaufen:
      // Was dem Nutzer als „Offline" erklaert wird, darf Sentry nicht als
      // Vorfall sehen — und umgekehrt.
      expect(isNetworkSyncError(const SocketException('x')), isTrue);
      expect(
        isNetworkSyncError(Exception('PostgrestException: 42501')),
        isFalse,
      );
    });
  });

  test('capture() selbst bleibt unveraendert — es meldet ALLES', () async {
    // Der allgemeine Weg ist nicht betroffen: ein Netzfehler ausserhalb des
    // Sync-Pfads (z. B. beim Bildupload) kann sehr wohl ein Vorfall sein.
    await CrashReporter.capture(
      const SocketException('Connection failed'),
      StackTrace.current,
      context: 'irgendwas-anderes',
    );

    expect(gemeldet, hasLength(1));
  });
}
