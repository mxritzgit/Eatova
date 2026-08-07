import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart'
    show kOutboxMaxAttempts;

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

  group('classifyOutboxFailure (Retry vs. endgueltig verwerfen)', () {
    // Achtung: PostgrestException hat KEIN statusCode-Feld. Der HTTP-Status
    // landet nur dann in `code`, wenn der Antwort-Body selbst keinen `code`
    // traegt — eine echte PostgREST-Fehlerantwort tut das aber immer. Eine
    // Check-Constraint-Verletzung kommt also als SQLSTATE an, NIE als '400'.
    PostgrestException pg(String code) =>
        PostgrestException(message: 'irgendwas Technisches', code: code);

    test('payload-determinierte Constraint-Fehler werden SOFORT verworfen',
        () {
      // 23514 check_violation — der reale Fall (z.B. kcal ausserhalb des
      // erlaubten Bereichs). Dieselben Bytes werden nie akzeptiert.
      expect(classifyOutboxFailure(pg('23514'), 0), OutboxVerdict.drop);
      // 23502 not_null_violation.
      expect(classifyOutboxFailure(pg('23502'), 0), OutboxVerdict.drop);
      // Klasse 22 (data exception), hier numeric_value_out_of_range.
      expect(classifyOutboxFailure(pg('22003'), 0), OutboxVerdict.drop);
      expect(classifyOutboxFailure(pg('22P02'), 0), OutboxVerdict.drop);
    });

    test('23503 (Fremdschluessel) bleibt retrybar — waehrend einer Migration '
        'bzw. eines Signup-Rennens ist das transient', () {
      expect(classifyOutboxFailure(pg('23503'), 0), OutboxVerdict.retryCounted);
    });

    test('500 verbrennt Versuche und faellt erst am Budget-Rand raus', () {
      expect(classifyOutboxFailure(pg('500'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('500'), kOutboxMaxAttempts - 2),
          OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('500'), kOutboxMaxAttempts - 1),
          OutboxVerdict.drop,
          reason: 'dieser Versuch ist der letzte des Budgets');
      expect(classifyOutboxFailure(pg('500'), kOutboxMaxAttempts + 99),
          OutboxVerdict.drop);
    });

    test('429/5xx sind retrybar, uebrige 4xx nicht', () {
      expect(classifyOutboxFailure(pg('429'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('503'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('502'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('404'), 0), OutboxVerdict.drop);
      expect(classifyOutboxFailure(pg('400'), 0), OutboxVerdict.drop);
      expect(classifyOutboxFailure(pg('422'), 0), OutboxVerdict.drop);
      // 401/403: fast immer ein abgelaufener Token, der Refresh heilt das.
      expect(classifyOutboxFailure(pg('401'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('403'), 0), OutboxVerdict.retryCounted);
    });

    test('42501 (RLS) und PGRST301 (JWT abgelaufen) sind retrybar', () {
      expect(classifyOutboxFailure(pg('42501'), 0), OutboxVerdict.retryCounted);
      expect(
          classifyOutboxFailure(pg('PGRST301'), 0), OutboxVerdict.retryCounted);
      // Andere PGRST-Codes beschreiben eine strukturell kaputte Anfrage.
      expect(classifyOutboxFailure(pg('PGRST204'), 0), OutboxVerdict.drop);
      expect(classifyOutboxFailure(pg('PGRST100'), 0), OutboxVerdict.drop);
    });

    test('transiente SQLSTATE-Klassen bleiben liegen', () {
      expect(classifyOutboxFailure(pg('08006'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('40001'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('53300'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('57P03'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('58030'), 0), OutboxVerdict.retryCounted);
    });

    test(
        'JEDER Netzwerkfehler ist retryFree — auch bei absurd vielen '
        'Versuchen (sonst wuerde ein Offline-Wochenende Daten vernichten)',
        () {
      final networkErrors = <Object>[
        const SocketException('host lookup failed'),
        const HttpException('connection closed'),
        TimeoutException('timeout', const Duration(seconds: 8)),
        http.ClientException('offline'),
        AuthRetryableFetchException(),
      ];
      for (final error in networkErrors) {
        expect(classifyOutboxFailure(error, 0), OutboxVerdict.retryFree,
            reason: '$error');
        expect(classifyOutboxFailure(error, 999), OutboxVerdict.retryFree,
            reason: '$error darf das Budget nie verbrennen');
      }
    });

    test('unbekannter Code / unbekannter Typ -> behalten (retryCounted)', () {
      expect(classifyOutboxFailure(pg('99999'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg(''), 0), OutboxVerdict.retryCounted);
      expect(
          classifyOutboxFailure(
              const PostgrestException(message: 'ohne code'), 0),
          OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(StateError('bug'), 0),
          OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(const FormatException('kaputt'), 0),
          OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(const AuthException('invalid login'), 0),
          OutboxVerdict.retryCounted);
    });
  });

  group('outboxLossHint (endgueltiger Verlust)', () {
    test('sagt es klar, leakt aber nichts Technisches', () {
      expect(outboxLossHint, isNotEmpty);
      for (final leak in const <String>[
        '23514',
        'logged_meals',
        'check constraint',
        'PostgrestException',
        'PGRST',
        'SQLSTATE',
        'Sync (',
      ]) {
        expect(outboxLossHint, isNot(contains(leak)));
      }
    });
  });
}
