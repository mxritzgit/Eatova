// G3 (REVIEW-2026-08-08): Diese Datei hatte 6 Tests und insgesamt 3
// `expect()`-Aufrufe. Ein leeres `capture() async {}` haette sie alle
// bestanden — nichts unterschied „schluckt Fehler sicher" von „verwirft
// jeden Crash, auch mit DSN".
//
// Jeder Test hier belegt jetzt BEIDE Richtungen: dass capture nicht wirft
// UND dass es den Report tatsaechlich weiterreicht. Beobachtet wird ueber
// CrashReporter.debugSentrySink / debugBreadcrumbSink — die einzige Stelle,
// an der ohne DSN, ohne Netz und ohne Sentry-Hub sichtbar wird, was Sentry
// bekaeme.
//
// Die Sanitisierung selbst (C1) hat ihre eigene Datei:
// test/services/crash_reporter_sanitize_test.dart.

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fehlerobjekt, dessen toString() selbst wirft — der Worst Case fuer
/// jede Logging-/Reporting-Schicht. CrashReporter muss auch das schlucken.
class _ThrowingToString {
  @override
  String toString() => throw StateError('toString kaputt');
}

void main() {
  final List<Object> gemeldet = <Object>[];
  final List<String?> kontexte = <String?>[];
  final List<String> spuren = <String>[];

  setUp(() {
    gemeldet.clear();
    kontexte.clear();
    spuren.clear();
    CrashReporter.debugSentrySink = (error, stack, context) {
      gemeldet.add(error);
      kontexte.add(context);
    };
    CrashReporter.debugBreadcrumbSink = spuren.add;
  });

  tearDown(() {
    CrashReporter.debugSentrySink = null;
    CrashReporter.debugBreadcrumbSink = null;
  });

  group('CrashReporter ohne DSN (Dev/CI/Tests)', () {
    test('DSN ist leer, Facade inaktiv, kein Sentry-Hub', () {
      // Tests laufen ohne --dart-define=SENTRY_DSN — die Facade muss dann
      // vollstaendig no-op sein (kein Sentry-Hub, kein Netzwerk). isActive
      // ist die einzige Schranke davor, also wird sie hier festgenagelt.
      expect(CrashReporter.dsn, isEmpty);
      expect(CrashReporter.isActive, isFalse);
    });

    test('capture reicht den Fehler weiter statt ihn zu verschlucken',
        () async {
      // Der eigentliche Punkt von G3: ein leeres `capture() async {}` faellt
      // genau hier durch.
      await CrashReporter.capture(
        Exception('sync kaputt'),
        StackTrace.current,
      );

      expect(gemeldet, hasLength(1));
      expect(gemeldet.single, isA<SanitizedError>());
      expect((gemeldet.single as SanitizedError).type, '_Exception');
      expect(kontexte.single, isNull);
    });

    test('capture haengt das context-Label an den Report', () async {
      await CrashReporter.capture(
        StateError('boot kaputt'),
        StackTrace.current,
        context: 'boot',
      );

      expect(gemeldet, hasLength(1));
      expect(kontexte.single, 'boot');
      expect((gemeldet.single as SanitizedError).type, 'StateError');
    });

    test('capture nimmt jeden Fehlertyp an und meldet jeden einzeln', () async {
      // Dart erlaubt `throw` fuer jedes Objekt — die Facade muss alles
      // annehmen, was in einem catch (Object e) landen kann, und darf dabei
      // keinen Aufruf unter den Tisch fallen lassen.
      await CrashReporter.capture('nur ein String', StackTrace.empty);
      await CrashReporter.capture(42, StackTrace.empty);
      await CrashReporter.capture(
        const FormatException('kaputtes JSON'),
        StackTrace.empty,
        context: 'meals_sync.load',
      );

      expect(gemeldet, hasLength(3));
      expect(
        gemeldet.map((e) => (e as SanitizedError).type).toList(),
        <String>['String', 'int', 'FormatException'],
      );
      expect(kontexte, <String?>[null, null, 'meals_sync.load']);
    });

    test('capture ueberlebt ein Fehlerobjekt mit werfendem toString() '
        'und meldet es trotzdem', () async {
      // Vorher belegte dieser Test nur „wirft nicht" — was auch ein stiller
      // Totalausfall erfuellt haette. Jetzt muss der Report ankommen, und
      // zwar OHNE dass irgendwer toString() aufgerufen hat.
      await CrashReporter.capture(_ThrowingToString(), StackTrace.current);

      expect(gemeldet, hasLength(1));
      expect((gemeldet.single as SanitizedError).type, '_ThrowingToString');
      expect(gemeldet.single.toString(), '_ThrowingToString');
    });

    test('capture propagiert nichts, auch wenn die Senke selbst wirft',
        () async {
      CrashReporter.debugSentrySink = (error, stack, context) {
        throw StateError('Senke kaputt');
      };

      // Reporting darf den Fehlerpfad des Aufrufers nie mitreissen.
      await expectLater(
        CrashReporter.capture(Exception('x'), StackTrace.current),
        completes,
      );
    });

    test('capture ist ohne Senke und ohne DSN ein sauberer No-Op', () {
      CrashReporter.debugSentrySink = null;

      // Der Produktionspfad in Dev/CI: kein Hub, kein Netz, kein Throw.
      expect(CrashReporter.isActive, isFalse);
      expect(
        CrashReporter.capture(
          const FormatException('kaputtes JSON'),
          StackTrace.current,
        ),
        completes,
      );
    });

    test('capture reicht den Stacktrace unveraendert durch', () async {
      final StackTrace stack = StackTrace.current;
      StackTrace? gesehen;
      CrashReporter.debugSentrySink = (error, s, context) => gesehen = s;

      await CrashReporter.capture(Exception('x'), stack);

      expect(gesehen, same(stack));
    });

    test('breadcrumb reicht die Spur weiter und wirft nie', () {
      CrashReporter.breadcrumb('outbox replay gestartet');
      CrashReporter.breadcrumb('outbox-cap: 3 ops dropped');
      CrashReporter.breadcrumb('');

      // Wortlaut unveraendert: der Aufrufer verantwortet den Inhalt (siehe
      // breadcrumb-Doku), die Facade darf ihn nicht stillschweigend
      // umschreiben oder verwerfen.
      expect(spuren, <String>[
        'outbox replay gestartet',
        'outbox-cap: 3 ops dropped',
        '',
      ]);
    });

    test('breadcrumb ist ohne Senke und ohne DSN ein No-Op', () {
      CrashReporter.debugBreadcrumbSink = null;

      CrashReporter.breadcrumb('outbox replay gestartet');

      // Nach Breadcrumbs bleibt die Facade inaktiv — nichts wurde lazy
      // initialisiert, kein Hub ist entstanden.
      expect(CrashReporter.isActive, isFalse);
      expect(spuren, isEmpty);
    });

    test('breadcrumb propagiert nichts, auch wenn die Senke wirft', () {
      CrashReporter.debugBreadcrumbSink = (message) {
        throw StateError('Senke kaputt');
      };

      expect(() => CrashReporter.breadcrumb('x'), returnsNormally);
    });
  });
}
