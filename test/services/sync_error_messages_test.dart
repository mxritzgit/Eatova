import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/sync_outbox.dart'
    show SyncOpKind, kOutboxMaxAttempts, kOutboxDeleteMaxAttempts;

// Pure error-text mapping for sync/profile errors: network errors get an
// honest offline hint, everything else a friendly message. Key invariant: no
// result ever leaks raw exception text (codes, table or constraint names).

void main() {
  group('isNetworkSyncError', () {
    // Every network type, TLS included, is pinned through its outbox verdict
    // in 'JEDER Netzwerkfehler ist retryFree' below (classifyOutboxFailure
    // asks isNetworkSyncError first); server and program errors are not
    // network errors per 'unbekannter TYP -> behalten'.
    test(
        'SYNC-5: eine 2xx-Antwort ohne JSON (Captive Portal) ist ein '
        'Netzfehler, jede andere Statuszahl nicht', () {
      for (final code in ['200', '201', '203', '299']) {
        final portal = PostgrestException(
          message: '<html><title>WLAN-Anmeldung</title></html>',
          code: code,
        );
        expect(isUnreadableSuccessResponse(portal), isTrue, reason: code);
        expect(isNetworkSyncError(portal), isTrue, reason: code);
      }
      for (final code in ['199', '300', '401', '500', '503', '20000', '2001',
          'PGRST200', '', null]) {
        final server = PostgrestException(message: 'x', code: code);
        expect(isUnreadableSuccessResponse(server), isFalse, reason: code);
        expect(isNetworkSyncError(server), isFalse, reason: code);
      }
      expect(isUnreadableSuccessResponse(const FormatException('200')),
          isFalse);
    });

    test(
        'SYNC-5: postgrest wirft die HTML-200-Seite eines Portals als genau '
        'diesen Fall', () async {
      final client = SupabaseClient(
        'https://portal-test.invalid',
        'dummy-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
              '<html><body>Bitte im Hotel-WLAN anmelden</body></html>',
              200,
              headers: const {'content-type': 'text/html'},
              request: request,
            )),
      );
      addTearDown(client.dispose);
      Object? caught;
      try {
        await client
            .rpc<dynamic>('apply_sync_operation', params: {'p_op': 1})
            .retry(enabled: false);
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<PostgrestException>());
      expect(isNetworkSyncError(caught!), isTrue,
          reason: 'sonst zaehlt das Portal gegen das Acht-Versuche-Budget');
      expect(classifyOutboxFailure(caught, kOutboxMaxAttempts - 1),
          OutboxVerdict.retryFree);
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

  // The profile save rides the same outbox, so it gets the same two hints.

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

    // The verdict table for a FRESH failure (attempts 0, no op kind). Moving a
    // code between the columns is a data-loss decision, so each assertion
    // names its code and reason.
    final urteile = <(String, OutboxVerdict, String)>[
      // Payload-determined — no user input produces these, so a retry would
      // fail identically forever.
      ('23502', OutboxVerdict.drop, 'not_null_violation'),
      ('22003', OutboxVerdict.drop, 'Klasse 22, numeric_value_out_of_range'),
      ('22P02', OutboxVerdict.drop, 'Klasse 22, invalid_text_representation'),
      // "75,5" in the weight field (-> 755 kg) is reproducible USER input, and
      // the correction window the attempts reset is built on.
      ('23514', OutboxVerdict.retryCounted, 'Check-Constraint aus Nutzereingabe'),
      ('23503', OutboxVerdict.retryCounted,
          'Fremdschluessel, waehrend Migration/Signup-Rennen transient'),
      // HTTP status codes: PostgREST only puts them in `code` when the body
      // carries none.
      ('500', OutboxVerdict.retryCounted, 'Serverfehler'),
      ('502', OutboxVerdict.retryCounted, 'Gateway'),
      ('503', OutboxVerdict.retryCounted, 'Gateway'),
      ('429', OutboxVerdict.retryCounted, 'Rate-Limit'),
      // 401/403: almost always an expired token, which the refresh heals.
      ('401', OutboxVerdict.retryCounted, 'Token-Alter, der Refresh heilt es'),
      ('403', OutboxVerdict.retryCounted, 'Token-Alter, der Refresh heilt es'),
      ('404', OutboxVerdict.drop, 'uebrige 4xx'),
      ('400', OutboxVerdict.drop, 'uebrige 4xx'),
      ('422', OutboxVerdict.drop, 'uebrige 4xx'),
      ('42501', OutboxVerdict.retryCounted, 'RLS, oft eine Sessionfrage'),
      ('PGRST301', OutboxVerdict.retryCounted, 'JWT abgelaufen'),
      // Sentry FLUTTER-9 (2026-08-26): PostgREST >= 12.2 reports an expired
      // JWT as PGRST303, which until then fell into the drop branch — a write
      // rejected only because of token age would have been thrown away.
      ('PGRST303', OutboxVerdict.retryCounted, 'JWT abgelaufen, FLUTTER-9'),
      // Other PGRST codes describe a structurally broken request; PGRST302
      // (anonymous access disabled) is a config error, not a token age.
      ('PGRST302', OutboxVerdict.drop, 'Konfigurationsfehler, kein Token-Alter'),
      ('PGRST204', OutboxVerdict.drop, 'strukturell kaputte Anfrage'),
      ('PGRST100', OutboxVerdict.drop, 'strukturell kaputte Anfrage'),
      // Transient SQLSTATE classes.
      ('08006', OutboxVerdict.retryCounted, 'Verbindungsklasse 08'),
      ('40001', OutboxVerdict.retryCounted, 'serialization_failure'),
      ('53300', OutboxVerdict.retryCounted, 'too_many_connections'),
      ('57P03', OutboxVerdict.retryCounted, 'cannot_connect_now'),
      ('58030', OutboxVerdict.retryCounted, 'io_error'),
      // Unknown stays in the queue: dropping on a code nobody classified is
      // the expensive direction.
      ('99999', OutboxVerdict.retryCounted, 'unbekannter Code'),
      ('', OutboxVerdict.retryCounted, 'leerer Code'),
    ];
    test('frischer Fehlschlag: jeder Code bekommt sein Urteil', () {
      for (final (code, urteil, warum) in urteile) {
        expect(classifyOutboxFailure(pg(code), 0), urteil,
            reason: 'Code "$code" ($warum)');
      }
    });

    test(
        '23514 (Check-Constraint) ueberlebt bis an den Budget-Rand — der '
        'Normalfall einer Nutzereingabe, nicht korrupte Daten', () {
      expect(classifyOutboxFailure(pg('23514'), kOutboxMaxAttempts - 2),
          OutboxVerdict.retryCounted);
      // The budget stays the emergency brake: not even a 23514 loops forever.
      expect(classifyOutboxFailure(pg('23514'), kOutboxMaxAttempts - 1),
          OutboxVerdict.drop);
    });

    test(
        'SYNC-5: eine Portal-200 verbraucht kein Budget, auch nicht am Rand '
        'und nicht bei Loeschungen', () {
      final portal = pg('200');
      for (final attempts in [0, kOutboxMaxAttempts - 1, kOutboxMaxAttempts + 5]) {
        expect(classifyOutboxFailure(portal, attempts), OutboxVerdict.retryFree,
            reason: 'Versuch $attempts');
      }
      expect(
        classifyOutboxFailure(portal, kOutboxDeleteMaxAttempts - 1,
            kind: SyncOpKind.mealDelete),
        OutboxVerdict.retryFree,
      );
      // The 5xx policy stays as it was: counted, dropped at the budget edge.
      expect(classifyOutboxFailure(pg('502'), kOutboxMaxAttempts - 1),
          OutboxVerdict.drop);
      expect(queuedDelivery(portal), SyncDelivery.queuedOffline);
    });

    test('isStaleAuthError kennt die drei Token-Ablehnungen und sonst nichts',
        () {
      expect(isStaleAuthError(pg('PGRST301')), isTrue);
      expect(isStaleAuthError(pg('PGRST303')), isTrue);
      // Bare HTTP status = the gateway answered, not PostgREST (FLUTTER-B).
      expect(isStaleAuthError(pg('401')), isTrue);
      expect(isStaleAuthError(pg('PGRST302')), isFalse);
      expect(isStaleAuthError(pg('403')), isFalse);
      expect(isStaleAuthError(pg('42501')), isFalse);
      expect(isStaleAuthError(const SocketException('offline')), isFalse);
      expect(
          isStaleAuthError(AuthRetryableFetchException(message: 'x')), isFalse);
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
        'Delete-Ops ignorieren Code-Urteil und SCHREIB-Budget — ein '
        'verworfener Delete holt die geloeschte Mahlzeit vom Server zurueck',
        () {
      // A dropped delete leaves the server row, so the next cold start counts
      // the meal again. Deletes are idempotent, hence their own budget. An
      // empty delete payload CANNOT cause a data violation, so a cold schema
      // cache (PGRST202) or a gateway 404 during a deploy must not drop it.
      for (final kind in SyncOpKind.values.where((k) => k.isDelete)) {
        for (final code in const <String>[
          'PGRST202',
          'PGRST204',
          'PGRST100',
          '404',
          '400',
          '422',
          '22003',
          '22P02',
          '23502',
        ]) {
          expect(classifyOutboxFailure(pg(code), 0, kind: kind),
              OutboxVerdict.retryCounted,
              reason: '${kind.name} gegen $code darf nicht sofort sterben');
        }
        expect(
            classifyOutboxFailure(pg('500'), kOutboxMaxAttempts * 4,
                kind: kind),
            OutboxVerdict.retryCounted,
            reason: '${kind.name} weit jenseits des SCHREIB-Budgets');
      }

      // Counter-check: write ops keep the instant drop and their budget.
      expect(classifyOutboxFailure(pg('PGRST204'), 0, kind: SyncOpKind.mealInsert),
          OutboxVerdict.drop);
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
        'das Delete-Budget ist gross, aber ENDLICH — sonst ist die Outbox nie '
        'leer und der Logout traegt PII weiter', () {
      // "Never drop deletes" would pin `preserveOutbox` to true forever
      // (audit M-1); instead a large budget plus a wall-clock bound.
      expect(kOutboxDeleteMaxAttempts, greaterThan(kOutboxMaxAttempts * 4));
      for (final kind in SyncOpKind.values.where((k) => k.isDelete)) {
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

    test('unbekannter TYP -> behalten (retryCounted)', () {
      // The unknown CODES sit in the verdict table above; here it is about
      // errors that are not a PostgrestException at all.
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

  group('deliveryHint (Luecke E)', () {
    // These hint functions take an optional [AppLocalizations] (default
    // German), under which the values here stay byte-identical.
    test('jede Zustellart haengt ihren eigenen Zusatz an', () {
      expect(
        deliveryHint('„Bowl" gespeichert', SyncDelivery.delivered),
        '„Bowl" gespeichert.',
      );
      expect(
        deliveryHint('„Bowl" gespeichert', SyncDelivery.queuedOffline),
        '„Bowl" gespeichert — wird synchronisiert, sobald du wieder online '
        'bist.',
      );
      expect(
        deliveryHint('„Bowl" gelöscht', SyncDelivery.queuedRetry),
        '„Bowl" gelöscht — die Übertragung wird automatisch wiederholt.',
      );
    });
  });
}
