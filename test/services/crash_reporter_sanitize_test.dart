// C1 (REVIEW-2026-08-08): Der Klassen-Header von crash_reporter.dart verspricht
// woertlich „niemals Nutzerdaten wie Gewicht, Mahlzeiten oder Health-Werte".
// Diese Datei macht aus dem Versprechen einen Test.
//
// Die Kette, die den Bruch erzeugt hat:
//   postgrest/types.dart:46  toString() => '...details: $details...'
//   sentry/sentry_exception_factory.dart:60  value = throwable.toString()
// PostgREST fuellt `details` aus PostgreSQLs DETAIL — bei einer CHECK-
// Verletzung (23514, z.B. `weight_kg between 30 and 300`) ist das die
// komplette fehlgeschlagene Zeile inkl. E-Mail, Anzeigename, Alter, Groesse
// und Gewicht.

import 'dart:async';

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/secure_cache_store.dart'
    show UndecryptableCacheSlot, redactUserSegment;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthApiException,
        AuthException,
        AuthWeakPasswordException,
        FunctionException,
        PostgrestException,
        StorageException;

/// Die reale DETAIL-Zeile einer 23514-Verletzung auf `public.profiles`.
/// Enthaelt Identitaet (UUID, E-Mail, Anzeigename) und Art.-9-Gesundheits-
/// werte (Alter 34, Groesse 178, Gewicht 25).
const String _failingRow =
    'Failing row contains (0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0, '
    'max@example.com, Max, 25, 178, 34).';

/// Alles, was in KEINEM Fall bei Sentry ankommen darf. Bewusst als eine
/// Liste, die jeder Test durchlaeuft — so faellt eine neue Leck-Stelle auf,
/// egal welcher Fehlertyp sie aufreisst.
const List<String> _verboten = <String>[
  'max@example.com',
  '@example.com',
  'Max',
  '0f1e2d3c',
  'Failing row',
  '178',
  '34',
];

/// Faengt ab, was `Sentry.captureException` bekommen wuerde.
class _SentrySpion {
  final List<Object> fehler = <Object>[];
  final List<String?> kontexte = <String?>[];

  void installieren() {
    CrashReporter.debugSentrySink = (error, stack, context) {
      fehler.add(error);
      kontexte.add(context);
    };
  }

  Object get einziger {
    expect(fehler, hasLength(1),
        reason: 'capture muss genau einen Report weiterreichen');
    return fehler.single;
  }

  /// Der String, den Sentry als Event-`value` schreiben wuerde
  /// (sentry_exception_factory.dart:60 `value = throwable.toString()`).
  String get sentryValue => einziger.toString();

  /// Der String, den Sentry als Event-`type` schreiben wuerde
  /// (sentry_exception_factory.dart:64 `throwable.runtimeType.toString()`).
  String get sentryType => einziger.runtimeType.toString();
}

void main() {
  late _SentrySpion spion;

  setUp(() {
    spion = _SentrySpion()..installieren();
  });

  tearDown(() {
    CrashReporter.debugSentrySink = null;
  });

  /// Prueft die Zusage aus dem Klassen-Header gegen den kompletten
  /// Sentry-Event (type + value).
  void erwarteKeineNutzerdaten() {
    final nutzlast = '${spion.sentryType}|${spion.sentryValue}';
    for (final geheim in _verboten) {
      expect(nutzlast, isNot(contains(geheim)),
          reason: 'Nutzerdaten "$geheim" duerfen Sentry nie erreichen — '
              'gesendet worden waere: $nutzlast');
    }
  }

  group('C1 · PostgrestException', () {
    test('E-Mail, Name und Koerperwerte aus details erreichen Sentry nicht',
        () async {
      await CrashReporter.capture(
        const PostgrestException(
          message: 'new row for relation "profiles" violates check constraint '
              '"profiles_weight_kg_check"',
          code: '23514',
          details: _failingRow,
          hint: 'weight_kg between 30 and 300',
        ),
        StackTrace.current,
        context: 'profil-settings',
      );

      erwarteKeineNutzerdaten();
    });

    test('das rohe Exception-Objekt wird gar nicht erst weitergereicht',
        () async {
      const roh = PostgrestException(
        message: 'violates check constraint',
        code: '23514',
        details: _failingRow,
      );

      await CrashReporter.capture(roh, StackTrace.current);

      expect(spion.einziger, isNot(same(roh)));
      expect(spion.einziger, isNot(isA<PostgrestException>()),
          reason: 'Wer das Objekt durchreicht, reicht auch sein toString() '
              'durch — und das ist genau der Leckpfad.');
    });

    test('bleibt fuer Entwickler diagnostisch: Typ und SQLSTATE ueberleben',
        () async {
      await CrashReporter.capture(
        const PostgrestException(
          message: 'violates check constraint',
          code: '23514',
          details: _failingRow,
        ),
        StackTrace.current,
      );

      // „Exception" allein waere wertlos, „PostgrestException code=23514" ist
      // die Diagnose: CHECK-Verletzung beim Profil-Upsert.
      expect(spion.sentryValue, contains('PostgrestException'));
      expect(spion.sentryValue, contains('23514'));
    });

    test('ohne code bleibt der Typ stehen, ohne Rest der Nachricht', () async {
      await CrashReporter.capture(
        const PostgrestException(message: _failingRow),
        StackTrace.current,
      );

      expect(spion.sentryValue, contains('PostgrestException'));
      erwarteKeineNutzerdaten();
    });

    test('context-Label bleibt erhalten — es ist ein Entwickler-Konstant',
        () async {
      await CrashReporter.capture(
        const PostgrestException(message: 'x', code: '23514'),
        StackTrace.current,
        context: 'profil-onboarding',
      );

      expect(spion.kontexte.single, 'profil-onboarding');
    });
  });

  group('C1 · weitere Fehlertypen mit gefaehrlichem toString()', () {
    test('AuthException: message faellt weg, statusCode und code bleiben',
        () async {
      await CrashReporter.capture(
        const AuthApiException(
          'A user with this email address (max@example.com) has already '
          'been registered',
          statusCode: '422',
          code: 'user_already_exists',
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('AuthApiException'));
      expect(spion.sentryValue, contains('422'));
      expect(spion.sentryValue, contains('user_already_exists'));
    });

    test('AuthWeakPasswordException: reasons sind kein Passwort-Hinweis-Leck',
        () async {
      await CrashReporter.capture(
        AuthWeakPasswordException(
          message: 'Password is too weak: contains "Max"',
          statusCode: '422',
          reasons: const <String>['length', 'characters'],
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('AuthWeakPasswordException'));
    });

    test('AuthException-Basisklasse faellt in denselben Zweig', () async {
      await CrashReporter.capture(
        const AuthException('max@example.com ist gesperrt', statusCode: '403'),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('403'));
    });

    test('StorageException: nur statusCode', () async {
      await CrashReporter.capture(
        const StorageException(
          'Object not found: meals/max@example.com/2026-08-08.jpg',
          statusCode: '404',
          error: 'NotFound',
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('StorageException'));
      expect(spion.sentryValue, contains('404'));
    });

    test('FunctionException: nur status — details ist der rohe Response-Body',
        () async {
      // analyze-meal antwortet mit erkannten Lebensmitteln. Der Body ist der
      // Mahlzeiteninhalt des Nutzers, also Art.-9-nah.
      await CrashReporter.capture(
        const FunctionException(
          status: 500,
          details: '{"items":[{"name":"Haehnchenbrust","kcal":178}],'
              '"user":"max@example.com"}',
          reasonPhrase: 'Internal Server Error',
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('FunctionException'));
      expect(spion.sentryValue, contains('500'));
    });

    test('ClientException: die uri traegt die PostgREST-Query mit der User-Id',
        () async {
      await CrashReporter.capture(
        ClientException(
          'Connection closed before full header was received',
          Uri.parse('https://x.supabase.co/rest/v1/profiles'
              '?id=eq.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0&select=*'),
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('ClientException'));
    });

    test('PlatformException: nur code, nie details', () async {
      await CrashReporter.capture(
        PlatformException(
          code: 'sign_in_failed',
          message: 'max@example.com',
          details: 'Failing row contains (Max, 178, 34)',
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('PlatformException'));
      expect(spion.sentryValue, contains('sign_in_failed'));
    });

    test('TimeoutException: Dauer bleibt, Freitext nicht', () async {
      await CrashReporter.capture(
        TimeoutException('profiles?id=eq.0f1e2d3c laedt nicht',
            const Duration(seconds: 12)),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('TimeoutException'));
    });

    test('FormatException: source ist der rohe JSON-Body und faellt weg',
        () async {
      await CrashReporter.capture(
        const FormatException(
          'Unexpected character',
          '{"email":"max@example.com","weight_kg":178}',
          9,
        ),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('FormatException'));
    });

    test('ArgumentError: invalidValue ist der getippte Gewichtswert', () async {
      await CrashReporter.capture(
        ArgumentError.value(178, 'heightCm', 'ausserhalb 100..250'),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('ArgumentError'));
    });

    test('TypeError bleibt vollstaendig — er nennt nur Typnamen', () async {
      Object? gefangen;
      try {
        // ignore: unnecessary_cast
        (<Object?>[null].first as String).length;
      } catch (e) {
        gefangen = e;
      }

      await CrashReporter.capture(gefangen!, StackTrace.current);

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('subtype'),
          reason: 'Der Dart-Laufzeittext nennt nur Typen und ist die '
              'wertvollste Diagnose ueberhaupt — er muss ueberleben.');
    });
  });

  group('C1 · Allowlist schliesst per Default zu', () {
    test('unbekannter Fremdtyp liefert nur den Typnamen', () async {
      await CrashReporter.capture(
        const _FremderFehler(_failingRow),
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
      expect(spion.sentryValue, contains('_FremderFehler'));
    });

    test('roher String wird nicht durchgereicht', () async {
      await CrashReporter.capture(_failingRow, StackTrace.current);

      erwarteKeineNutzerdaten();
    });

    test('nackte Exception(...) leakt ihre Message nicht', () async {
      await CrashReporter.capture(Exception(_failingRow), StackTrace.current);

      erwarteKeineNutzerdaten();
    });

    test('verschachtelter Fehler in einer Liste bleibt aussen vor', () async {
      await CrashReporter.capture(
        <Object>[_failingRow, 42],
        StackTrace.current,
      );

      erwarteKeineNutzerdaten();
    });

    test('Fehlerobjekt mit werfendem toString() bringt capture nicht um',
        () async {
      await CrashReporter.capture(_KaputterToString(), StackTrace.current);

      // Kein Throw nach aussen UND trotzdem ein brauchbarer Report.
      expect(spion.fehler, hasLength(1));
      expect(spion.sentryValue, contains('_KaputterToString'));
    });
  });

  group('C1 · Stacktrace', () {
    test('bleibt unveraendert erhalten', () async {
      final stack = StackTrace.current;
      StackTrace? gesehen;
      CrashReporter.debugSentrySink = (error, s, context) => gesehen = s;

      await CrashReporter.capture(
        const PostgrestException(message: 'x', code: '23514'),
        stack,
      );

      // Begruendung fuer das Behalten: ein Dart-Stacktrace besteht aus
      // Datei-, Klassen- und Methodennamen plus Zeilennummern — alles zur
      // Uebersetzungszeit festgelegt. Laufzeitwerte kommen darin nicht vor,
      // also auch keine Gewichte, Mahlzeiten oder E-Mails. Ohne ihn waere ein
      // Report nicht mehr zuzuordnen.
      expect(gesehen, same(stack));
    });
  });

  group('C1 · sanitizeForReport direkt', () {
    test('ist idempotent — doppelte Sanitisierung veraendert nichts', () {
      final einmal = sanitizeForReport(
        const PostgrestException(
          message: 'x',
          code: '23514',
          details: _failingRow,
        ),
      );
      final zweimal = sanitizeForReport(einmal);

      expect(zweimal, same(einmal));
      expect(zweimal.type, 'PostgrestException');
      expect(zweimal.detail, 'code=23514');
    });

    test('liefert bei fehlenden Allowlist-Feldern detail == null', () {
      final ohneCode =
          sanitizeForReport(const PostgrestException(message: _failingRow));

      expect(ohneCode.type, 'PostgrestException');
      expect(ohneCode.detail, isNull);
      expect(ohneCode.toString(), 'PostgrestException');
    });

    test('AuthException ohne code liefert nur den statusCode', () {
      final s = sanitizeForReport(
        const AuthException('max@example.com', statusCode: '429'),
      );

      expect(s.detail, 'statusCode=429');
    });

    test('unbekannter Typ liefert Typname ohne detail', () {
      final s = sanitizeForReport(const _FremderFehler(_failingRow));

      expect(s.type, '_FremderFehler');
      expect(s.detail, isNull);
    });

    test('bereits sanitisierte App-Typen behalten ihre Kurzfassung', () {
      // UndecryptableCacheSlot (secure_cache_store.dart) traegt nur einen
      // Fehlertypnamen und einen um die User-UUID gekuerzten Slot-Key. Genau
      // diese Information soll erhalten bleiben — sonst waere der Report
      // wertlos.
      final s = sanitizeForReport(
        UndecryptableCacheSlot(
          errorType: 'InvalidCipherTextException',
          storageKey: redactUserSegment(
              'eatova.v1.meals.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'),
        ),
      );

      expect(s.type, 'UndecryptableCacheSlot');
      expect(s.detail, contains('<uid>'));
      expect(s.detail, contains('InvalidCipherTextException'));
      expect(s.detail, isNot(contains('0f1e2d3c')));
    });
  });
}

/// Ein Typ, den die Allowlist nicht kennt — der Default-Fall.
class _FremderFehler implements Exception {
  const _FremderFehler(this.payload);
  final String payload;

  @override
  String toString() => '_FremderFehler($payload)';
}

/// Worst Case fuer jede Reporting-Schicht.
class _KaputterToString {
  @override
  String toString() => throw StateError('toString kaputt');
}
