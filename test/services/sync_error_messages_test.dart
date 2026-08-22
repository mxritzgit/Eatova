import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart'
    show SyncOpKind, kOutboxMaxAttempts, kOutboxDeleteMaxAttempts;

// Pure error-text mapping for sync/profile errors: network errors get an
// honest offline hint, everything else a friendly message. Key invariant: no
// result ever leaks raw exception text (codes, table or constraint names).

void main() {
  group('isNetworkSyncError', () {
    test('erkennt die real ankommenden Netzwerk-Fehlertypen', () {
      expect(isNetworkSyncError(const SocketException('host lookup failed')),
          isTrue);
      expect(isNetworkSyncError(const HttpException('connection closed')),
          isTrue);
      expect(isNetworkSyncError(TimeoutException('timeout', const Duration(seconds: 8))),
          isTrue);
      // package:http wraps socket errors in ClientException.
      expect(isNetworkSyncError(http.ClientException('offline')), isTrue);
      // gotrue's "retryable fetch" wrapper for auth-stack network errors.
      expect(isNetworkSyncError(AuthRetryableFetchException()), isTrue);
    });

    test(
        'TLS-Fehler sind Netzfehler — Captive Portal / MITM-Proxy erreichen '
        'den Server NIE', () {
      // TlsException is none of the types above, and package:http only wraps
      // SocketException/HttpException, so without this arm
      // CERTIFICATE_VERIFY_FAILED arrives unclassified and burns the budget.
      expect(
        isNetworkSyncError(
            const HandshakeException('Handshake error in client')),
        isTrue,
      );
      expect(
        isNetworkSyncError(
            const TlsException('CERTIFICATE_VERIFY_FAILED(ssl_client.cc)')),
        isTrue,
      );
      expect(isNetworkSyncError(const CertificateException('bad certificate')),
          isTrue);
    });

    test('Server-Fehler und Programmfehler sind KEINE Netzwerk-Fehler', () {
      // The server was reachable, so "offline" would be a lie.
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
      // Schema leakage guard: nothing from the raw error may seep through.
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

  group('Profil-Save haengt seit Luecke D am Outbox-Netz', () {
    // The profile save goes through the outbox, so a "save it again later"
    // message would be wrong: there is an auto-retry.
    test('offline -> derselbe Warteschlangen-Hinweis wie jeder andere Write',
        () {
      expect(
        queuedSyncHint(http.ClientException('offline')),
        'Offline — wird synchronisiert, sobald du wieder online bist.',
      );
    });

    test('Server-Fehler -> neutrale Retry-Meldung ohne Spaltennamen', () {
      const error = PostgrestException(
          message: 'null value in column "daily_kcal_goal"');
      final msg = queuedSyncHint(error);
      expect(msg,
          'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.');
      expect(msg, isNot(contains('daily_kcal_goal')));
      expect(msg, isNot(contains('Bitte speichere es später erneut')),
          reason: 'das waere gelogen — die Outbox versucht es selbst erneut');
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
    // PostgrestException has NO statusCode field: the HTTP status only lands
    // in `code` when the body has none, which a real PostgREST error always
    // does — so a check-constraint violation arrives as SQLSTATE, never '400'.
    PostgrestException pg(String code) =>
        PostgrestException(message: 'irgendwas Technisches', code: code);

    test('payload-determinierte Constraint-Fehler werden SOFORT verworfen',
        () {
      // 23502 not_null_violation — no user input produces this.
      expect(classifyOutboxFailure(pg('23502'), 0), OutboxVerdict.drop);
      // Class 22 (data exception), here numeric_value_out_of_range.
      expect(classifyOutboxFailure(pg('22003'), 0), OutboxVerdict.drop);
      expect(classifyOutboxFailure(pg('22P02'), 0), OutboxVerdict.drop);
    });

    test(
        '23514 (Check-Constraint) ist KEIN Sofort-Verwurf — das ist der '
        'Normalfall einer Nutzereingabe, nicht korrupte Daten', () {
      // "75,5" in the weight field (-> 755 kg) is reproducible user input,
      // and the correction window the attempts reset is built on.
      expect(classifyOutboxFailure(pg('23514'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('23514'), kOutboxMaxAttempts - 2),
          OutboxVerdict.retryCounted);
      // The budget stays the emergency brake: not even a 23514 loops forever.
      expect(classifyOutboxFailure(pg('23514'), kOutboxMaxAttempts - 1),
          OutboxVerdict.drop);
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
      // 401/403: almost always an expired token, which the refresh heals.
      expect(classifyOutboxFailure(pg('401'), 0), OutboxVerdict.retryCounted);
      expect(classifyOutboxFailure(pg('403'), 0), OutboxVerdict.retryCounted);
    });

    test('42501 (RLS) und PGRST301 (JWT abgelaufen) sind retrybar', () {
      expect(classifyOutboxFailure(pg('42501'), 0), OutboxVerdict.retryCounted);
      expect(
          classifyOutboxFailure(pg('PGRST301'), 0), OutboxVerdict.retryCounted);
      // Other PGRST codes describe a structurally broken request.
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
        // TLS family: the device never reached the server at all.
        const HandshakeException('Handshake error in client'),
        const TlsException('CERTIFICATE_VERIFY_FAILED(ssl_client.cc)'),
        const CertificateException('bad certificate'),
      ];
      for (final error in networkErrors) {
        expect(classifyOutboxFailure(error, 0), OutboxVerdict.retryFree,
            reason: '$error');
        expect(classifyOutboxFailure(error, 999), OutboxVerdict.retryFree,
            reason: '$error darf das Budget nie verbrennen');
      }
    });

    test(
        'Delete-Ops sterben nicht am SCHREIB-Budget — ein verworfener Delete '
        'holt die geloeschte Mahlzeit vom Server zurueck', () {
      // A dropped delete leaves the server row, so the next cold start counts
      // the meal again. Deletes are idempotent, hence their own budget.
      for (final kind in const <SyncOpKind>[
        SyncOpKind.mealDelete,
        SyncOpKind.favoriteDelete,
        SyncOpKind.recipeDelete,
      ]) {
        expect(
            classifyOutboxFailure(pg('500'), kOutboxMaxAttempts * 4,
                kind: kind),
            OutboxVerdict.retryCounted,
            reason: '${kind.name} weit jenseits des SCHREIB-Budgets');
        expect(
            classifyOutboxFailure(pg('23503'), kOutboxMaxAttempts - 1,
                kind: kind),
            OutboxVerdict.retryCounted,
            reason: '${kind.name} am Schreib-Budget-Rand');
      }

      // Counter-check: write ops still run into the budget.
      for (final kind in const <SyncOpKind>[
        SyncOpKind.mealInsert,
        SyncOpKind.mealUpsert,
        SyncOpKind.weightInsert,
        SyncOpKind.favoriteUpsert,
        SyncOpKind.recipeUpsert,
      ]) {
        expect(
            classifyOutboxFailure(pg('500'), kOutboxMaxAttempts - 1,
                kind: kind),
            OutboxVerdict.drop,
            reason: '${kind.name} behaelt sein Budget');
      }
      // Without kind (caller without op context) the old behaviour stands.
      expect(classifyOutboxFailure(pg('500'), kOutboxMaxAttempts - 1),
          OutboxVerdict.drop);
    });

    test(
        'ein strukturell unmoeglicher Delete wird NICHT sofort verworfen — '
        'sonst kehrt die geloeschte Mahlzeit still vom Server zurueck', () {
      // Transient-suspect, not payload-determined: an empty delete payload
      // CANNOT cause a data violation, so a cold schema cache or gateway 404
      // must not drop it. The exemption covers code verdict AND budget.
      for (final code in const <String>[
        'PGRST202', // schema cache does not know the function/route yet
        'PGRST204',
        'PGRST100',
        '404', // gateway route during a deploy
        '400',
        '422',
        '22003', // class 22 — structurally impossible for an EMPTY payload
        '22P02',
        '23502',
      ]) {
        for (final kind in const <SyncOpKind>[
          SyncOpKind.mealDelete,
          SyncOpKind.favoriteDelete,
          SyncOpKind.recipeDelete,
        ]) {
          expect(classifyOutboxFailure(pg(code), 0, kind: kind),
              OutboxVerdict.retryCounted,
              reason: '${kind.name} gegen $code darf nicht sofort sterben');
        }
        // Counter-check: write ops keep the instant drop.
        expect(classifyOutboxFailure(pg(code), 0, kind: SyncOpKind.mealInsert),
            OutboxVerdict.drop,
            reason: 'mealInsert gegen $code bleibt ein Sofort-Verwurf');
      }
    });

    test(
        'das Delete-Budget ist gross, aber ENDLICH — sonst ist die Outbox nie '
        'leer und der Logout traegt PII weiter', () {
      // "Never drop deletes" would pin `preserveOutbox` to true forever
      // (audit M-1); instead a large budget plus a wall-clock bound.
      expect(kOutboxDeleteMaxAttempts, greaterThan(kOutboxMaxAttempts * 4));
      for (final kind in const <SyncOpKind>[
        SyncOpKind.mealDelete,
        SyncOpKind.favoriteDelete,
        SyncOpKind.recipeDelete,
      ]) {
        expect(
            classifyOutboxFailure(pg('PGRST204'), kOutboxDeleteMaxAttempts - 2,
                kind: kind),
            OutboxVerdict.retryCounted);
        expect(
            classifyOutboxFailure(pg('PGRST204'), kOutboxDeleteMaxAttempts - 1,
                kind: kind),
            OutboxVerdict.drop,
            reason: 'dieser Versuch ist der letzte des Delete-Budgets');
        expect(
            classifyOutboxFailure(pg('500'), kOutboxDeleteMaxAttempts + 99,
                kind: kind),
            OutboxVerdict.drop);
        // Network errors stay free for deletes too — an offline holiday must
        // never cost a deletion.
        expect(
            classifyOutboxFailure(const SocketException('offline'),
                kOutboxDeleteMaxAttempts + 99,
                kind: kind),
            OutboxVerdict.retryFree);
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
      expect(outboxLossHint(), isNotEmpty);
      for (final leak in const <String>[
        '23514',
        'logged_meals',
        'check constraint',
        'PostgrestException',
        'PGRST',
        'SQLSTATE',
        'Sync (',
      ]) {
        expect(outboxLossHint(), isNot(contains(leak)));
      }
    });
  });

  group('deliveryHint (Luecke E)', () {
    // These hint functions take an optional [AppLocalizations] (default
    // German), under which the values here stay byte-identical.
    test('delivered haengt nur einen Punkt an', () {
      expect(
        deliveryHint('„Bowl" gespeichert', SyncDelivery.delivered),
        '„Bowl" gespeichert.',
      );
    });

    test('queuedOffline nennt den Offline-Grund', () {
      expect(
        deliveryHint('„Bowl" gespeichert', SyncDelivery.queuedOffline),
        '„Bowl" gespeichert — wird synchronisiert, sobald du wieder online '
        'bist.',
      );
    });

    test('queuedRetry nennt den automatischen Retry', () {
      expect(
        deliveryHint('„Bowl" gelöscht', SyncDelivery.queuedRetry),
        '„Bowl" gelöscht — die Übertragung wird automatisch wiederholt.',
      );
    });
  });
}
