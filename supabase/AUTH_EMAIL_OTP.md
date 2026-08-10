# E-Mail-OTP-Konfiguration (GoTrue)

Die Anmelde-Mails laufen seit 2026-08-09 ueber **6-stellige Codes** statt
Mail-Links (`AuthCodeScreen` in der App). Die zugehoerige Konfiguration lebt
NICHT im Repo, sondern in der Supabase-Auth-Config des Projekts
`ftoozzvmduptrvrrrshb` — gesetzt per Management API
(`PATCH /v1/projects/{ref}/config/auth`, User-Agent-Falle beachten:
Default-Python-UAs blockt Cloudflare, `curl/8.0` mitschicken).

## Massgebliche Werte

| Feld | Wert | Bedeutung |
|---|---|---|
| `mailer_otp_length` | `6` | Stellen des Codes. **Muss zur App passen** (Code-Feld und Validierung in `auth_code_screen.dart` erwarten exakt 6). Stand vorher auf 8 — die App nahm den Code dann nicht an. |
| `mailer_otp_exp` | `600` | Gueltigkeit in Sekunden (10 Minuten, so kommuniziert es die App und beide Mails). |
| `mailer_subjects_confirmation` | `Dein Eatova-Code: E-Mail bestätigen` | |
| `mailer_subjects_recovery` | `Dein Eatova-Code: Passwort zurücksetzen` | |
| `mailer_templates_confirmation_content` / `..._recovery_content` | HTML mit `{{ .Token }}` | Eatova-Design: heller Rahmen, eat◎va-Wortmarke, dunkle Code-Box mit Lime-Ziffern. **Kein** `{{ .ConfirmationURL }}` mehr — ein Link-Template wuerde den Code-Flow der App aushebeln. |

## Konto-Aenderungen aus der App (seit 2026-08-10)

| Feld | Wert | Bedeutung |
|---|---|---|
| `mailer_secure_email_change_enabled` | `true` | GoTrue schickt bei einer Adress-Aenderung **zwei** Codes: einen an die bisherige, einen an die neue Adresse. Beide muessen bestaetigt werden. Ohne das genuegte der Zugriff auf EIN Postfach, um die Adresse — und damit das Konto — zu uebernehmen. |
| `security_update_password_require_reauthentication` | `true` | Erzwingt die Nonce beim Passwortsetzen. **Ohne das ist der Code Zierde:** GoTrue nimmt `updateUser(password:)` dann auch ohne ihn an, und wer eine fremde Sitzung erbeutet, tauscht das Passwort ohne Zugriff aufs Postfach. |
| `mailer_subjects_email_change` | `Dein Eatova-Code: E-Mail-Adresse ändern` | |
| `mailer_templates_email_change_content` | HTML mit `{{ .Token }}` **und** `{{ .NewEmail }}` | Diese EINE Vorlage geht an BEIDE Adressen — der Text muss aus beiden Blickwinkeln stimmen und nennt deshalb das Ziel per `{{ .NewEmail }}`. Vorher stand hier `{{ .ConfirmationURL }}`; damit waere der Code-Flow der App ins Leere gelaufen. |
| `mailer_subjects_reauthentication` | `Dein Eatova-Code: Passwort ändern` | |
| `mailer_templates_reauthentication_content` | HTML mit `{{ .Token }}` | Vorher der englische GoTrue-Default. |

Die App-Seite dazu: `AuthRepository.startPasswordChange` / `confirmPasswordChange`
(`reauthenticate` + `updateUser(nonce:)`) und `startEmailChange` /
`confirmEmailChange` (`updateUser(email:)` + zweimal `verifyOTP(emailChange)`),
festgehalten in `test/auth_account_change_test.dart`.

## Wer haengt daran

- `lib/src/screens/auth_code_screen.dart` — Code-Eingabe (6 Stellen,
  Hinweistext „10 Minuten"), Flusslogik recovery/signup.
- `lib/src/auth/auth_repository.dart` — `verifyRecoveryCode` /
  `verifySignupCode` (`verifyOTP`), `resendSignupCode`,
  `sendPasswordReset`.

Wer eines der Felder aendert, muss die jeweils andere Seite nachziehen —
es gibt keinen Test, der App und Auth-Config gegeneinander prueft.
