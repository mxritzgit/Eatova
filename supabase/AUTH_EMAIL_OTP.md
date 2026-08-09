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

## Wer haengt daran

- `lib/src/screens/auth_code_screen.dart` — Code-Eingabe (6 Stellen,
  Hinweistext „10 Minuten"), Flusslogik recovery/signup.
- `lib/src/auth/auth_repository.dart` — `verifyRecoveryCode` /
  `verifySignupCode` (`verifyOTP`), `resendSignupCode`,
  `sendPasswordReset`.

Wer eines der Felder aendert, muss die jeweils andere Seite nachziehen —
es gibt keinen Test, der App und Auth-Config gegeneinander prueft.
