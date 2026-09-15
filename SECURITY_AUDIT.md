# Eatova — Sicherheits-Checkbuch

Stand: **15.09.2026**. Runde 3 überprüft alle **91 Prüfpunkte** mit zehn fachlich aufgeteilten Agents, Gegenreviews und gemeinsamer Integration. Die Tabellen enthalten den aktuellen Stand; Runde 1 und 2 bleiben darunter als datierte Vorgeschichte erhalten. Eine erfolgreiche Codekorrektur ist keine pauschale Sicherheitsfreigabe.

## Runde 3 — aktueller Stand

Die Änderungen betreffen Kontotrennung bei asynchronen Anmelde-, Datei- und Löschvorgängen, tatsächliche Exportvollständigkeit, verpflichtende KI-Aufrufbudgets, begrenzte Upload-/Antwortkörper, Bildmetadaten und Decoder-Vorprüfung, Datenbankprivilegien sowie den Build- und Prüfprozess. Es wurde keine neue ausnutzbare P0-Lücke belegt. Verbleibende P1-Prüfbedarfe stehen ausdrücklich weiter offen beziehungsweise sind ohne Betreiberzugriff nicht prüfbar.

**Arbeitsgrenzen:** Isolierte Worktrees ab Main `8e83645672e92b1cce74f445ed8ec93a96f0e647`; fremde Änderungen im ursprünglichen Ordner bleiben erhalten. Funktionstests verwenden synthetische Konten und Daten. Keine produktiven REST-/RPC-/Storage-/AI-Verhaltenstests, Lasttests, Zahlungen oder echten Gesundheitsdaten. Live-Abgleiche lesen ausschließlich benötigte Kataloge, Konfiguration und öffentliche Inhalte. Benannte Zugangsdaten verbleiben im ausführenden Prozess; Werte und Schlüssel-Hashes stehen nicht in diesem Bericht.

### Nachweisarten und tatsächlicher Umfang

| Bereich | Nachweis in Runde 3 | Grenze |
| --- | --- | --- |
| Backend/Auth | Vollständige Deno-Suite einschließlich Offline-Evaluation: **662 Tests grün**; alle **35 Function-Testdateien einzeln** grün; Lint und alle drei Entry-Point-Typechecks. Zusätzlich **38** lokale Auth-/Handlerfälle gegen GoTrue **2.196.0**, neun simulierte Paid-Calls mit genau neun passenden vorherigen Budgetreservierungen. | Kein Aufruf geschützter Produktionsfunktionen; kein Beweis über einen installierten Client. |
| Datenbank | PostgreSQL **17.6**, vollständiger Replay von **46 Migrationen**, eingeschränkte Rollen, A/B/anon, Tabellen-/RPC-Berechtigungen, Löschung und Budget-Races; gesonderte synthetische Restore-Probe. | Die tatsächliche Produktionswiederherstellung und verwaltete Supabase-Infrastruktur sind dadurch nicht bewiesen. |
| Flutter | Flutter **3.47.2 / Dart 3.13.2**; strikte Analyse und vollständige CI-Suite auf `78f8d55` grün: **4620 Tests**, **95,0%** Zeilenabdeckung. Zuvor wurden vier Integrationsfehler im lokalen Gesamtlauf entdeckt und mit 228 gemeinsamen Regressionen korrigiert. | Android-Debug, Android-Release mit R8/AOT und iOS ohne Codesign in CI gebaut. Coverage-Floor unverändert **88%**. Kein signiertes Storeartefakt oder installierter Nutzerclient nachgewiesen. |
| Android-Gerätetest | Frische isolierte Android-36-Testinstanz: **19 native Assertions**, sichere Session-/PKCE-Ablage, Neustarts, A/B-Namensräume, Logout-Marker, Screenshot-Sperre, Backup-Verweigerung und TLS-Negativkontrolle. | Synthetischer Debug-Probe; keine installierte produktive App, kein iOS-, physischer Geräte- oder Store-Nachweis. |
| Abhängigkeiten | Gradle **8.14 → 8.14.4**, offizieller Distributionshash, reproduzierbarer Resolverfehler vorher/nachher. OSV **2.3.8** prüft Pub, neun Swift-Revisionen und 169 aufgelöste Android-Runtime-/Desugar-Module ohne Treffer. | Null Treffer bedeutet keine vollständige Schwachstellenfreiheit. **45 Advisory-IDs** in separaten Buildwerkzeugen bleiben mit konkreter Erreichbarkeit und Updatepfaden [sichtbar bewertet](android/BUILD_TOOL_SECURITY.md). Kein unbegründetes globales Paket-Override. |
| KI-Verhalten | Zwölf feste synthetische Textfälle über den tatsächlichen lokalen Handler gegen `google/gemini-3.8-flash`; positive JSON/SSE-/Rezept-/Planpfade, Ablehnungen und Kontext-Manipulation. [Harness und Ergebnisse](supabase/eval/results/2026-09-15.md) sind versioniert. | Der Evaluationsschlüssel unterscheidet sich vom bereitgestellten Schlüssel. Keine produktive Credential-/Routing-/Kosten- oder fachliche medizinische Abnahme. Keine Bildadversarial-Evaluation. |

Die reale Modellevaluation blieb innerhalb des vorab begrenzten Budgets: konservativ **1,86 USD** reserviert/verbraucht bei maximal **1,92 USD**. Ein früher Harness-Abbruch wird dabei vollständig mitgerechnet; 21 dokumentierte Calls melden zusammen 0,02695275 USD Provider-Usage. Dies ist keine Rechnung oder Behauptung, dass der erste abgebrochene Lauf kostenlos war. Alle weiteren Regressionen laufen offline ohne Providerkosten.

### Live-Konfiguration und Veröffentlichung

Die folgenden vier eng begrenzten Änderungen wurden am **14.09.2026, 22:26–22:30 UTC** mit vorhandener Nutzerfreigabe vorgenommen und anschließend erneut gelesen:

| Einstellung | Nachgewiesener Zustand | Praktische Grenze |
| --- | --- | --- |
| Datenbank-TLS | SSL-Enforcement von `false` auf `true`; `appliedSuccessfully=true`, Projekt anschließend `ACTIVE_HEALTHY`. | Kurzer erforderlicher Datenbankneustart; kein Nachweis sämtlicher ruhender Drittclients. |
| Realtime | `private_only=true`, übrige gelesene Konfiguration unverändert. | Die App verwendet derzeit weder Realtime-Publikationen noch Broadcast/Presence. |
| Auth-Sicherheitsmails | Benachrichtigungen für Passwort-/E-Mail-Wechsel und Verknüpfung/Entfernung einer Identität aktiviert; übrige Einstellungen unverändert. | Keine Testmail versendet; SMTP-Zustellung noch separat nachzuweisen. |
| GitHub | Private Vulnerability Reporting aktiviert; acht bindende Main-Checks und Admin-Schutz unverändert. | Kein Testbericht oder externe Nachricht versendet. |

**Backend-Rollout dieser Runde:** Nach grüner [CI 34910018466](https://github.com/mxritzgit/Eatova/actions/runs/34910018466) auf Quellstand `78f8d55673f2df46dcc5edc04b7398390f675008` wurden die drei neuen Migrationen atomar bereitgestellt. Anschließend wurden `coach-chat` **v48**, `analyze-meal` **v31**, `search-key` **v10** ausgerollt: alle ACTIVE, `verify_jwt=true`, sämtliche importierten TypeScript-Quellen erneut heruntergeladen und mit dem getesteten Baum verglichen. Der [versionierte Rollout-Nachweis](docs/SECURITY-ROLLOUT-2026-09-15.json) enthält die geprüften Metadaten. Der unabhängige Live-Katalogabgleich bestätigt 46 Migrationen, 19 App-Tabellen mit RLS, 35 Policies und 34 Funktionen einschließlich Definitionen, ACLs, Ownern und `search_path`. 36 Spaltengrants, 83 Constraints, 17 Fremdschlüssel und 12 Trigger entsprechen dem geprüften Stand. Drei bereits bewertete reine SQL-Kommentarabweichungen wurden nur bei exakt unveränderten bekannten Hashes akzeptiert. Der Advisor meldet 20 Einträge: 15 beabsichtigte, einzeln geprüfte Client-RPC-Warnungen, vier erwartete Hinweise auf ausschließlich serverseitige Tabellen und weiterhin eine Warnung zum deaktivierten Passwort-Leak-Schutz; keine ERROR-Einträge. Die administrativen Budgetwerte wurden mit 1000 Calls global, 150 je Konto und 50 Rezeptbildern pro UTC-Tag zurückgelesen; alle vier Stoppschalter sind vorhanden und eingeschaltet. Kein geschützter Produktionsendpoint wurde für Verhaltenstests aufgerufen.

Abschluss Backend: **2026-09-15T00:12:44.536608+00:00**. Datenschutzveröffentlichung: **2026-09-15T00:13:24.756114+00:00**; öffentliche Antwort, Serverdatei und lokale zugeordnete Quelle stimmen bytegenau überein (SHA-256 `81a6128993911d83bd7d89825aa8ea1e131d096265f0dbbd9f639c24e9d68fc8`). Die übrigen 34 Website-Dateien blieben unverändert. Die tatsächliche öffentliche Seite wurde bei 320, 390, 768 und 1440 Pixeln auf Darstellung, Anker, Ressourcen und CSP geprüft. Rollbackkopien sind gesichert. [PR #92](https://github.com/mxritzgit/Eatova/pull/92) führt den geschützten Merge und die abschließenden Checks; Backendveröffentlichung bedeutet keine Installation einer neuen App auf Nutzergeräten.

**Konfigurationsnachweis:** Der erste Gesamtvergleich der Secret-Metadaten stoppte wegen aktualisierter `updated_at`-Werte der sieben verwalteten Supabase-Einträge. Die acht App-Einträge tragen weiterhin Zeitstempel vor dem Rollout; zwei spätere Leseabfragen sind stabil. Ein zusätzlicher rein lesender Abgleich ordnet die aktuell eingespeisten Schlüssel dem richtigen Projekt zu: `SUPABASE_ANON_KEY` enthält hier einen Publishable-Key, `SUPABASE_SERVICE_ROLE_KEY` einen Secret-Key. Die drei Textmodell-Overrides stimmen; das Rezeptbildmodell verwendet den geprüften Quellstandard. Kein Schlüssel wurde überschrieben. Da die ursprünglichen Secret-Digests ausschließlich im ersten Prozess gehalten wurden, wird keine vollständige Wertgleichheit vor/nach dem Rollout behauptet. [Supabase beschreibt die verwalteten Variablen](https://supabase.com/docs/guides/functions/secrets); die konkrete Typzuordnung hier stammt aus dem Projektabgleich, nicht aus dem Variablennamen.

Der unabhängige Header-Review bestätigt: Ausgehende Service-REST-/RPC-Aufrufe setzen denselben Key in `apikey` und Bearer. Das entspricht der [offiziellen Kompatibilitätsausnahme](https://github.com/orgs/supabase/discussions/29260) und dem REST-Verhalten von [supabase-js v2.110.7](https://github.com/supabase/supabase-js/blob/v2.110.7/packages/core/supabase-js/src/SupabaseClient.ts#L353), hier als versionierte Vergleichsquelle. Die Nutzerprüfung sendet dagegen den echten Nutzer-JWT an Auth; ein API-Key allein erzeugt keinen Nutzerkontext. Kein weiterer Headerfix erforderlich. Dieser Code-/Quellenabgleich ersetzt keinen Hosted-Gateway-Laufzeittest; die lokale GoTrue-Probe verwendet für REST/RPC Stubs. Ein zusätzlicher Laufzeitnachweis gehört in eine freigegebene synthetische Staging-Umgebung.

### Verbleibende Betreiber- und Freigabepunkte

Diese Punkte wurden untersucht; weitere erfolglose identische Zugriffsversuche würden keinen Nachweis hinzufügen. Sie sind keine stillschweigend erledigten Aufgaben:

1. **C06/K02 · P1:** Der einzige Supabase-Owner hat nach Metadaten **keine MFA**. Eigentümer muss einen Faktor und Wiederherstellungszugang selbst einrichten. GitHub-Owner-MFA ist mit dem vorhandenen Token nicht sichtbar; dort angemeldete Sicherheitseinstellungen prüfen.
2. **K05 · P1:** Free-Projekt, **keine abrufbaren Backups, kein PITR**, kein belegter produktiver Wiederherstellungspunkt. RPO/RTO, verschlüsseltes Ziel, Zeitplan, Aufbewahrung und Verantwortung festlegen; dann eine autorisierte Wiederherstellung in ein separates Ziel durchführen. Der neue [Restore-Ablauf](docs/OPERATIONS.md#backups-and-the-restore-rehearsal) ist synthetisch geprüft.
3. **F02/F07/I06 · P1:** Der benannte Infisical-OpenRouter-Key ist **nicht** der bereitgestellte Key. Sein fehlendes Geldlimit darf deshalb nicht der Live-App zugeschrieben werden. Managementpfade sind mit diesem Nicht-Management-Key unzugänglich. Betreiber muss den wirklichen Runtime-Key zuordnen und wiederkehrendes Geldlimit, Routing/Datenverwendung und Aufbewahrung belegen. Kein ungefragtes Überschreiben des funktionierenden Live-Keys.
4. **K06/K07/I03/I06 · P1:** Kein ausreichender Sentry-/Anbieter-Adminzugang, Log-Drain-Zugriff verweigert, kein Dashboard-Browser verfügbar. Tatsächliche Alarmregeln und Zustellung, Aufbewahrung, Verträge, Rechtsgrundlagen und gegebenenfalls Datenschutz-Folgenabschätzung benötigen zugriffsberechtigte beziehungsweise fachkundige Personen. Der [Betriebsablauf](docs/OPERATIONS.md) benennt konkrete Nachweise.
5. **C/H/K01/E · P1/P2:** Kein verifiziertes separates Staging-Projekt, keine echte OAuth-/SMTP-/Abuse-/iOS-/Store-Integrationsabnahme. Zwölf synthetische Modellfälle ersetzen keine fachlich geprüften Gesundheits-/Minderjährigen-/Verletzungsfälle. Geleakte-Passwort-Prüfung ist im Free-Projekt deaktiviert; ein Tarifwechsel ist eine Betreiberentscheidung. CAPTCHA benötigt einen passenden Clientablauf und darf nicht blind aktiviert werden.

Zusätzliche Grenzen bleiben in der 91-Punkte-Tabelle sichtbar: anfrageabhängige statt garantierter 30-Tage-Löschung, begrenzter In-App-Export statt vollständiger Anbieter-/Backup-Auskunft, Header-/Containerprüfung statt zertifiziertem Bilddecoder und separat bewertete Buildwerkzeug-Advisories.

## Vollständiges Checkbuch

Aktueller Stand der 91 Prüfpunkte aus Runde 3. CODE, TEST und LIVE sind getrennte Nachweise; ERFÜLLT gilt ausschließlich für den genannten Umfang. Prioritäten offener Nachweise sind Prüfprioritäten, keine bewiesenen Schwachstellen.

### A. Supabase: RLS und Datenbankberechtigungen

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| A01 | RLS-Abdeckung aller erreichbaren Tabellen | ERFÜLLT | P1 | LIVE: alle 19 App-Tabellen mit RLS; API-Schemas und neue Budgettabellen unabhängig mit dem vollständigen PG17.6-Replay verglichen. [Schema](supabase/SCHEMA_STATE.md), [Budgetmigration](supabase/migrations/20260915091000_ai_provider_budgets.sql). | RLS-/Schemaabgleich und eingeschränkte Rollenprüfungen bei neuen Tabellen wiederholen. |
| A02 | CRUD, USING und WITH CHECK | ERFÜLLT | P1 | LIVE: alle 35 Policies samt Grants/USING/WITH CHECK entsprechen dem getesteten Stand. TEST prüft eigene erlaubte und fremde verbotene CRUD-Nebenwirkungen; Usage erlaubt nur eigenes SELECT. [RLS-Suite](test/migrations/rls_cross_user.sql), [Privacy-Suite](test/migrations/privacy_deletion.sql). | Neue Policies immer mit Positiv- und Negativfällen auf Daten und Nebenwirkungen prüfen. |
| A03 | Nutzer-/Mandantentrennung, Verknüpfungen | ERFÜLLT | P1 | TEST: tatsächliche eingeschränkte Rollen A/B, eigene CRUD erlaubt, fremde Reads/Änderungen ohne Wirkung; Sessions, Training, Rezepte und Mahlzeitkonvertierung eingeschlossen. LIVE: bisherige Definitionen entsprechen dem getesteten Stand. [RLS-Suite](test/migrations/rls_cross_user.sql). | Neue verknüpfte Domänen mit denselben Positiv-/Negativfällen absichern; aktueller Live-Definitionsabgleich abgeschlossen. |
| A04 | Geschützte Eigentümer-/Rollen-/Kontingentfelder | ERFÜLLT | P1 | LIVE: 36 explizite Profil-Spaltengrants; Identität/E-Mail/Anzeigename nicht frei überschreibbar. TEST: fremde Eigentümer, Quota-/Counter-Resets und neue Usage-Schreibzugriffe abgewiesen. Keine Admin-/Premium-/Mandantenfelder. [Berechtigungen](supabase/migrations/20260814120000_audit_rls_guard.sql), [Budgettests](test/migrations/ai_provider_budget.sql). | Neue Rollen/Entitlements und jede zusätzliche Profilspalte ausdrücklich auf Schreibrechte prüfen. |
| A05 | Zu offene Policies | ERFÜLLT | P1 | LIVE: keine USING(true)/WITH CHECK(true) in den 35 App-Policies, anon ohne App-Tabellengrants. TEST: neue Owner-Policy erkennt bewusst gelockerte Mutation als Fehler. [RLS](test/migrations/rls_cross_user.sql), [Usage-Policy](supabase/migrations/20260915093000_ai_usage_export.sql). | Vollständigen Policy-/Rollenabgleich bei jeder Schemaänderung erhalten. |
| A06 | Minimale Schema-/Tabellen-/Funktionsrechte | ERFÜLLT | P2 | LIVE: globales PUBLIC-EXECUTE-Default für künftige postgres-Funktionen entzogen; keine anon-/authenticated-/PUBLIC-MAINTAIN-Rechte an App-Tabellen. Aktuelle App-RPCs explizit begrenzt. TEST: PG17.6 und PG16.15 rot→grün. [Migration](supabase/migrations/20260915090000_database_privilege_boundaries.sql), [Regression](test/migrations/database_privilege_boundaries.sql). | Neue Owner und Funktionen mit expliziten Grants bewerten; verwaltete Provider-Defaults nicht pauschal verändern. |
| A07 | Views und materialisierte Views | NICHT RELEVANT | P2 | LIVE: keine Views/materialisierten Views in den API-exponierten App-Schemas; pg_graphql nicht installiert. Managed Systemviews sind keine freigegebenen App-Views. [Schema-Inventar](supabase/SCHEMA_STATE.md). | Bei erster App-View security_invoker, Owner, Grants und A/B-Zugriff prüfen. |
| A08 | RPCs, SECURITY DEFINER, search_path | ERFÜLLT | P1 | LIVE: alle 34 App-Funktionen mit Definitionshash, ACL, Owner und search_path abgeglichen; Advisorhinweise bewertet. TEST: Budget-RPC nur privilegiert, atomar und begrenzt. [Migrationen](supabase/migrations), [RLS](test/migrations/rls_cross_user.sql), [Budgettests](test/migrations/ai_provider_budget.sql). | Neue Funktionen benötigen explizites EXECUTE und erneut überprüfte Definer-/Ownergrenzen. |
| A09 | Vertrauenswürdige Rolleninformationen/JWT | ERFÜLLT | P1 | CODE/LIVE: Rechte aus auth.uid beziehungsweise verifiziertem Servicepfad; user_metadata ausschließlich zur Anzeigename-Initialisierung. Keine daraus abgeleiteten Admin-/Premiumrechte. [Profiltrigger](supabase/migrations/20260516150000_create_profiles.sql), [RLS-Suite](test/migrations/rls_cross_user.sql). | Bei Rollen-/Claim-Einführung serverseitige Herkunft und Wirkung bereits ausgestellter JWTs prüfen. |
| A10 | Unangemeldet vs. Anonymous Sign-ins | ERFÜLLT | P1 | LIVE: Anonymous Sign-ins deaktiviert; kein Gast-UI. TEST: anon und öffentlicher anon-Bearer dürfen keine geschützten App-/AI-Aktionen ausführen; A/B besitzen eigene Rechte. [RLS](test/migrations/rls_cross_user.sql), [Auth-Probe](scripts/security/README.md). | Vor Aktivierung echter anonymer Konten deren authenticated-Rechte und Budgets getrennt testen. |
| A11 | Bereitgestellte Policies/Grants/Advisor | ERFÜLLT | P1 | LIVE: 46 Migrationen, 19 RLS-Tabellen, 35 Policies, 36 Spaltengrants, 83 Constraints, 17 FKs, 12 Trigger und 34 Funktionen unabhängig mit lokalem Replay verglichen. Advisors und verwaltete Abweichungen getrennt bewertet. [Schema](supabase/SCHEMA_STATE.md), [Migrationsquellen](supabase/migrations). | Diesen Definitions-/Rechteabgleich bei Backendänderungen wiederholen; automatisierter Driftjob prüft nur Versionsnummern. |

### B. Backend, Edge Functions und Secrets

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| B01 | Keine privilegierten Secrets im Client/Repo | TEILWEISE | P1 | TEST: finaler Root-Gitleaks-Scan über 601 erreichbare Commits/24,74 MB und 1051 getrackte Dateien ohne Treffer; synthetische privilegierte Negativkontrollen schlagen an. Server-Env-Referenz ist kein Leak. [Scanregeln](.gitleaks.toml), [CI](.github/workflows/security.yml). | Spätere Änderungen sowie tatsächlich verteilte Artefakte prüfen; gelöschte Referenzen und externe Buildlogs sind nicht durch den Historienlauf belegt. |
| B02 | Öffentliche Supabase-Keys korrekt einordnen | ERFÜLLT | P1 | CODE/TEST: eingebetteter Supabase-Key ist anon, als User-Bearer abgewiesen. LIVE: beide verwendeten Meili-Suchfähigkeiten nur search/products, kein Admin-/Schreibrecht; derzeit nicht ablaufend. [Suchendpoint](supabase/functions/search-key/index.ts), [Anon-Test](supabase/functions/search-key/auth_fail_gate_test.ts). | Suchkey-Rotation beziehungsweise kurzlebige Tenant-Tokens als Betriebsentscheidung festhalten; öffentliche Produktdaten nicht mit privaten Supabase-Daten verwechseln. |
| B03 | Echte serverseitige Tokenvalidierung | TEILWEISE | P2 | CODE/TEST: projektspezifisches /auth/v1/user prüft wirklich; GoTrue 2.196.0 mit gültigen A/B und ungültigen Tokens getestet. Neue Subject-/Audience-/Expiry-Anwesenheitsbindung rot→grün. Abweichender Issuer mit gültigem Projektschlüssel bleibt gesonderte Grenze. [Helper](supabase/functions/_shared/user_token_context.ts), [Probe](scripts/security/README.md). | Alle drei geprüften Bundles sind live; tatsächliche/Legacy-Issuer und Authversion ohne echte User-JWTs belegen, dann zusätzliche Issuerbindung entscheiden. |
| B04 | Objekt-/Aktionsautorisierung jedes Endpoints | ERFÜLLT | P1 | CODE/TEST: alle drei Endpoints verfolgt. Coach bindet Session/History/Schreibwerte an bestätigte UID; A→B-Session erzeugt nur eigene Defaultsession. Analyse speichert keine Tagebuchdaten; Suche liefert öffentlichen Produktindex. [Handler](supabase/functions/coach-chat/handler.ts), [echte lokale Auth-Probe](scripts/security/README.md). | Neue Aktionen bis Daten/Nebenwirkungen prüfen; bereitgestellte Quellen abgeglichen, kein Produktionstest mit fremden Daten. |
| B05 | Keine vertrauten Client-Behauptungen | ERFÜLLT | P1 | CODE/TEST: Identität nur aus verifizierter Authantwort; user_id/isAdmin/isPremium/role/model/messages verleihen keine Rechte. Neue Feld-Allowlist weist solche Bodies explizit zurück. [24 Feldregressionen](supabase/functions/_shared/request_fields_test.ts). | Feld-Allowlist in bereitgestellten Quellen bestätigt; neue Requestfelder ausdrücklich freigeben und Negativfälle beibehalten. |
| B06 | Auth-Konfiguration aller Edge Functions | ERFÜLLT | P1 | LIVE: genau `coach-chat` **v48**, `analyze-meal` **v31**, `search-key` **v10**, alle ACTIVE/verify_jwt=true; komplette Importgraphen stimmen mit getestetem Quellbaum überein. Zusätzlich eigene Authdienstprüfung, keine alte öffentliche Function. [Backend](docs/BACKEND.md), [Quellen](supabase/functions). | Inventar, Authflags und vollständige Bundlequellen nach jeder Bereitstellung vergleichen. |
| B07 | Privilegierte Backend-Clients | ERFÜLLT | P1 | CODE/TEST: Servicezugriffe für Sessions/History/Titel nach Ownerprüfung; Limits aus bestätigter UUID; keine mutierende globale Requestidentität. A/B-Probe prüft Filter, Inserts und Sessionantwort. [Coach](supabase/functions/coach-chat/handler.ts), [Auth-Probe](scripts/security/README.md). | Budget-RPC-Grants und bereitgestellte Definitionen bestätigt; neue privilegierte Aktionen erneut unabhängig autorisieren. |
| B08 | Serverseitige Eingabevalidierung | ERFÜLLT | P2 | CODE/TEST: Coach acht, Analyse vier erlaubte Top-Level-Felder; JSON-Objekte, Typ-/Längen-/Trainings-/Bildgrenzen. Unbekannte Felder vor Session/Tagesquota/Provider abgewiesen; kompatible optionale Defaults bleiben. [Feldtests](supabase/functions/_shared/request_fields_test.ts), [Bildprüfung](supabase/functions/_shared/image_validation.ts). | Kombinierte Quellen sind bereitgestellt und abgeglichen; technische Gültigkeit nicht als fachliche/medizinische Richtigkeit bewerten. |
| B09 | SQL-/Shell-/Inhalt-Injection | ERFÜLLT | P1 | CODE: keine Edge-eval-/Shell-/freie-SQL-Senke; UUID-Filter validiert, Werte über JSON/Parameter. Dynamische Trigger-SQL nutzt serverseitige Identifier mit %I und Werte mit USING. TEST: bestehende RLS/RPC-Fälle. [Row-Caps](supabase/migrations/20260829120000_row_caps_and_hardening.sql), [Handler](supabase/functions/coach-chat/handler.ts). | Bei neuen Importern/Tools erneut vom fremden Eingang bis zur Senke verfolgen. Externer Mirror-Importer ist nicht Teil dieses Repos. |
| B10 | SSRF/externe Requests/Weiterleitungen | ERFÜLLT | P2 | CODE: alle Edge-fetch-Ziele fest beziehungsweise serverkonfiguriert; keine client-/LLM-gesteuerte URL-Abrufaktion, Bilddaten als geprüfte data-URL. [Coach](supabase/functions/coach-chat/handler.ts), [Analyse](supabase/functions/analyze-meal/handler.ts), [Meili-Client](lib/src/services/meilisearch_product_service.dart). | Separaten Mirror-/Importer-Quellstand bei entsprechendem Zugriff prüfen; fehlendes Fremdrepo ist kein belegter SSRF-Befund. |
| B11 | Webhooks/Replay/Idempotenz | NICHT RELEVANT | P2 | CODE plus LIVE-Drei-Function-Inventar: keine Webhook-/Zahlungsempfänger. App-RPC-Idempotenz separat unter F05/A08. [Functions](supabase/functions), [Abhängigkeiten](pubspec.yaml). | Bei neuer Webhook-Integration Signatur, Replay und mehrfache Zustellung prüfen. |

### C. Login, Account-Schutz und Sessions

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| C01 | Registrierung/E-Mail/Passwortschutz | TEILWEISE | P2 | LIVE: E-Mail-Bestätigung nötig, Passwortminimum 8, OTP acht Ziffern/600 s; HIBP aus, Freeplan. CODE/TEST: passende Authabläufe. [Repository](lib/src/auth/auth_repository.dart), [Signup-/OTP-Tests](test/auth_otp_session_isolation_test.dart). | Kompromittierte-Passwort-Prüfung und nötigen Tarif bewusst entscheiden; echte Bestätigungs-/Passwortpolicy in separater Testumgebung prüfen. |
| C02 | Login-/Recovery-Missbrauch | TEILWEISE | P2 | LIVE: Mail-/OTP-/Verify-/Refreshlimits konfiguriert, CAPTCHA aus. TEST: Cooldown und Fehlerpfade; UI unterscheidet trotz neutralem Text einzelne Signupfälle. [Cooldown](test/auth_code_cooldown_test.dart), [Enumeration](test/auth_enumeration_test.dart). | Direkte Authlimits/Enumeration isoliert testen; CAPTCHA nur mit funktionierender Client-Challenge und kompatiblen Recovery-/Google-Flows ergänzen. |
| C03 | PKCE/Redirects/Magic-/Recovery-Links | TEILWEISE | P1 | CODE/TEST: fremde Hosts/Schemes und URL-Tokenpayloads abgewiesen. LIVE: konkrete Callback-Allowlist ohne Wildcards; Recovery-/Signup-Templates mit Codes. [Callback-Prüfung](lib/src/config/supabase_config.dart), [Regression](test/auth_deeplink_predicate_test.dart). | Tatsächlichen Google-/Browser-Rückweg mit positiven/negativen Fällen auf Testprojekt und Android/iOS nachweisen. |
| C04 | Sessionablauf/Refresh/Logout/Sperren | TEILWEISE | P2 | LIVE: JWT 3600 s, Refreshrotation/10-s-Reuse; keine absolute/Idle-Grenze. TEST: spätes OTP stellt nach Logout keine A-Sitzung wieder her; Android-Persistenz geprüft. [OTP-Tests](test/auth_otp_session_isolation_test.dart), [Storage-Tests](test/services/session_logout_restore_test.dart). | Echten Serverrefresh/Sperre/Widerruf isoliert prüfen. Bereits ausgestellte Access-JWTs nicht als durch lokalen Logout sofort ungültig darstellen. |
| C05 | Reauthentifizierung sensibler Änderungen | TEILWEISE | P1 | CODE/TEST/LIVE-Definition: delete_account nur eigene UID und OTP/recovery-AMR ≤5 min; Löschrequest nutzt neues Token. LIVE: doppelte Mailbestätigung/Passwortreauth und vier Warnmail-Flags an. [RPC](supabase/migrations/20260815120000_delete_account_reauth.sql), [Wiretest](test/delete_account_wire_test.dart). | Passwort-24-h-Ausnahme/CurrentPassword-Anforderung bewusst gestalten; echte Geräte-/Auth-Roundtrips und Warnmailzustellung noch nachweisen. |
| C06 | MFA für Administration und App-Nutzer | TEILWEISE | P1 | LIVE: einziger Supabase-Owner MFA=false, konkret fehlender zweiter Faktor. GitHub-MFA-Feld nicht zugänglich; App ohne MFA-Enrollment-/Challenge-UI. [Betriebsanforderungen](docs/OPERATIONS.md), [Auth-Implementierung](lib/src/auth). | Owner richtet eigenen Faktor/Recoverymittel ein; Status erneut lesen. GitHub-MFA über autorisierte Kontoeinstellung prüfen; App-MFA separat risikobasiert entscheiden. |
| C07 | Accountverknüpfung/Wiederherstellung | TEILWEISE | P1 | LIVE: manuelles Linking/Anonymous aus, Google an, Apple aus. TEST: bewiesener später Recovery-/Signup-Sessionwechsel auf A behoben, zulässiger Login nach Logout/Refresh erhalten. [Mutationsguard](lib/src/auth/auth_session_mutation.dart), [A/B-Regression](test/auth_mutation_session_isolation_test.dart). | Reale Google-Verknüpfung/unbestätigte Identität/doppelte Mailänderung in Testprojekt prüfen; Clientfix noch an Endgeräte ausliefern. |

### D. Dateien, Storage und Realtime

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| D01 | Private Dateien/Buckets | NICHT RELEVANT | P2 | CODE: keine Supabase-Storage-Integration; LIVE: keine Datei-, Vektor- oder Analytics-Buckets. Rezeptbilder liegen lokal, KI-Fotos passieren Requestpfade. [Bildstore](lib/src/services/recipe_image_store.dart), [Datenschutz](PRIVACY.md). | Vor Cloud-Dateispeicherung private Bucketarchitektur und Zugriffskonzept neu prüfen; lokale Bilder unter D05/E02. |
| D02 | Storage-Policies für alle Operationen | NICHT RELEVANT | P2 | LIVE: keine Buckets/Storage-Policies; storage.objects/buckets mit RLS. Kein App-Upload/List/Move/Upsert/Delete-Pfad. Managed Grants allein umgehen leere Policies nicht. [Services](lib/src/services), [Schema](supabase/SCHEMA_STATE.md). | Neue Buckets mit A/B-Prüfung jeder Operation, einschließlich Update/Upsert/Move, absichern. |
| D03 | Signed URLs/Berechtigung/Laufzeit | NICHT RELEVANT | P2 | CODE/LIVE: kein Signed-Storage-URL-Pfad und kein Bucket; lokale Bilddateien statt freigegebener Downloadlinks. [Bildstore](lib/src/services/recipe_image_store.dart). | Bei Einführung Owner-Prüfung, Laufzeit, Logging und Weitergabe festlegen. |
| D04 | Uploadgröße und tatsächlicher Dateityp | TEILWEISE | P2 | CODE/TEST: kanonisches Base64, Containerstruktur und Rasterbudget vor Session/Provider; gemessener Bildtyp statt Client-MIME. Analyse 5 MB, Coach 6 Mio Base64-Zeichen. [Servervalidator](supabase/functions/_shared/image_validation.ts), [Tests](supabase/functions/_shared/image_validation_test.ts). | Beide AI-Funktionen deployen; Strukturprüfung ist kein vollständiges serverseitiges Pixeldecoding. Keine Live-Bildprobe ausgeführt. |
| D05 | Bildverarbeitung/Dimensionen/EXIF | TEILWEISE | P2 | CODE/TEST: Metadaten-Originalpfad repariert, EXIF vor Decoder entfernt; 64-MiB-RGBA-/32-MiB-Encoded-Grenzen, beschränkte PNG-/ICC-Inflation, validierter JPEG-Ausgang. [Container](lib/src/services/photo_container.dart), [Metadatenregression](test/services/meal_photo_metadata_boundary_test.dart). | Native Gesamt-RSS/CPU und iOS prüfen; Rasterbudget ist kein Prozessspeicherlimit. Direkte API-Bilder werden serverseitig nicht neu kodiert; Provider-Metadaten bleiben möglich. |
| D06 | Postgres Changes vs. Broadcast/Presence | NICHT RELEVANT | P2 | CODE: keine App-Channels/Broadcast/Presence/PostgresChanges. LIVE: keine publizierten Tabellen, realtime.messages RLS/keine Policies, Presence aus; private_only=true inzwischen zurückgelesen. [Services](lib/src/services), [Betrieb](docs/OPERATIONS.md). | Bei Realtime-Einführung private Channels/Autorisierung mit getrennten A/B-Tests für jeden Kanaltyp prüfen. |
| D07 | Private API-/Dateicaches | TEILWEISE | P1 | CODE/TEST: Bildleser prüft Scope nach IO; verzögertes A-Cleanup erhält B-Bilder/Cache. Android-Prozessneustart und A/B-Isolation ergänzt; Handler no-store. [Bildlesetests](test/services/recipe_image_read_scope_test.dart), [Cleanup-Tests](test/privacy_cleanup_owner_test.dart). | Proxy-/CDN-Header sowie iOS/physische Backups getrennt nachweisen; neue Clientfixes noch ausliefern. Kein bestätigter bisheriger UI-Fremddatenabfluss behauptet. |

### E. Flutter und das Endgerät

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| E01 | Tatsächliche sichere Tokenablage | TEILWEISE | P2 | CODE/TEST: eigener Session-/PKCE-SecureStore und dauerhaftes Revoke-Journal; Android-native Neustarts, kein synthetischer Tokenklartext in Runtime-Prefs, alte Bytes nach Logout gesperrt. [Konfiguration](lib/src/config/supabase_config.dart), [Speichertests](test/services/session_storage_test.dart). | Signierte Android-/iOS-Builds, physische Sperr-/Erstentsperrung und unterbrochene Schreibvorgänge prüfen. Simulierter Löschfehler beweist keinen Hardwarefehlerschutz. |
| E02 | Lokale sensible Daten/Schlüsselschutz | TEILWEISE | P2 | CODE/TEST: accountgebundene AES-GCM-Frames; Android zeigt verschlüsseltes Profil und Sandboxschutz. Lokale Rezeptbilder bleiben Klartext-JPEG im Appverzeichnis. [Cache](lib/src/services/local_cache.dart), [Verschlüsselung](lib/src/services/secure_cache_store.dart), [Löschtests](test/services/privacy_cache_deletion_test.dart). | iOS Data-Protection-Klasse, physischer Schlüsselschutz und tatsächliche Backup-/Transferkopien nachweisen; keine Foto-Verschlüsselung behaupten. |
| E03 | Logout und Accountwechsel | TEILWEISE | P2 | TEST: native A/B-Cache-/Bildtrennung und Revoke über Neustarts; zusätzliche OTP-, Bildlese- und verspätete Cleanup-Races rot→grün. Verschlüsselte A-Outbox bleibt beim Logout bewusst erhalten. [OTP](test/auth_otp_session_isolation_test.dart), [Cleanup](test/privacy_cleanup_owner_test.dart). | Integrierte signierte App auf echten Geräten prüfen; Logout nicht mit vollständiger Kontolöschung oder serverseitigem JWT-Sofortwiderruf gleichsetzen. |
| E04 | Logs/Crash/Clipboard/Push/Vorschau/Backup | TEILWEISE | P2 | CODE/TEST: Sentry-Filter aktiv, keine PII-/Screenshot-/Print-Defaults; expliziter Clipboardexport. Android FLAG_SECURE mit sichtbarer Positivkontrolle, lokale Backups abgewiesen, synthetische Logcanaries fehlen. [Sentry](lib/src/services/crash_reporter.dart), [Appschutz](test/app_private_screen_test.dart). | Echte native Sentry-Envelopes, Lockscreen-Nachrichten, iOS-App-Switcher und tatsächlichen D2D-/Cloudrestore prüfen. Native Probe initialisierte Sentry nicht. |
| E05 | TLS/Release-Zertifikatsprüfung | TEILWEISE | P2 | CODE: kein Trust-Bypass/Cleartext-/ATS-Ausnahmepfad gefunden. TEST: Android-Dart-HttpClient lehnt lokale selbstsignierte Gegenstelle ab; Release-Manifest ohne Custom-Trust-Ausnahme. [Android-Manifest](android/app/src/main/AndroidManifest.xml), [iOS-Konfiguration](ios/Runner/Info.plist). | Signierte Android-/iOS-Artefakte und alle tatsächlichen Netzwerkpfade mit isolierten Testzertifikaten prüfen. Einzelner Handshake ist kein vollständiger TLS-Audit. |
| E06 | Deep Links/Intents/exportierte Komponenten | TEILWEISE | P2 | TEST: installierter Android-Probe akzeptiert vorgesehenen Callback, verwirft täuschende Hosts/Schemes; Komponenten mit passenden Plattform-/Signaturrechten inventarisiert. CODE/TEST: Auth-/Routengrenzen. [Manifest](android/app/src/main/AndroidManifest.xml), [Callbacktests](test/auth_deeplink_predicate_test.dart). | Reale OAuth-Codeverarbeitung und signierte Android-/iOS-Linkpfade prüfen; Custom-Scheme allein authentifiziert keinen Absender. |
| E07 | WebViews und Bridges | NICHT RELEVANT | P2 | CODE: kein eingebetteter JS-/Datei-WebView oder Remote-JS-Bridge; Auth nutzt SFSafariViewController/Chrome Custom Tabs. Native Methodchannels sind kein entsprechender Webzugriff. [Auth](lib/src/auth/auth_repository.dart). | Bei echtem WebView Ziele, JS-Bridges und Dateizugriffe neu prüfen. |
| E08 | Minimale Plattformberechtigungen | TEILWEISE | P2 | CODE/TEST: Android-Releaseberechtigungen inventarisiert, Health nur READ_STEPS; iOS Schritte/Gewicht, explizite Gewichtsschreibvorgänge. Verweigerungsfälle lokal getestet. [Manifest](android/app/src/main/AndroidManifest.xml), [iOS-Entitlements](ios/Runner/Runner.entitlements), [Healthtests](test/services/android_health_service_test.dart). | Native Verweigerung/Widerruf auf signierten Geräten und tatsächliche HealthKit-Verarbeitung prüfen; SDK-Stubs sind kein Plattformnachweis. |
| E09 | Release-Signierung/Debug/Testkonfiguration | TEILWEISE | P2 | TEST: fehlende Android-Signierung stoppt Release-Taskgraph, Release-Manifest ohne debuggable. Geprüfter installierter Probe ist ausdrücklich Debug. iOS-CI baut release/no-codesign. [Build](android/app/build.gradle.kts), [iOS-CI](.github/workflows/ios.yml). | Tatsächlich verteilte APK/AAB/IPA auf Signatur, Flags, Endpoints und Assets prüfen; CI-Dummybuild ist kein Storeartefakt. |

### F. Missbrauch, Rate Limits und AI-Kosten

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| F01 | Eigene API-/AI-Limits | ERFÜLLT | P1 | CODE/TEST/LIVE-QUELLEN: bestehende IP-/User-/Tagesgates plus unabhängiges Budget vor jedem tatsächlichen Provideraufruf. RPC, Grants und Konfiguration live verglichen; ungültige Bodies ohne Providerbuchung lokal getestet. [Budgethelper](supabase/functions/_shared/provider_budget.ts), [Coachtests](supabase/functions/coach-chat/handler_test.ts). | Neue Providerpfade zwingend mit demselben Budget prüfen; keine produktiven Lasttests oder tatsächlichen Calls für den Nachweis ausgeführt. |
| F02 | Nutzer-/globale Budgets und neue Accounts | TEILWEISE | P1 | CODE/TEST und LIVE-Konfiguration: atomar 1000 Calls/UTC-Tag global, davon 50 Bilder, 150/Konto; keine Providerbudget-Refunds. LIVE-App-Geldlimit unbekannt: Vault-Key ist nicht Runtime-Key. [Migration](supabase/migrations/20260915091000_ai_provider_budgets.sql), [Races](test/migrations/ai_provider_budget_concurrency.py). | Betreiber muss tatsächlichen Runtime-Key/Konto identifizieren und USD-Limit, Autoaufladung/BYOK prüfen; kein blindes Ersetzen des funktionierenden Keys. |
| F03 | Größen/Pagination/Kontext/Output/Parallelität | TEILWEISE | P2 | CODE/TEST: Byte-/Kontext-/Outputgrenzen; Providerbodies begrenzt; Coach-Upload maximal 30 s/10 s ohne echte Bytes plus Abbruchsignal. [Bodyreader](supabase/functions/_shared/provider_body.ts), [Uploadregression](supabase/functions/coach-chat/handler_test.ts). | Plattformkonkurrenz/In-flight-Limits und echte Geräte-Latenz gezielt isoliert nachweisen; kein eigener globaler Semaphore, keine Produktionslasttests. |
| F04 | Kostenprüfung und Verbuchung vor Ausführung | ERFÜLLT | P1 | CODE/TEST: Pflichtbudget vor Classifier, Chat/SSE, Rezept, Plan, Bild und Analyse. Sechs erstattete Fehler bei Callcap 3 erzeugen nur drei Calls. Kein Abo/Kaufpfad. [Helper](supabase/functions/_shared/provider_budget.ts), [Coachtests](supabase/functions/coach-chat/handler_test.ts). | Pflichtbudget in allen bereitgestellten Importgraphen bestätigt; neue Providerpfade dürfen es nicht umgehen. Kein USD-Reservierungsnachweis daraus. |
| F05 | Atomare Kontingente/Race Conditions | ERFÜLLT | P1 | TEST PG17.6: 20 Konten/Globalcap 7 → 7 erlaubt; zwölf parallele Calls/Usercap 4 → 4 erlaubt, gespeicherte Summen passend. Entfernte FOR-UPDATE-Sperre macht Regression rot. [RPC](supabase/migrations/20260915091000_ai_provider_budgets.sql), [Racetest](test/migrations/ai_provider_budget_concurrency.py). | Live-RPC und Grants entsprechen dem getesteten Stand. Alte Fragenrefunds ohne Reservation-ID sind keine allgemeine Exactly-once-Garantie; neues Callbudget wird nie erstattet. |
| F06 | Timeouts/Retry-/Agenten-/Toolgrenzen | TEILWEISE | P2 | CODE/TEST: Classifier 15 s, Text 45 s, Bild 60 s, Budget-RPC ≤5 s; begrenzte Antwortleser/Uploadfristen, keine neue Retry-/Agentenschleife. [Bodyreader](supabase/functions/_shared/provider_body.ts), [Deadline-Tests](supabase/functions/coach-chat/handler_deadline_test.ts). | Reales Abbruch-/Billingverhalten gesondert nachweisen; kumulierte Coach-Latenz ist keine garantierte End-to-end-Frist, Providerabrechnung stoppt nicht bewiesen mit Clientabbruch. |
| F07 | Alarme und serverseitige Notabschaltung | TEILWEISE | P1 | CODE/TEST und LIVE-Konfiguration: globale/funktionsbezogene DB-Schalter vor jedem Call; fehlende Konfiguration scheitert geschlossen. Alarmzustellung nicht belegt. [Budgettests](test/migrations/ai_provider_budget.sql), [Notfallablauf](docs/OPERATIONS.md). | Operator/Alarmroute benennen und abgeschirmten Regel-/Zustellnachweis planen. Schalter beendet keine bereits gestartete Providerarbeit. |

### G. AI-Coach und Guardrails

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| G01 | Pflichtschutz auf allen Endpoint-/Moduspfaden | TEILWEISE | P1 | CODE/TEST: gemeinsamer Coach-Einstieg und serverseitige Prüfung vor Chat/Rezept/Plan; Bild ohne Caption benötigt keinen Textclassifier. Zwölf synthetische echte Modellfälle ergänzen Offlineprüfungen. [Handler](supabase/functions/coach-chat/handler.ts), [versionierte Eval](supabase/eval/results/2026-09-15.md). | Bild-only/Bildtext und ausgewählte Plannotizen gezielt prüfen; tatsächlicher Runtime-Key-/Deploymentkontext ist durch Vault-Key-Eval nicht belegt. |
| G02 | Direkte/indirekte Prompt Injection | TEILWEISE | P1 | CODE/TEST: Kontext als untrusted user-Daten, begrenzte Freitexte; echte direkte, Kontext- und Verlaufs-Canaries abgewehrt. Keine LLM-Rechteausweitung beobachtet. [Guardrails](supabase/functions/coach-chat/guardrails.ts), [Eval](supabase/eval/results/2026-09-15.md). | Mehr Sprachen, Verschleierungen, lange Mehrstufenfälle sowie Bilder/Plan-Notizen isoliert und explizit budgetiert erweitern. Kein universeller Injectionschutz behauptet. |
| G03 | Vertrauenswürdige Rollen/Modellparameter | ERFÜLLT | P1 | CODE/TEST: Systemrollen/Modelle serverseitig; History nur user/assistant; Client kann keine Rollen-, Tool- oder Modellliste einschleusen. Neue Feldtests weisen Manipulation ab. [Handler](supabase/functions/coach-chat/handler.ts), [Feldregression](supabase/functions/_shared/request_fields_test.ts). | Geänderte Bundlequellen und unveränderte Konfiguration nach Rollout verglichen; neue Rollenparameter nur serverseitig zulassen. |
| G04 | Keine Geheimnisse/unnötigen Daten im Kontext | TEILWEISE | P1 | CODE/TEST: Providerkey nur Header; Classifier nur aktuelle Nachricht/ausdrücklicher Trainingstext. Antwort erhält begrenzte eigene History und optionalen Tageskontext, keine automatische E-Mail/Name. [Snapshot](lib/src/app/home_store.dart), [Kontexttests](test/home_store_coach_context_slots_test.dart). | Notwendigkeit automatischer Gewichts-/Ernährungswerte je Anfrage entscheiden; Providerlogging/Retention unter I06 prüfen. Freitext ist nicht automatisch anonym. |
| G05 | Begrenzte Tool-Rechte | NICHT RELEVANT | P2 | CODE: kein LLM-Tool-Executor, freie SQL-/Shell-/URL-Aktion, RAG oder Vektortool; Bildgenerierung bleibt fester serverseitiger Providerpfad. [Coach](supabase/functions/coach-chat/handler.ts). | Vor Tool-/Agent-Einführung Berechtigungen und Parameter außerhalb des Modells erzwingen; Bild-/Kostenprüfung bleibt relevant. |
| G06 | Datenrechte außerhalb des LLM | ERFÜLLT | P1 | CODE/TEST: bestätigte UID und Owner-Session vor History/Modell; LLM führt keine Rechteentscheidung aus. Tatsächliche lokale Authprobe und eingeschränkte SQL-Rollen ergänzen den Datenfluss. [Auth-Probe](scripts/security/README.md), [RLS](test/migrations/rls_cross_user.sql). | Bereitgestellte Quellen entsprechen dem getesteten Kandidaten; neue Daten-/Toolaktionen separat autorisieren. |
| G07 | Geprüfte Ausgaben/Darstellung/Links/Bilder | TEILWEISE | P1 | CODE/TEST: finish/filter/Leakprüfung, strikte Rezept-/Planschemas und Grenzen; Flutter führt keinen generierten HTML-/SQL-/Code-/Linkinhalt aus. Positive echte Vorschläge geprüft. [Rezeptparser](supabase/functions/coach-chat/recipe.ts), [Planparser](supabase/functions/coach-chat/training_plan.ts), [Eval](supabase/eval/results/2026-09-15.md). | Fachliche Nährwert-/Trainingsplausibilität und Bildcodecgrenzen getrennt prüfen; strukturell gültig heißt nicht medizinisch sinnvoll. |
| G08 | Nutzertrennung in Chat/Memory/Caches | TEILWEISE | P1 | CODE/TEST: Historyfilter UID UND Session, Rollen-/Längengrenzen; keine Embeddings/Vektorsuche/Antwortcaches. A/B-SQL/Endpoint- und lokale Geräte-/Cleanup-Proben grün. [Handler](supabase/functions/coach-chat/handler.ts), [RLS](test/migrations/rls_cross_user.sql), [Accountwechsel](test/coach_session_race_test.dart). | Integrierten signierten Client und isolierten Cloud-A/B-Roundtrip ergänzen; kein Produktionschat für Prüfung gelesen. |
| G09 | Echte Bestätigung folgenreicher Aktionen | ERFÜLLT | P1 | CODE/TEST: Rezeptübernahme nach bestätigtem Sheet, Trainingsplan nach Editor-Save mit aktiver Identität/Sitzung/Draft; Abbruch/Accountwechsel/Doppelspeichern getestet. Modellantwort bleibt Vorschlag. [Rezeptflow](test/coach_recipe_flow_test.dart), [Planflow](test/coach_training_plan_flow_test.dart). | Neue automatische Aktionen vor Einführung prüfen; tatsächliches Endgeräteverhalten bleibt separater Release-Nachweis. |
| G10 | Verhalten bei Schutz-/Providerfehlern | ERFÜLLT | P1 | CODE/TEST: ungültiger Classifier/Filter/Parse-/Abschlussfehler stoppt vor ungeprüfter Ausgabe/Persistenz. Reale verkürzte Planantwort endet kontrolliert ohne Assistant-Eintrag. [Handlerregressionen](supabase/functions/coach-chat/handler_test.ts), [Eval](supabase/eval/results/2026-09-15.md). | Verhalten mit bereitgestellter Credential/Proxy getrennt bestätigen; technische Fail-closed-Prüfung ist keine semantische Guardrail-Zertifizierung. |
| G11 | Sicherheit bereits ausgegebener Streamteile | ERFÜLLT | P1 | CODE/TEST: vollständige Antwort vor Deltas final geprüft; späte Filter/EOF/Abbruch/Unicodefälle halten ungeprüften Text zurück. Echter EN-SSE-Pfad mit freigegebener Persistenz geprüft. [Streamingregression](supabase/functions/coach-chat/handler_stream_test.ts), [Eval](supabase/eval/results/2026-09-15.md). | Tatsächliches Proxy-/Disconnect-Timing und Runtime-Key nachweisen. Empfang am Endgerät ist kein Persistenz-Ack; semantische Grenzen bleiben G02/H. |
| G12 | Adversariale und legitime Regressionstests | TEILWEISE | P1 | TEST: umfangreiche Offline-Suite plus zwölf versionierte rein synthetische echte Modellfälle, positive Chat/SSE/Rezept/Plan und negative Risiko-/Injectionfälle. [Evalharness](supabase/eval), [Ergebnisse](supabase/eval/results/2026-09-15.md). | Bild-/Plannotiz-/Mehrstufenmatrix und fachliche Abnahme ergänzen; Modellslug allein fixiert keinen unveränderlichen Modelbuild. |

### H. Fitness-spezifische Nutzersicherheit

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| H01 | Grenzen bei Diagnosen/Medikamenten/Heilung | TEILWEISE | P1 | CODE/TEST: Prefilter/Classifier/feste Ablehnung; echte Symptom-/Schmerz-/Extremdiätfälle abgewehrt. Irrführender Steroid-only-Refusal durch symptombezogenen DE/EN-Text ersetzt, alle vier Modi rot→grün. [Handlerregression](supabase/functions/coach-chat/handler_test.ts), [Eval](supabase/eval/results/2026-09-15.md). | Korrigierter Text ist bereitgestellt; fachliche Prüfung von Risikoerkennung, Eskalation und legitimen Gegenfällen bleibt erforderlich. Kein klinischer Wirksamkeitsnachweis. |
| H02 | Fachlich geprüfte Risikosituationen | NICHT PRÜFBAR | P1 | Technische synthetische Risikofälle vorhanden; keine zugängliche benannte medizinische/ernährungsfachliche Freigabe. [Vorhandene Fälle](supabase/eval/results/2026-09-15.md). | Fachperson benennt/prüft Warnsymptome, Verletzungen, Essstörungen, Belastung/Versorgung und erlaubte Gegenfälle; dokumentierte Abnahme erforderlich. |
| H03 | Minderjährige und Einschränkungen | TEILWEISE | P1 | CODE/TEST: Mindestalter 16 als Profilgrenze, explizites Minderjährigen-Extremziel abgewiesen. Coach-Snapshot enthält kein Altersband/Einschränkungsinventar. [Profilgrenzen](lib/src/models/model_limits.dart), [Snapshot](lib/src/app/home_store.dart), [Eval](supabase/eval/results/2026-09-15.md). | Produkt-/Fachkonzept für 16-/17-Jährige und Einschränkungen festlegen; Altersconstraint ist kein klinischer/rechtlicher Eignungsnachweis. |
| H04 | Plausible Profile und Empfehlungen | TEILWEISE | P1 | CODE/TEST: technische Profil-/Rezept-/Plangrenzen und fehlende Ziele behandelt. Echte Antworten zeigen weiterhin fachlichen Prüfbedarf bei unangefragten Defizitzahlen, schwerem Training und verallgemeinerter Blutzuckerwirkung. [Grenzen](lib/src/models/model_limits.dart), [Eval](supabase/eval/results/2026-09-15.md). | Fachlich geprüfte Widerspruchs-/Empfehlungsmatrix entwickeln; keine eigenmächtigen medizinischen Grenzwerte ergänzen. |

### I. Datenschutz und Gesundheitsdaten

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| I01 | Dateninventar inkl. Ableitungen und Empfänger | ERFÜLLT | P1 | CODE/LIVE-Inventar: 19 App-Tabellen; 18 lokale Slots, Bilder/Outbox, Health/Speech, Supabase/OpenRouter/Google, Produktsuche, Sentry und Support getrennt verfolgt. [Schema](supabase/SCHEMA_STATE.md), [Datenschutz](PRIVACY.md), [Exportliste](lib/src/services/data_export.dart). | Nach Schema-/Provideränderung fortschreiben; tatsächliche Anbieter-Kontoeinstellungen bleiben gesondert I06. |
| I02 | Datensparsamkeit AI/Analytics/Support | TEILWEISE | P1 | CODE/TEST: begrenzter Tageskontext, Classifier ohne Bild/History/Profil; Rezept/Training ohne automatischen Körperkontext. Sentry filtert reale SDK-Payloads synthetisch. [Snapshot](lib/src/app/home_store.dart), [Sentrytests](test/services/crash_reporter_before_send_test.dart), [Coachservice](lib/src/services/coach_chat_service.dart). | Notwendigkeit automatischer Gewichts-/Tageswerte je Frage entscheiden; native Crashenvelopes und tatsächliche Providerlogging-/Supportregeln prüfen. |
| I03 | Einwilligungen und zutreffende Information | TEILWEISE | P1 | CODE/TEST: DE/EN-Coachinformation korrigiert. LIVE: Websiteangaben zu Usage und ereignisabhängiger Retention passend zum Backend veröffentlicht, öffentliche Bytes/Darstellung geprüft. [Datenschutz](PRIVACY.md), [Disclosuretest](test/coach_ai_disclosure_test.dart), [Websitekorrektur](docs/PRIVACY-WEBSITE-CORRECTION-2026-09-14.md). | Rechtsgrundlagen, Gesundheitsdaten/Einwilligungsdesign und Verträge fachlich prüfen lassen; technische Textkorrektur ersetzt keine rechtliche Abnahme. |
| I04 | Vollständige Löschung/Anbieter/Backups | TEILWEISE | P1 | TEST: tatsächliches delete_account als A entfernt alle 16 UID-Tabellen des Kandidaten, B-JSON unverändert; lokale Slots/Bilder und späte Cleanup-Races geprüft. Logout-Outbox-Ausnahme getrennt. [SQL](test/migrations/privacy_deletion.sql), [Cachetests](test/services/privacy_cache_deletion_test.dart), [Cleanup](test/privacy_cleanup_owner_test.dart). | Staging-End-to-end-Löschung sowie Auth-/Provider-/Support-/Backup- und OS-Kopienprozesse nachweisen. Datenbankcascade allein beweist keine vollständige externe Löschung. |
| I05 | Sicherer vollständiger Eigenexport | TEILWEISE | P1 | CODE/TEST: In-App-Serverexport repariert, kleinere Pagecaps/fehlender Count ehrlich behandelt; 15 eigene Bereiche einschließlich Usage, SELECT-only-RLS; expliziter Clipboardtap. [Exporttests](test/services/data_export_service_test.dart), [A/B-SQL](test/migrations/privacy_deletion.sql), [Sheet](lib/src/widgets/shared/data_export_sheet.dart). | In-App-Serverumfang ist geprüft; lokale Bilder/unsynced Daten, Authinternals, Dedupe-, Anbieter-/Support-/Backupdaten brauchen ergänzenden autorisierten Auskunftsablauf. Offsetscan ist kein atomarer Snapshot. |
| I06 | Anbieter, Aufbewahrung, Orte, Verträge | TEILWEISE | P1 | LIVE: Supabase eu-west-1/Free, keine verfügbaren Restorepunkte nachgewiesen. CODE: Retention bei Aktivität, kein garantierter TTL. OpenRouter-Runtime-Key weicht vom geprüften Vault-Key ab; Privacy/ZDR/Logging/Sentry-Kontoeinstellungen unbekannt. [Datenschutz](PRIVACY.md), [Retention-RPC](supabase/migrations/20260915091000_ai_provider_budgets.sql). | Richtige Anbieter-Kontozuordnung und reine Einstellungsnachweise für Nutzung/Logging/Weiterleitung/Ort/Löschung/Retention beschaffen; DPAs/Transfers gesondert fachlich prüfen. |

### J. Abos und Zahlungen

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| J01 | Serverseitig verifizierte Käufe | NICHT RELEVANT | P2 | CODE/LIVE-Inventar: kein Payment-/Store-SDK, Receipt-/Kauf-/Entitlement-Endpunkt im tatsächlichen Produkt. [Abhängigkeiten](pubspec.yaml), [Functions](supabase/functions), [Schema](supabase/SCHEMA_STATE.md). | Bei Monetarisierung vertrauenswürdige serverseitige Kaufprüfung und Nutzerzuordnung implementieren/testen. |
| J02 | Geschützte Premium-/Credits-Freischaltung | NICHT RELEVANT | P2 | CODE: keine Premium-/gekauften Creditfelder oder Freischaltung; manipulierte Premiumbehauptung erzeugt keine Rechte. AI-Kontingente separat F04/F05. [Schema](supabase/SCHEMA_STATE.md), [Feldtests](supabase/functions/_shared/request_fields_test.ts). | Vor Entitlementeinführung Serverdurchsetzung einschließlich manipulierter Clients prüfen. |
| J03 | Ablauf/Refund/Restore/Ereigniskonsistenz | NICHT RELEVANT | P2 | CODE/LIVE-Inventar: kein Abo-, Kaufrefund-, Restore- oder Paymentwebhookpfad. AI-Fragenrefund ist keine Zahlung. [Functions](supabase/functions), [Abhängigkeiten](pubspec.yaml). | Bei Zahlungsintegration verspätete/doppelte Ereignisse, Refund und Ablauf serverseitig testen. |
| J04 | Trials/Gutscheine/Empfehlungen/Guthaben | NICHT RELEVANT | P2 | CODE/Schema: keine Trial-/Gutschein-/Referral-/gekaufte-Guthabenlogik; keine echten Zahlungen getestet. [Schema](supabase/SCHEMA_STATE.md), [Services](lib/src/services). | Neue Geschäftslogik vor Freigabe auf Wiederholung, Doppelbuchung und Parallelität prüfen. |

### K. Betrieb, Dependencies und Release-Prozess

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| K01 | Getrennte Entwicklung/Test/Produktion | TEILWEISE | P1 | CODE/TEST: CI-Dummydefines und disposable DBs; LIVE: geschützte main-only Drift-Umgebung. Vault-Label dev zeigt auf verlinktes Liveprojekt; keine eigene Staging-Branch belegt. [CI](.github/workflows/security.yml), [Betrieb](docs/OPERATIONS.md). | Eigenes Testprojekt samt getrennten Credentials/Providerbudgets benennen und belegen; dev-Label nicht als Isolation behandeln. |
| K02 | Infrastruktur-/CI-Rechte, MFA, DB-Netz/TLS | TEILWEISE | P1 | LIVE: DB-TLS-Pflicht jetzt aktiviert/zurückgelesen; acht geschützte Checks, Admins eingeschlossen, kein Forcepush/Löschen. Supabase-Owner ohne MFA; GitHub-MFA unbekannt. Netz weiterhin öffentlich erreichbar mit Auth/RLS. [CI](.github/workflows/security.yml), [Betrieb](docs/OPERATIONS.md). | Owner-MFA einrichten/belegen; GitHub-MFA prüfen. Netzrestriktionen erst mit Inventar legitimer Clients planen, keine blinde IP-Sperre. |
| K03 | Bekannte Schwachstellen der Abhängigkeiten | TEILWEISE | P1 | TEST: 153 Pub-, neun Swift-Revisions- und 169 Android-Runtimekomponenten ohne OSV-Match. Gradle-8.14-Resolverlücke mit Herstellerbeleg rot→grün auf 8.14.4; 45 separate Buildtool-Advisories nach Erreichbarkeit triagiert. [Wrapper](android/gradle/wrapper/gradle-wrapper.properties), [Buildtool-Triage](android/BUILD_TOOL_SECURITY.md), [Inventar](tool/security_inventory.py). | Android Debug/Release einschließlich R8 sowie iOS-Build ohne Codesign in CI erfolgreich; verbleibende passende Buildtool-Updates planen. OSV-zero beweist keine vollständige Schwachstellenfreiheit. |
| K04 | Secret-/statische-/RLS-Prüfungen in CI | ERFÜLLT | P1 | CODE/TEST und [CI 34910018466](https://github.com/mxritzgit/Eatova/actions/runs/34910018466): erforderliche Checks, strikte Analyse/Coverage, native/Swift-Inventare, PG17.6, Budget-Races, Restore und Offline-Eval erfolgreich. LIVE: Secret-/Pushschutz und acht Checkbindungen an GitHub Actions. [Workflow](.github/workflows/security.yml), [Scannerregression](test/tooling/osv_cli_test.py). | Finalen PR-Head vor geschütztem Merge prüfen; Rechte-/Funktionsabgleich gesondert vom reinen Versionsdriftjob erhalten. |
| K05 | DB-/Storage-Backup und Restore-Nachweis | TEILWEISE | P1 | TEST: zwei getrennte PG17.6-Cluster, synthetischer Restore mit Daten-/Katalog-/Rollenvergleich und A/B-Zugriff; RLS-/Datenmutanten erkannt. LIVE: Free, PITR aus, Backup-Liste/Restorefenster leer. [Rehearsal](test/operations/backup_restore.py), [Runbook](docs/OPERATIONS.md). | Produktionsbackupziel, Zeitplan, Retention, RPO/RTO und tatsächlichen nutzbaren Restorepunkt festlegen/nachweisen; lokaler Restore ist kein Produktionsrestore. |
| K06 | Nachvollziehbare, sparsame Sicherheitslogs | TEILWEISE | P1 | CODE/TEST: Sentry- und Providerdiagnostik gefiltert, keine unnötigen Inhalte; erlaubte technische Felder geprüft. LIVE-Admin-Auditretention unzugänglich, Logdrains 403, kein Sentry-Adminzugang. [Sentry](lib/src/services/crash_reporter.dart), [Providerlogtests](supabase/functions/_shared/provider_log_test.ts), [Betrieb](docs/OPERATIONS.md). | Audit-/Sentry-Einstellungen mit nötigem Lesezugriff prüfen; keine echten Health-/Logpayloads für den Nachweis exportieren. |
| K07 | Alarme für Kosten/Fehler/Datenmissbrauch | NICHT PRÜFBAR | P1 | CODE/DOKU: konkrete begrenzte Alarmvorschläge und sichere Prüfschritte im Runbook. Kein zugänglicher Nachweis tatsächlicher Regeln, Empfänger oder Zustellung; kein Testalarm versendet. [Monitoringablauf](docs/OPERATIONS.md). | Provider-Admin-Lesezugang, Haupt-/Vertretungszuständigkeit und autorisierte isolierte Zustellprobe organisieren; fehlender Nachweis bedeutet nicht automatisch keine Alarme. |
| K08 | Rotation/Sperre/Rollback/Notabschaltung | TEILWEISE | P1 | CODE/TEST: Runbook und synthetischer Restore. LIVE: AI-Schalter und geprüfte Functions bereitgestellt; Private Vulnerability Reporting aktiviert. [Notfallablauf](docs/OPERATIONS.md), [Budgetschalter](supabase/migrations/20260915091000_ai_provider_budgets.sql). | Verantwortliche benennen und Rotation/Sperre/Rollback/Alarm im Tabletop üben; kein Schlüssel ohne geklärte Zuordnung ersetzen, kein Appupdate als einzige Abwehr. |

### L. Web-Version und zusätzliche Härtung

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
|---|---|---|---|---|---|
| L01 | Flutter Web/XSS/CSP/Browser-Tokenablage | NICHT RELEVANT | P2 | CODE: kein Flutter-web-Target oder Webrelease; native Android/iOS. Separate Marketingwebsite ist keine Flutter-Browser-Session. [Architektur](README.md), [Workflows](.github/workflows). | Bei Flutter-Web-Einführung Browserstorage, XSS/CSP und Authflows neu prüfen. |
| L02 | CORS und gegebenenfalls Cookie-CSRF | ERFÜLLT | P2 | CODE/TEST: 48 Antworten über drei Handler/acht Origins; Coach-Origin auf echten JSON/SSE-Antworten korrigiert, keine Credentials-CORS. LIVE-QUELLEN: Fix in bereitgestellten Importgraphen; Origin-Allowlist derzeit nicht gesetzt, Bearerauth statt Cookies. [Matrix](supabase/functions/_shared/cors_origin_contract_test.ts), [Coachtests](supabase/functions/coach-chat/handler_cors_test.ts). | Keine Allowlist ohne Webbedarf aktivieren; bei Cookieauth CSRF neu prüfen. CORS ist keine Objekt-/Tokenautorisierung. |
| L03 | Certificate Pinning nach Bedrohungsmodell | ERFÜLLT | P2 | Bewertet: Standard-TLS mit nativer Ablehnung nicht vertrauenswürdiger Zertifikate; keine Pins. Für wechselnde verwaltete Provider überwiegt ohne weitergehendes Bedrohungsmodell das Aussperr-/Rotationsrisiko. [TLS-Konfiguration](android/app/src/main/AndroidManifest.xml), [Betriebsgrundlagen](docs/OPERATIONS.md). | Entscheidung durch Produkteigner bestätigen; bei höherem Schutzbedarf Backup-Pins, Ablauf, Rotation und Wiederherstellung vor Einführung planen. Keine fehlende Pflichtfunktion behauptet. |
| L04 | Geräteintegrität/Attestation | TEILWEISE | P2 | Bewertet: kein Play-Integrity-/App-Attest-Backendpfad; Auth/Ownerchecks/Budgets sind primäre Grenzen. Fehlende optionale Attestation ist kein nachgewiesener Autorisierungsbypass. [Functions](supabase/functions), [Plattformen](pubspec.yaml). | Bei belegtem automatisiertem Missbrauch Nutzen, Request-/Replaybindung, echte Storekonfiguration und legitime Ablehnungen/Fallbacks planen. |
| L05 | Obfuscation | TEILWEISE | P2 | CODE: Android R8/Resource-Shrinking und Mappingprüfung, keine Dart-Obfuscation/split-debug-info; tatsächliches Storeartefakt nicht untersucht. [Gradle](android/app/build.gradle.kts), [CI](.github/workflows/security.yml). | Optionale Dart-Hürde nur mit sicherer Symbolablage und getesteter Crashauflösung entscheiden; kein Ersatz für Autorisierung oder Geheimnisschutz. |

## Runde 3 — Befunde und Korrekturen

Die folgenden 16 Gruppen trennen konkrete Fehler von zusätzlicher Härtung. CODE/TEST ist kein Deployment-Nachweis; der tatsächliche Rollout steht im aktuellen Stand oben. Quelllinks nennen betroffene Funktionen und Regressionstests.

### R3-01 · P1 · Verspätete OTP-Antwort konnte den Kontowechsel rückgängig machen

- **Grenze:** [verifyRecoveryCode/verifySignupCode](lib/src/auth/auth_repository.dart#L193), [Sitzungsübernahme](lib/src/auth/auth_session_mutation.dart#L72); Recovery wird auch vor der Kontolöschung benutzt.
- **Voraussetzung/Schaden:** A startet eine Codeprüfung, meldet sich während des Requests ab oder B an; die verspätete SDK-Antwort stellte A global wieder her. Dadurch konnte die nächste Bedienperson unerwartet A sehen. Kein produktiver Zugriff wurde durchgeführt.
- **Rot:** Echte installierte GoTrue-Dart-SDK mit gehaltenem synthetischem `/verify`: erwartet B, tatsächlich A; nach Logout ebenfalls unerwartete Wiederanmeldung. [Mutationsregression](test/auth_mutation_session_isolation_test.dart).
- **Fix, CODE/LOKAL:** Verifikation im isolierten Client; Übernahme nur bei unveränderter UID und `session_id`. Synchroner Listener merkt auch A→B→A; fremde/leere Antwortsession wird abgewiesen. Refresh derselben Sitzung bleibt erlaubt.
- **Review-Folgefix ausdrücklich enthalten:** `55e38d7` verwarf neue legitime Codes nach bereits abgeschlossenem Logout, weil GoTrue 2.27.2 ein historisches `signedOut` erneut ausliefert. `531f20c` vergleicht tatsächliche Identitäten: null→null sperrt nicht, wirkliche Zwischenwechsel weiterhin schon.
- **Grün/Auswirkung:** [OTP-Suite](test/auth_otp_session_isolation_test.dart#L49) deckt zulässigen Login, abgeschlossenen Logout, schnelle Zwischenwechsel, neue A-Sitzung und Refresh ab; zwei neue Positivfälle waren auf dem ersten Fix rot. Alte Codes nach wirklichem Wechsel können neu angefordert werden müssen.
- **Rest:** Stubs beweisen nicht SMTP, Social-Provider, gehostete OTP-/Sperrpolitik oder iOS; bereits ausgegebene Access-Tokens werden dadurch nicht sofort widerrufen.

### R3-02 · P2 · Unvollständige Exporte wurden als vollständig bezeichnet

- **Grenze:** [DataExportService._alleLoggedMeals](lib/src/services/data_export.dart#L198) und `_rows`/`vollstaendigkeitUnbekannt` in derselben Datei; Export liest mit festgehaltener Nutzer-ID.
- **Voraussetzung/Schaden:** Ein niedrigeres PostgREST-Zeilenlimit oder eine fehlende Gesamtzahl konnte einen gekürzten Ernährungs-/Gewichtsdatensatz als vollständige Auskunft erscheinen lassen. Kein Fremddatenzugriff und kein auslösender Live-Zeilenlimitnachweis.
- **Rot:** Fünf synthetische Mahlzeiten, angeforderte Seite 3, Servermaximum 2 ergaben nur zwei Zeilen. Eine ungezählte Gewichtsantwort mit demselben Maximum meldete ebenfalls fälschlich vollständig.
- **Fix, CODE/LOKAL:** Offset um tatsächlich gelieferte Zeilen erhöhen, erst bei leerer Seite stoppen, Wiederholung ohne neue IDs abbrechen. Nichtleere ungezählte Abschnitte behalten ihre Daten, markieren Vollständigkeit aber ausdrücklich als unbekannt/teilweise.
- **Grün:** [Paging-/Stillstandsregression](test/services/data_export_service_test.dart#L215) erhält alle fünf Zeilen über Offsets 0/2/4/5; [fehlender Count](test/services/export_paket_data_export_test.dart#L136) meldet teilweise; bekannte leere/vollständige Antworten bleiben korrekt.
- **Auswirkung:** Eine zusätzliche leere Endabfrage; verständliche DE/EN-Teilstatusanzeige. Eigene tägliche AI-Nutzung ist mit [SELECT-only-Policy](supabase/migrations/20260915093000_ai_usage_export.sql#L3) aufgenommen; globale Budgets bleiben unsichtbar.
- **Rest:** Offset-Paging ist keine transaktionale Momentaufnahme bei parallelem Löschen/Einfügen. Schließen des Sheets beendet laufende Reads nicht; AuthGate/UID-Filter sind zusätzliche Grenzen, kein nachgewiesener vollständiger Abbruchvertrag.

### R3-03 · P1 · Lokale Bild-Reads und verspätete Bereinigung wechselten den Eigentümer

- **Grenze:** [RecipeImageStore.resolve/readProposalImage](lib/src/services/recipe_image_store.dart#L219), [clear(expectedUserId)](lib/src/services/recipe_image_store.dart#L526), [HomeStore._clearCache/_resolveCacheForOwner](lib/src/app/home_store_sync.dart#L1663).
- **Voraussetzung/Schaden:** Bei Kontowechsel während Datei-I/O lieferte ein alter A-Read noch A-Bytes zurück. Verzögerte A-Abmeldung/-Löschung konnte außerdem B-Bilder bzw. B-Cache löschen, einschließlich lokaler noch nicht synchronisierter Daten.
- **Rot:** Angehaltenes `readAsBytes` lieferte nach A→B `[1,2,3,4]` statt null; angehaltene A-Bereinigung entfernte B-Dateien. Ungebooteter Store wählte über den veränderten gemeinsamen Client den falschen Cache.
- **Fix, CODE/LOKAL:** Scope-Token vor/nach Dateiauflösung und Lesen vergleichen; Bereinigung erhält die unveränderliche `sync.userId` und entfernt nur deren Namespace. Cache-Fallback verwendet dieselbe Eigentümer-ID.
- **Grün:** [Read-/Scope-Tests](test/services/recipe_image_read_scope_test.dart), [sechs HomeStore-Bereinigungsfälle](test/privacy_cleanup_owner_test.dart) prüfen erlaubtes eigenes Löschen, B-Bytes/-Scope und verschlüsselten B-Cache nach verzögertem A-Logout/-Delete.
- **Auswirkung:** Veraltete Reads liefern null/Platzhalter; eigener Logout und Delete entfernen weiterhin eigene Bilder. Media- und Privacy-Callerfix gehören zusammen (`e909efa`/`ca61974`).
- **Rest:** Der Low-Level-Readfehler ist belegt, eine sichtbare Fremddatenanzeige im echten UI nicht; AuthGate entfernt zusätzlich alte Routen. Android-Prozessnachweise ersetzen weder iOS noch OEM-/Backup-Prüfungen.

### R3-04 · P1 · Provideraufrufe hatten kein unabhängiges gemeinsames Kostenbudget

- **Grenze:** [reserve_ai_provider_call](supabase/migrations/20260915091000_ai_provider_budgets.sql#L37), [ProviderCallBudget](supabase/functions/_shared/provider_budget.ts#L23), alle Coach-/Analyse-Providerstarts.
- **Voraussetzung/Schaden:** Mehrere Konten und erstattete Providerfehler öffneten zusätzliche bezahlte Versuche trotz Fragen-/IP-Limits. Das fehlende globale Gate und synthetische Erstattungsfolgen sind belegt; gezielt erzeugbare reale Providerfehler oder unbegrenztes Guthaben nicht.
- **Fix, CODE/LOKAL:** Nicht erstattbare atomare Buchung unmittelbar vor jedem Classifier-, Antwort-, Rezept-, Plan-, Bild- und Analyseaufruf; Singleton-Zeilensperre, UTC-Tag nach Lock, globale/operationsbezogene Abschaltung. Ungültiges/fehlendes RPC-Ergebnis sperrt.
- **Grenzen:** 1000 Provider-HTTP-Aufrufe insgesamt, 150 je Konto, davon global höchstens 50 Rezeptbilder pro UTC-Tag; Fragenkontingente gelten zusätzlich. Dies zählt Calls, keine Dollar oder providerinternen Billingeinheiten.
- **Rot/Grün:** [Handlerfälle](supabase/functions/coach-chat/handler_test.ts#L2713): alte globale Ablehnung trotzdem 200/Providerarbeit, jetzt 429 ohne Aufruf; wiederholte Fragenrefunds öffnen das Callbudget nicht. [SQL-Rollen](test/migrations/ai_provider_budget.sql) und [Parallelität](test/migrations/ai_provider_budget_concurrency.py): 20 Konten/Cap7→7 erlaubt; zwölf gleiche UID/Cap4→4 erlaubt. Entferntes Lock ergab im isolierten Mutationstest 14 statt 7, Original wieder grün.
- **Auswirkung:** Globale Erschöpfung begrenzt alle Nutzer; verlorene RPC-Antworten dürfen konservativ mitzählen. Bildbudget-Ablehnung lässt den gültigen Rezeptvorschlag ohne Bild zu; fehlende Migration führt bewusst zu 503.
- **Rest:** Bereitstellung von Migration und Functions getrennt belegen. App-Key-Dollarlimit, Autoaufladung, Provider-Billingstopp und Livealarme bleiben offen; der geprüfte Vault-Key ist ausdrücklich ein anderer als der bereitgestellte Key.

### R3-05 · P2 · Unbegrenzte Body-Lesephasen belasteten Verfügbarkeit

- **Grenze:** [Coach.readBodyLimited](supabase/functions/coach-chat/handler.ts#L2154) und [readProviderBody](supabase/functions/_shared/provider_body.ts#L2); Analyse verwendet den Providerreader ebenfalls.
- **Voraussetzung/Schaden:** Ein authentifizierter langsamer Upload hielt den Coach ohne eigene Lesefrist offen; ungewöhnlich große Provider-/Gatewayantworten konnten trotz Fetch-Deadline vollständig gepuffert werden. Keine Produktionslast und kein nutzersteuerbarer riesiger Providerbody nachgewiesen.
- **Rot:** Sieben Uploadfälle liefen beim alten Reader weiter bis zur Quota oder ließen Streamfehler entweichen; ein synthetischer HTTP400-Body wurde mit 1.310.720 Bytes vollständig konsumiert.
- **Fix, CODE/LOKAL:** Upload maximal 30 s insgesamt/10 s ohne echte Bytes, zusätzlich Request-Abbruch; 6.250.000-Bytegrenze bleibt. Providertext/-fehler maximal 512 KiB, erfolgreiches Rezeptbild 8 MiB; vorhandenes Abortsignal gilt bis Bodyende. Cancel-Cleanup wird nicht endlos abgewartet.
- **Grün:** [Upload-Negativ- und Positivmatrix](supabase/functions/coach-chat/handler_test.ts#L2805), [Providerreader](supabase/functions/_shared/provider_body_test.ts), [bezahlter übergroßer Fehler](supabase/functions/coach-chat/handler_test.ts#L2766) prüfen Abbruch, Stall, UTF-8, hängendes Cancel und unveränderte Behandlung bezahlter 4xx.
- **Auswirkung:** Langsame Uploads erhalten 408, abgebrochene 499, unerreichbare Bodies 400; Rate-Versuch zählt, Session/Frage/Providerarbeit beginnen noch nicht. Keine rohen Fehlertexte werden durch diese Reader ausgegeben.
- **Integrationskorrektur:** Der vollständige Flutter-Lauf erkannte eine fehlende Zuordnung für `provider_response_too_large`. Budgetstopps werden ebenfalls als vorübergehende Servicegrenze behandelt, ohne persönliche Quoten zu sperren; Uploadfehler erhalten passende bestehende DE/EN-Texte. [Wire-Regressionen](test/services/ai_security_error_contract_test.dart) waren vorher rot; 156 betroffene Clienttests und anschließend 228 gemeinsame Client-/Schemaschutztests sind grün.
- **Rest:** Kein Gesamtprozess-RSS- oder universeller 95-s-End-to-End-Nachweis; ältere sonstige RPC-Lese-/Diagnosepfade sind damit nicht pauschal abgedeckt. Tatsächliche Plattformparallelität bleibt separat.

### R3-06 · P2 · Verifizierte JWTs waren nicht zusätzlich an den App-Kontext gebunden

- **Grenze:** [hasExpectedUserTokenContext](supabase/functions/_shared/user_token_context.ts#L5) nach erfolgreichem projektspezifischem `/auth/v1/user` in Coach, Analyse und Search-Key.
- **Voraussetzung/Schaden:** GoTrue 2.196.0 akzeptierte lokal auch mit dem gültigen Projektschlüssel signierte Tokens anderer Audience. Voraussetzung ist ein gültiges Token falschen Kontextes bzw. Signierfähigkeit; keine bloße Dekodierung, fremde Signatur oder gewöhnliche Kontoübernahme wurde festgestellt.
- **Fix, CODE/LOKAL:** Subject muss der bestätigten User-UUID entsprechen, Audience `authenticated`/entsprechendes Array enthalten, Ablauf numerisch/endliche positive Zahl. Authdienst bleibt für Signatur, tatsächlichen Ablauf und `nbf` zuständig.
- **Rot/Grün:** [30 Handlerfälle](supabase/functions/_shared/user_token_context_test.ts): ohne Kontextbindung 21 Fehler, mit Fix 30/30. [Echter lokaler Authprobe](scripts/security/local_edge_auth_probe.py) nutzt isoliertes GoTrue 2.196.0/Postgres 17.6: falsche Audience vorher Auth200→Coach200, danach Auth200→Handler401.
- **Positiv/Auswirkung:** Gültige A/B weiterhin erlaubt; falsche Signatur, abgelaufene/future-nbf/alg:none-/opake Tokens ohne geschützte Daten-/AI-Arbeit abgewiesen. Keine zusätzliche Auth-Rolle wird aus Claims vertraut.
- **Rest:** Keine erfundene harte Issuer-Allowlist: historisch gültige Hosted-Issuer sind noch nicht belegt. Ein anderer Issuer mit gültigem Projektschlüssel blieb lokal zulässig; Schlüsselkompromittierung verlangt Rotation.

### R3-07 · P2 · Unbekannte Requestfelder wurden stillschweigend ignoriert

- **Einordnung:** Zusätzliche Eingabehärtung, **kein nachgewiesener Mass-Assignment-/Premium-/Admin-Bypass**. [Coach-Feldprüfung](supabase/functions/coach-chat/handler.ts#L2394), [Analyse-Feldprüfung](supabase/functions/analyze-meal/handler.ts#L874).
- **Voraussetzung/Schaden:** Manipulierte/fehlerhafte Clients konnten fremde Top-Level-Felder mitsenden und dennoch Folgearbeit auslösen; der Vertrag unterschied solche Requests nicht ausdrücklich von gültigen.
- **Fix, CODE/LOKAL:** Nichtobjekte und unbekannte Felder mit neutralem `400 invalid_body` vor Session, Tagesquota und Provideroperation abweisen; bestehende Auth-/Versuchsgates bleiben davor. Aktuelle Flutter-Wires nutzen nur erlaubte Felder.
- **Rot/Grün:** [24 Fremdfeldfälle](supabase/functions/_shared/request_fields_test.ts), einschließlich `__proto__`, waren vorher rot und sind danach grün; geprüft werden auch null Session-/Quota-/Providerwirkungen, nicht nur Status.
- **Auswirkung/Rest:** Aktuelle Defaults für Sprache/Portion bleiben erhalten; falsch konfigurierte Drittclients müssen ihr Protokoll korrigieren. Feld-Allowlist ersetzt weder Eigentümerprüfung noch verschachtelte fachliche Validierung.

### R3-08 · P2 · Bildheader, Raster und komprimierte Daten wurden zu spät begrenzt

- **Grenze:** [Edge-imageMimeFromBytes](supabase/functions/analyze-meal/image_type.ts#L4), [inspectPhotoContainer](lib/src/services/photo_container.dart#L32), [bounded_zlib](lib/src/services/bounded_zlib.dart#L9), [compressMealPhoto](lib/src/services/meal_photo_compressor.dart#L24).
- **Voraussetzung/Schaden:** Manipulierte Header/Kompressionsströme konnten unnötige Decoderallokationen oder beschädigte Ausgaben erzeugen. Bei image 4.8.0 allokiert bereits JPEG-`readInfo` Koeffizienten; eine kleine PNG mit überlangem IDAT wurde vorher akzeptiert.
- **Fix, CODE/LOKAL:** Eigener begrenzter Headerparser vor dem Decoder; höchstens 64 MiB RGBA-Raster (16-bit-PNG doppelt gezählt), kanonisches Base64/Container/MIME auf Edge vor Session/Quota. PNG-/ICC-Inflation mit 32-KiB-Fenster, exakter Ausgabelänge und Zlib-/Adler-Prüfung; fertigen JPEG-Container erneut validieren.
- **Rot/Grün:** [Metadata-/Decoder-Grenztests](test/services/meal_photo_metadata_boundary_test.dart#L39) erkennen zuvor akzeptierten PNG-Overrun und beschädigtes 66-KiB-ICC-JPEG; [Container](test/services/photo_container_test.dart)/[Zlib](test/services/bounded_zlib_test.dart) und Edge-Typfälle ergänzen Negativtests.
- **Positive Kontrollen/Auswirkung:** Übliche 12-MP-JPEGs, progressive JPEGs, 8×8-Adam7, Graustufen/16-bit-PNG und lossy/lossless/Alpha-WebP geprüft. Übergrenzen, Animationen und ungeeignete Container werden kontrolliert abgewiesen; HEIC muss über die bestehende Galerieumwandlung normalisiert werden.
- **Commander-Folgeprüfung:** Das ursprüngliche Rasterprodukt konnte bei extremen PNG-Headerwerten über Dart-VM-`int64` laufen: `4294967295 × 2147483649` wird negativ. `_checkRaster` vergleicht deshalb nach positiven Dimensionen durch Division. Zwei nur 58 Byte große 8-/16-bit-Header belegen vorher/nachher die Ablehnung bereits vor der Zlib-Prüfung; für diese Fälle wurden weder Pixel dekodiert noch Daten aufgebläht. [Header-Regressionen](test/services/photo_container_test.dart) prüfen auch die exakte 16-bit-Grenze. Kein produktiver Ressourcenangriff wurde ausgeführt.
- **Rest:** 64 MiB sind keine Gesamt-RSS-Garantie. Edge dekomprimiert keine Pixel; plausible Header können erst beim Provider scheitern. Seltene Codeceigenheiten und großes ICC bleiben Kompatibilitätsgrenzen, keine behauptete vollständige Decoderabsicherung.

### R3-09 · P2 · Die Größenoptimierung konnte private Bildmetadaten weiterreichen

- **Grenze:** [compressMealPhoto](lib/src/services/meal_photo_compressor.dart#L53) und [PhotoContainer-Metadatenprüfung](lib/src/services/photo_container.dart#L32); Kamera/Galerie→Upload und lokale Rezeptbilder.
- **Voraussetzung/Schaden:** `decoded.exif.isEmpty` erfasste PNG-tEXt/iTXt/eXIf und JPEG-XMP nicht. War das Original kleiner als das neue JPEG, wurden Originalbytes samt möglicher Orts-/Geräte-/XMP-Daten weitergegeben.
- **Rot:** Vier kleine synthetische Bilder mit `SYNTHETIC_PRIVATE_LOCATION` behielten den Marker; keine echten Standortdaten verwendet. [Versionierte Regressionen](test/services/meal_photo_metadata_boundary_test.dart#L126).
- **Fix, CODE/LOKAL:** PNG/WebP normalisieren; JPEG-Original nur nach vollständigem unbedenklichem Marker-Walk behalten. EXIF/XMP vor dem fremden Parser entfernen, begrenzt nur IFD0-Orientierung lesen und ins Bild einbacken; keine GPS-/Sub-IFD-Verfolgung.
- **Grün/Auswirkung:** Marker werden in allen vier Fällen entfernt, Orientierung und normale ICC-Farbprofile bleiben erhalten. Kleine Metadatenbilder dürfen dadurch etwas größer werden. Keine zyklischen EXIF-Payloads zur Gefährdung des Decoders ausgeführt.
- **Rest:** Provider-generierte Rezeptbilder werden serverseitig strukturell geprüft, im Dart-Vorschlagspfad aber nicht nochmals mit dieser Kompressorstrecke normalisiert. Kein vollständiger Metadaten-/Datenschutzbeweis für alle Drittanbieterpfade.

### R3-10 · P1 · Medizinische Ablehnung verwies bei Symptomen auf das falsche Thema

- **Grenze:** [REFUSAL_TEXTS.medical_risk/refusalForReason](supabase/functions/coach-chat/handler.ts#L1501); JSON/SSE sowie Bild-, Rezept- und Planmodus nutzen denselben Katalog.
- **Voraussetzung/Schaden:** Echte synthetische Brustschmerz-/Schwindel- und Verletzungsanfragen wurden korrekt als riskant klassifiziert, erhielten aber nur einen Steroid-/SARMs-Text mit Einladung zu natürlichem Training. Unpassende Orientierung kann notwendige fachliche Abklärung erschweren; keine Diagnose oder tatsächlicher Schaden beobachtet.
- **Fix, CODE/LOKAL:** DE/EN-Katalogtext deckt Symptome, Verletzungen, Medikamente und Doping ab; keine Diagnose/Behandlung/Weitertrainieren, stattdessen professionelle Abklärung und bedingter Notfallhinweis. Grundlage: [gesund.bund.de: Notfallnummern](https://gesund.bund.de/notfallnummern), geprüft 15.09.2026; keine erfundenen Schwellen.
- **Rot/Grün:** [Medical-refusal-Matrix](supabase/functions/coach-chat/handler_test.ts#L393) war für beide Sprachen rot, danach über vier Modi grün: passender Text, kein zusätzlicher Antwort-/Entwurfsaufruf, kein Refund, gleiche sichere Persistenz.
- **Auswirkung:** Zwei feste Texte geändert, kein zusätzlicher LLM-Aufruf; zulässige Coach-Antworten und explizit zu bestätigende Vorschläge bleiben möglich.
- **Rest:** Weder fachlich validierte Triage noch klinische/ernährungsmedizinische Zertifizierung. Die reale Modellevaluation unten hatte wichtige qualitative Grenzen trotz erfüllter technischer Erwartungen.

### R3-11 · P2 · Coach-CORS verlor die erlaubte Origin nach dem Preflight

- **Grenze:** [äußerer handleRequest-Wrapper](supabase/functions/coach-chat/handler.ts#L2248); vorher OPTIONS mit Request, tatsächliche JSON-/SSE-Antwort ohne dessen Origin.
- **Voraussetzung/Schaden:** Ein erlaubter Browserclient bestand den Preflight, konnte die eigentliche Antwort jedoch nicht lesen. Verfügbarkeits-/Protokollfehler, kein Authentifizierungs- oder Fremddatenbypass.
- **Fix, CODE/LOKAL:** Zustandsloser äußerer Response-Wrapper setzt erlaubte Origin/Vary je Request und erhält Status, Header und Body; keine globale Originvariable und kein neues SSE-Puffern.
- **Rot/Grün:** [Coach-CORS-Tests](supabase/functions/coach-chat/handler_cors_test.ts) waren vorher rot; [48 Antworten über drei Endpoints](supabase/functions/_shared/cors_origin_contract_test.ts) prüfen erlaubte/verbotene/null/fehlende Origins, Preflight/echte Antwort, 401, no-store und keine Cookie-Credentials. Gleichzeitige Origins vermischen sich nicht.
- **Auswirkung/Rest:** Autorisierte Browser-Origin erhält den vorgesehenen Zugriff auf ihre Antwort; Auth-/SSE-Abbruchvertrag bleibt erhalten. Kein bereitgestellter Flutter-Web-Build oder vollständiger Browser-End-to-End-Test behauptet.

### R3-12 · P2 · Funktionsdefaults und PG17-MAINTAIN waren zu weit

- **Grenze:** [20260915090000_database_privilege_boundaries.sql](supabase/migrations/20260915090000_database_privilege_boundaries.sql#L1); betrifft Migrationsowner `postgres` und Clientrollen auf `public`-Tabellen.
- **Voraussetzung/Schaden:** Schema-lokales REVOKE entfernte das globale PUBLIC-EXECUTE-Default nicht; eine künftig vergessene Funktionsfreigabe könnte aufrufbar werden. Bereits vorhandene 33 Funktionen waren ausdrücklich beschränkt. Neun Live-Tabellen hatten zusätzlich PG17-MAINTAIN; Nutzung erforderte einen weiteren SQL-Ausführungspfad, der in der App nicht gefunden wurde.
- **Fix, CODE/LOKAL:** Globales EXECUTE-Default für den ausführenden Migrationsowner entziehen; ausschließlich MAINTAIN für public/anon/authenticated auf PG≥17 entfernen. Bestehende CRUD-/explizite Funktionsgrants bleiben erhalten; PG16-kompatible bedingte Ausführung.
- **Rot/Grün:** [Restricted-role-Regression](test/migrations/database_privilege_boundaries.sql) erstellt eine harmlose neue Funktion: anon-Aufruf vorher möglich, danach verweigert; explizite authenticated-Freigabe weiterhin möglich. Synthetisches historisches MAINTAIN-Grant wird erkannt und entfernt; gesamte Rollen-Suite auf PostgreSQL 17.6 und 16.15 grün, Migration zweimal ausgeführt.
- **Auswirkung:** Neue postgres-erstellte Funktionen verlangen explizite Freigaben; Client benötigt keine Wartungsrechte. Kein nachgewiesener PostgREST-Wartungs-/Datenangriff oder aktueller SECURITY-DEFINER-Bypass.
- **Integrationsprüfung:** Der bestehende Dart-Migrationswächter schlug bei den neuen Tabellen/RPCs und globalen Defaults zunächst fehl. Er modelliert jetzt PG17-MAINTAIN sowie additive globale/schemaweite EXECUTE-Defaults; nur der exakte geprüfte bedingte DO-Rumpf wird erkannt, keine Dateiausnahme. [Elf Parserfälle](test/migrations/migration_schema_test.dart) und gezielt veränderte Defaults/Grants prüfen diese Erweiterung; 72 Migrationstests grün. `SCHEMA_STATE.md` wurde über den Generator erneuert.
- **Rest:** Defaults anderer Owner, darunter `supabase_admin`, nicht global umgebaut. DDL-/ACL-Liveabgleich nach Root-Rollout abgeschlossen; Repository-Migration allein wäre dafür kein Beleg.

### R3-13 · P1 · Gradle 8.14 konnte bei Verbindungsfehlern fremde Repository-Fallbacks wählen

- **Grenze:** [Gradle-Wrapper](android/gradle/wrapper/gradle-wrapper.properties#L5), mehrere konfigurierte Maven-Repositories; [GHSA-mqwm-5m85-gmcv](https://github.com/gradle/gradle/security/advisories/GHSA-mqwm-5m85-gmcv) und [GHSA-w78c-w6vf-rw82](https://github.com/gradle/gradle/security/advisories/GHSA-w78c-w6vf-rw82).
- **Voraussetzung/Schaden:** Bei Verbindungs-/Hostfehler der bevorzugten Quelle konnte ein weiteres Repository ein unerwartetes Artefakt gleicher Koordinaten liefern. Eine ausgetauschte reale App-Abhängigkeit wurde nicht beobachtet.
- **Fix, CODE/LOKAL:** Wrapper auf Hersteller-Patch 8.14.4 samt offizieller SHA256; kein AGP-/Kotlin-Betawechsel, keine Pub-Lock-/Cache-Manipulation.
- **Rot/Grün:** [Lokaler Resolver-Test](test/tooling/android_dependencies_test.py#L96): erstes synthetisches Maven-Repository unterbricht HTTP, zweites bietet harmloses leeres JAR; 8.14 fiel fälschlich zurück, 8.14.4 sperrt. Legitime 404-Fallbacks, Auflösung, Transitive und Desugaring bleiben positiv; fünf Tests grün.
- **Auswirkung/Rest:** Echte App-Abhängigkeitsauflösung mit AGP 8.11.1/Kotlin 2.2.20/Java 21 geprüft; Release-/R8-/AOT-Build in geschützter CI bestanden; signierter Store-/Installationsnachweis bleibt separat. OSV kannte diese Gradle-Advisories nicht: null Scannertreffer waren kein Entwarnungsbeweis.

### R3-14 · P2 · Automatisierte Abhängigkeitsprüfung ließ native Graphen aus

- **Grenze:** [Android-Auflösungsinventar](android/dependency_inventory.gradle), [Swift-/Wrapper-Inventar](tool/security_inventory.py), [Buildtool-Inventar](android/build_tool_inventory.init.gradle), [.github/workflows/security.yml](.github/workflows/security.yml).
- **Voraussetzung/Schaden:** Der Pub-Scan enthielt keine Android-Transitiven; OSV 2.3.8 erkennt die vorhandenen Swift-`Package.resolved` nicht selbst als unterstützte Locks. Dadurch konnten bekannte native Probleme unbemerkt bleiben; kein zusätzlicher Runtime-Exploit behauptet.
- **Fix, CODE/LOKAL:** Tatsächlich ausgewählte Release-/Desugaring-Komponenten als CycloneDX, neun Revisionen aus beiden Swift-Lockfiles im offiziellen Custom-Format, Gradle-Version sowie separates Settings-/R8-Buildtool-Inventar. Leere/fehlende/inkonsistente Graphen und unbekannte/private Origins scheitern vor Export.
- **Rot/Grün:** [Inventartests](test/tooling/security_inventory_test.py), [Resolver-/Graphfälle](test/tooling/android_dependencies_test.py), [Scanner-Ergebnisprüfung](test/tooling/build_tool_report_test.py); absichtlich verwundbare öffentliche Gson-2.8.8-Fixture ergibt Advisory/Exit1. Synthetische Root-only-Graph-Fixture fand zunächst die falsche Leergraphbehandlung, nach Ausschluss grün.
- **Auswirkung:** Bestehende erforderliche CI-Checknamen bleiben; native Runtime-Funde sperren. Buildtools haben einen getrennten unverfälschten Bericht mit sichtbarer Warnung; Fehler/fehlende Ergebnisse sperren weiterhin, keine stillen OSV-Ignores.
- **CI-Folgefix:** Der erste PR-Lauf brach mit Exit 127 ab: OSV 2.3.8 ignorierte bei rekursiver Suche das ausdrücklich angegebene relative Custom-Inventar unter `build/`. Die SHA-256-geprüfte CLI erhält jetzt `--no-ignore` zur Dateierfassung; Advisory-Ausnahmen werden dadurch nicht gesetzt. Ein [echter temporärer Git-Checkout](test/tooling/osv_cli_test.py) prüft beide Inventarformate, sauberes SARIF, bekannte Gson-Schwachstellen (Exit 1), leere Scans (128) und fehlerhafte Eingaben (127). Entfernen des Flags macht den positiven Test wieder rot. Die frühere Action behandelte 128 als Erfolg; die direkte CLI lässt jeden Nichtnull-Exit scheitern. Vier Linux-Regressionsfälle grün; erforderliche Checknamen unverändert.
- **Rest:** Runtime-Inventar ohne Treffer ist nur datierter Scan. 45 verschiedene Buildtool-Advisories bleiben in [BUILD_TOOL_SECURITY.md](android/BUILD_TOOL_SECURITY.md) mit konkreter Erreichbarkeitsprüfung und Updatebedarf; keine pauschale Behauptung, alle Abhängigkeiten seien bereinigt.

### R3-15 · P2 · Direkte Datenbankverbindungen erzwangen TLS nicht

- **Grenze:** Supabase-Projekteinstellung SSL enforcement; [Betriebsverfahren](docs/OPERATIONS.md). Flutter verwendet die HTTPS-APIs, direkte Postgres-Verbindungen benötigen eine gesonderte TLS-Grenze.
- **Voraussetzung/Schaden:** Bei gültigen DB-Zugangsdaten und entsprechendem direkten Client war eine unverschlüsselte Verbindung nicht serverseitig ausgeschlossen; tatsächlicher Mitschnitt/Angriff wurde nicht getestet.
- **Fix, LIVE-Konfiguration:** Root setzte enforcement von false auf true; Management-API meldete `appliedSuccessfully=true`, anschließender Projektzustand ACTIVE_HEALTHY, 14.09.2026 22:28 UTC.
- **Vorher/Nachher-Nachweis:** Nur lesender Konfigurationsvergleich und `pg_stat_ssl`-Metadaten; danach beobachtete öffentliche Postgres-Verbindungen mit TLS, verbleibende Nicht-TLS-Verbindung lokal/loopback. Kein künstlicher Klartextlogin mit echten Credentials.
- **Auswirkung:** Direkte Clients müssen TLS verwenden; Einstellung kann kurz neu starten. Quelle/Runbook empfiehlt CA-/Hostnameprüfung. Gesonderten synthetischen Clienttest vor künftigen Änderungen planen.
- **Rest:** Momentaufnahme beweist nicht jeden seltenen Client. Keine geratenen Netzwerk-CIDRs gesetzt; separate IPv4/IPv6-Restriktion bleibt offen. Verschlüsselung ersetzt weder DB-Rechte noch MFA.

### R3-16 · P2 · Sicherheitsereignisse und vertraulicher Meldeweg waren nicht aktiviert

- **Grenze:** Supabase-Auth-Flags für PasswordChanged/EmailChanged/IdentityLinked/IdentityUnlinked sowie Github Private Vulnerability Reporting; [Meldeweg](SECURITY.md#reporting-a-vulnerability), [Incident-Verfahren](docs/OPERATIONS.md#incident-response-containment-and-rollback).
- **Voraussetzung/Schaden:** Nutzer konnten entsprechende Änderungen ohne die vorgesehenen Sicherheitsnachrichten erhalten; der dokumentierte private GitHub-Meldeweg war deaktiviert. Erschwerte Erkennung/Meldung, kein nachgewiesener Kontodiebstahl.
- **Fix, LIVE-Konfiguration:** Root aktivierte genau die vier vorhandenen Notification-Booleans und Private Vulnerability Reporting. Readbacks bestätigen die Werte; sonstige Auth-Konfiguration blieb beim vollständigen Vergleich unverändert.
- **Sicherer Nachweis:** Flags vor/nach Änderung per GET, vorhandene Templates auf fehlende Token-/ConfirmationURL-/RedirectTo-Variablen geprüft; Github-Feature per GET bestätigt, 14.09.2026 22:26 UTC. Kein echtes Kontoereignis, keine Probe-Mail und kein Vulnerability-Report ausgelöst.
- **Auswirkung:** Künftige echte Änderungen können zusätzliche Mails im vorhandenen SMTP-/Mailbudget erzeugen; keine Challenge-/Passwortpolicyänderung. Vertrauliche Meldungen sind erreichbar, ohne öffentliche Issue-Veröffentlichung zu benötigen.
- **Rest:** Versand/Zustellung und tatsächliche Reaktionszeit sind ungeprüft. Gehostetes CAPTCHA, MFA für den einzigen Supabase-Owner und verbindliche Incident-Zuständigkeiten sind dadurch nicht erledigt.

### Zusätzlich nachgewiesen oder gehärtet, ohne neuen Exploit zu behaupten

- Realtime `private_only=true` per Root-Readback gesetzt; vorher nicht ausdrücklich gepinnt. Die App nutzt weder Channels noch publizierte Tabellen, keine öffentliche Datenübertragung demonstriert. Das ist präventive Konfiguration, keine behobene belegte Fremddatenlücke.
- Android: 19 synthetische native Assertions über vier Prozessstarts, tatsächliche verschlüsselte Session-/PKCE-Persistenz, Scope-/Löschmarker, FLAG_SECURE mit schwarzem Screenshot und sichtbarer positiver Kontroll-Activity, abgewiesenes selbstsigniertes TLS. Reproduzierbare Quellgrenzen in [Session-Storage-Tests](test/services/session_storage_test.dart), [Cache-Tests](test/services/secure_cache_store_test.dart) und [Screen-Tests](test/services/secure_screen_test.dart); native Probe war ein isolierter Debug-AVD, kein ausgelieferter Release oder iPhone.
- [Backup-/Restore-Harness](test/operations/backup_restore.py) stellt synthetische Daten in zwei netzlosen PostgreSQL-17.6-Clustern wieder her; [eingeschränkte Rollenprüfung](test/operations/backup_verify.sql) und absichtliche RLS-/Zeilenmutationen erkennen Fehler. Dies ist erstmals wiederholbarer Restore-Nachweis für das Testschema, **kein Produktionsbackup**; live wurden null abrufbare Backups/PITR=false festgestellt.

### Versionierte Modellevaluation: eigenständiger Nachweis mit engen Grenzen

- [Harness/Vertrag](supabase/eval/README.md), [offline getestete Limits](supabase/eval/coach_eval_test.ts), [zwölf synthetische Fälle](supabase/eval/coach_cases.ts), [Ergebnisse und Rubrikreview](supabase/eval/results/2026-09-15.md) samt verlinkten JSON-Artefakten sind versioniert. Auth, DB, History und Persistenz blieben lokale Stubs; nur die ausdrücklich budgetierten Provideraufrufe waren echt.
- Modellantworten nannten `google/gemini-3.8-flash`; Provider Google AI Studio/Google. Geprüft: legitime DE/EN-Fragen, SSE, verschleierte Anweisungsmanipulation, medizinisches Risiko, spanische Essstörungsanfrage, Verletzungsplan, Kontext-/History-Canaries, minderjährige Person mit extremem Abnehmziel sowie gültiger Plan-/Rezeptvorschlag.
- Zwölf unterschiedliche Fälle erfüllten über die dokumentierten Läufe ihre technischen Erwartungen. Die manuelle Prüfung fand dennoch R3-10; bloßes `pass=true` genügte nicht. Ein mit künstlich reduziertem Harness-Tokenlimit abgeschnittener Plan wurde sicher abgewiesen; mit tatsächlichem Serverlimit war der positive Entwurf gültig. Entwürfe wurden nicht automatisch übernommen.
- Harte Hosts/Modelle, vorab nicht erstattbare Budgetreservierung, Byte-/Token-/Zeitgrenzen, keine Bilder/Tools/Redirects/Retries/Fallbacks; kumulativ konservativ höchstens 1,86 USD von freigegebenen 1,92 USD. Beim ersten abgebrochenen Lauf fehlt ein belastbares Callartefakt, weshalb dessen ganzes Limit als verbraucht gerechnet wurde; Provider-Usage ist keine Rechnung.
- Der benutzte Infisical-Key unterscheidet sich vom bereitgestellten Runtime-Key. Dies belegt tatsächliche Antworten für den getesteten Modell-/Providerzugang, **nicht** dessen produktive Credentials, Routing, Geldlimit oder Datennutzung; keine Schlüsselwerte/Hashes veröffentlicht.
- Qualitätsgrenzen: Cutting-Antwort mit ungefragten allgemeinen Defizitzahlen/schweren Gewichten; Snack-Antwort mit verallgemeinerter Blutzuckerwirkung. Keine fachlich validierte Ernährungsberatung, klinische Wirksamkeit, vollständige Minderjährigenpolitik oder dauerhafte Prompt-Injection-Garantie. Bild-only, alle Trainingsnotizen und längere mehrstufige Angriffe sind damit nicht real evaluiert.

### Noch getrennt zu schließen

Kombinierte CI/Release-Checks und Root-Rollout-/Source-/DDL-Readback sind dokumentiert; Fachtests hier sind keine automatische Gesamtfreigabe. Offen bleiben insbesondere Runtime-Key-Geldlimit/Alarme, Owner-MFA, produktiver Backup-/Restore-Prozess, iOS/physische Geräte-/Transfernachweise, Provideraufbewahrung/Verträge und fachlich überprüfte Gesundheitsfälle. Die App erhält daraus keine pauschale Sicherheitszusage.


## Datierte Vorgeschichte

Die folgenden Aussagen der Runden 1 und 2 beschreiben den damaligen Stand. Für aktuelle Erfüllung, Live-Nachweise und verbleibende Aufgaben gelten Runde 3 und die aktuelle Tabelle. Insbesondere sind alte Versions-, Migrations- und Testzahlen keine aktuellen Gesamtzahlen.
## Verifizierte Veröffentlichung am 14.09.2026

Nach ausdrücklicher zusätzlicher Nutzerfreigabe wurden die beiden Backend-Funktionen und die Datenschutzkorrektur veröffentlicht. Grundlage ist der nach [grüner CI](https://github.com/mxritzgit/Eatova/actions/runs/34896102345) gemergte [PR #90](https://github.com/mxritzgit/Eatova/pull/90), Main-Commit `ea03845747f66e5776c15e774ff6de7256bfae25`; sein Git-Baum entspricht dem getesteten Stand.

| Ziel | Live-Nachweis | Grenze |
| --- | --- | --- |
| `coach-chat` | Version **47**, ACTIVE, `verify_jwt=true`; erneut heruntergeladen, alle **12** importierten TypeScript-Dateien stimmen mit dem geprüften Quellbaum überein. | Quell-/Deployment-Nachweis; keine kostenpflichtige Produktionsgenerierung. |
| `analyze-meal` | Version **30**, ACTIVE, `verify_jwt=true`; alle **9** importierten TypeScript-Dateien stimmen überein. `search-key` bleibt Version **9**. | Reine Testfixtures gehören nicht zum Produktions-Importgraphen. Keine Produktionskonten oder Gesundheitsdaten verwendet. |
| Modellkonfiguration | Vorhandene Overrides für Antwort, Klassifizierung und Fotoanalyse bestätigen `google/gemini-3.8-flash`; Rezeptbilder verwenden den geprüften Default `google/gemini-3.1-flash-image`. | Keine Secret-Werte protokolliert oder Einstellungen geändert. Kein Nachweis der Anbieter-Aufbewahrung, Abrechnung oder semantischen Qualität. |
| [Datenschutzseite](https://eatova.de/datenschutz) | Am **14.09.2026, 21:34 UTC** atomar als einzelne HTML-Datei veröffentlicht. Öffentliches HTML, Serverdatei und aktualisierte lokale Datenschutzquelle stimmen überein; alle **34** übrigen Website-Dateien unverändert. | Kein kompletter Website-Build oder Upload bestehender fremder Designänderungen. |
| Öffentliches Rendering | Chromium bei **320/390/768/1440 px** mit tatsächlicher Server-CSP: keine Überbreite, JS-/Konsolenfehler oder fehlenden Ressourcen; **26** eindeutige IDs und gültige Sprungziele. Mobil/Desktop visuell geprüft. | Kein installierter App-Build und keine fachliche Rechtsprüfung. |

SHA-256 des veröffentlichten HTML: `8da5302da819a5e6f2fce4ba7f9f1bc302a1b087f05ecfc5b17cd61b122ac22f`. Vorherige Funktionsquellen und die ursprüngliche HTML-Datei sind für einen gezielten Rollback gesichert. CLI-Nachweis: Supabase **2.116.0**, Management API **v1**; [Deployment](https://supabase.com/docs/reference/cli/supabase-functions-deploy) und [Modell-Secret-Abgleich](https://supabase.com/docs/reference/api/v1-list-all-secrets), Dokumentation am 14.09.2026 geprüft.

Funktionale Backend-Nachweise bleiben die isolierten Regressionstests. Echte Provider-/Geräteprüfungen, Live-Policies/Grants, Anbieterbudgets, Alarme, Restore und rechtliche Bewertung bleiben im jeweiligen Prüfumfang offen. Die Veröffentlichung macht nicht alle 91 Prüfpunkte zu ERFÜLLT.

## Runde 2 — Korrekturen und verbleibende Freigabeschritte

Der Nutzer hat nach dem Audit ausdrücklich Korrekturen, fünf Subagents, Funktionsprüfung sowie Push und Merge nach grüner CI beauftragt. Die ursprüngliche Beschränkung auf Dokumentation gilt für die unten erhaltene **Runde 1**. Runde 2 arbeitet auf einem isolierten Topic-Branch ab Main `a3a7422`; fremde Änderungen im ursprünglichen Arbeitsordner bleiben erhalten. Datenbank, Policies, Auth- und Providerkonfiguration wurden nicht verändert; die ausdrücklich freigegebenen Function-Deployments sind oben separat nachgewiesen. Sämtliche ausgeführten Funktionstests verwenden synthetische Daten und ersetzte externe Requests.

Die folgende Tabelle bewertet die **konkreten Befunde**, nicht die vollständige Erfüllung aller 91 breiteren Prüfpunkte. Die ursprünglichen Reproduktionen und Quellzeilen in S01–S07 bleiben als datierter Vorher-Nachweis erhalten; aktuelle Implementierungen und Regressionen sind hier verlinkt.

| Befund | Stand der Korrektur | Aktuelle Durchsetzung und Nachweis | Noch erforderlich |
| --- | --- | --- | --- |
| S01 · P1 | ERFÜLLT — CODE/TEST | [`finalizeAnswer`, `handleRecipeMode`, `handlePlanMode`](supabase/functions/coach-chat/handler.ts) behandeln `content_filter` als sichere Ablehnung. Kein normaler Assistant-Eintrag, übernehmbarer Entwurf oder nachgelagerter Bildaufruf; keine Erstattung für Sicherheitsablehnungen. Fehlende/unerwartete Abschlussgründe werden abgewiesen. JSON/SSE-/Rezept-/Plan-Regressionen erkennen das vorherige Verhalten. | Version 47 bereitgestellt; zusätzlich im freigegebenen Testsystem mit echtem Provider nachweisen. |
| S02 · P1 | ERFÜLLT — CODE/TEST | [`classify` und `handleRequest`](supabase/functions/coach-chat/handler.ts) stoppen Bild+Text bei unbrauchbarer Klassifikation vor der Antwortgenerierung. Auch eine benigne Kategorie benötigt ausdrücklich `finish_reason=stop`; fehlend/null wurde vorher rot und danach grün getestet. Erkannte Gefahren bleiben konservativ gesperrt. | Version 47 bereitgestellt; reale semantische Qualität einschließlich bildlicher Manipulation bleibt gesonderte Modell-/Fachprüfung. |
| S03 · P2 | ERFÜLLT — CODE/TEST | [`SecureSessionLocalStorage`](lib/src/config/supabase_config.dart), [`SessionRevocations`](lib/src/services/session_revocations.dart), [`SupabaseAuthRepository`](lib/src/auth/auth_repository.dart): tokenfreie Logout-Marker, geordnete Speicherung und Bindung an den aktuellen SDK-Token. Native Legacy-Löschbestätigung vor Markerabbau; Vorbereitung vor Datenbereinigung; Kompensation des PKCE-Fehlerpfads. 26 [Storage-/SDK-Regressionen](test/services/session_logout_restore_test.dart) sowie vier [echte App-Fehler-/Retry-Flows](test/sign_out_failure_test.dart) grün; ursprüngliche Wiederherstellung, Preferences-Cachefehler, fehlendes SDK-Ereignis und verfrühte Fotolöschung zuvor nachgewiesen. | Geräte-/Backup-Prüfung mit synthetischen Konten; bei SDK-Updates den an gotrue 2.27.2 gebundenen Kompensationspfad erneut prüfen. |
| S04 · P2 | ERFÜLLT — CODE/TEST | [`EatovaApp`](lib/src/app/eatova_app.dart) hält `SecureScreenGuard` um den Navigator aktiv. [`app_private_screen_test.dart`](test/app_private_screen_test.dart) prüft alle fünf Tabs, gepushte/nested Routen, restaurierte Sitzung, Login/Logout und A→B. Beide Regressionen schlugen vor dem Fix fehl. | Installierter Android-/iOS-Build: Android-Screenshot/Screen-Sharing und iOS-App-Switcher prüfen. iOS-Screenshots werden dadurch nicht generell verhindert. |
| S05 · P2 | ERFÜLLT — CODE/TEST | [`image_type.ts`](supabase/functions/analyze-meal/image_type.ts) prüft kanonisches Base64 und begrenzte JPEG-/PNG-/WebP-Containermerkmale vor Tages-/Globalkontingent und Provider. [`image_validation_test.ts`](supabase/functions/analyze-meal/image_validation_test.ts) prüft 19 gültige/ungültige Fälle und tatsächliche Gate-/Provideraufrufe. | Version 30 bereitgestellt. Kein vollständiger Bilddecoder und kein abschließender Schutz gegen Dimensions-/EXIF-/Decoderprobleme; D05 bleibt offen im Prüfumfang. |
| S06 · P2 | ERFÜLLT — CODE/TEST | [`sseAnswerResponse`](supabase/functions/coach-chat/handler.ts) prüft die komplette Antwort vor dem ersten Textdelta. Die 64-Zeichen-Sicherheitsschranke entfällt. [`handler_stream_test.ts`](supabase/functions/coach-chat/handler_stream_test.ts) prüft lange Leerzeichen, späte Filter, ungültige Frames, fehlenden Abschluss, Abbruch, positive Antworten und Unicode-Grenzen. | Version 47 bereitgestellt; keine Garantie, dass heuristische Promptmuster jede semantische Manipulation erkennen. |
| S07 · P1 | ERFÜLLT — CODE/TEST; Website LIVE | Beide [`ARBs`](lib/l10n/app_de.arb), [`Coach-Infosheet-Test`](test/coach_ai_disclosure_test.dart) und [`PRIVACY.md`](PRIVACY.md) nennen OpenRouter/Google/Gemini und die tatsächlich übertragenen Kontextarten. Vier DE/EN-Regressionen vorher rot, danach grün. Die [Datenschutzkorrektur und Prüfung](docs/PRIVACY-WEBSITE-CORRECTION-2026-09-14.md) sind veröffentlicht; öffentliche Bytes und Rendering nachgewiesen, Modellkonfiguration abgeglichen. | Neuen App-Build ausliefern; Backend und Website sind veröffentlicht. Rechtsgrundlagen, Verträge und tatsächliche Anbieter-Kontoeinstellungen bleiben gesondert zu prüfen. |

### Funktionale Auswirkungen und Restgrenzen

- **Coach:** Metadaten und Wartezustand bleiben möglich, die erste Textausgabe folgt jetzt erst auf die vollständige technische Prüfung. Danach bleibt das bestehende SSE-Format `meta → delta → done`; sichere Ablehnungen haben keine Textdeltas. Unterbrochene oder ungültige Rezept-/Planentwürfe sind nicht übernehmbar. Vor Freigabe wird kein generierter Assistant-Präfix gespeichert; die Nutzerfrage kann bestehen bleiben. Nach Freigabe kann bereits die vollständige geprüfte Antwort gespeichert sein, obwohl das Gerät sie nicht vollständig empfangen hat.
- **Kosten:** Client-Abbruch beim SSE-Antwortpfad eröffnet keine kostenlose Wiederholung. Erfolgreiche Textantwortkörper und SSE sind auf 512 KiB begrenzt, Rezeptbildantworten auf 8 MiB; bestehende Zeitlimits bleiben. Einige nicht erfolgreiche Providerantworten werden weiterhin zeitlich, aber nicht nach Bytes begrenzt gelesen. F02/F03/F07 sind dadurch nicht insgesamt erledigt. Der lokale Fetch-Abbruch beweist keinen Ende-der-Abrechnung-Nachweis: OpenRouter nennt Google/Google AI Studio derzeit ausdrücklich als nicht unterstützte Anbieter für diesen Kostenstopp. [OpenRouter API v1, Streaming](https://openrouter.ai/docs/api_reference/streaming), unversionierte Dokumentation geprüft am 14.09.2026.
- **Session:** Marker enthalten ausschließlich gehashte Nutzer-/Sitzungskennungen bzw. eine konservative Unbekannt-Kennung, keine Tokens. Sie verhindern App-Wiederherstellung aus verbliebenen Bytes, löschen diese Bytes aber nicht durch Magie. Falls sämtliche dauerhaften Speicher ausfallen, kann die App keinen erfolgreichen dauerhaften Logout versprechen. Unlesbare Legacy-Sitzungen können eine neue dauerhafte Anmeldung verhindern, bis die tatsächliche Bereinigung nachgewiesen ist. Manipulation des Gerätespeichers durch einen Angreifer mit umfassendem lokalem Zugriff wird damit nicht gelöst.
- **Bildanalyse:** Gültige kleine JPEG-/PNG-/WebP-Dateien bleiben möglich, erkannter MIME-Typ stammt aus den Bytes. Absichtlich beliebige Nutzdaten, ungültiges Base64, unpassende Container und Größenangaben lösen keine kostenpflichtige Analyse aus. Dies ist eine begrenzte Containerprüfung; keine Behauptung vollständiger Dekodierbarkeit oder medizinischer Zuverlässigkeit.
- **Vorschauschutz:** Android-Nutzer können die App gegebenenfalls nicht mehr per Screenshot/Screen-Sharing teilen. Die iOS-Abdeckung betrifft den vorhandenen App-Switcher-Mechanismus. Plattformkanaltests beweisen das Verdrahten, nicht die physische Betriebssystemwirkung.

Die aktuelle Abschlussstatus-Allowlist ist gegen die [OpenRouter API-v1-Referenz](https://openrouter.ai/docs/api_reference/overview) geprüft: `stop`, `length`, `content_filter`, `tool_calls`, `error`. `length` bleibt bei normalen Textantworten erkennbar unvollständig; strukturierte Vorschläge benötigen `stop`. Fehlende, unbekannte oder fehlerhafte Abschlüsse werden nicht als Freigabe interpretiert. Dokumentationsstand 14.09.2026, keine erfundene Provider-Standardeinstellung.

### Verifikation und Auslieferungsstatus der Korrekturrunde

| Prüfung | Tatsächlich ausgeführt | Ergebnis / Grenze |
| --- | --- | --- |
| Vollständiges Flutter | Flutter 3.47.2 / Dart 3.13.2; `flutter test --no-pub --coverage --reporter expanded` mit `SUPABASE_URL=https://ci.invalid` und `SUPABASE_ANON_KEY=ci-dummy-key` | **4500 Tests bestanden**, keine übersprungenen Tests; 95.07% Zeilenabdeckung (26944/28340, generierte Lokalisierung ausgeschlossen), Mindestwert 88%. Keine installierte native App. |
| Strikte Analyse | `flutter analyze --no-pub --fatal-infos --fatal-warnings` | Keine Befunde. |
| Deno vollständig | Deno 2.8.1; `deno lint supabase/functions`, alle drei `index.ts` mit `deno check`, `deno test --allow-env supabase/functions` | **541 Tests bestanden**; anschließend alle **28 Testdateien einzeln** ebenfalls bestanden. Keine Netzwerkfreigabe, Fetch durch Fixtures ersetzt. |
| Fehlernachweise | Fünf getrennte Arbeitsbäume und Gegenreviews; Tests verlangten nachweislich sichere Gegenbedingungen zum alten Verhalten | Alle sieben ursprünglichen Befunde mit gezielten Vorher-/Nachher-Nachweisen; zusätzlich Classifier-Abschluss, PKCE-Ereignis, native Preferences-Fehler und UI-Cleanup korrigiert. S07-Website anschließend ausdrücklich freigegeben und veröffentlicht. |
| Dokumente / Secrets | Alle 58 Markdown-Dateien: 325 lokale Links/Anker, Quellen/Versionen; redigierter Gitleaks-Scan 8.30.1 des getrackten Quellbaums plus neuer Dateien | Keine kaputten Links oder Secret-Treffer. Der historische B01-Scan bleibt getrennt; CI scannt zusätzlich die Git-Historie. |
| Website | Einzeldatei-Patch gegen byteidentische öffentliche Quelle; isoliertes Chromium bei 320/390/768/1440 Pixeln | Keine Überbreite, fehlenden Ressourcen oder JS-Fehler; 26 eindeutige IDs und gültige Sprungziele; anschließend dieselben Prüfungen an der veröffentlichten Seite bestanden. |

**Git-Auslieferung:** Topic-Branch `fix/security-audit-findings`; Push/geschützter PR und Merge nach grüner CI sind autorisiert. Zum Dokument-Commit sind lokale Tests und Reviews abgeschlossen; der zugehörige PR enthält den anschließend verifizierten CI-/Merge-Nachweis. Acht bindende Main-Checks und `enforce_admins=true` wurden vor Auslieferung über die GitHub-API gelesen. Keine Tests oder Schutzregeln wurden abgeschwächt.

Der SDK-Folgefix greift ausschließlich bei ausgelassenem `signedOut` und bereits leerer SDK-Sitzung ein; kein `await` zwischen Nullprüfung und Benachrichtigung. Ein nachträglicher Widerrufsversuch verwendet nur den vor dem SDK-Aufruf erfassten A-Token (lokaler Scope, maximal ein Versuch, 10 Sekunden Wartebudget). Ein zwischenzeitlich angemeldeter B wird nicht abgemeldet. Verweigert die dauerhafte Vorbereitung den Logout, läuft keine lokale Datenbereinigung; die Oberfläche zeigt einen neutralen DE/EN-Fehler und lässt einen neuen Versuch zu.

**Weiterhin nicht erfolgt:** Änderung von Policies/Grants/Authsettings, Store-Publikation oder Installation eines Gerätebuilds. Backend- und Website-Veröffentlichung sind oben ausdrücklich getrennt nachgewiesen. Ein GitHub-Merge ist kein Nachweis einer dieser Aktionen. Aktuelle Live-RLS-, Auth-, Providerbudget-, Alarm- und Restore-Nachweise bleiben entsprechend A11/C/F/I/K unvollständig.

## Runde 1 — ursprünglicher Prüfauftrag und Nachweisgrenzen

- Ausschließlich dieses Dokument wird erstellt/geändert. Keine Sicherheitskorrekturen, Datenbankänderungen, Cloudänderungen, Commits oder Veröffentlichungen gehören zu dieser Runde.
- Prüfstand: `origin/main` **a3a7422d547df0574fba1c31dc396ec5524d3cf2**. Gelesen wird der saubere Dokumentations-Worktree mit HEAD `2768c4c16e5d8eac9e3133f5e2302d495595a379`; beide haben denselben Git-Baum **5dcc8d69621c39d29ee0c5740ada5b2fca7bb63d**. Der ursprüngliche Arbeitsordner steht auf einem älteren Branch mit fremden Änderungen; diese bleiben erhalten.
- Quellenangaben `Pfad:Zeile` beziehen sich auf diesen Prüfstand. Dauerhafte Quelllinks verwenden den vollständigen Main-Commit. Frühere Reviews und Deployment-Vermerke liefern Kontext, keinen aktuellen Laufzeitnachweis.
- **CODE** = Durchsetzung im gelesenen Quellstand nachvollzogen. **TEST** = in dieser Runde tatsächlich ausgeführter, isolierter Test mit synthetischen Daten. **LIVE** = in der bereitgestellten Umgebung nachgewiesen. In dieser Runde werden keine authentifizierten Produktionsaufrufe, Provider-Generierungen oder echten Nutzerdaten verwendet. Eine öffentlich gelesene Datenschutzseite beweist keine Backendkonfiguration.
- **ERFÜLLT** gilt nur für den ausdrücklich genannten Prüfumfang. **TEILWEISE** bedeutet Teilumsetzung oder wesentliche Nachweislücke. **FEHLT** verlangt belegte Abwesenheit. **NICHT PRÜFBAR** verlangt fehlenden Zugriff/Nachweis. **OFFEN** ist noch nicht vertieft untersucht. **NICHT RELEVANT** braucht eine konkrete Begründung.
- P0 = akut/kritisch, P1 = wichtige Lücke, P2 = zusätzliche Härtung/geringeres Risiko. Bei offenen oder nicht zugänglichen Punkten bezeichnet die Priorität die Reihenfolge der Prüfung, keinen bereits bewiesenen Schweregrad.
- Fünf Subagents prüfen Datenbank; Backend; Auth/Endgerät; AI/Kosten; Datenschutz/Betrieb. Die Hauptinstanz prüft Befunde und führt dieses gemeinsame Checkbuch.

## Tatsächliche Architektur und Datenflüsse

Die mobile Flutter-App hat Today, Food, Recipes, Training und Coach. Sie verarbeitet Konto-/Profildaten, Körperwerte und Ziele, Tagebuch und Nährwerte, Rezepte, Essenspläne/Einkaufslisten, Trainingspläne/-verläufe sowie Coach-Chats und Bilder. Herkunft und Zweck dieser Daten sind getrennt zu bewerten; nicht jedes Datum ist medizinisch, zusammen können sie aber ein sensibles Gesundheitsprofil bilden.

| Grenze | Tatsächlicher Pfad | Sicherheitsrelevanz |
| --- | --- | --- |
| Gerät → Auth | Flutter → Supabase Auth; E-Mail/Passwort und Google, OAuth-Fallback | Session-/PKCE-Ablage, Redirects, Accountänderungen |
| Gerät → Datenbank | HomeStore/Services → Supabase REST/RPC → Postgres | Client ist nicht vertrauenswürdig; RLS, Grants und Funktionscode müssen Eigentümerschaft erzwingen |
| Gerät → AI | `analyze-meal`, `coach-chat` → OpenRouter → konfigurierter Modellanbieter | Auth, serverseitige Kostenprüfung, fremde Bilder/Texte, Ausgabeprüfung |
| Gerät → Produktsuche | `search-key` → begrenzte Meilisearch-Zugangsdaten; Meilisearch/Open Food Facts | Rechte des ausgegebenen Schlüssels und externe Bild-/Suchziele |
| Gerät → lokale Ablage | sichere Session-/PKCE-Adapter, verschlüsselter Cache/Outbox, lokale Rezeptbilder | Betriebssystem-Schlüsselschutz, Nutzerwechsel, Backups und Restdateien |
| Gerät → Gesundheitsdaten | iOS HealthKit: Schritte/Gewicht; Android Health Connect: Schritte | Berechtigungen, Minimierung, Weiterverwendung im Coach-Kontext |
| Gerät → Diagnose | optional Sentry; lokale Benachrichtigung | tatsächliche Filter, Inhalt und Metadaten statt bloßer Paketpräsenz |

Bestandsquellen: [README](https://github.com/mxritzgit/Eatova/blob/a3a7422d547df0574fba1c31dc396ec5524d3cf2/README.md), [Backend](https://github.com/mxritzgit/Eatova/blob/a3a7422d547df0574fba1c31dc396ec5524d3cf2/docs/BACKEND.md), `lib/src/config/supabase_config.dart`, `lib/src/app/home_store.dart`, `supabase/functions/`. Die Quellen werden in den Einzelprüfungen bis zur Durchsetzung verfolgt.

## Scanprotokoll B01

Gitleaks **8.30.1**, am 14.09.2026 ausgeführt, vollständige Redaktion, aktuelle `.gitleaks.toml`:

```text
gitleaks git <sauberer Prüf-Worktree> --log-opts=--all --config .gitleaks.toml --redact=100
543 erreichbare Commits, ca. 23,49 MB: Exit 0, keine Treffer.
gitleaks dir <sauberer Prüf-Worktree> --config .gitleaks.toml --redact=100
ca. 10,08 MB: Exit 0, keine Treffer.
```

Die Konfiguration erlaubt gezielt den öffentlichen Supabase-anon-JWT und lokale Slotnamen `eatova.v1.*`; ein öffentlicher Clientkey ist kein privilegiertes Secret. Zusätzlich wurden die vorhandene lokale Client-Defines-Datei und neun direkt im ursprünglichen `build/` liegende Reviewlogs redigiert gescannt: keine Treffer. In der ignorierten lokalen Android-Signierungskonfiguration erkennt der Scanner zwei Passwortfelder **[MASKIERT]**; Datei und Keystore sind nicht Git-getrackt. Das ist kein Nachweis eines Leaks und wird nicht als eingebetteter Client-Schlüssel gewertet. Keine Werte wurden ausgegeben oder in dieses Dokument übernommen.

Grenzen: Musterbasierter Scan ist keine vollständige Geheimniserkennung. Keine aktuellen Store-/Release-Binärdateien des geprüften Main-Stands, externen CI-/Cloudlogs, Vault-Inhalte, gelöschten Remote-Refs oder Produktions-Runtimekonfigurationen untersucht. Keine Rotation allein aus einem unbewiesenen Verdacht abgeleitet.

## Standards und Primärreferenzen

Referenzstand 14.09.2026. Allgemeine Dokumentation erklärt erwartetes Verhalten, ersetzt aber keinen App-Test.

- PostgreSQL **16**, [Row Security Policies](https://www.postgresql.org/docs/16/ddl-rowsecurity.html): RLS unter eingeschränkten Rollen testen; Eigentümer/privilegierte Rollen können anders behandelt werden.
- Supabase-Dokumentation, fortlaufend aktualisiert, [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security): Grants und Policies sind getrennte Schranken; Anonymous Sign-ins verwenden die Rolle `authenticated`.
- Supabase-Dokumentation, [API Keys](https://supabase.com/docs/guides/getting-started/api-keys): öffentliche Clientkeys von privilegierten Backendkeys unterscheiden.
- Supabase-Dokumentation, [Sessions](https://supabase.com/docs/guides/auth/sessions): Session- und JWT-Lebenszyklus sind gesondert zu prüfen.

## Fünf vertiefte Prüfungen der Runde 1

### V1 — A03: Fremde Nutzerdaten und privilegierte SQL-Pfade

**Ergebnis: ERFÜLLT für den geprüften SQL-Zustand und lokalen Testumfang. LIVE: NICHT PRÜFBAR.** Die 43 Migrationen wurden tatsächlich auf PostgreSQL 16.15 ausgeführt. Der anschließende Katalog hatte 16 Tabellen mit aktivem RLS, 34 Policies und 33 öffentliche Funktionen. Es gab keine öffentlichen Views/materialisierten Views. Eine Migration wurde nicht bloß nach ihrem Namen oder Kommentar bewertet.

Tabellen: `chat_messages`, `chat_quota_usage`, `chat_sessions`, `edge_rate_limits`, `favorite_meals`, `lifetime_stats`, `lifetime_stats_requests`, `logged_meals`, `planned_meals`, `profiles`, `shopping_checks`, `training_history`, `training_history_deletions`, `training_plans`, `user_recipes`, `weight_log`. Kein Gruppen-, Trainer-, Mandanten- oder Premiumsystem im geprüften Schema; solche Rollen wurden nicht erfunden.

Die Suite `test/migrations/rls_cross_user.sql` und ihre eingebundenen Trainings-/Rezept-/Meal-Plan-Tests prüfen Daten und Zeilenzahlen mit `SET LOCAL ROLE anon/authenticated` und `SECURITY INVOKER`-Assertions. Administratorrechte dienten dem isolierten Aufbau und der Ergebnisinspektion. Zusätzliche positive Proben prüften **beide Richtungen A und B**, inklusive eigener Mahlzeiten, Favoriten, Gewichtslogs, Rezepte, Chats und Profilgewicht. Fremdes Lesen/Ändern/Löschen lieferte keine Zeilen; fremde Inserts und Eigentümerwechsel wurden abgewiesen. Ein Favoriten-Eigentümerwechsel wurde zusätzlich mit konfliktfreiem Schlüssel geprüft, damit ein UNIQUE-Fehler nicht irrtümlich als RLS-Nachweis zählt.

Verknüpfte Daten wurden einbezogen: eigene Trainingsabschlüsse/Löschbelege, fremde Tagebuch-UUID beim Verbrauch eines geplanten Essens, Kontolöschung mit frischer Authentifizierung. A konnte B nicht überschreiben; gescheiterte Umwandlung hinterließ keinen halben Beleg; erlaubte A-Löschung ließ B bestehen. Direkte Clientänderungen an Chat, Kontingent und Lifetime-Zählern waren gesperrt. Profilspaltenrechte verhindern das Umgehen der vorgesehenen Accountänderungswege.

**Negativkontrolle:** Nur in einer wegwerfbaren lokalen DB-Transaktion wurde `logged_meals_select_own` auf `USING(true)` gesetzt. Die vorhandene Assertion schlug mit `RLS-VERLETZUNG` fehl; anschließend Rollback. Damit wurde gezeigt, dass die Kontrolle eine echte offene Policy erkennt. Keine Policy der App oder Cloud wurde geändert.

Ein synthetischer angemeldeter Gast mit `is_anonymous:true` bekam unter `authenticated` nur sein eigenes Profil. Das belegt die Trennung, aber keine gewollte Gastfreigabe: der aktuelle Code unterscheidet angemeldete Gäste nicht von regulären Nutzern. Ob Anonymous Sign-ins live aktiviert sind, bleibt offen. Die SQL-Tests simulieren Claims; JWT-Kryptografie, PostgREST, andere API-Schemas und manuell angelegte Cloudobjekte sind nicht damit bewiesen.

### V2 — B04: Authentifizierung und Objektbesitz an allen Edge Functions

**Ergebnis: CODE und lokale Handlerproben nachvollzogen, kein Autorisierungs-Bypass nachgewiesen; insgesamt TEILWEISE wegen fehlender echter Auth-/Gateway-/Liveprüfung.** Genau drei Entrypoints wurden gefunden:

| Endpoint | Durchsetzung vor geschützter Arbeit | Nachweis |
| --- | --- | --- |
| `analyze-meal` POST | Bearer erforderlich; bekannter anon-Key abgewiesen; User aus projektgebundenem `/auth/v1/user`; Gates an diese ID gebunden | `supabase/functions/analyze-meal/handler.ts:346,378,626` |
| `search-key` GET | gleiche Userprüfung; Limits vor Suchberechtigung; keine vom Client gewählte private Ressource | `supabase/functions/search-key/index.ts:161,174,304` |
| `coach-chat` POST, JSON/SSE/Rezept/Plan | Auth-Antwort und UUID prüfen; gewünschte Sitzung mit Sitzung UND User abfragen; History und Writes servergebunden; Modi erst danach | `supabase/functions/coach-chat/handler.ts:2299,2334,2063,1956,2028,2621,2633` |

Sechs zusätzliche Offlineproben gegen den echten Coach-Handler ersetzten **sämtliche** Netzaufrufe. A/eigene Sitzung war erlaubt. A/B-Sitzung wurde nach festgestellter Nichtzugehörigkeit auf A-Standardsitzung zurückgeführt: HTTP 200, aber nur A-Sitzung, A-History und A-Schreibparameter. Das ist kein Fremdzugriff. Eine fehlerhafte Ownership-Abfrage lieferte 500 ohne History-/Nachrichten-/Providerarbeit. Fehlender Bearer und vom Auth-Stub abgelehnter Token lieferten 401 ohne geschützte Nebenwirkungen. Ein vom Auth-Stub akzeptierter angemeldeter Gast wurde wie ein anderer User behandelt.

Zusätzliche Bodyfelder `user_id=B`, `role=system`, `isAdmin=true`, `model=attacker-model` änderten weder Identität noch Rollen oder Modell. Unbekannte Felder werden hier häufig ignoriert; das ist keine nachgewiesene Privilegienübernahme. Der Coach lässt nur erlaubte Historyrollen aus eigener Sitzung an den Provider. Die übrigen Endpoints wurden durch 218 bestehende Handler-/Shared-Tests abgedeckt.

Wichtige Grenze: Fake-Auth-Ablehnung beweist Handlerverhalten, nicht Signatur-, Ablauf-, Issuer- oder Audienceprüfung eines echten JWT. Fake-REST-Writes sind aufgezeichnete Parameter, keine echten Datenbankzeilen; diese zweite Grenze prüft V1 getrennt. `/auth/v1/user` ist ein dokumentierter serverseitiger Verifikationspfad, aber bereitgestellte Auth-/Signing-Versionen und zusätzliche alte Functions sind nicht eingesehen. [Supabase JWT-Dokumentation](https://supabase.com/docs/guides/auth/jwts).

### V3 — E01: Tatsächliche Tokenablage bis zum nativen Adapter

**Ergebnis: sichere Ablage ist tatsächlich verdrahtet und lokal getestet; TEILWEISE wegen Löschfehler S03 und fehlendem Gerätenachweis.**

`lib/src/config/supabase_config.dart:81` übergibt sowohl `SecureSessionLocalStorage` als auch den PKCE-Adapter an `Supabase.initialize`. PKCE-Verifier gehen ab Zeile 204 an `SecureKeyStore`. Die Sessionmigration ab Zeile 279 schreibt zunächst sicher und entfernt erst danach den alten Preferences-Eintrag; normales Lesen/Schreiben ab Zeile 311 verwendet den sicheren Adapter, keinen Klartextfallback.

`lib/src/services/secure_cache_store.dart:649` bindet das an `flutter_secure_storage` mit Android `resetOnError:false` und iOS `first_unlock_this_device`. Der installierte Code von **supabase_flutter 2.17.2** wurde geprüft: seine Preferences-Defaults gelten nur ohne diese Overrides. Im installierten **flutter_secure_storage 10.3.1** wurden die Android-Optionen und die native RSA-OAEP-/AES-GCM-Implementierung bis zum AndroidKeyStore verfolgt. **flutter_secure_storage_darwin 0.3.2** ordnet die Option tatsächlich `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` zu.

`test/wiring_supabase_session_storage_test.dart:62` startet die reale Appinitialisierung auf Testplattformen: vorhandene Session bleibt nutzbar, verschwindet aus Preferences und landet im Secure-Storage-Testadapter. Der echte SDK-Aufruf zur OAuth-URL-Erzeugung legt den PKCE-Verifier dort ab. Das ist mehr als ein isolierter Test eines unbenutzten Adapters. Insgesamt bestanden 115 passende Fluttertests zu Speicherung, Fehlern, Authwechseln, Deep Links und Bildern.

**Nicht bewiesen:** Eigenschaften eines tatsächlich installierten Android-/iOS-Releases, Hardware-Schlüsselstatus, Backup-/Restore-Inhalt, Speicherzugriff nach Geräteentsperren. Apples Option verhindert Migration auf ein anderes Gerät und erlaubt Zugriff nach erstem Entsperren; sie bedeutet nicht pauschal „in keinem Backup enthalten“. [Apple Keychain-Klasse](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly), [Plugin-Version 10.3.1](https://pub.dev/packages/flutter_secure_storage/versions/10.3.1).

### V4 — F05: Parallele Kontingentbeanspruchung und Erstattungen

**Ergebnis: ERFÜLLT für atomaren Claim-Cap und geprüfte Refundpfade; kein Nachweis einer vollständigen globalen Geldkostenkontrolle.** `supabase/migrations/20260908120000_chat_quota_refund_day.sql:28` kombiniert Anlage, `FOR UPDATE`-Zeilensperre und Increment. Claim/Refund sind nur für die vorgesehene Serverrolle ausführbar. Der Handler übergibt die verifizierte User-ID (`coach-chat/handler.ts:1736`) und beansprucht das Kontingent **vor dem ersten kostenpflichtigen Classifier** (:2522). Rezept und Plan zweigen erst danach ab.

Im isolierten PostgreSQL liefen zehn gleichzeitige Claims für denselben neuen synthetischen Nutzer bei Limit 5: **5 erlaubt, 5 abgewiesen, gespeicherter `used_count=5`**. Zehn gleichzeitige tagesbezogene Refunds endeten bei **0**, nie negativ. Clientrollen durften weder RPCs ausführen noch Quotenzeilen selbst schreiben. Die Deno-Suite deckte Erstattung, Streamabbruch und Tageswechsel ab; unbekanntes Claimdatum wird nicht geraten und nicht erstattet. In den geprüften Handlerpfaden wurde keine doppelte Erstattung nachgewiesen.

**Grenze:** Die Refund-RPC besitzt keine Reservation-ID. Die Untergrenze 0 beweist keine Idempotenz pro Request; der Handler muss die höchstens einmalige Erstattung sicherstellen. Keine allgemeine Exactly-once-Garantie behaupten.

**Offener Kostenpunkt F02/F07:** Der Coach hat standardmäßig 5 Fragen pro Konto/UTC-Tag, Nutzer60/h und IP120/10min; im Rezeptpfad können Classifier, Rezepttext und ein Bildauftrag entstehen. Fehlererstattungen machen das Fragenlimit nicht zu einem festen Geldbudget. Für wiederholte erstattete Fehler bleibt insbesondere das Stundenlimit. Eine gezielte Auslösung solcher Fehler als Kostenexploit wurde nicht nachgewiesen. Anders als die Fotoanalyse mit eigenem globalem Tagesgate besitzt der Coach keine eigene globale Reservierung. Ob ein wirksames externes OpenRouter-Geldlimit, Autoaufladungsgrenzen und Alarme das abfangen, ist **NICHT PRÜFBAR**. Das wird nicht als „unbegrenzte Kosten bewiesen“ berichtet. `COACH_DAILY_LIMIT=0` ist kein Abschalter: der positive Integerparser fällt auf den Default zurück. M4 beschreibt den erforderlichen Nachweis.

### V5 — G11: Schon ausgegebene Streamteile und finale Sicherheitsentscheidung

**Ergebnis: TEILWEISE; S01 und S06 lokal reproduziert.** Der Handler hält am Anfang den Refusalmarker zurück und prüft fortlaufend Promptmuster. Ein 64-Zeichen-Tail soll noch nicht erkennbare Muster abdecken (`coach-chat/handler.ts:760,942,964`). Bestehende Tests für geteilte Marker, Abbrüche, Providerfehler, Refunds und legitime lange Antworten bestanden.

Die zusätzlichen Gegenproben zeigen die Grenzen: `finish_reason:content_filter` des **Antwortmodells** wird nicht als Ablehnung behandelt; alle synthetischen SSE-Textbytes wurden ausgeliefert und als akzeptiert zum Speichern übergeben. Derselbe Fehler wurde für JSON, Rezept und Trainingsplan nachgewiesen. Beim Rezept wurde sogar ein nachfolgender Bildauftrag im Stub beobachtet. Außerdem konnten bei einem bekannten, durch lange Leerzeichen auseinandergezogenen Promptmuster **562 Präfixzeichen** vor dem späteren `refusal:true` als Deltas herausgehen. Nicht nur Endstatus/Flutteransicht, sondern die tatsächlichen Response-Bytes wurden geprüft.

Diese Tests simulieren Providerantworten. Sie beweisen die fehlerhafte Durchsetzung auf diesem Input, nicht, dass der aktuell bereitgestellte Gemini tatsächlich gefährlichen Inhalt oder geheime Daten erzeugt hat. Der betroffene Prompt ist öffentlich im Repository und enthält nach Sichtung keine Zugangsdaten. Es wurde keine zusätzliche Daten-/Toolberechtigung durch AI-Manipulation nachgewiesen.

## Ursprüngliche Befunde und Korrekturvorschläge der Runde 1

Keine der folgenden Korrekturen wurde umgesetzt. **Kein P0 wurde im untersuchten Umfang nachgewiesen.** Ein unbekannter Livezustand ist keine Entwarnung.

### S01 — Sicherheitsabschluss des Antwortproviders wird ignoriert — P1

- **Betroffen:** `supabase/functions/coach-chat/handler.ts:647`, `finalizeAnswer`; Streamparser :860; Rezept :1386; `draftTrainingPlan` :1483. Der Classifier behandelt `content_filter` an :385 korrekt; das darf nicht mit den Antwortmodi verwechselt werden.
- **Beweis:** fünf zusätzliche Offline-Auditproben, darunter vier Modi mit harmloser Providerantwort bzw. gültigem Rezept-/Plan-Fixture und `finish_reason:"content_filter"`. JSON/SSE geben Text als `refusal:false` aus und reichen ihn so zur Chatpersistenz; Rezept/Plan bleiben übernehmbar, Rezept löst zusätzlich einen Bild-Stub aus.
- **Schaden/Voraussetzung:** Falls ein Provider trotz sicherheitsbedingtem Abschluss Inhalt liefert, kann dieser als normaler Coachrat oder Vorschlag erscheinen und als akzeptierter Chatkontext weitergenutzt werden. Tatsächlich schädliche Antworten und deren gezielte Auslösbarkeit sind nicht live bewiesen. Keine Auth-/Datenrechtsumgehung nachgewiesen.
- **Kleinster sinnvoller Fix:** Abschlussstatus in allen Antwortmodi zentral prüfen; `content_filter` als sichere Ablehnung ohne übernehmbaren Vorschlag, Bildfolgeauftrag oder nutzbaren Assistant-Verlauf behandeln. Eine bezahlte Sicherheitsablehnung nicht automatisch erstatten. Für die Zusage, dass solche Inhalte nie gesendet werden, bis zur Freigabe puffern oder ein ausdrücklich geeignetes serverseitiges Freigabeverfahren vor Veröffentlichung verwenden. Nur das finale `done` oder die Flutterbubble zu ersetzen holt Bytes nicht zurück.
- **Einfluss:** verständliche Ablehnung statt Teilantwort; vollständige Pufferung erhöht wahrgenommene Latenz. Bestehende `stop`-/`length`-/Quota-Verträge erhalten.
- **Regression:** JSON, SSE, Rezept, Plan jeweils mit leerem und nichtleerem `content_filter`; normale Antwort als Gegenprobe. Bytes, akzeptierte DB-Schreibparameter, Vorschläge, Bildaufrufe und Kontingent prüfen, nicht nur HTTP 200.

Minimaler harmloser Providerstub für die Reproduktion mit den vorhandenen Fake-Fetch-Helfern aus `handler_stream_test.ts`:

```json
{"choices":[{"message":{"content":"Synthetic provider-filtered answer for audit only."},"finish_reason":"content_filter"}]}
```

Classifierstub vorher gültig `nutrition/high`, Auth/Quota/History ebenfalls synthetisch. Beobachtet: Sentinel im Reply und akzeptierten Assistant-Write. Für SSE erst Sentinel als `delta.content`, dann Abschlussframe `content_filter`, anschließend `[DONE]`; die Bytes verlassen den Handler trotzdem. [OpenRouter API v1, normalisierte Abschlusswerte](https://openrouter.ai/docs/api_reference/overview), [Streaming](https://openrouter.ai/docs/api_reference/streaming).

### S02 — Ungültiger Classifier läuft bei Bild plus Text weiter — P1

- **Betroffen:** `supabase/functions/coach-chat/guardrails.ts:48,106`, `handler.ts:2563,2591`. Der Bildpfad ist von der Behandlung unbrauchbarer Klassifikation ausgenommen; nur strukturierte/Trainingspfade erzwingen dort die Ablehnung.
- **Beweis/Reproduktion:** der frisch ausgeführte vorhandene Test `supabase/functions/coach-chat/handler_test.ts:833` liefert die synthetische ungültige Klassifikation `Ich denke, das ist Fitness.` zusammen mit einem Testbild. Er verlangt ausdrücklich einen Answer-Aufruf und `refusal:false`. Das ist ein bestehender grüner Test für problematisches Verhalten, kein Sicherheitsbeweis.
- **Schaden/Voraussetzung:** Wenn der Classifier unbrauchbaren Output liefert, wird seine unabhängige inhaltliche Prüfung für die Bildfrage nicht durchgesetzt. Es bleiben andere vorhandene Kontrollen, insbesondere Prefilter und Antwortprompt; ein gleichwertiger wirksamer Krisencheck ist auf diesem Ausfallpfad nicht nachgewiesen. Keine echte gefährliche Beratung oder Autorisierungsumgehung im Test behauptet.
- **Kleinster sinnvoller Fix:** bei vorhandenem Text und unbrauchbarer Klassifikation geschlossen abbrechen; Bildprüfung/Fallback gesondert definieren. Bild **ohne Text** separat behandeln: reines Textklassifizieren wäre dort sinnlos; der heutige Sprung über den Classifier beweist keine sichere Bildmoderation.
- **Einfluss:** legitime Bildfragen können bei Classifierstörung eine wiederholbare Fehlermeldung bekommen.
- **Regression:** malformed/empty/invalid-category für Bild+Text: kein Answer-Aufruf, keine akzeptierte Assistantnachricht; gültige harmlose Bildfrage weiterhin erlaubt. Mehrsprachige und bildliche Semantik später fachlich/mit begrenzter Modell-Eval prüfen.

### S03 — Keystore-Löschfehler lässt Sessiondaten zurück — P2

- **Betroffen:** `lib/src/config/supabase_config.dart:343`, `SecureSessionLocalStorage.removePersistedSession`. Fehler von Secure-Delete und Legacy-Purge werden gemeldet, aber geschluckt. Eine dauerhaft vermerkte Logoutabsicht gegen späteres Wiederlesen fehlt.
- **Beweis/Reproduktion:** `test/services/session_storage_keystore_report_test.dart:192` simuliert einen fehlgeschlagenen Secure-Delete und bestätigt ausdrücklich die verbliebenen Sessionbytes; in T3 frisch bestanden. Nachfolgendes Lesen verwendet weiterhin den vorhandenen Storewert. Ein kompletter Neustart/Online-Widerruf auf echtem Gerät wurde nicht ausgeführt.
- **Schaden/Voraussetzung:** bei Speicherfehler plus Gerätezugriff können lokale Sitzungstoken nach vermeintlicher Abmeldung verbleiben. Wiederherstellung einer noch verwendbaren Session ist ein zu prüfendes Folgerisiko. Kein Nachweis, dass normaler Online-Logout den serverseitigen Refresh-Widerruf umgeht. Das Dart-SDK `gotrue 2.27.2` leert In-Memory-Zustand und sendet Logout vor der Serveranfrage; bestehende JWT-Gültigkeit und zusätzlicher Netzausfall sind gesondert zu betrachten.
- **Kleinster sinnvoller Fix:** tokenfreie Logoutabsicht dauerhaft separat markieren und bei Wiederherstellung beachten, bis Löschung verifiziert oder ausdrücklich neu angemeldet wurde; Fehler erkennbar behandeln. Bloßes Werfen eines Fehlers genügt wegen asynchroner SDK-Storageevents nicht als vollständiger Fix.
- **Einfluss:** nach Speicherfehler ggf. erneute Anmeldung; Offline-/Recoveryverhalten und fremde Outboxdaten nicht beschädigen.
- **Regression:** A speichern, Delete fehlschlagen lassen, neue Adapter-/SDK-Instanz mit wieder funktionierendem Lesen starten: A darf nicht automatisch wiederhergestellt werden. Erfolgreicher Logout und explizite neue Anmeldung B als Gegenproben.

### S04 — Haupttabs nicht vom vorhandenen Vorschauschutz erfasst — P2

- **Betroffen:** `lib/src/app/eatova_app.dart:171` (`AuthGate → EatovaHomePage`), `lib/src/services/secure_screen.dart:39`, `ios/Runner/AppDelegate.swift:83`, Android `MainActivity.kt:25`. Guards bestehen auf Auth-, Profil-, Ziel- und Settingsseiten, nicht um den angemeldeten Navigator bzw. Today/Food/Coach/Trainingshistorie.
- **Beweis:** Quellfluss bis zum nativen Flag/Zähler verfolgt. Schutz wird nur bei aktivem Guard eingeschaltet. **Kein Screenshot oder tatsächlicher App-Switcher-Zustand auf Gerät beobachtet.**
- **Schaden/Voraussetzung:** private Chat-/Gesundheitsinhalte können in der Taskvorschau erscheinen; Android-Screenshot-/Capture-Schutz ist im Hauptbereich nicht aktiviert. Voraussetzung ist Sicht auf Gerät/Vorschau oder entsprechende Bildschirmaufnahme, kein entfernter Fremdkontozugriff.
- **Sichere Reproduktion:** ausschließlich synthetischen Coachtext auf Testgerät anzeigen, App verlassen und Vorschau prüfen; geschützte Profilseite als Gegenprobe.
- **Kleinster sinnvoller Fix:** Schutz um den authentifizierten Navigator/all seine sensiblen Routen mit korrekter Lebensdauer legen.
- **Einfluss:** Android-Screenshots/Screen-Sharing dort eingeschränkt; diese Produktwirkung bewusst entscheiden.
- **Regression:** nativen Methodenkanal faken, Tabs und zusätzliche sensible Routen wechseln, Aktivierung dauerhaft nachweisen; danach synthetischer Android-/iOS-Gerätetest.

### S05 — Fotoanalyse akzeptiert Nicht-Bildbytes bis zum Provider — P2

- **Betroffen:** `supabase/functions/analyze-meal/handler.ts:889`, `parseImageBase64`; Kostenreihenfolge :393–422. Geprüft werden Alphabet/geschätzte Größe, nicht tatsächlicher Bildcontainer. MIME wird aus Data-URL übernommen bzw. JPEG angenommen.
- **Beweis/Reproduktion:** authentifizierter synthetischer User, `imageBase64=btoa('NOT_AN_IMAGE_'.repeat(20))` (240 Textbytes), erlaubende Limiterstubs, Providerstub 400. Beobachtet: vier Gates einschließlich User-Tag und Global verbraucht, ein Provider-Aufruf, abschließend 502 `provider_error`.
- **Schaden/Voraussetzung:** offensichtlich ungeeignete Eingaben beanspruchen Kontingente und externe Verarbeitung. Tatsächliche Providerabrechnung wurde nicht geprüft. Vorhandene Limits begrenzen den einzelnen Nutzer; kein Beweis für unbegrenzte Kosten, Decoder-RCE oder Fremdzugriff.
- **Kleinster sinnvoller Fix:** vor Tages-/Globalkontingent JPEG/PNG/WebP-Container mindestens per Magic Bytes prüfen, MIME daraus ableiten, unbekannte Formate abweisen. Der Coach besitzt diesen ersten Check bereits (`handler.ts:466,2471`); er ersetzt keine vollständige Dekodierung/Dimensionsprüfung.
- **Einfluss:** ungültige Bilder früher 400; unterstützte echte Bilder unverändert möglich.
- **Regression:** minimale echte erlaubte Bildfixtures, Nicht-Bild, falsche MIME und abgeschnittene Header. Bei Ablehnung keine Tages-/Globalreservierung und kein Provider-Aufruf. Aktuelle Tests mit künstlichem Prefix+Padding nicht als echte Bilddekodierung werten.

### S06 — Festes Stream-Tail passt nicht zu normalisierten Wortmustern — P2

- **Betroffen:** `supabase/functions/coach-chat/handler.ts:537` normalisiert beliebig lange Nichtwortsequenzen; :558 prüft sieben Wörter; :760/:964 hält nur 64 Rohzeichen zurück. Test `handler_stream_test.ts:1134` kalkuliert kurze Trennzeichen.
- **Beweis/Reproduktion:** erstes öffentliches Shingle aus `PROMPT_LEAK_GUARD.shingles` in Wörter zerlegen, je Wort 100 Leerzeichen und einen eigenen Providerframe senden. Der vollständige Text wird korrekt erkannt; **562 Präfixzeichen einschließlich Wortinhalt** waren bereits als Deltas ausgegeben, danach `refusal:true`. V5/T4.
- **Schaden/Voraussetzung:** die implementierte Garantie gegen Promptrekonstruktion greift nicht für alle normalisierten Varianten. Der betroffene Prompt ist öffentlich, enthält keine nachgewiesenen Secrets oder fremden Nutzerdaten; deshalb P2 und kein Secret-Leak/P0.
- **Kleinster sinnvoller Fix:** Rückhaltefenster an noch offenen normalisierten Wortfenstern ausrichten oder vor Prüfen/Versand identisch normalisieren; ggf. vollständig puffern. Ein größeres fixes Zeichenfenster liefert keinen allgemeinen Beweis.
- **Einfluss:** zusätzliche Latenz oder veränderte Whitespaceformatierung.
- **Regression:** verschiedene Leerzeichen/Punktuation/Chunkgrenzen; kein geschützter Präfix in Deltas; legitime lange Antwort weiterhin vollständig ausgeben.

### S07 — Falsche AI-Anbieterinformation in App und öffentlicher Policy — P1

- **Betroffen:** `lib/l10n/app_de.arb:606`, `lib/l10n/app_en.arb:590`, tatsächlich angezeigt durch `lib/src/screens/coach/coach_composer.dart:649`. Beide nennen Grok/xAI. Aktuelle Defaults `supabase/functions/coach-chat/handler.ts:61` nennen Gemini. `PRIVACY.md:157` ist bereits aktualisiert.
- **Beweis/Reproduktion:** Quelltext bis gerendertes Coach-Infosheet verfolgt. Zusätzlich am 14.09.2026 die öffentliche [Datenschutzseite](https://eatova.de/datenschutz) gelesen: Stand 01.09.2026, Abschnitt 5.3 und Empfängerangaben ebenfalls Grok/xAI; neue Training-/Health-Connect-Flüsse dort nicht zutreffend vollständig beschrieben. Infosheet auf Deutsch/Englisch mit synthetischem Konto ansehen, keine AI-Anfrage erforderlich.
- **Schaden:** widersprüchliche Empfängerinformation bei potenziell gesundheitsbezogenen Daten. Das ist ein Transparenzfehler, kein Beweis unzulässiger Verarbeitung oder tatsächlicher Exfiltration. Aktuelle Live-Modelloverrides wurden nicht eingesehen; diese Grenze bleibt bestehen.
- **Kleinster sinnvoller Fix:** tatsächliche Anbieter-/Routingkonfiguration feststellen, beide ARBs und veröffentlichte Policy auf abgestimmte Empfängerbeschreibung bringen, Lokalisierung regenerieren. Consent/Rechtsgrundlagen/Widerruf und eine eventuell erforderliche Nutzerinformation fachlich prüfen lassen.
- **Einfluss:** Informationsänderung; kein notwendiger Eingriff in AI-Funktion. Eine rechtliche Entscheidung wird hier nicht vorweggenommen.
- **Regression:** tatsächliches Coach-Infosheet DE/EN gegen genehmigte Anbieterbeschreibung prüfen; separater Veröffentlichungscheck der Website gegen das Dateninventar.

## Historische Testnachweise der Runde 1 und Grenzen

| ID | Ausgeführt am 14.09.2026 | Ergebnis | Grenze |
| --- | --- | --- | --- |
| T1 | Gitleaks 8.30.1, Git `--all` und aktueller Quellbaum, redigiert | 543 Commits, keine Treffer im Repo; lokaler Umfang oben | Kein vollständiger ausgelieferter Binär-/Cloudlogscan |
| T2 | PostgreSQL 16.15, CI-gepinntes Image, zwei eigene Wegwerfcontainer ohne Netzwerk/Hostports; Bootstrap +43 Migrationen + RLS-Suite und Zusatzproben | Alle regulären Prüfungen bestanden; bewusst aufgeweichte Policy erkannt; Claims5/10 | Minimaler Supabase-DB-Bootstrap, keine echte JWT-/PostgREST-/Cloudprüfung |
| T3 | Flutter3.47.2/Dart3.13.2, zehn gezielte Testdateien | 115 bestanden | Testplattformen, keine realen nativen Speicher-/Gerätenachweise |
| T4 | Deno2.8.1, Coach-Suite; fünf zusätzliche Offline-Gegenproben | 289 bestehende Tests grün; fünf Auditproben reproduzieren S01/S06 | „Grün“ der Ist-Reproduktion bedeutet nicht behoben; kein echter Modelllauf |
| T5 | Deno2.8.1, Fotoanalyse/Suche/Shared; sechs Coach-Auth-/Ownership-Proben und Nicht-Bild-Probe | 218 bestehende Tests grün; sechs Authproben erfolgreich; S05 reproduziert; zwei Entrypoints typechecked | Fetch vollständig ersetzt, keine echten JWTs/Provider/DB-Writes |
| T6 | OSV API1.0 `querybatch`, nur öffentliche Paketnamen/-versionen und Fremdprojekt-Revisionen | 153 Pub +9 native Git-Revisionen,162 Ergebnisse,0 Advisory-Treffer,0 Fortsetzungsseiten | Keine vollständige Android-Native-Auflösung/Wartungs-/Runtimeprüfung |

T4+T5 ergeben **507 bestehende Deno-Tests**; die zusätzlichen Auditproben sind davon getrennt. Keine produktiven AI-Kosten oder echten Zahlungen, kein Belastungstest. Docker-Container gestoppt und entfernt. Die getesteten Quellbäume blieben unverändert. Keine vollständige Flutter-Testsuite, Releasebuild oder CI für diese reine Auditdokumentation neu gestartet.

Reproduzierbare Kernbefehle aus dem sauberen Prüfstand:

```text
deno test --no-lock --allow-env supabase/functions/coach-chat
deno test --allow-env --cached-only --no-check supabase/functions/analyze-meal supabase/functions/search-key supabase/functions/_shared
deno check --no-remote --no-npm --no-lock supabase/functions/analyze-meal/index.ts supabase/functions/search-key/index.ts
```

Kein `--allow-net`; Fetch wird durch Fixtures ersetzt. Deno kann öffentliche Modulmetadaten separat laden; die vorhandenen Functions importieren ausschließlich lokale Module. Die zusätzlichen Reproduktionen nutzten temporäre Kopien der vorhandenen Test-Fetch-Helfer außerhalb des Repositories und die echten Handler per `file:`-Import. Die konkreten Inputs/Assertions sind in S01/S02/S05/S06 beschrieben; keine neuen Tests wurden in Appcode aufgenommen.

Die fünf zusätzlich ausgeführten T4-Reproduktionen sind vorübergehend lokal verfügbar; diese Pfade sind keine dauerhaften Repository-Tests:

```text
deno test --no-lock --allow-env --filter AUDIT C:/Users/morit/AppData/Local/Temp/eatova-audit-ai-20260914-mhcpgdw4/stream_audit_test.ts
deno test --no-lock --allow-env --filter AUDIT C:/Users/morit/AppData/Local/Temp/eatova-audit-ai-20260914-mhcpgdw4/recipe_audit_test.ts C:/Users/morit/AppData/Local/Temp/eatova-audit-ai-20260914-mhcpgdw4/plan_audit_test.ts
```

Ergebnisse: drei plus zwei Ist-Reproduktionen bestanden. Nach einer späteren Korrektur müssen neue Regressionstests die jeweils sichere Gegenbedingung verlangen.

Für T2: `test/migrations/pg_bootstrap.sql`, alle Migrationsdateien lexikografisch, danach `psql -v ON_ERROR_STOP=1 -f test/migrations/rls_cross_user.sql`. Die Suite bindet `training_plans_rls.sql`, `recipe_ingredients_rls.sql`, `training_history_rls.sql` und `meal_plans_rls.sql` ein. **Nur auf einer neu angelegten wegwerfbaren Datenbank ausführen**, nie gegen Produktion. Die absichtliche Negativkontrolle ist auf diese isolierte DB begrenzt.

T3 lief im vorbereiteten separaten Icon-Worktree. `git diff` der Verzeichnisse `lib`, `test` und beider Pubspec-Dateien gegen den Auditstand war leer. Aufruf `flutter test --no-pub --reporter expanded --dart-define=SUPABASE_URL=https://ci.invalid --dart-define=SUPABASE_ANON_KEY=ci-dummy-key` mit diesen Dateien:

```text
test/services/session_storage_test.dart
test/services/session_storage_keystore_report_test.dart
test/wiring_supabase_session_storage_test.dart
test/auth_deeplink_predicate_test.dart
test/auth_mutation_session_isolation_test.dart
test/delete_account_reauth_test.dart
test/services/secure_cache_store_wiring_test.dart
test/auth_gate_session_loss_test.dart
test/deeplink_route_guard_test.dart
test/services/recipe_image_store_test.dart
```

Versionsbasis: Flutter3.47.2/Dart3.13.2; Lockfile `supabase_flutter`2.17.2, `supabase`2.16.1, `gotrue`2.27.2, `flutter_secure_storage`10.3.1, `sentry_flutter`/`sentry`9.26.0, `image`4.8.0, `health`13.3.1, `google_sign_in`7.2.0. Native `Package.resolved` enthält neun Revisionen, darunter Sentry Cocoa8.58.4, GoogleSignIn-iOS9.2.0, AppAuth-iOS2.1.0. Kein Paket allein wegen seines Alters als verwundbar bezeichnet. [OSV API1.0](https://google.github.io/osv.dev/api/), [Batchabfragen](https://google.github.io/osv.dev/post-v1-querybatch/).

## Fehlender Laufzeitzugriff: konkrete sichere Prüfschritte

Diese Verfahren wurden **nicht** gegen die Cloud ausgeführt. Ergebnisse ausschließlich als gefilterte Metadaten dokumentieren; keine vollständigen Settings-, Secret-, Authuser- oder Gesundheitsdaten-Dumps. Keine schreibenden RPCs, Restores oder echten Nutzeraktionen ausführen.

### M1 — A11: Schemas, Policies, Grants, Funktionen und Advisor

Zuerst im Dashboard API-exponierte Schemas feststellen. Unten `public` um tatsächlich exponierte zusätzliche Schemas ergänzen. Nur Metadaten lesen; Funktionskörper nicht unkontrolliert exportieren, da manuell angelegte Funktionen theoretisch sensible Literale enthalten könnten.

```sql
begin transaction read only;
select current_setting('server_version');

select n.nspname, c.relname, c.relkind,
       c.relrowsecurity, c.relforcerowsecurity,
       pg_get_userbyid(c.relowner) as owner, c.reloptions
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','p','v','m')
order by 1,2;

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies where schemaname = 'public'
order by tablename, policyname;

select table_schema, table_name, grantee, privilege_type
from information_schema.table_privileges
where table_schema = 'public' order by table_name, grantee, privilege_type;

select table_name, column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public' order by table_name, column_name, grantee;

select p.oid::regprocedure as signature,
       pg_get_userbyid(p.proowner) as owner,
       p.prosecdef, p.proconfig, p.proacl,
       md5(pg_get_functiondef(p.oid)) as definition_hash
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f' order by 1;

select pg_get_userbyid(d.defaclrole) as creator,
       n.nspname, d.defaclobjtype, d.defaclacl
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
order by 1,2,3;
rollback;
```

Definition-Hashes hier nur für Driftvergleich, nicht als kryptografischer Integritätsschutz. Unterschiede zunächst unter gleicher PostgreSQL-Ausgabeversion untersuchen; unterschiedliche Hashes sind noch keine Lücke. Zusätzlich Rollenmitgliedschaften/Schema-CREATE/USAGE und Default-Grants **je Ersteller** lesen. Security Advisor öffnen, Check-ID/Objekt/Schweregrad und Datum ohne Nutzerdaten festhalten. Vorhandene Migrationnummern reichen nicht: der derzeitige Workflow prüft nur deren Registrierung (`security.yml:482,501`), keine nachträglich geänderten Definitionen.

### M2 — B03/B06/C/A10: Auth und Functions

Dashboard/Management-API nur lesend und mit Feld-Allowlist:

- alle Function-Slugs, aktive Versionen, Status, `verify_jwt`; auch alte/zusätzliche Endpoints. Heruntergeladene Definitionen lokal geschützt gegen Prüfstand vergleichen, keine Secretswerte kopieren;
- Auth: aktivierte Provider/Anonymous Sign-ins, E-Mail-Bestätigung, Passwortregeln/Breached-Password-Prüfung, Login-/OTP-/Signup-/Recovery-Raten, Bot-/CAPTCHA-Konfiguration;
- Redirect-Allowlist, Recovery-/Magic-Link-Templates ohne echte Links/Tokens, JWT-Laufzeit/Signing-Verfahren, Refresh-Reuse/Sessionregeln und Secure Email Change;
- Admin-/Repo-/Supabase-MFA ohne Recoverycodes oder Tokenmaterial nachweisen.

Anschließend im ausdrücklich freigegebenen **Testprojekt**: unauth, angemeldeter Gast (falls aktiviert), A/B; echte ungültige/abgelaufene/falsche Projekt-Tokens; erlaubte UND verbotene REST/RPC-/Function-Aktionen; zurückgegebene Daten und Zeileneffekte prüfen. Keine Produktionskonten dafür erzeugen. Passwort-Nonce hat laut aktueller Supabase-Dokumentation eine Ausnahme für kürzlich erstellte Sessions; die vorhandene 24h-Regel nicht als neue unbekannte Lücke ausgeben. [Password Security](https://supabase.com/docs/guides/auth/password-security).

### M3 — D01/D02/D06: Storage und Realtime

```sql
begin transaction read only;
select id, public, file_size_limit, allowed_mime_types
from storage.buckets order by id;

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where (schemaname = 'storage' and tablename = 'objects')
   or (schemaname = 'realtime' and tablename = 'messages');

select pubname, schemaname, tablename
from pg_publication_tables where pubname = 'supabase_realtime';
rollback;
```

Danach Grants, Bucket-/Private-Channel-Einstellungen prüfen, ohne `storage.objects`-Dateinamen oder Objektinhalte auszulesen. Falls tatsächlich genutzt: getrennte A/B-Tests für Lesen/Listen/Upload/Update/Upsert/Verschieben/Löschen, Signed URLs, Postgres Changes und Broadcast/Presence ausschließlich im Testsystem. Falls Inventar leer und Funktion ungenutzt bestätigt: betreffenden Punkt begründet auf NICHT RELEVANT setzen.

### M4 — F02/F07: Geldbudget, Missbrauch und Abschaltung

OpenRouter API v1 bietet `GET https://openrouter.ai/api/v1/key`. Nur innerhalb eines vertrauenswürdigen lokalen Prozesses mit dem benötigten serverseitigen Key abfragen und ausschließlich `limit`, `limit_remaining`, `limit_reset`, `include_byok_in_limit`, optional `is_free_tier` übernehmen. Key, Labels und vollständige Antwort nicht loggen. [Offizielle Key-Metadatenabfrage](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key).

Zusätzlich tatsächliche Autoaufladung, organisationsweite Budgets, Alarmregeln/Verantwortliche und Abschaltverfahren lesen. Geldbudget gilt nicht automatisch für jede weitere Providerintegration. Für einen späteren Fix wäre ein atomar gebuchtes, nicht über Nutzer-Refunds rücksetzbares globales Spend-/Aufrufbudget vor Coach-Classifier/Draft/Bild sinnvoll; Modellkosten und legitime Ausfälle berücksichtigen. Das beeinflusst Verfügbarkeit für alle Nutzer bei erschöpftem Budget. Regression in isolierter Umgebung: viele synthetische Konten, kleine globale Grenze, danach keine weiteren Provider-Stubs; normale erlaubte Anfrage und kontrollierter Refund bleiben korrekt. Hier wurde kein solcher Fix implementiert und kein realer Abschalt-/Kostenalarm ausgelöst.

### M5 — I/K: Anbieter, Betrieb, Backups und Veröffentlichung

- Anbieter-/Routing-/Training-/Retention-/Regionswerte aus OpenRouter/Sentry/Supabase lesen; nur notwendige Metadaten. Fehlender per-Request-Privacyfilter beweist keine fehlenden Accountsettings. Verträge, Rechtsgrundlagen und ggf. DSFA gesondert fachlich prüfen. [OpenRouter Provider Logging](https://openrouter.ai/docs/guides/privacy/provider-logging).
- GitHub-Teamrechte, Branchschutz/Required Checks, Environment-Branchregeln und minimale CI-Berechtigungen lesen; Supabase-Team-/Datenbank-/Netz-/TLS-Einstellungen ebenso. Workflowtext allein beweist nicht die aktivierten Dashboardregeln.
- Backup-Datum/Typ/Status/Rückhaltezeit aus Dashboard Database → Backups oder Management-API `GET /v1/projects/{ref}/database/backups` gefiltert erfassen; existierenden Restorebericht anfordern. Datenbankbackup enthält keine Storage-Objektbytes. Separater synthetischer Restore-Drill nur in freigegebener isolierter Umgebung, niemals Produktion überschreiben. [Supabase Backups](https://supabase.com/docs/guides/platform/backups).
- Admin-/Berechtigungs-Auditlogs, Alarmkonfiguration/Empfänger und Retention lesen; keine vollständigen Ereignis-/Gesundheitsdaten-Dumps. Schlüsselrotation, Kontosperre, Rollback, AI-Abschaltung und Zuständigkeiten als prüfbares Verfahren belegen.
- Tatsächlich ausgeliefertes APK/AAB/IPA, zusammengeführte Berechtigungen, TLS und synthetische Geräte-/Backup-/Vorschauprüfungen ergänzen. Hier wurde kein Store-/Releaseartefakt erzeugt oder installiert.

## Ergänzendes Dateninventar I01/I02

Supabase speichert neben Kontodaten die oben aufgeführten Nutzerdomänen, Chats/AI-Vorschläge, Quoten sowie serverseitige Dedupe-/Ratelimitdaten. OpenRouter erhält je nach Funktion Essensfoto, Frage, begrenzten Verlauf, optionale Coachbilder und explizite Trainingsbriefs. `HomeStore.coachContext` ergänzt Sprache, Gewicht/Ziel und Tagesbilanz/Makros sowie begrenzte Essensnamen. Auch ohne expliziten Namen/E-Mail kann dies sensibel sein; automatische Weitergabe pro Modus auf Notwendigkeit prüfen.

Meilisearch/Open Food Facts erhalten Suchbegriffe/Barcodes und technisch Verbindungsmetadaten. Google-Anmeldung ist optional. iOS HealthKit/Android Health Connect sind lokale Datenquellen; daraus übernommene Werte können im App-/Coachkontext weiterverarbeitet werden. iOS-Diktat setzt On-device-Verarbeitung nur bei Unterstützung (`ios/Runner/AppDelegate.swift:244`); sonst ist Apple-Verarbeitung möglich. Optionale Sentry-Telemetrie hängt vom Build-DSN ab. Benachrichtigungen sind lokal, kein Pushdienst. Bilder liegen lokal; verschlüsselte Cache-/Outbox-Aussagen dürfen nicht auf sämtliche JPEG-/Temporärdateien übertragen werden.

Löschung in der eigenen Datenbank, lokale Bereinigung, Providerretention und Backupaufbewahrung sind verschiedene Nachweise. Der Export filtert eigene UID, markiert Fehler/Kappung und wird derzeit bewusst in die Zwischenablage kopiert; ein unverdrahteter Sharecallback ist kein tatsächlich ausgelieferter Dateiexport. RAG/Embeddings, Payment und Supabase-Storage-/Realtime-Appfunktionen wurden im Source nicht festgestellt; außerhalb des Repositories angelegte Infrastruktur bleibt unbekannt.

## Ergebnis der Runde 1 und weitere Prüfplanung

**Tatsächlich geprüft:** aktueller Main-Quellbaum, alle drei Edge-Entrypoints, Datenmodell/Migrationen, tatsächliche SDK-Storageverdrahtung, sensible Integrationspfade, Kosten-/Streamingmechanik und vorhandene CI; fünf Vertiefungen mit isolierten positiven und negativen Proben. Sieben belegte Befunde S01–S07, davon drei P1 (Antwortfilter, Bild-Classifier-Ausfallpfad, Anbieterinformation), vier P2. Kein nachgewiesener P0, privilegierter Client-Secret-Leak oder Fremddatenzugriff im geprüften Umfang.

**Weiterhin unbekannt:** aktuelle bereitgestellte Policies/Grants/Functions/Authregeln, zusätzliche Buckets/Realtimeobjekte, echte JWT-End-to-End-Prüfung, Provider-Geldlimits/Alarme/Privacysettings, fachliche Coachfreigabe, Restore-/Geräte-/Releasezustand. Lokale grüne Tests ersetzen diese Nachweise nicht.

Nächste fünf noch nicht abgeschlossene Prüfpunkte, erst auf weitere Aufforderung:

1. **A11:** tatsächliche bereitgestellte Rechte/Definitionen und Security Advisor mit M1/M2 abgleichen. Ohne Zugriff bleibt der Liveanteil NICHT PRÜFBAR.
2. **F02:** globale Coach-Kostenkontrolle, Gast-/Mehrfachkonten und Refund-Spendgrenze; Providerbudget nach M4 nur lesend belegen.
3. **G10:** nach den technischen Regressionen aus Runde 2 reale versionierte Modell-/Guardrail-Eval und bereitgestellte Fehlerpfade im freigegebenen Testsystem nachweisen.
4. **C02:** reale Auth-/Recovery-Raten, Enumeration und Botschutz; Tests nur im freigegebenen Testprojekt.
5. **I04:** vollständige Löschmatrix aller aktuellen Datendomänen, lokaler Dateien und externer Anbieter-/Backupfristen.

Die bestätigten Befunde sind getrennt von diesen Nachweisarbeiten zu behandeln. Runde 1 hatte ausschließlich das Checkbuch erstellt. Die danach ausdrücklich beauftragten Korrekturen und deren aktuellen Auslieferungsstatus dokumentiert Runde 2 am Dokumentanfang.

Dokumentkontrolle der Runde 1: alle 91 IDs einmalig und in Reihenfolge vorhanden; 11 ERFÜLLT im jeweils begrenzten Umfang, 55 TEILWEISE, 13 NICHT PRÜFBAR, 10 NICHT RELEVANT, 2 OFFEN. Tabellenstruktur, vorhandene explizite Quellpfade/Zeilennummern und commitgebundene Quelllinks geprüft; `supabase/config.toml` wird ausdrücklich als nicht vorhanden beschrieben. Keine Whitespacefehler oder Gitleaks-Treffer im Bericht. AI- und Gerätebefunde wurden zusätzlich durch die jeweiligen Prüfer gegengelesen; Originalarbeitsänderungen bleiben erhalten, beide verwendeten Quell-/Test-Worktrees sind sauber.
