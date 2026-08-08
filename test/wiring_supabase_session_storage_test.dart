// VERDRAHTUNGS-WAECHTER C5 — der Session-Storage am Produktionspfad.
//
// `test/services/session_storage_test.dart` treibt `SecureSessionLocalStorage`
// sehr gruendlich: Persistenz im Keystore, Einmal-Migration, Logout, defekter
// Keystore, Key-Gleichheit. Es betritt die Klasse aber ausschliesslich ueber
// `EatovaSupabaseConfig.buildSessionStorage(...)` — also ueber genau die Naht,
// die die Produktion danach nicht mehr benutzt.
//
// Die drei Zeilen, die die geprueften Eigenschaften ueberhaupt erst wirksam
// machen, sind diese hier (lib/src/config/supabase_config.dart:71-73):
//
//     authOptions: FlutterAuthClientOptions(
//       localStorage: buildSessionStorage(),
//     ),
//
// Ohne sie greift der Default aus `Supabase.initialize`
// (supabase_flutter-2.17.1/lib/src/supabase.dart:128-137):
// `SharedPreferencesLocalStorage`. Access- UND Refresh-Token liegen dann als
// Klartext-JSON in genau der `FlutterSharedPreferences.xml`, deren
// Health-Blobs seit 7f895f9 AES-256-GCM-verschluesselt sind — der Angreifer,
// gegen den die Verschluesselung gebaut wurde (Extraktion vom RUHENDEN
// Geraet), nimmt dann einfach den Refresh-Token und holt sich Mahlzeiten,
// Gewicht, Schlaf und Coach-Chat ueber das Netz.
//
// Vor dieser Datei blieben nach dem Loeschen der drei Zeilen 21 von 21 Tests
// gruen, bei sauberem `flutter analyze`.
//
// WIE HIER GEPRUEFT WIRD (und warum das trotz `Supabase.initialize` geht)
//
// Der Test faehrt den ECHTEN `EatovaSupabaseConfig.initialize()`. Das ist
// moeglich, ohne das Netz anzufassen:
//   * SharedPreferences und flutter_secure_storage laufen ueber die
//     In-Memory-Test-Plattformen der jeweiligen Pakete
//     (`setMockInitialValues`) — kein Plugin-Channel.
//   * Der Access-Token der vorgelegten Session ist bewusst KEIN JWT. `Session`
//     leitet `expiresAt` aus dem JWT-Payload ab (gotrue-2.27.1
//     `types/session.dart:76-82`); scheitert das, ist `expiresAt == null` und
//     `isExpired` liefert `false`. `recoverSession` nimmt damit den
//     Nicht-Ablauf-Zweig und ruft NIE `_callRefreshToken` — es gibt keinen
//     HTTP-Verkehr.
//   * `Supabase` ist ein Prozess-Singleton: `initialize` laeuft deshalb genau
//     einmal, in genau dieser Datei, und wird im tearDown entsorgt.
//
// Beobachtet wird das Ergebnis der Einmal-Migration, weil sie das schaerfste
// beobachtbare Unterscheidungsmerkmal der beiden Storages ist:
//
//   mit den drei Zeilen : Klartext wandert aus SharedPreferences in den
//                         Keystore und wird dort geraeumt
//   ohne die drei Zeilen: der Klartext bleibt liegen, der Keystore bleibt leer
//
// EINSTUFUNG: stark — geprueft wird, WO die Token nach einem echten App-Start
// physisch liegen, nicht ob eine Quelltextzeile existiert. Der Waechter
// ueberlebt Umbenennungen (`buildSessionStorage`, `SecureSessionLocalStorage`),
// Umformatierung und jeden Umbau der Konfiguration, solange die Token am Ende
// im Keystore und nicht im Klartext landen.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/supabase_config.dart';

/// Der Generalschluessel zum Konto. Taucht er irgendwo in SharedPreferences
/// auf, ist C5 zurueck.
const String _refreshToken = 'refresh-o5Xq7c9aTtZZ-nicht-im-klartext';

/// Bewusst KEIN JWT (siehe Kopfkommentar): so bleibt `expiresAt` null, die
/// Session gilt als nicht abgelaufen und `recoverSession` geht nie ins Netz.
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

  /// Der In-Memory-Keystore, den `TestFlutterSecureStoragePlatform` bedient.
  /// Was hier landet, laege auf dem Geraet im Android Keystore / der iOS
  /// Keychain.
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

      // Ausgangslage: ein Bestandsnutzer, dessen Session noch aus der Zeit vor
      // C5 im Klartext in SharedPreferences steht.
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: _bestandsSession,
        // Ein unbeteiligter Nachbar-Eintrag, damit die Aussage „der
        // Klartext-Slot wurde geraeumt" nicht mit „die Prefs sind leer"
        // verwechselt werden kann.
        'eatova_irgendein_anderer_slot': '{"harmlos":true}',
      });
      keystore.clear();
      FlutterSecureStorage.setMockInitialValues(keystore);

      // Der echte Produktionspfad. Genau hier haengen die drei Zeilen.
      await EatovaSupabaseConfig.initialize();

      // 1) Der Token liegt im Keystore. Ohne `authOptions` bliebe diese Map
      //    leer — `SharedPreferencesLocalStorage` fasst sie nie an.
      expect(keystore[key], isNotNull,
          reason: 'Ohne den localStorage-Override greift der Supabase-Default '
              'SharedPreferencesLocalStorage und der Keystore bleibt leer.');
      expect(keystore[key], contains(_refreshToken));

      // 2) Und er liegt NIRGENDWO mehr im Klartext. Bewusst ueber ALLE
      //    Prefs-Werte gesucht, nicht nur ueber den bekannten Slot: ein
      //    zusaetzlicher Klartext-Ablageort waere derselbe Schaden.
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

      // 3) Die Umstellung darf Bestandsnutzer NICHT ausloggen — sonst waere
      //    der sichere Speicherort mit einem Massen-Logout erkauft. Die
      //    Session muss aus dem Keystore heraus wiederhergestellt worden sein.
      final session = Supabase.instance.client.auth.currentSession;
      expect(session, isNotNull,
          reason: 'Ohne funktionierende Migration waere beim Update JEDER '
              'eingeloggte Nutzer auf dem Login-Screen gelandet.');
      expect(session!.refreshToken, _refreshToken);
      expect(session.user.id, _userId);
    },
  );
}
