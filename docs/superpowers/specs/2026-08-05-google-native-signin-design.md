# Design: Nativer Google Sign-In — „Eatova" statt „…supabase.co"

**Datum:** 2026-08-05 · **Status:** Design freigegeben, Infrastruktur erledigt, Implementierung offen

## Problem

Der Google-Login läuft über den Web-OAuth-Flow (`signInWithOAuth` → Chrome Custom Tab / SFSafariViewController). Google zeigt dabei aus Phishing-Schutz-Gründen immer die Domain der Redirect-URL an: „to continue to **ftoozzvmduptrvrrrshb.supabase.co**". Das ist beim Web-Flow nicht abstellbar — weder über den Consent-Screen-App-Namen noch sonstwie. Eine Supabase-Custom-Domain (`auth.eatova.de`) wurde verworfen: ~35 $/Monat (Pro-Plan + Add-on) und es stünde weiterhin eine Domain dort.

## Entscheidung

**Nativer Google Sign-In** über das `google_sign_in`-Package (v7) + `supabase.auth.signInWithIdToken()`. Das native Google-Sheet zeigt den Consent-Screen-App-Namen — **„Eatova"** — statt einer Domain. Nebeneffekt: bessere UX (Account-Picker direkt in der App statt Browser-Tab).

**Unverändert bleiben:** Apple-Login (Web-Flow), E-Mail/Passwort, E-Mail-Bestätigungs-Redirect, der `eatova://login-callback/`-Deep-Link und der `_wireOAuthSheetDismiss`-Mechanismus (wird von Apple/E-Mail weiter gebraucht).

## Bereits erledigt (2026-08-05, via Chrome-Automation + Management-API)

GCP-Projekt: **„My First Project" (`inlaid-marker-469401-v6`, Nr. 534676906581) unter moritz.gietl@gmail.com** — Achtung: NICHT `fitpilot-496516`.

| Was | Wert |
|---|---|
| Consent-Screen-App-Name | „FitPilot" → **„Eatova"** (gespeichert, verifiziert) |
| Web-Client (bestand) | `534676906581-fi1vr2d0qvhsabh6hmbcvlap5i8t5557.apps.googleusercontent.com` — bleibt Supabase-OAuth-Client, wird `serverClientId` |
| Android-Client (neu) | `534676906581-058jqclj4cns8ei0ed3h97cj8gv9gnac.apps.googleusercontent.com` — com.eatova.app, Debug-SHA-1 `82:0B:9C:0B:80:F8:16:39:2F:73:EB:00:BD:A4:58:DA:88:B0:F3:E1` |
| iOS-Client (neu) | `534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u.apps.googleusercontent.com` — com.eatova.app |
| iOS-URL-Schema | `com.googleusercontent.apps.534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u` |
| Supabase `external_google_client_id` | Komma-Liste: Web, Android, iOS (**Web zwingend zuerst** — gehört zum Secret) |

Smoke-Test grün: `GET /auth/v1/authorize?provider=google` redirected mit der Web-client_id — bestehender Browser-Flow intakt.

**Gelernte Falle:** Ein PATCH auf `external_google_additional_client_ids` der Management-API überschreibt in Wirklichkeit `external_google_client_id` (passiert + repariert). Immer das Haupt-Feld als Liste setzen.

## Architektur

```
AuthScreen ──signInWithOAuth(google)──▶ SupabaseAuthRepository
                                             │
                              ┌──────────────┴──────────────┐
                              │ GoogleIdTokenProvider        │  (neues Interface)
                              │  .getIdToken()               │
                              │   → String  (Erfolg)         │
                              │   → null    (User-Abbruch)   │
                              │   → throws  (techn. Fehler)  │
                              └──────────────┬──────────────┘
              Erfolg: signInWithIdToken(google, idToken)
              Abbruch: AuthException („Google Login wurde abgebrochen.")
              Fehler:  Fallback auf bisherigen Web-OAuth-Flow
```

- **`GoogleIdTokenProvider`** (neu, `lib/src/auth/google_id_token_provider.dart`): schmales Interface + Produktiv-Implementierung auf `google_sign_in` v7 (`GoogleSignIn.instance.initialize(serverClientId: <Web-ID>, clientId: <iOS-ID, nur Apple-Plattformen>)`, dann `authenticate()` → `authentication.idToken`). Lazy-Init beim ersten Aufruf.
- **`SupabaseAuthRepository`**: bekommt den Provider injiziert (Default = Produktiv-Impl); `signInWithOAuth` verzweigt nur bei `EatovaOAuthProvider.google` in den nativen Pfad. Apple läuft unverändert durch den bestehenden Code.
- **Fallback-Prinzip:** Der Login darf nie kaputter sein als heute. Technische Fehler des nativen Flows (fehlende Play Services, Propagation, etc.) → alter Web-Flow. Nur expliziter User-Abbruch bricht ab.
- **Nonce:** `google_sign_in` unterstützt kein Nonce; Supabase akzeptiert Google-ID-Tokens ohne Nonce (`skip_nonce_check` bleibt false).

## Code-Änderungen

1. `pubspec.yaml`: `google_sign_in: ^7.x` (exakte Version beim Plan festnageln)
2. `lib/src/auth/google_id_token_provider.dart` (neu): Interface + `GoogleSignInIdTokenProvider`
3. `lib/src/auth/auth_repository.dart`: Google-Branch + DI-Parameter, deutsche Fehlermeldungen wie bisher
4. `lib/src/config/supabase_config.dart`: Konstanten `googleWebClientId` / `googleIosClientId` (`String.fromEnvironment`-Muster wie bei SUPABASE_URL — Client-IDs sind öffentlich, kein Secret)
5. `ios/Runner/Info.plist`: zusätzliches `CFBundleURLTypes`-Schema `com.googleusercontent.apps.534676906581-h9no9hlboqtm3mfn56r95sg5c7n8no0u` (neben `eatova`)
6. Android: keine Manifest-Änderung nötig

## Tests

- **Unit** (`test/`, Fake-`GoogleIdTokenProvider`): Erfolg → `signInWithIdToken` mit Token; `null` → AuthException mit Abbruch-Meldung, kein Fallback; Exception → Web-Flow-Fallback wird aufgerufen
- **Manuell** (Emulator `fitpilot_pixel`, Google-Konto auf dem Gerät): Sheet zeigt „**Eatova**", Login läuft end-to-end durch, Session persistiert; Apple-/E-Mail-Flows unverändert (Regression)

## Risiken / Offene Punkte

- **Propagation:** Neue Google-Clients brauchen laut Console „5 Minuten bis mehrere Stunden", bis sie greifen — beim Emulator-Test einplanen.
- **Teststatus:** Die OAuth-App ist im Testing-Modus (nur Testnutzer). Bestand schon vorher; vor einem öffentlichen Release auf „In Produktion" stellen.
- **Play-Store-Release (später):** App-Signing-SHA-1 aus der Play Console muss als weiterer Fingerprint/Client ergänzt werden, sonst schlägt der native Login in Store-Builds fehl.
- **iOS-Build:** braucht ohnehin neues Provisioning für com.eatova.app (bekannt aus dem Rebranding); der native Google-Login auf iOS kann erst mit dem nächsten Xcode-Build am Gerät getestet werden.
