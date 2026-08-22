// WIRING GUARD C5 — the session storage on the production path.
//
// `test/services/session_storage_test.dart` exercises
// `SecureSessionLocalStorage` thoroughly, but only through
// `EatovaSupabaseConfig.buildSessionStorage(...)` — the seam production does
// not use. What makes those properties effective is the `localStorage:
// buildSessionStorage()` override in supabase_config.dart; without it the
// Supabase default `SharedPreferencesLocalStorage` puts both tokens in
// plaintext next to the encrypted health blobs. Deleting those lines left all
// other tests green.
//
// This test drives the REAL `EatovaSupabaseConfig.initialize()` without
// touching the network: both storages run on their packages' in-memory test
// platforms, and the access token is deliberately NOT a JWT, so `expiresAt`
// stays null, `isExpired` is false and `recoverSession` never refreshes.
// `Supabase` is a process singleton, so initialize runs once here and is
// disposed in tearDown.
//
// It observes the result of the one-time migration, the sharpest observable
// difference between the two storages: with the override the plaintext moves
// into the keystore and is wiped, without it the plaintext stays and the
// keystore stays empty. The guard survives renames and reformatting because
// it checks WHERE the tokens physically end up.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/supabase_config.dart';

/// The master key to the account. If it shows up anywhere in
/// SharedPreferences, C5 is back.
const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-klartext';

/// Deliberately NOT a JWT (see the header): `expiresAt` stays null, the
/// session counts as unexpired and `recoverSession` never hits the network.
const String _accessToken = 'access-token-ohne-jwt-struktur';

const String _userId = '11111111-2222-3333-4444-555555555555';

const String _bestandsSession = '{"access_token":"$_accessToken",'
    '"refresh_token":"$_refreshToken","token_type":"bearer",'
    '"expires_in":3600,'
    '"user":{"id":"$_userId","aud":"authenticated",'
    '"created_at":"2026-01-01T00:00:00Z",'
    '"email":"nutzer@example.de","app_metadata":{},"user_metadata":{}}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The in-memory keystore served by `TestFlutterSecureStoragePlatform`.
  /// What lands here would live in the Android Keystore / iOS Keychain.
  final Map<String, String> keystore = <String, String>{};

  tearDownAll(() async {
    if (Supabase.instance.isInitialized) {
      await Supabase.instance.dispose();
    }
  });

  test(
    'C5-Verdrahtung: nach einem echten App-Start liegen Access- und '
    'Refresh-Token im Keystore — nicht im Klartext in SharedPreferences',
    () async {
      final key = EatovaSupabaseConfig.sessionPersistKey;

      // Starting point: an existing user whose pre-C5 session still sits in
      // plaintext in SharedPreferences.
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: _bestandsSession,
        // An unrelated neighbouring entry, so "the plaintext slot was wiped"
        // cannot be confused with "the prefs are empty".
        'eatova_irgendein_anderer_slot': '{"harmlos":true}',
      });
      keystore.clear();
      FlutterSecureStorage.setMockInitialValues(keystore);

      // The real production path.
      await EatovaSupabaseConfig.initialize();

      // 1) The token is in the keystore. Without `authOptions` this map would
      //    stay empty — SharedPreferencesLocalStorage never touches it.
      expect(keystore[key], isNotNull,
          reason: 'Ohne den localStorage-Override greift der Supabase-Default '
              'SharedPreferencesLocalStorage und der Keystore bleibt leer.');
      expect(keystore[key], contains(_refreshToken));

      // 2) And it is nowhere in plaintext. Searched across ALL prefs values,
      //    not just the known slot: another plaintext location is the same
      //    damage.
      final prefs = await SharedPreferences.getInstance();
      final alleWerte =
          prefs.getKeys().map((k) => prefs.get(k).toString()).join('\n');
      expect(alleWerte, isNot(contains(_refreshToken)),
          reason: 'Der Refresh-Token ist der Generalschluessel zum Konto — er '
              'darf nicht neben den verschluesselten Health-Blobs im Klartext '
              'in FlutterSharedPreferences.xml liegen.');
      expect(alleWerte, isNot(contains(_accessToken)));
      expect(prefs.containsKey(key), isFalse,
          reason: 'Der Klartext-Slot muss nach der Migration weg sein.');
      expect(prefs.containsKey('eatova_irgendein_anderer_slot'), isTrue,
          reason: 'Nur der Session-Slot wird geraeumt, nicht der ganze Store.');

      // 3) The migration must not log existing users out — the session has to
      //    be recovered from the keystore.
      final session = Supabase.instance.client.auth.currentSession;
      expect(session, isNotNull,
          reason: 'Ohne funktionierende Migration waere beim Update JEDER '
              'eingeloggte Nutzer auf dem Login-Screen gelandet.');
      expect(session!.refreshToken, _refreshToken);
      expect(session.user.id, _userId);
    },
  );

  test(
    'PKCE-Verdrahtung: der Code-Verifier landet im Keystore, nicht im '
    'Klartext in SharedPreferences',
    () async {
      // `getOAuthSignInUrl` creates the PKCE verifier and stores it through
      // the configured `pkceAsyncStorage` — no browser, no network, and the
      // same storage path `signInWithOAuth` takes.
      //
      // The verifier is short-lived but real: whoever grabs it AND the
      // callback link can do the code exchange. It was the last auth artifact
      // still stored in plaintext by default.
      await Supabase.instance.client.auth
          .getOAuthSignInUrl(provider: OAuthProvider.google);

      final imKeystore =
          keystore.keys.where((k) => k.contains('code-verifier'));
      expect(imKeystore, isNotEmpty,
          reason: 'Ohne pkceAsyncStorage-Override greift der '
              'SharedPreferences-Default und der Keystore sieht nie einen '
              'Verifier.');

      final prefs = await SharedPreferences.getInstance();
      final verifierInPrefs =
          prefs.getKeys().where((k) => k.contains('code-verifier'));
      expect(verifierInPrefs, isEmpty,
          reason: 'Der Verifier darf nicht neben den verschluesselten Blobs '
              'im Klartext liegen — C5 gilt fuer JEDEN Auth-Baustein.');
    },
  );
}
