# Nativer Google Sign-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Google-Login läuft nativ (Sheet zeigt „Eatova" statt „…supabase.co"), mit Web-OAuth als Fallback; Apple/E-Mail unverändert.

**Architecture:** Neues schmales Interface `GoogleIdTokenProvider` + freistehende, Supabase-freie Ablauffunktion `runNativeGoogleSignIn` (testbar mit Fakes). `SupabaseAuthRepository.signInWithOAuth` verzweigt bei Google in den nativen Pfad und tauscht das ID-Token per `signInWithIdToken`; technische Fehler fallen auf den bestehenden Web-Flow zurück.

**Tech Stack:** Flutter 3.44.0, `google_sign_in ^7.2.0`, `supabase_flutter ^2.12.4` (liefert `AuthException`, `OAuthProvider`, `signInWithIdToken`).

## Global Constraints

- Flutter ist NICHT auf PATH: immer `C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat` voll ausschreiben (Arbeitsverzeichnis `C:\Users\morit\Desktop\Bridgespace\Projects\Eatova`).
- Dart-Kommentare ASCII-umlautfrei schreiben („fuer", „laeuft") — bestehende Konvention, siehe `auth_repository.dart`.
- UI-/Fehlertexte deutsch, Muster wie bisher: `'Google Login wurde abgebrochen.'`
- Client-IDs (verbatim, sind öffentlich):
  - Web/serverClientId: `534676906581-fi1vr2d0qvhsabh6hmbcvlap5i8t5557.apps.googleusercontent.com`
  - iOS: `534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u.apps.googleusercontent.com`
  - iOS-URL-Schema: `com.googleusercontent.apps.534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u`
  - (Android-Client `…-058jqclj4cns8ei0ed3h97cj8gv9gnac…` existiert in GCP, taucht im Code NICHT auf — Android braucht nur serverClientId.)
- Jeder Commit endet mit `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Nach jedem Task: `flutter analyze` muss 0 Issues melden, `flutter test` grün.

---

### Task 1: Dependency + Client-ID-Konstanten

**Files:**
- Modify: `pubspec.yaml` (dependencies-Block, nach `camera: ^0.12.0+2`)
- Modify: `lib/src/config/supabase_config.dart` (nach `anonKey`-Konstante)

**Interfaces:**
- Consumes: —
- Produces: `EatovaSupabaseConfig.googleWebClientId` und `EatovaSupabaseConfig.googleIosClientId` (beide `static const String`) — Task 2 liest sie.

- [ ] **Step 1: pubspec.yaml ergänzen**

Nach der Zeile `  camera: ^0.12.0+2` einfügen:

```yaml
  # google_sign_in traegt den NATIVEN Google-Login (Credential-Manager-Sheet
  # auf Android, Google-SDK-Dialog auf iOS). Das Sheet zeigt den Consent-
  # Screen-App-Namen "Eatova" statt der Supabase-Domain - der Web-OAuth-Flow
  # zeigt zwangsweise "to continue to <ref>.supabase.co" (Phishing-Schutz,
  # nicht abstellbar). Das ID-Token wird per signInWithIdToken eingetauscht.
  google_sign_in: ^7.2.0
```

- [ ] **Step 2: Dependencies auflösen**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" pub get`
Expected: `Got dependencies!`, pubspec.lock enthält google_sign_in 7.2.x

- [ ] **Step 3: Konstanten in supabase_config.dart**

In `EatovaSupabaseConfig` nach der `anonKey`-Konstante einfügen:

```dart
  // Google-OAuth-Client-IDs (GCP-Projekt inlaid-marker-469401-v6, siehe
  // docs/superpowers/specs/2026-08-05-google-native-signin-design.md).
  // Client-IDs sind oeffentlich (im Bundle extrahierbar), KEINE Secrets -
  // gleiches Muster wie SUPABASE_URL oben.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '534676906581-fi1vr2d0qvhsabh6hmbcvlap5i8t5557.apps.googleusercontent.com',
  );

  static const String googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue:
        '534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u.apps.googleusercontent.com',
  );
```

- [ ] **Step 4: Analyze + Tests**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" analyze` dann `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test`
Expected: `No issues found!`, alle Tests grün (Bestand unverändert)

- [ ] **Step 5: Commit**

```powershell
git add pubspec.yaml pubspec.lock lib/src/config/supabase_config.dart
git commit -m "feat(auth): google_sign_in-Dependency + Google-Client-ID-Konstanten"
```

---

### Task 2: GoogleIdTokenProvider + Flow-Logik (TDD)

**Files:**
- Create: `lib/src/auth/google_id_token_provider.dart`
- Test: `test/native_google_sign_in_test.dart`

**Interfaces:**
- Consumes: `EatovaSupabaseConfig.googleWebClientId` / `.googleIosClientId` (Task 1)
- Produces (Task 3 verlässt sich exakt darauf):
  - `abstract class GoogleIdTokenProvider { Future<String?> getIdToken(); }`
  - `class GoogleSignInIdTokenProvider implements GoogleIdTokenProvider` mit `const`-Konstruktor
  - `Future<bool> runNativeGoogleSignIn({required GoogleIdTokenProvider tokenProvider, required Future<void> Function(String idToken) exchangeIdToken})` — true = eingeloggt, false = Web-Fallback nötig, wirft `AuthException` bei User-Abbruch

- [ ] **Step 1: Failing Tests schreiben** (`test/native_google_sign_in_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/google_id_token_provider.dart';

class _FakeProvider implements GoogleIdTokenProvider {
  _FakeProvider(this._getIdToken);
  final Future<String?> Function() _getIdToken;
  @override
  Future<String?> getIdToken() => _getIdToken();
}

void main() {
  group('runNativeGoogleSignIn', () {
    test('tauscht das ID-Token ein und meldet Erfolg', () async {
      final exchanged = <String>[];
      final ok = await runNativeGoogleSignIn(
        tokenProvider: _FakeProvider(() async => 'token-123'),
        exchangeIdToken: (idToken) async => exchanged.add(idToken),
      );
      expect(ok, isTrue);
      expect(exchanged, ['token-123']);
    });

    test('User-Abbruch wirft AuthException und tauscht nichts ein', () async {
      var exchangeCalls = 0;
      await expectLater(
        runNativeGoogleSignIn(
          tokenProvider: _FakeProvider(() async => null),
          exchangeIdToken: (_) async => exchangeCalls++,
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'Google Login wurde abgebrochen.',
          ),
        ),
      );
      expect(exchangeCalls, 0);
    });

    test('technischer Fehler meldet false fuer den Web-Fallback', () async {
      var exchangeCalls = 0;
      final ok = await runNativeGoogleSignIn(
        tokenProvider: _FakeProvider(() async => throw StateError('kaputt')),
        exchangeIdToken: (_) async => exchangeCalls++,
      );
      expect(ok, isFalse);
      expect(exchangeCalls, 0);
    });

    test('Exchange-Fehler propagiert unveraendert, kein stiller Fallback',
        () async {
      await expectLater(
        runNativeGoogleSignIn(
          tokenProvider: _FakeProvider(() async => 'token-123'),
          exchangeIdToken: (_) async => throw AuthException('audience mismatch'),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
```

- [ ] **Step 2: Tests laufen lassen — müssen scheitern**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/native_google_sign_in_test.dart`
Expected: FAIL — Compile-Fehler, `google_id_token_provider.dart` existiert nicht

- [ ] **Step 3: Implementierung** (`lib/src/auth/google_id_token_provider.dart`)

```dart
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../config/supabase_config.dart';

/// Liefert das Google-ID-Token fuer den nativen Sign-In-Flow.
///
/// null = User hat das Google-Sheet abgebrochen. Exceptions = technischer
/// Fehler (keine Play Services, Client-Propagation, ...) - der Aufrufer
/// faellt dann auf den Web-OAuth-Flow zurueck.
abstract class GoogleIdTokenProvider {
  Future<String?> getIdToken();
}

/// Produktiv-Implementierung auf google_sign_in v7. Das native Sheet zeigt
/// den Consent-Screen-App-Namen ("Eatova") statt der Supabase-Domain -
/// das ist der ganze Grund fuer diesen Flow.
class GoogleSignInIdTokenProvider implements GoogleIdTokenProvider {
  const GoogleSignInIdTokenProvider();

  // initialize() darf pro Prozess nur einmal laufen. Der Future wird
  // statisch gecacht, damit parallele/wiederholte Logins nicht doppelt
  // initialisieren (GoogleSignIn.instance ist selbst ein Singleton).
  static Future<void>? _initialization;

  @override
  Future<String?> getIdToken() async {
    final signIn = GoogleSignIn.instance;
    _initialization ??= signIn.initialize(
      // iOS braucht den eigenen iOS-Client (URL-Schema-Callback);
      // Android laeuft komplett ueber den serverClientId (Web-Client),
      // dessen Audience Supabase als erste client_id kennt.
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? EatovaSupabaseConfig.googleIosClientId
          : null,
      serverClientId: EatovaSupabaseConfig.googleWebClientId,
    );
    await _initialization;
    try {
      final account = await signIn.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }
}

/// Ablauf-Logik des nativen Google-Logins, von Supabase entkoppelt,
/// damit sie ohne SupabaseClient testbar ist (test/native_google_sign_in_test.dart).
///
/// true = eingeloggt. false = technischer Fehler, Aufrufer startet den
/// Web-OAuth-Fallback. User-Abbruch wirft AuthException mit deutscher
/// Meldung (Muster wie der bisherige Web-Flow-Abbruch).
Future<bool> runNativeGoogleSignIn({
  required GoogleIdTokenProvider tokenProvider,
  required Future<void> Function(String idToken) exchangeIdToken,
}) async {
  final String? idToken;
  try {
    idToken = await tokenProvider.getIdToken();
  } on Object {
    return false;
  }
  if (idToken == null) {
    throw AuthException('Google Login wurde abgebrochen.');
  }
  await exchangeIdToken(idToken);
  return true;
}
```

- [ ] **Step 4: Tests laufen lassen — müssen grün sein**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test test/native_google_sign_in_test.dart`
Expected: 4 Tests PASS

- [ ] **Step 5: Analyze**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```powershell
git add lib/src/auth/google_id_token_provider.dart test/native_google_sign_in_test.dart
git commit -m "feat(auth): nativer Google-Sign-In-Provider + Flow-Logik (TDD)"
```

---

### Task 3: Repository-Branch + Web-Flow-Extraktion

**Files:**
- Modify: `lib/src/auth/auth_repository.dart:54-115` (`SupabaseAuthRepository`)

**Interfaces:**
- Consumes: `GoogleIdTokenProvider`, `GoogleSignInIdTokenProvider`, `runNativeGoogleSignIn` (Task 2)
- Produces: unveränderte öffentliche API (`AuthRepository.signInWithOAuth(EatovaOAuthProvider)`) — Aufrufer (`auth_screen.dart`, `eatova_app.dart`) bleiben unangetastet.

- [ ] **Step 1: Import + Konstruktor + Feld**

In `auth_repository.dart` oben ergänzen:

```dart
import 'google_id_token_provider.dart';
```

`SupabaseAuthRepository`-Kopf ersetzen (Konstruktor bleibt const, Aufrufstelle `eatova_app.dart:42` braucht keine Änderung):

```dart
class SupabaseAuthRepository implements AuthRepository {
  const SupabaseAuthRepository(
    this._client, {
    GoogleIdTokenProvider? googleIdTokenProvider,
  }) : _googleIdTokenProvider =
           googleIdTokenProvider ?? const GoogleSignInIdTokenProvider();

  final SupabaseClient _client;
  final GoogleIdTokenProvider _googleIdTokenProvider;
```

- [ ] **Step 2: signInWithOAuth verzweigen, Web-Flow in private Methode extrahieren**

Die bisherige `signInWithOAuth`-Methode (inkl. ihres Doc-Kommentars zum inAppBrowserView) ersetzen durch:

```dart
  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) async {
    if (provider == EatovaOAuthProvider.google) {
      final nativeOk = await runNativeGoogleSignIn(
        tokenProvider: _googleIdTokenProvider,
        exchangeIdToken: (idToken) async {
          await _client.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
          );
        },
      );
      if (nativeOk) return;
      // Technischer Fehler im nativen Flow (keine Play Services, Client
      // noch nicht propagiert, ...) - Login soll nie kaputter sein als
      // frueher, also runter in den bewaehrten Web-Flow.
    }
    await _signInWithWebOAuth(provider);
  }

  /// Web-OAuth via Browser-Sheet - Standardweg fuer Apple, Fallback fuer
  /// Google (dort zeigt Google zwangsweise die Supabase-Domain an).
  ///
  /// inAppBrowserView oeffnet SFSafariViewController (iOS) bzw. Chrome
  /// Custom Tabs (Android) - ein Sheet das ueber der App liegt und sich
  /// automatisch schliesst sobald das eatova://login-callback/ Scheme
  /// greift. Wichtig: kein inAppWebView - das waere ein embedded
  /// WKWebView, den Google explizit fuer OAuth blockt.
  Future<void> _signInWithWebOAuth(EatovaOAuthProvider provider) async {
    final launched = await _client.auth.signInWithOAuth(
      provider.supabaseProvider,
      redirectTo: EatovaSupabaseConfig.oauthRedirectUrl,
      authScreenLaunchMode: LaunchMode.inAppBrowserView,
    );
    if (!launched) {
      throw AuthException('${provider.displayName} Login wurde abgebrochen.');
    }
  }
```

- [ ] **Step 3: Analyze + kompletter Testlauf**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" analyze` dann `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test`
Expected: `No issues found!`, ALLE Tests grün (Bestandstests decken InMemory/Preview ab, die unverändert sind)

- [ ] **Step 4: Commit**

```powershell
git add lib/src/auth/auth_repository.dart
git commit -m "feat(auth): Google-Login laeuft nativ mit Web-OAuth-Fallback"
```

---

### Task 4: iOS-URL-Schema für den Google-Callback

**Files:**
- Modify: `ios/Runner/Info.plist:25-37` (`CFBundleURLTypes`-Array)

**Interfaces:**
- Consumes: iOS-URL-Schema aus Global Constraints
- Produces: — (reine Plattform-Registrierung; ohne sie kehrt das Google-SDK auf iOS nie in die App zurück)

- [ ] **Step 1: Zweiten URL-Type-Eintrag ergänzen**

Im bestehenden `CFBundleURLTypes`-Array nach dem `eatova-auth`-Dict (Zeile 36 `</dict>`) einfügen:

```xml
		<dict>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>CFBundleURLName</key>
			<string>google-signin</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>com.googleusercontent.apps.534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u</string>
			</array>
		</dict>
```

- [ ] **Step 2: Diff prüfen**

Run: `git diff ios/Runner/Info.plist`
Expected: genau ein neuer `<dict>`-Block im `CFBundleURLTypes`-Array, XML wohlgeformt (Einrückung Tabs wie Umgebung)

- [ ] **Step 3: Commit**

```powershell
git add ios/Runner/Info.plist
git commit -m "feat(ios): Google-Callback-URL-Schema fuer nativen Sign-In"
```

---

### Task 5: Gesamtverifikation + Emulator-Test

**Files:** — (nur Verifikation)

**Interfaces:**
- Consumes: alles aus Task 1–4
- Produces: Nachweis, dass das Sheet „Eatova" zeigt und der Login end-to-end läuft

- [ ] **Step 1: Kompletter Analyze- + Testlauf**

Run: `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" analyze` dann `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" test`
Expected: 0 Issues, alle Tests grün

- [ ] **Step 2: Android-Emulator starten und App deployen**

Run: Emulator `fitpilot_pixel` starten (JDK-21-Umgebung, siehe Memory android-emulator-setup), dann `& "C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat" run -d emulator-5554`
Expected: App bootet, Auth-Screen erreichbar (ggf. vorher ausloggen)

- [ ] **Step 3: Manueller Google-Login**

„Mit Google anmelden" tippen. Expected: **natives Credential-Manager-Sheet mit „Eatova"** (kein Browser-Tab, keine supabase.co-Domain); Login durchläuft, App landet eingeloggt. Falls Google `DEVELOPER_ERROR`/Sheet-Fehler zeigt: Client-Propagation abwarten (laut Console 5 Min–Stunden) — dank Fallback öffnet sich stattdessen der Browser-Flow, die App bleibt benutzbar. Falls kein Google-Konto auf dem Emulator: in den Emulator-Settings eines hinzufügen (braucht User).

- [ ] **Step 4: Regression Apple/E-Mail**

E-Mail/Passwort-Login einmal durchspielen (bestehender Testaccount). Expected: unverändert. (Apple ist auf dem Android-Emulator nicht testbar — Web-Flow-Codepfad ist unverändert und durch Task-3-Diff-Review abgedeckt.)

- [ ] **Step 5: Push**

```powershell
git push
```
