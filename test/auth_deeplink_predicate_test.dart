// AUDIT 2026-08-14 — deeplink session hijacking.
//
// With supabase_flutter's default deeplink observer, any URI carrying
// `access_token`, `code` or an `error*` parameter — in the query OR the
// fragment — went to `getSessionFromUrl`, and gotrue only enforces PKCE when
// NO `access_token` is present. The intent filter is BROWSABLE, so any app
// could log the user's data into an ATTACKER ACCOUNT.
//
// Checked on two levels: the predicate itself, and the WIRING into the real
// `initialize()` — without that the guard stays green if someone drops the
// `detectSessionInUriPredicate:` line.

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
      // Supabase appends extra parameters to the callback; the path must stay
      // open or the Google login is dead.
      expect(
        _laesstDurch('eatova://login-callback/?code=abc&type=signup'),
        isTrue,
      );
      // Scheme and host are case-insensitive (RFC 3986) and normalised by
      // `Uri.parse`; the comparison must not trip on that.
      expect(_laesstDurch('EATOVA://LOGIN-CALLBACK/?code=abc'), isTrue);
    });

    test('lehnt Implicit-Flow-Token im FRAGMENT ab', () {
      // The actual attack: `queryParameters` is empty, but `getSessionFromUrl`
      // rewrites `#` to `?`/`&` and reads the tokens anyway.
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
      // Looks like the real callback, but after the `#`→`&` rewrite
      // `getSessionFromUrl` takes the access_token and skips PKCE.
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
      // No prefix match: `login-callback.example.com` is NOT our host.
      expect(
        _laesstDurch('eatova://login-callback.example.com/?code=abc'),
        isFalse,
      );
    });

    test('lehnt eine URI ohne code und ohne Token ab', () {
      expect(_laesstDurch('eatova://login-callback/'), isFalse);
      expect(_laesstDurch('eatova://login-callback/?foo=bar'), isFalse);
      // Reset and email change use 8-digit codes, so no recovery link needs to
      // pass here.
      expect(_laesstDurch('eatova://login-callback/?type=recovery'), isFalse);
      // Error parameters: the app shows nothing from them, or a foreign
      // deeplink could push an invented message into the auth stream.
      expect(
        _laesstDurch('eatova://login-callback/?error_description=gesperrt'),
        isFalse,
      );
    });

    test('wirft nicht bei unlesbaren Prozent-Escapes', () {
      // `%C3%28` parses but is not valid UTF-8, so `queryParameters` throws —
      // and the predicate runs BEFORE supabase_flutter's try/catch, making
      // that an unhandled zone error any foreign app could trigger.
      expect(_laesstDurch('eatova://login-callback/#%C3%28=x'), isFalse);
      expect(_laesstDurch('eatova://login-callback/?%C3%28=x&code=abc'),
          isFalse);
    });
  });

  group('Verdrahtung am Produktionspfad', () {
    // The app_links channel feeding `SupabaseAuth._handleIncomingLinks`; this
    // test plays the platform.
    const EventChannel deeplinkKanal =
        EventChannel('com.llfbandit.app_links/events');

    /// Errors `getSessionFromUrl` pushes into the auth stream. An entry proves
    /// the URI ARRIVED there.
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

        // Belt and braces: `_wireOAuthSheetDismiss` has carried an `onError`
        // since the FLUTTER-8 fix, but `initialize` starts more than that one
        // listener, and anything it lets escape would fail the test instead of
        // being collected here.
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

        // Each probe makes `getSessionFromUrl` fail with a distinct
        // AuthException WITHOUT network, so "arrived" is observable offline.

        // 1) The attack: implicit-flow tokens in the fragment, which without
        //    the predicate fail only on the missing `expires_in`.
        plattform!.success(
          'eatova://login-callback/'
          '#access_token=gestohlen&refresh_token=gestohlen'
          '&token_type=bearer',
        );

        // 2) Foreign host with an error parameter, which the default heuristic
        //    accepts. iOS URL schemes do not bind the host at all.
        plattform!.success(
          'eatova://untergeschoben/?error_description=Konto+gesperrt',
        );

        // 3) The real callback. Must ARRIVE, or the Google login is off too;
        //    without a stored code verifier it fails locally, which is proof.
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
