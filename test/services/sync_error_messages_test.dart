import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/sync_error_messages.dart';

// Pures Fehlertext-Mapping fuer Sync-/Profil-Fehler: Netzwerkfehler werden als
// solche erkannt (-> ehrlicher Offline-Hinweis), alles andere bekommt eine
// freundliche deutsche Meldung OHNE Exception-Details. Wichtigste Invariante:
// KEIN Mapping-Ergebnis enthaelt jemals Roh-Text der Exception (Postgres-
// Codes, Tabellennamen, Constraint-Namen — Schema-Leakage im UI).

void main() {
  group('isNetworkSyncError', () {
    test('erkennt die real ankommenden Netzwerk-Fehlertypen', () {
      expect(isNetworkSyncError(const SocketException('host lookup failed')),
          isTrue);
      expect(isNetworkSyncError(const HttpException('connection closed')),
          isTrue);
      expect(isNetworkSyncError(TimeoutException('timeout', const Duration(seconds: 8))),
          isTrue);
      // package:http (IOClient) wickelt Socket-Fehler in ClientException —
      // derselbe Typ, den der MockClient der Store-Tests offline wirft.
      expect(isNetworkSyncError(http.ClientException('offline')), isTrue);
      // gotrues "retryable fetch"-Huelle fuer Netzfehler im Auth-Stack.
      expect(isNetworkSyncError(AuthRetryableFetchException()), isTrue);
    });

    test('Server-Fehler und Programmfehler sind KEINE Netzwerk-Fehler', () {
      // Postgrest-500/Constraint: der Server war erreichbar — "Offline" waere
      // gelogen, und der Fehler verschwindet nicht von selbst.
      expect(
        isNetworkSyncError(const PostgrestException(
          message: 'duplicate key value violates unique constraint '
              '"logged_meals_pkey"',
          code: '23505',
        )),
        isFalse,
      );
      expect(isNetworkSyncError(const AuthException('invalid login')), isFalse);
      expect(isNetworkSyncError(StateError('bug')), isFalse);
      expect(isNetworkSyncError(const FormatException('kaputtes JSON')),
          isFalse);
      expect(isNetworkSyncError('nur ein String'), isFalse);
    });
  });

  group('queuedSyncHint (Outbox-Writes, Auto-Retry laeuft)', () {
    test('Netzwerkfehler -> dezenter Offline-Hinweis', () {
      expect(
        queuedSyncHint(const SocketException('offline')),
        'Offline — wird synchronisiert, sobald du wieder online bist.',
      );
    });

    test('Nicht-Netzwerk-Fehler -> freundliche Retry-Meldung ohne Details',
        () {
      const error = PostgrestException(
        message: 'insert into "logged_meals" violates check constraint',
        code: 'PGRST301',
      );
      final hint = queuedSyncHint(error);
      expect(hint,
          'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.');
      // Schema-Leakage-Guard: nichts vom Roh-Fehler darf durchsickern.
      expect(hint, isNot(contains('logged_meals')));
      expect(hint, isNot(contains('PGRST')));
      expect(hint, isNot(contains('Exception')));
    });

    test('null (Op hinter pendender Op eingereiht) -> Retry-Meldung', () {
      expect(
        queuedSyncHint(null),
        'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.',
      );
    });
  });

  group('profileSyncErrorMessage (kein Auto-Retry)', () {
    test('unterscheidet Offline von Sonstigem, nie Roh-Details', () {
      expect(
        profileSyncErrorMessage(http.ClientException('offline')),
        'Offline — Profil konnte nicht synchronisiert werden. Bitte speichere es später erneut.',
      );
      const error = PostgrestException(
          message: 'null value in column "daily_kcal_goal"');
      final msg = profileSyncErrorMessage(error);
      expect(msg,
          'Profil konnte nicht gespeichert werden. Bitte versuch es später erneut.');
      expect(msg, isNot(contains('daily_kcal_goal')));
    });
  });

  group('directSyncErrorMessage (z.B. Konto-Löschung)', () {
    test('unterscheidet Offline von Sonstigem, nie Roh-Details', () {
      expect(
        directSyncErrorMessage(const SocketException('offline')),
        'Offline — das hat gerade nicht geklappt. Bitte versuch es mit Internetverbindung erneut.',
      );
      const error =
          PostgrestException(message: 'permission denied for table profiles');
      final msg = directSyncErrorMessage(error);
      expect(msg, 'Das hat gerade nicht geklappt. Bitte versuch es später erneut.');
      expect(msg, isNot(contains('profiles')));
      expect(msg, isNot(contains('permission')));
    });
  });
}
