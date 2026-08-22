// G3: an empty `capture() async {}` used to pass this whole file — nothing
// distinguished "swallows errors safely" from "drops every crash, DSN or not".
//
// Every test now proves BOTH directions: capture does not throw AND it
// actually forwards the report. Observed via CrashReporter.debugSentrySink /
// debugBreadcrumbSink, the only place that shows what Sentry would get without
// a DSN, network or hub.
//
// Sanitisation itself (C1) lives in crash_reporter_sanitize_test.dart.

import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Error object whose toString() throws — the worst case for any reporting
/// layer. CrashReporter must swallow this too.
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
      // Tests run without --dart-define=SENTRY_DSN, so the facade must be a
      // full no-op. `isActive` is the only gate, so it is pinned here.
      expect(CrashReporter.dsn, isEmpty);
      expect(CrashReporter.isActive, isFalse);
    });

    test('capture reicht den Fehler weiter statt ihn zu verschlucken',
        () async {
      // The point of G3: an empty `capture() async {}` fails exactly here.
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
      // Dart allows `throw` on any object, so the facade must accept anything
      // a catch (Object e) can hold and must not drop a single call.
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
      // The report must arrive, and WITHOUT anyone calling toString().
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

      // Reporting must never tear down the caller's error path.
      await expectLater(
        CrashReporter.capture(Exception('x'), StackTrace.current),
        completes,
      );
    });

    test('capture ist ohne Senke und ohne DSN ein sauberer No-Op', () {
      CrashReporter.debugSentrySink = null;

      // The production path in dev/CI: no hub, no network, no throw.
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

      // Wording unchanged: the caller owns the content, the facade must not
      // silently rewrite or drop it.
      expect(spuren, <String>[
        'outbox replay gestartet',
        'outbox-cap: 3 ops dropped',
        '',
      ]);
    });

    test('breadcrumb ist ohne Senke und ohne DSN ein No-Op', () {
      CrashReporter.debugBreadcrumbSink = null;

      CrashReporter.breadcrumb('outbox replay gestartet');

      // The facade stays inactive after breadcrumbs — nothing lazily
      // initialised, no hub created.
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
