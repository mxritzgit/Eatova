import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// C1, second half: the `beforeSend` hook.
///
/// `CrashReporter.capture` only sanitises what goes through the facade, while
/// the Sentry integrations pick up unhandled errors DIRECTLY. Without
/// `beforeSend` a `PostgrestException` from an uncaught future goes out raw.
void main() {
  // Exactly the shape PostgREST returns on a CHECK violation: PostgreSQL's
  // DETAIL contains the entire failing row.
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
            // How sentry_exception_factory.dart:60 builds the value.
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
      // A real case: events logged from the native layer carry type and value
      // but no Dart object.
      final event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(type: 'PostgrestException', value: failingRow),
        ],
      );

      final value = sanitizeSentryEvent(event, Hint())!.exceptions!.single.value;
      expect(value, isNot(contains('max@example.com')));
      expect(value, 'PostgrestException');
    });

    test(
        'ein Event ohne exceptions wird trotzdem gefiltert — die alte '
        'Erwartung "geht unveraendert durch" war der Bug', () {
      // The events C1 leaks through HAVE no `exceptions`:
      // `FlutterErrorIntegration` builds its event from `throwable` plus
      // `contexts['flutter_error_details']`, and contexts/breadcrumbs/message/
      // extra/request hang off the event anyway. So "passes through
      // unchanged" meant the whole rest of the event went out raw.
      //
      // The filter now always runs over the whole event. It still returns the
      // same object (mutates instead of copying), but the content is filtered.
      final event = SentryEvent(exceptions: const <SentryException>[])
        ..contexts['flutter_error_details'] = <String, String>{
          'information': 'The following RangeError was thrown: 187.4',
        };

      final gefiltert = sanitizeSentryEvent(event, Hint())!;

      expect(gefiltert, same(event), reason: 'in-place, kein copyWith');
      expect(gefiltert.contexts.containsKey('flutter_error_details'), isFalse,
          reason: 'genau dieser Schluessel ist Leck 2');

      final ohne = SentryEvent();
      expect(sanitizeSentryEvent(ohne, Hint()), same(ohne),
          reason: 'ein wirklich leeres Event bleibt leer — nichts zu tun');
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

  // ---------------------------------------------------------------------
  // C1, leak 2: everything on the event outside exceptions[].value.
  // ---------------------------------------------------------------------

  group('sanitizeSentryEvent — contexts', () {
    test(
        'contexts[flutter_error_details] wird verworfen: information ist der '
        'gerenderte Diagnostics-Baum', () {
      // flutter_error_integration.dart:38-50,72 attaches exactly this map, and
      // contexts.dart `toJson` passes unknown keys through unchanged.
      final event = SentryEvent()
        ..contexts['flutter_error_details'] = <String, String>{
          'library': 'widgets library',
          'context': 'thrown while building MealTile',
          'information': 'The following assertion was thrown building '
              'MealTile(dirty): "Haferflocken mit Banane" ueberschreitet '
              '412 kcal fuer max@example.com',
        };

      final contexts = sanitizeSentryEvent(event, Hint())!.contexts;

      expect(contexts.containsKey('flutter_error_details'), isFalse);
      expect(contexts.toJson().toString(), isNot(contains('max@example.com')));
      expect(contexts.toJson().toString(), isNot(contains('Haferflocken')));
    });

    test('Geraet, OS, App und Runtime bleiben — das ist legitime Diagnostik',
        () {
      final event = SentryEvent(
        contexts: Contexts(
          device: SentryDevice(model: 'Pixel 7', arch: 'arm64'),
          operatingSystem: SentryOperatingSystem(name: 'Android', version: '14'),
          app: SentryApp(name: 'Eatova', version: '1.2.3'),
          runtimes: <SentryRuntime>[SentryRuntime(name: 'Dart', version: '3.9')],
        ),
      );

      final contexts = sanitizeSentryEvent(event, Hint())!.contexts;

      expect(contexts.device?.model, 'Pixel 7');
      expect(contexts.operatingSystem?.version, '14');
      expect(contexts.app?.version, '1.2.3');
      expect(contexts.runtimes.single.name, 'Dart');
    });

    test('jeder unbekannte contexts-Schluessel faellt weg (Allowlist)', () {
      final event = SentryEvent()
        ..contexts['irgendein_neues_plugin'] = <String, String>{
          'letzte_mahlzeit': 'Haferflocken mit Banane',
        }
        ..contexts['state'] = <String, dynamic>{'gewicht_kg': 87.4};

      final contexts = sanitizeSentryEvent(event, Hint())!.contexts;

      expect(contexts.containsKey('irgendein_neues_plugin'), isFalse);
      expect(contexts.containsKey('state'), isFalse);
      expect(contexts.toJson(), isEmpty);
    });

    test('contexts[feedback] faellt weg — das ist wortwoertlich Nutzertext',
        () {
      final event = SentryEvent(
        contexts: Contexts(
          feedback: SentryFeedback(
            message: 'Mein Gewicht 87,4 kg wird falsch gespeichert',
            contactEmail: 'max@example.com',
            name: 'Max Mustermann',
          ),
        ),
      );

      final contexts = sanitizeSentryEvent(event, Hint())!.contexts;

      expect(contexts.feedback, isNull);
      expect(contexts.toJson().toString(), isNot(contains('max@example.com')));
    });
  });

  group('sanitizeSentryEvent — message', () {
    test(
        'die interpolierte Fassung wird durch das Template ersetzt, params '
        'fallen weg', () {
      // `formatted` carries the substituted runtime values, `template` is a
      // source literal — free of user data by construction and enough for
      // Sentry to group by.
      final event = SentryEvent(
        message: SentryMessage(
          'Gewicht 87.4 kg fuer max@example.com konnte nicht gespeichert '
          'werden',
          template: 'Gewicht %s kg fuer %s konnte nicht gespeichert werden',
          params: <dynamic>[87.4, 'max@example.com'],
        ),
      );

      final message = sanitizeSentryEvent(event, Hint())!.message!;

      expect(message.formatted, isNot(contains('max@example.com')));
      expect(message.formatted, isNot(contains('87.4')));
      expect(message.formatted,
          'Gewicht %s kg fuer %s konnte nicht gespeichert werden');
      expect(message.params, isNull, reason: 'params SIND die Laufzeitwerte');
    });

    test('ohne template bleibt nur ein Platzhalter uebrig', () {
      final event = SentryEvent(
        message: SentryMessage('87,4 kg fuer max@example.com'),
      );

      final message = sanitizeSentryEvent(event, Hint())!.message!;

      expect(message.formatted, isNot(contains('max@example.com')));
      expect(message.formatted, isNot(contains('87,4')));
      expect(message.formatted, isNotEmpty,
          reason: 'ein leerer formatted-String wuerde in Sentry nur verwirren');
    });
  });

  group('sanitizeSentryEvent — extra, request, user', () {
    test('extra wird komplett verworfen — beliebige Schluessel ohne Schema',
        () {
      final event = SentryEvent(
        // ignore: deprecated_member_use
        extra: <String, dynamic>{
          'profil': <String, dynamic>{'email': 'max@example.com', 'kg': 87.4},
        },
      );

      // ignore: deprecated_member_use
      expect(sanitizeSentryEvent(event, Hint())!.extra, isNull);
    });

    test('request wird verworfen — Cookies, Header und Query in einem Feld',
        () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://abcdefg.supabase.co/rest/v1/profiles',
          queryString: 'id=eq.0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
          cookies: 'sb-access-token=ey...',
          headers: <String, String>{'Authorization': 'Bearer ey...'},
        ),
      );

      expect(sanitizeSentryEvent(event, Hint())!.request, isNull);
    });

    test('user wird verworfen — die App identifiziert bewusst niemanden', () {
      // sendDefaultPii is off and the app never calls scope.setUser, so a
      // filled user object can only come from a future slip or the native
      // scope.
      final event = SentryEvent(
        user: SentryUser(
          id: '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
          email: 'max@example.com',
          ipAddress: '203.0.113.7',
        ),
      );

      expect(sanitizeSentryEvent(event, Hint())!.user, isNull);
    });

    test('tags bleiben — context und error_type sind unsere eigene Diagnose',
        () {
      final event = SentryEvent(
        tags: <String, String>{'context': 'boot', 'error_type': 'StateError'},
      );

      expect(sanitizeSentryEvent(event, Hint())!.tags,
          <String, String>{'context': 'boot', 'error_type': 'StateError'});
    });
  });

  group('sanitizeSentryEvent — breadcrumbs am Event (zweite Reihe)', () {
    test(
        'ein console-Breadcrumb wird auch dann noch entfernt, wenn er am '
        'Event haengt statt durch beforeBreadcrumb zu laufen', () {
      // Second line behind beforeBreadcrumb: load_contexts_integration.dart
      // writes native breadcrumbs straight into `event.breadcrumbs`.
      final event = SentryEvent(
        breadcrumbs: <Breadcrumb>[
          Breadcrumb.console(message: 'Eatova boot failed: max@example.com'),
          Breadcrumb(category: 'app.lifecycle', message: 'resumed'),
        ],
      );

      final breadcrumbs = sanitizeSentryEvent(event, Hint())!.breadcrumbs!;

      expect(breadcrumbs, hasLength(1));
      expect(breadcrumbs.single.category, 'app.lifecycle');
    });

    test('ein Event ohne breadcrumbs bleibt ohne breadcrumbs', () {
      final event = SentryEvent();
      expect(sanitizeSentryEvent(event, Hint())!.breadcrumbs, isNull);
    });
  });

  group('sanitizeSentryEvent — Robustheit', () {
    test('der Hook wirft nie: ein Throw in beforeSend verwirft das Event still',
        () {
      // sentry_client.dart only logs the throw and then drops the event, so a
      // broken filter would silently kill crash reporting entirely.
      final event = SentryEvent(message: SentryMessage('x'));
      expect(() => sanitizeSentryEvent(event, Hint()), returnsNormally);
    });
  });
}
