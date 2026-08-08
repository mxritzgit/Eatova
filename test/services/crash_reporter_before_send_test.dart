import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// C1, zweite Haelfte: der `beforeSend`-Hook.
///
/// `CrashReporter.capture` sanitisiert nur, was durch die Facade laeuft.
/// `SentryFlutter.init` installiert zusaetzlich `FlutterErrorIntegration`,
/// `OnErrorIntegration` und `RunZonedGuardedIntegration` — die greifen
/// unbehandelte Fehler DIREKT ab. Ohne `beforeSend` geht eine
/// `PostgrestException` aus einem nicht gefangenen Future roh hinaus.
void main() {
  // Exakt die Form, die PostgREST bei einer CHECK-Verletzung liefert:
  // PostgreSQLs DETAIL enthaelt die komplette fehlgeschlagene Zeile.
  const failingRow =
      'Failing row contains (0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0, '
      'max@example.com, Max Mustermann, 25, 178, 34).';

  const postgrest = PostgrestException(
    message: 'new row for relation "profiles" violates check constraint '
        '"profiles_weight_kg_check"',
    code: '23514',
    details: failingRow,
    hint: 'weight_kg between 30 and 300',
  );

  SentryEvent eventFor(Object throwable) => SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: throwable.runtimeType.toString(),
            // So baut sentry_exception_factory.dart:60 den Wert.
            value: throwable.toString(),
            throwable: throwable,
          ),
        ],
      );

  group('sanitizeSentryEvent', () {
    test(
        'ein unbehandelter PostgrestException-Event traegt weder E-Mail noch '
        'Koerperdaten nach Sentry', () {
      final sanitized = sanitizeSentryEvent(eventFor(postgrest), Hint());

      final value = sanitized!.exceptions!.single.value!;
      expect(value, isNot(contains('max@example.com')),
          reason: 'die E-Mail ist ein direkter Personenbezug');
      expect(value, isNot(contains('Max Mustermann')));
      expect(value, isNot(contains('0f1e2d3c')),
          reason: 'die User-UUID ist eine stabile Nutzerkennung');
      expect(value, isNot(contains('178')),
          reason: 'Koerpergroesse ist ein Art.-9-Gesundheitsdatum');
      expect(value, isNot(contains('Failing row')));
      expect(value, isNot(contains('weight_kg between 30 and 300')),
          reason: 'der hint verraet, welche Constraint gerissen ist');
    });

    test('der SQLSTATE bleibt erhalten — sonst ist der Report wertlos', () {
      final sanitized = sanitizeSentryEvent(eventFor(postgrest), Hint());
      final e = sanitized!.exceptions!.single;

      expect(e.value, contains('23514'));
      expect(e.type, 'PostgrestException',
          reason: 'type bleibt unangetastet, damit Sentry weiter gruppiert');
    });

    test('mehrere verkettete Exceptions werden alle sanitisiert', () {
      final event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'PostgrestException',
            value: postgrest.toString(),
            throwable: postgrest,
          ),
          SentryException(
            type: 'StateError',
            value: 'Bad state: $failingRow',
            throwable: StateError(failingRow),
          ),
        ],
      );

      final sanitized = sanitizeSentryEvent(event, Hint())!;
      expect(sanitized.exceptions, hasLength(2));
      for (final e in sanitized.exceptions!) {
        expect(e.value, isNot(contains('max@example.com')));
        expect(e.value, isNot(contains('Failing row')));
      }
    });

    test('ohne throwable faellt der Wert auf den Typnamen zurueck, nie auf den '
        'urspruenglichen value', () {
      // Diesen Fall gibt es real: aus dem nativen Layer geloggte Events
      // tragen type und value, aber kein Dart-Objekt.
      final event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(type: 'PostgrestException', value: failingRow),
        ],
      );

      final value = sanitizeSentryEvent(event, Hint())!.exceptions!.single.value;
      expect(value, isNot(contains('max@example.com')));
      expect(value, 'PostgrestException');
    });

    test('ein Event ohne exceptions geht unveraendert durch', () {
      final event = SentryEvent(exceptions: const <SentryException>[]);
      expect(sanitizeSentryEvent(event, Hint()), same(event));
      final ohne = SentryEvent();
      expect(sanitizeSentryEvent(ohne, Hint()), same(ohne));
    });

    test('doppeltes Sanitisieren aendert nichts (idempotent)', () {
      final einmal = sanitizeSentryEvent(eventFor(postgrest), Hint())!;
      final zweimal = sanitizeSentryEvent(einmal, Hint())!;
      expect(zweimal.exceptions!.single.value, einmal.exceptions!.single.value);
    });

    test('der Stacktrace bleibt erhalten — er traegt keine Laufzeitwerte', () {
      final stack = SentryStackTrace(frames: <SentryStackFrame>[
        SentryStackFrame(fileName: 'home_store_sync.dart', lineNo: 236),
      ]);
      final event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'PostgrestException',
            value: postgrest.toString(),
            throwable: postgrest,
            stackTrace: stack,
          ),
        ],
      );

      final e = sanitizeSentryEvent(event, Hint())!.exceptions!.single;
      expect(e.stackTrace, isNotNull);
      expect(e.stackTrace!.frames.single.lineNo, 236);
    });
  });
}
