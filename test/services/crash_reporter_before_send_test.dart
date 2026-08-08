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

    test(
        'ein Event ohne exceptions wird trotzdem gefiltert — die alte '
        'Erwartung "geht unveraendert durch" war der Bug', () {
      // Bis Welle 5 stand hier woertlich:
      //
      //   test('ein Event ohne exceptions geht unveraendert durch', () {
      //     final event = SentryEvent(exceptions: const <SentryException>[]);
      //     expect(sanitizeSentryEvent(event, Hint()), same(event));
      //     final ohne = SentryEvent();
      //     expect(sanitizeSentryEvent(ohne, Hint()), same(ohne));
      //   });
      //
      // Das hat die Luecke als gewolltes Verhalten festgeschrieben. Genau
      // die Events, die C1 aufreisst, HABEN keine `exceptions`:
      // `FlutterErrorIntegration` baut sein Event aus `throwable` plus
      // `contexts['flutter_error_details']` (flutter_error_integration.dart
      // :66-76) — `exceptions` fuellt erst der Exception-Factory-Lauf im
      // Client, und `contexts`, `breadcrumbs`, `message`, `extra` und
      // `request` haengen sowieso am Event, nicht an der Exception.
      // „Unveraendert durch" hiess also: der ganze Rest des Events geht roh
      // raus, solange nur die Exception-Liste leer ist.
      //
      // Jetzt gilt: der Filter laeuft IMMER ueber das ganze Event. Dass er
      // dasselbe Objekt zurueckgibt (mutiert statt kopiert), bleibt richtig
      // und wird hier weiter festgehalten — aber der Inhalt ist danach
      // gefiltert, nicht unangetastet.
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
  // C1, Leck 2 (Welle 6): alles am Event ausserhalb von exceptions[].value.
  // ---------------------------------------------------------------------

  group('sanitizeSentryEvent — contexts', () {
    test(
        'contexts[flutter_error_details] wird verworfen: information ist der '
        'gerenderte Diagnostics-Baum', () {
      // sentry_flutter-9.26.0/lib/src/integrations/flutter_error_integration
      // .dart:38-50,72 haengt genau diese Map ans Event, und
      // sentry-9.26.0/lib/src/protocol/contexts.dart `toJson` schiebt
      // unbekannte Schluessel im `default:`-Zweig unveraendert raus.
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
      // `formatted` traegt die eingesetzten Laufzeitwerte, `template` ist ein
      // Literal aus dem Quelltext. Nur das Literal ist per Konstruktion frei
      // von Nutzerdaten — und es reicht Sentry zum Gruppieren.
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
      // sendDefaultPii ist aus und die App ruft nirgends scope.setUser. Ein
      // gefuelltes user-Objekt kann hier also nur aus einem kuenftigen
      // Versehen oder aus dem nativen Scope stammen.
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
      // Zweite Reihe hinter beforeBreadcrumb: `load_contexts_integration
      // .dart:263` schreibt native Breadcrumbs direkt in `event.breadcrumbs`,
      // und ein Event kann auch von Hand mit Breadcrumbs gebaut werden.
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
      // sentry_client.dart:571 loggt den Throw nur und
      // sentry_client.dart:580 verwirft dann das Event. Ein kaputter Filter
      // waere also ein stiller Totalausfall des Crash-Reportings.
      final event = SentryEvent(message: SentryMessage('x'));
      expect(() => sanitizeSentryEvent(event, Hint()), returnsNormally);
    });
  });
}
