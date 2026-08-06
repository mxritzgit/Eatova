import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fehlerobjekt, dessen toString() selbst wirft — der Worst Case fuer
/// jede Logging-/Reporting-Schicht. CrashReporter muss auch das schlucken.
class _ThrowingToString {
  @override
  String toString() => throw StateError('toString kaputt');
}

void main() {
  group('CrashReporter ohne DSN (Dev/CI/Tests)', () {
    test('DSN ist leer, Facade inaktiv', () {
      // Tests laufen ohne --dart-define=SENTRY_DSN — die Facade muss dann
      // vollstaendig no-op sein (kein Sentry-Hub, kein Netzwerk).
      expect(CrashReporter.dsn, isEmpty);
      expect(CrashReporter.isActive, isFalse);
    });

    test('capture wirft nicht — Standardfall', () async {
      await CrashReporter.capture(
        Exception('sync kaputt'),
        StackTrace.current,
      );
    });

    test('capture wirft nicht — mit context-Label', () async {
      await CrashReporter.capture(
        StateError('boot kaputt'),
        StackTrace.current,
        context: 'boot',
      );
    });

    test('capture wirft nicht — beliebige Fehlertypen', () async {
      // Dart erlaubt `throw` fuer jedes Objekt — die Facade muss alles
      // annehmen, was in einem catch (Object e) landen kann.
      await CrashReporter.capture('nur ein String', StackTrace.empty);
      await CrashReporter.capture(42, StackTrace.empty);
      await CrashReporter.capture(
        const FormatException('kaputtes JSON'),
        StackTrace.empty,
        context: 'meals_sync.load',
      );
    });

    test('capture wirft nicht — Fehlerobjekt mit werfendem toString()',
        () async {
      await CrashReporter.capture(_ThrowingToString(), StackTrace.current);
    });

    test('breadcrumb wirft nicht und ist ohne DSN ein No-Op', () {
      CrashReporter.breadcrumb('outbox replay gestartet');
      CrashReporter.breadcrumb('');
      // Nach Breadcrumbs bleibt die Facade inaktiv — nichts wurde lazy
      // initialisiert.
      expect(CrashReporter.isActive, isFalse);
    });
  });
}
