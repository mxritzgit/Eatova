// AUDIT 2026-08-14 — Deeplink-Session-Kaperung.
//
// Der Deeplink-Beobachter von supabase_flutter lief mit Default-Verhalten:
// jede eingehende URI mit `access_token`, `code`, `error`, `error_code` oder
// `error_description` — im Query ODER im Fragment — ging an
// `getSessionFromUrl` (supabase_auth.dart:222-233). Und dort ist der
// PKCE-Zwang abschaltbar: gotrue-2.27.1 prueft den Flow-Typ nur, wenn KEIN
// `access_token` in der URL steht (gotrue_client.dart:1014-1019).
//
// Der Intent-Filter (`android/app/src/main/AndroidManifest.xml`) ist
// BROWSABLE mit `autoVerify="false"` — jede fremde App und jede Webseite darf
// `eatova://…` schicken. Ein
// `eatova://login-callback/#access_token=…&refresh_token=…&token_type=…&expires_in=…`
// war damit ein vollwertiger Login OHNE Code-Verifier: der Nutzer haette
// seine Mahlzeiten, sein Gewicht und seinen Coach-Chat unbemerkt in ein
// ANGREIFERKONTO protokolliert. Die harmlosere Variante desselben Lochs ist
// der stille Zwangs-Logout.
//
// Geprueft wird auf zwei Ebenen:
//
//   1. Das Praedikat selbst (`isOAuthCallbackDeeplink`) — Tabellenfaelle.
//   2. Die VERDRAHTUNG: dass es tatsaechlich in den `authOptions` des echten
//      `EatovaSupabaseConfig.initialize()` landet. Ohne diesen zweiten Teil
//      bliebe der Waechter gruen, wenn jemand die eine Zeile
//      `detectSessionInUriPredicate:` entfernt (Vorbild:
//      `test/wiring_supabase_session_storage_test.dart`).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/supabase_config.dart';

bool _laesstDurch(String uri) =>
    EatovaSupabaseConfig.isOAuthCallbackDeeplink(Uri.parse(uri));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isOAuthCallbackDeeplink', () {
    test('laesst den echten PKCE-Rueckweg durch', () {
      expect(_laesstDurch('eatova://login-callback/?code=abc'), isTrue);
      // Supabase haengt an den Callback noch Zusatzparameter; der Weg muss
      // trotzdem offen bleiben, sonst waere der Google-Login tot.
      expect(
        _laesstDurch('eatova://login-callback/?code=abc&type=signup'),
        isTrue,
      );
      // Scheme und Host sind laut RFC 3986 case-insensitiv und werden von
      // `Uri.parse` normalisiert — der Vergleich darf daran nicht scheitern.
      expect(_laesstDurch('EATOVA://LOGIN-CALLBACK/?code=abc'), isTrue);
    });

    test('lehnt Implicit-Flow-Token im FRAGMENT ab', () {
      // Der eigentliche Angriff. `uri.queryParameters` ist hier leer —
      // `getSessionFromUrl` ersetzt `#` aber durch `?`/`&` und liest die
      // Token trotzdem. Wer nur den Query prueft, prueft nichts.
      expect(
        _laesstDurch(
          'eatova://login-callback/#access_token=x&refresh_token=y',
        ),
        isFalse,
      );
      expect(
        _laesstDurch('eatova://login-callback/#token_type=bearer'),
        isFalse,
      );
    });

    test('lehnt Implicit-Flow-Token im QUERY ab', () {
      expect(
        _laesstDurch(
          'eatova://login-callback/?access_token=x&refresh_token=y',
        ),
        isFalse,
      );
      expect(
        _laesstDurch('eatova://login-callback/?token_type=bearer'),
        isFalse,
      );
    });

    test('lehnt ein gueltiges `code` ab, das Token huckepack traegt', () {
      // Die gemeinste Variante: sieht aus wie der echte Rueckweg, aber
      // `getSessionFromUrl` nimmt nach dem `#`→`&`-Ersatz den access_token —
      // und ueberspringt damit die PKCE-Pruefung.
      expect(
        _laesstDurch(
          'eatova://login-callback/?code=abc#access_token=x&refresh_token=y',
        ),
        isFalse,
      );
    });

    test('lehnt ein fremdes Scheme ab', () {
      expect(_laesstDurch('fitpilot://login-callback/?code=abc'), isFalse);
      expect(_laesstDurch('https://login-callback/?code=abc'), isFalse);
    });

    test('lehnt einen fremden Host bei richtigem Scheme ab', () {
      expect(_laesstDurch('eatova://untergeschoben/?code=abc'), isFalse);
      // Kein Praefix-Vergleich: `login-callback.example.com` ist NICHT unser
      // Host.
      expect(
        _laesstDurch('eatova://login-callback.example.com/?code=abc'),
        isFalse,
      );
    });

    test('lehnt eine URI ohne code und ohne Token ab', () {
      expect(_laesstDurch('eatova://login-callback/'), isFalse);
      expect(_laesstDurch('eatova://login-callback/?foo=bar'), isFalse);
      // Reset und E-Mail-Wechsel laufen ueber 8-stellige Codes (siehe
      // `auth_repository.dart:140` und `:197`) — es gibt keinen
      // Recovery-Link, der hier durchmuesste.
      expect(_laesstDurch('eatova://login-callback/?type=recovery'), isFalse);
      // Fehler-Rueckmeldungen: die App zeigt daraus nichts an, ein
      // Fremd-Deep-Link koennte sonst eine erfundene Meldung in den
      // Auth-Stream schieben.
      expect(
        _laesstDurch('eatova://login-callback/?error_description=gesperrt'),
        isFalse,
      );
    });

    test('wirft nicht bei unlesbaren Prozent-Escapes', () {
      // `%C3%28` ist syntaktisch gueltig (Uri.parse laesst es stehen), aber
      // kein gueltiges UTF-8 — `queryParameters`/`splitQueryString` werfen
      // darauf FormatException. supabase_flutter ruft das Praedikat VOR
      // seinem try/catch (`_handleDeeplink`, supabase_auth.dart:302-303), ein
      // Wurf waere also ein unbehandelter Zonen-Fehler, ausgeloest von einer
      // URI, die jede fremde App schicken darf.
      expect(_laesstDurch('eatova://login-callback/#%C3%28=x'), isFalse);
      expect(_laesstDurch('eatova://login-callback/?%C3%28=x&code=abc'),
          isFalse);
    });
  });

  group('Verdrahtung am Produktionspfad', () {
    // Der Deeplink-Kanal von app_links. Ueber ihn schiebt die Plattform die
    // eingehende URI in `SupabaseAuth._handleIncomingLinks`; hier spielen wir
    // die Plattform.
    const EventChannel deeplinkKanal =
        EventChannel('com.llfbandit.app_links/events');

    /// Alles, was `getSessionFromUrl` an Fehlern in den Auth-Stream gibt
    /// (`notifyException`). Ein Eintrag beweist, dass die URI dort ANKAM.
    final List<String> ausGetSessionFromUrl = <String>[];

    tearDownAll(() async {
      if (Supabase.instance.isInitialized) {
        await Supabase.instance.dispose();
      }
    });

    test(
      'nur der echte OAuth-Rueckweg erreicht getSessionFromUrl — '
      'untergeschobene eatova://-Links nicht',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        FlutterSecureStorage.setMockInitialValues(<String, String>{});

        MockStreamHandlerEventSink? plattform;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
          deeplinkKanal,
          MockStreamHandler.inline(
            onListen: (Object? arguments, MockStreamHandlerEventSink events) {
              plattform = events;
            },
          ),
        );

        // `_wireOAuthSheetDismiss` hoert ohne `onError` auf den Auth-Stream.
        // Ein `notifyException` liefe von dort als unbehandelter Fehler in die
        // Zone, in der `listen()` aufgerufen wurde — also in diese hier, wo
        // wir ihn einsammeln statt den Test daran platzen zu lassen.
        await runZonedGuarded<Future<void>>(
          EatovaSupabaseConfig.initialize,
          (Object fehler, StackTrace stack) =>
              ausGetSessionFromUrl.add(fehler.toString()),
        );

        Supabase.instance.client.auth.onAuthStateChange.listen(
          (_) {},
          onError: (Object fehler) =>
              ausGetSessionFromUrl.add(fehler.toString()),
        );

        await pumpEventQueue(times: 50);
        expect(plattform, isNotNull,
            reason: 'Ohne laufenden Deeplink-Beobachter prueft dieser Test '
                'nichts — dann waere `detectSessionInUri` abgeschaltet.');

        // Die drei Sonden sind bewusst so gewaehlt, dass `getSessionFromUrl`
        // bei jeder von ihnen OHNE Netzzugriff mit einer eindeutigen
        // AuthException abbricht. So ist „ist angekommen" beobachtbar, ohne
        // dass der Test je eine Verbindung braucht.

        // 1) Der Angriff: Implicit-Flow-Token im Fragment. Ohne das Praedikat
        //    landet das bei `getSessionFromUrl` und scheitert dort erst am
        //    fehlenden `expires_in`.
        plattform!.success(
          'eatova://login-callback/'
          '#access_token=gestohlen&refresh_token=gestohlen'
          '&token_type=bearer',
        );

        // 2) Fremder Host mit Fehlerparameter — die Default-Heuristik nimmt
        //    auch den an und wirft die Fremdmeldung in den Auth-Stream. Der
        //    Android-Intent-Filter bindet den Host, die iOS-URL-Schemes tun
        //    das NICHT: dort kommt `eatova://irgendwas` genauso an.
        plattform!.success(
          'eatova://untergeschoben/?error_description=Konto+gesperrt',
        );

        // 3) Der echte Rueckweg. Muss ANKOMMEN, sonst haetten wir den
        //    Google-Login mitabgeschaltet. Ohne hinterlegten Code-Verifier
        //    bricht der Austausch lokal ab — genau das ist unser Beleg.
        plattform!.success('eatova://login-callback/?code=abc');

        await pumpEventQueue(times: 50);

        expect(
          ausGetSessionFromUrl.join('\n'),
          isNot(contains('expires_in')),
          reason: 'Der untergeschobene Token-Link darf getSessionFromUrl nie '
              'erreichen — dort greift der PKCE-Zwang nicht, sobald ein '
              'access_token in der URL steht.',
        );
        expect(
          ausGetSessionFromUrl.join('\n'),
          isNot(contains('Konto gesperrt')),
          reason: 'Ein fremder Host darf gar nicht erst als Auth-Callback '
              'gelten.',
        );
        expect(
          ausGetSessionFromUrl.join('\n'),
          contains('Code verifier'),
          reason: 'Der echte PKCE-Rueckweg muss weiterhin durchgereicht '
              'werden — sonst ist der Google-Login tot.',
        );
        expect(Supabase.instance.client.auth.currentSession, isNull);
      },
    );
  });
}
