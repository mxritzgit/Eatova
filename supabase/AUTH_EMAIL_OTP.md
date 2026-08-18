# E-Mail-OTP-Konfiguration (GoTrue)

Die Anmelde-Mails laufen seit 2026-08-09 ueber **Ziffern-Codes** statt
Mail-Links (`AuthCodeScreen` in der App); seit 2026-08-18 sind es **8 Stellen**. Die zugehoerige Konfiguration lebt
NICHT im Repo, sondern in der Supabase-Auth-Config des Projekts
`ftoozzvmduptrvrrrshb` — gesetzt per Management API
(`PATCH /v1/projects/{ref}/config/auth`, User-Agent-Falle beachten:
Default-Python-UAs blockt Cloudflare, `curl/8.0` mitschicken).

## Massgebliche Werte

| Feld | Wert | Bedeutung |
|---|---|---|
| `mailer_otp_length` | `8` | Stellen des Codes. **Muss zur App passen** (`kAccountCodeLength` in `account_change_messages.dart` steuert Feld und Validierung ueberall; `auth_code_screen.dart` nutzt dieselbe Konstante). Bis 2026-08-18 stand hier 6 — Erhoehung nach externem Brute-Force-Befund, siehe Abschnitt unten. Reihenfolge bei jeder Aenderung: ERST App-Build mit neuer Laenge verteilen, DANN Config patchen — ein alter Build schneidet die Eingabe ab und nimmt den Code nie an. |
| `mailer_otp_exp` | `600` | Gueltigkeit in Sekunden (10 Minuten, so kommuniziert es die App und beide Mails). |
| `mailer_subjects_confirmation` | `Dein Eatova-Code: E-Mail bestätigen` | |
| `mailer_subjects_recovery` | `Dein Eatova-Code: Passwort zurücksetzen` | |
| `mailer_templates_confirmation_content` / `..._recovery_content` | HTML mit `{{ .Token }}` | Eatova-Design: heller Rahmen, eat◎va-Wortmarke, dunkle Code-Box mit Lime-Ziffern. **Kein** `{{ .ConfirmationURL }}` mehr — ein Link-Template wuerde den Code-Flow der App aushebeln. |

## Brute-Force-Rechnung (Befund-Verifikation 2026-08-18)

`/auth/v1/verify` ist bei GoTrue **nur pro IP** limitiert (`rate_limit_verify`,
Token-Bucket 30 mit Nachfuellrate 30/5 min → Burst 30 + 6/min). Ein falscher
Versuch verbraucht den Code NICHT (kein Attempt-Zaehler, nur `mailer_otp_exp`).
Pro 10-Minuten-Fenster sind das ~90 Versuche pro IP; mit einem
Residential-Proxy-Pool skalierte das bei 6 Stellen auf ~9 % (1.000 IPs) bis
~90 % (10.000 IPs) Trefferquote pro Fenster. Mit 8 Stellen (10^8 Keyspace)
faellt das um Faktor 100 auf 0,09-0,9 % — deshalb `mailer_otp_length = 8`
(GoTrue erlaubt 6-10). `rate_limit_email_sent = 2`/h drosselt zusaetzlich die
Code-NEUGENERIERUNG pro Konto.

**Bewusst nicht gesenkt:** `rate_limit_verify` (steht auf 30/5 min). Gegen
einen verteilten Angreifer hilft ein niedrigerer Wert nur marginal (das Limit
ist pro IP), aber hinter CGNAT/Buero-NAT teilen sich viele legitime Nutzer
eine IP — Fehlsperren waeren real. Der Keyspace ist der wirksame Hebel.

## Konto-Aenderungen aus der App (seit 2026-08-10)

| Feld | Wert | Bedeutung |
|---|---|---|
| `mailer_secure_email_change_enabled` | `true` | GoTrue schickt bei einer Adress-Aenderung **zwei** Codes: einen an die bisherige, einen an die neue Adresse. Beide muessen bestaetigt werden. Ohne das genuegte der Zugriff auf EIN Postfach, um die Adresse — und damit das Konto — zu uebernehmen. |
| `security_update_password_require_reauthentication` | `true` | Verlangt beim Passwortsetzen eine Nonce — aber NUR, wenn die Sitzung fehlt oder aelter als 24 h ist (GoTrue `internal/api/user.go`, gemessen an `session.CreatedAt`). Bei juengeren Sitzungen wird die Nonce weder verlangt noch geprueft. Details und Restrisiko: Abschnitt „Nonce-Semantik" unten. |
| `mailer_subjects_email_change` | `Dein Eatova-Code: E-Mail-Adresse ändern` | |
| `mailer_templates_email_change_content` | HTML mit `{{ .Token }}` **und** `{{ .NewEmail }}` | Diese EINE Vorlage geht an BEIDE Adressen — der Text muss aus beiden Blickwinkeln stimmen und nennt deshalb das Ziel per `{{ .NewEmail }}`. Vorher stand hier `{{ .ConfirmationURL }}`; damit waere der Code-Flow der App ins Leere gelaufen. |
| `mailer_subjects_reauthentication` | `Dein Eatova-Code: Passwort ändern` | |
| `mailer_templates_reauthentication_content` | HTML mit `{{ .Token }}` | Vorher der englische GoTrue-Default. |

Die App-Seite dazu: `AuthRepository.startPasswordChange` / `confirmPasswordChange`
(`reauthenticate` + `updateUser(nonce:)`) und `startEmailChange` /
`confirmEmailChange` (`updateUser(email:)` + zweimal `verifyOTP(emailChange)`),
festgehalten in `test/auth_account_change_test.dart`.

## Nonce-Semantik (geklaert 2026-08-18)

Der im Audit 2026-08-14 offene Widerspruch (Recovery ohne Nonce vs.
Reauth-Pflicht) ist am GoTrue-Quellcode aufgeloest (master,
`internal/api/user.go`, `UserUpdate`):

- Die Nonce wird nur verlangt, wenn **keine Sitzung** vorliegt oder die
  Sitzung **aelter als 24 Stunden** ist (`session.CreatedAt + 24h`). Bei
  juengeren Sitzungen ueberspringt der Server den gesamten Nonce-Block —
  eine mitgeschickte (auch falsche) Nonce wird ignoriert.
- „Passwort vergessen" funktioniert genau deshalb: `verifyRecoveryCode`
  legt unmittelbar vorher eine frische Sitzung an, `updatePassword` laeuft
  ohne Nonce durch. **Der Recovery-Flow haengt an dieser Frische-Ausnahme.**
  Verschaerft GoTrue die Semantik je (Nonce immer), bricht „Passwort
  vergessen" fuer alle Nutzer — `test/auth_enumeration_test.dart` haelt die
  Wire-Formate fest, damit so ein Eingriff auffaellt.

**Restrisiko (akzeptiert):** wer eine fremde Sitzung erbeutet, die juenger
als 24 h ist (ab Login der Sitzung, nicht ab Diebstahl), kann das Passwort
ohne Postfach-Zugriff tauschen; die Nonce schuetzt nur aeltere Sitzungen.
Das Postfach bleibt die Wurzel des Vertrauens: Mail-Recovery setzt
jederzeit ein neues Passwort und beendet dabei alle anderen Sitzungen
(GoTrue: `LogoutAllExceptMe`), und die Mailadresse ist wegen
`mailer_secure_email_change_enabled` nicht ohne das alte Postfach zu
uebernehmen. Ein Konto laesst sich also voruebergehend kapern, aber nicht
dauerhaft aussperren.

**Moeglicher Hebel, bewusst nicht gezogen:**
`security_update_password_require_current_password = true` (steht auf
`false`) wuerde zusaetzlich das aktuelle Passwort verlangen und das
24-h-Fenster fuer Passwort-/OAuth-Sitzungen schliessen. „Passwort
vergessen" braeche dabei NICHT: GoTrue nimmt Recovery-Sitzungen aus
(`!session.IsRecovery()`; Sitzungen aus `verifyOTP` zaehlen als Recovery).
Kosten: die App muesste beim In-App-Wechsel das aktuelle Passwort abfragen
und als `current_password` mitschicken (gotrue-dart kann das:
`UserAttributes.currentPassword`) — das Flag OHNE App-Update umzulegen
braeche den In-App-Wechsel. Ausserdem blieben Sitzungen aus
OTP-Verifikation (Signup/Recovery) und reine Google-Konten ohne Passwort
ausgenommen. Einen Auth-Hook fuer Passwort-Updates gibt es nicht
(GoTrue-Hooks: send-sms, send-email, customize-access-token,
mfa-verification, password-verification, before-/after-user-created).
Optional pruefen: die GoTrue-Benachrichtigung „Passwort geaendert"
(`Mailer.Notifications.PasswordChangedEnabled`) als Detektionsmassnahme.

## Wer haengt daran

- `lib/src/screens/auth_code_screen.dart` — Code-Eingabe (`kAccountCodeLength`
  = 8 Stellen, Hinweistext „10 Minuten"), Flusslogik recovery/signup.
- `lib/src/auth/auth_repository.dart` — `verifyRecoveryCode` /
  `verifySignupCode` (`verifyOTP`), `resendSignupCode`,
  `sendPasswordReset`.

Wer eines der Felder aendert, muss die jeweils andere Seite nachziehen —
es gibt keinen Test, der App und Auth-Config gegeneinander prueft.
