import 'package:eatova/src/services/crash_reporter.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// C1, Leck 4: `exceptions[].mechanism`.
///
/// `beforeSend` sanitisierte lange nur `exceptions[].value`. Der von
/// `SentryFlutter.init` per Default registrierte
/// `PlatformExceptionEventProcessor` legt `code` und `message` der
/// `PlatformException` aber zusaetzlich in `mechanism.data` ab
/// (`platform_exception_event_processor.dart:27-38`) — und Event-Prozessoren
/// laufen VOR `beforeSend` (`sentry_client.dart:160-177`). Genau der Text, den
/// die Allowlist in `sanitizeForReport` auf der `value`-Seite zurueckhaelt,
/// ging damit ueber `mechanism.data['message']` doch hinaus.
void main() {
  // Der reale Fall: Google Sign-In gibt die Server-Begruendung woertlich in
  // `PlatformException.message` zurueck, samt Konto und Anmelde-Token.
  const String email = 'max@example.com';
  const String token =
      'ya29.a0AfB_byC-3kQm7Zx1LpR9vTn4WqE8sJhG2dYbN6cVfU0iKoP';

  final PlatformException platform = PlatformException(
    code: 'sign_in_failed',
    message: 'com.google.android.gms.common.api.ApiException: 10: '
        'Konto $email abgelehnt (access_token=$token)',
    details: 'Failing account: $email',
  );

  /// Baut das Event exakt so, wie es der `PlatformExceptionEventProcessor` an
  /// `beforeSend` uebergibt: `value` aus `throwable.toString()`, dazu ein
  /// `mechanism` vom Typ `platformException` mit `code` und `message`.
  SentryEvent eventWiePlatformProzessor(PlatformException fehler) => SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'PlatformException',
            value: fehler.toString(),
            throwable: fehler,
            mechanism: Mechanism(
              type: 'platformException',
              handled: false,
              data: <String, dynamic>{
                'code': fehler.code,
                'message': fehler.message,
              },
            ),
          ),
        ],
      );

  group('sanitizeSentryEvent — mechanism.data', () {
    test('weder E-Mail noch Token ueberleben in mechanism.data', () {
      final SentryEvent sanitisiert =
          sanitizeSentryEvent(eventWiePlatformProzessor(platform), Hint())!;

      final Mechanism mechanism = sanitisiert.exceptions!.single.mechanism!;

      expect(mechanism.data.toString(), isNot(contains(email)),
          reason: 'die E-Mail ist ein direkter Personenbezug');
      expect(mechanism.data.toString(), isNot(contains('ya29.')),
          reason: 'auch der Token-Praefix allein ist ein Anmeldegeheimnis');
      expect(mechanism.data['message'], isNull,
          reason: 'PlatformException.message steht nicht auf der Allowlist — '
              'auf der value-Seite wird sie schon zurueckgehalten');
    });

    test('nichts davon steht mehr im serialisierten Event', () {
      // Der eigentliche Beleg: was `toJson` liefert, ist woertlich das, was
      // das Geraet verlaesst.
      final SentryEvent sanitisiert =
          sanitizeSentryEvent(eventWiePlatformProzessor(platform), Hint())!;

      final String nutzlast = sanitisiert.toJson().toString();

      expect(nutzlast, isNot(contains(email)));
      expect(nutzlast, isNot(contains(token)));
      expect(nutzlast, isNot(contains('ApiException')),
          reason: 'die Server-Begruendung ist Fremdtext ohne Schema');
    });

    test('der code bleibt — sonst ist der Report wertlos', () {
      // `code` ist ein vom Plugin vergebener Konstant-String und genau das
      // Feld, das sanitizeForReport auch in `value` durchlaesst.
      final SentryEvent sanitisiert =
          sanitizeSentryEvent(eventWiePlatformProzessor(platform), Hint())!;

      final SentryException e = sanitisiert.exceptions!.single;

      expect(e.mechanism!.data['code'], 'sign_in_failed');
      expect(e.value, contains('code=sign_in_failed'),
          reason: 'mechanism und value duerfen nicht auseinanderlaufen');
    });

    test('das Geruest des Mechanismus bleibt stehen', () {
      // `type` und `handled` steuern in Sentry die Unhandled-Markierung, die
      // Gruppen-IDs die Darstellung verketteter Exceptions. Beides sind
      // Konstanten bzw. Indizes und darf die Redaktion ueberleben.
      final SentryEvent event = eventWiePlatformProzessor(platform);
      event.exceptions!.single.mechanism!
        ..source = 'originalError'
        ..exceptionId = 1
        ..parentId = 0
        ..isExceptionGroup = false;

      final Mechanism mechanism =
          sanitizeSentryEvent(event, Hint())!.exceptions!.single.mechanism!;

      expect(mechanism.type, 'platformException');
      expect(mechanism.handled, isFalse);
      expect(mechanism.source, 'originalError');
      expect(mechanism.exceptionId, 1);
      expect(mechanism.parentId, 0);
      expect(mechanism.isExceptionGroup, isFalse);
    });

    test('description faellt weg — das ist Freitext', () {
      // `SentryHttpClient` setzt dort die rohe Fehlerbegruendung
      // (`failed_request_client.dart:183-186`).
      final SentryEvent event = eventWiePlatformProzessor(platform);
      event.exceptions!.single.mechanism!.description =
          'Exception while fetching profile of $email';

      final Mechanism mechanism =
          sanitizeSentryEvent(event, Hint())!.exceptions!.single.mechanism!;

      expect(mechanism.description, isNull);
    });
  });

  group('sanitizeSentryEvent — mechanism.meta', () {
    test('meta wird geleert — die Eintraege passen nie auf die Allowlist', () {
      // `meta` ist im Protokoll fuer Betriebssystem-Fehlercodes gedacht
      // (`io_exception_event_processor.dart:120-126`), ist aber eine offene
      // Map: ein Prozessor kann dort alles ablegen.
      final SentryEvent event = eventWiePlatformProzessor(platform);
      event.exceptions!.single.mechanism = Mechanism(
        type: 'platformException',
        meta: <String, dynamic>{
          'errno': <String, dynamic>{'number': 10},
          'signal': 'Konto $email, Token $token',
        },
      );

      final Mechanism mechanism =
          sanitizeSentryEvent(event, Hint())!.exceptions!.single.mechanism!;

      expect(mechanism.meta, isEmpty);
      expect(mechanism.meta.toString(), isNot(contains(email)));
    });
  });

  group('sanitizeSentryEvent — mechanism ohne throwable', () {
    test(
        'aus dem nativen Layer geloggte Events verlieren ihre mechanism-Daten '
        'komplett', () {
      // Ohne `throwable` faellt `value` auf den blossen Typnamen zurueck —
      // dann gibt es nichts, was ein mechanism-Feld noch decken koennte.
      final SentryEvent event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'PlatformException',
            value: platform.toString(),
            mechanism: Mechanism(
              type: 'platformException',
              data: <String, dynamic>{
                'code': 'sign_in_failed',
                'message': 'Konto $email abgelehnt',
              },
            ),
          ),
        ],
      );

      final SentryException e =
          sanitizeSentryEvent(event, Hint())!.exceptions!.single;

      expect(e.value, 'PlatformException');
      expect(e.mechanism!.data, isEmpty);
      expect(e.mechanism!.type, 'platformException',
          reason: 'der Mechanismus-Typ selbst ist eine Konstante der SDK');
    });
  });

  group('sanitizeSentryEvent — mechanism, Robustheit', () {
    test('ein Exception-Eintrag ohne mechanism bleibt ohne mechanism', () {
      final SentryEvent event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'PlatformException',
            value: platform.toString(),
            throwable: platform,
          ),
        ],
      );

      expect(sanitizeSentryEvent(event, Hint())!.exceptions!.single.mechanism,
          isNull);
    });

    test('doppeltes Sanitisieren aendert am mechanism nichts (idempotent)', () {
      final SentryEvent einmal =
          sanitizeSentryEvent(eventWiePlatformProzessor(platform), Hint())!;
      final SentryEvent zweimal = sanitizeSentryEvent(einmal, Hint())!;

      expect(zweimal.exceptions!.single.mechanism!.data,
          einmal.exceptions!.single.mechanism!.data);
    });

    test('der Hook wirft auch bei kaputten mechanism-Werten nicht', () {
      // Ein Throw aus `beforeSend` verwirft das GANZE Event
      // (`sentry_client.dart:571/580`) — ein stiller Totalausfall.
      final SentryEvent event = eventWiePlatformProzessor(platform);
      event.exceptions!.single.mechanism!.data = <String, dynamic>{
        'code': <String, dynamic>{'verschachtelt': 'sign_in_failed'},
        'message': null,
      };

      expect(() => sanitizeSentryEvent(event, Hint()), returnsNormally);
    });
  });
}
