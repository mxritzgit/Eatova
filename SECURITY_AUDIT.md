# Eatova — Sicherheits-Checkbuch

Stand: 14.09.2026. Runde 1 dokumentiert die Bestandsaufnahme; Runde 2 behandelt die sieben belegten Befunde. Dies ist keine Freigabe der gesamten App.

## Runde 2 — Korrekturen und verbleibende Freigabeschritte

Der Nutzer hat nach dem Audit ausdrücklich Korrekturen, fünf Subagents, Funktionsprüfung sowie Push und Merge nach grüner CI beauftragt. Die ursprüngliche Beschränkung auf Dokumentation gilt für die unten erhaltene **Runde 1**. Runde 2 arbeitet auf einem isolierten Topic-Branch ab Main `a3a7422`; fremde Änderungen im ursprünglichen Arbeitsordner bleiben erhalten. Datenbank und Cloudkonfiguration wurden nicht verändert. Sämtliche ausgeführten Funktionstests verwenden synthetische Daten und ersetzte externe Requests.

Die folgende Tabelle bewertet die **konkreten Befunde**, nicht die vollständige Erfüllung aller 91 breiteren Prüfpunkte. Die ursprünglichen Reproduktionen und Quellzeilen in S01–S07 bleiben als datierter Vorher-Nachweis erhalten; aktuelle Implementierungen und Regressionen sind hier verlinkt.

| Befund | Stand der Korrektur | Aktuelle Durchsetzung und Nachweis | Noch erforderlich |
| --- | --- | --- | --- |
| S01 · P1 | ERFÜLLT — CODE/TEST | [`finalizeAnswer`, `handleRecipeMode`, `handlePlanMode`](supabase/functions/coach-chat/handler.ts) behandeln `content_filter` als sichere Ablehnung. Kein normaler Assistant-Eintrag, übernehmbarer Entwurf oder nachgelagerter Bildaufruf; keine Erstattung für Sicherheitsablehnungen. Fehlende/unerwartete Abschlussgründe werden abgewiesen. JSON/SSE-/Rezept-/Plan-Regressionen erkennen das vorherige Verhalten. | `coach-chat` bereitstellen und im freigegebenen Testsystem nachweisen. |
| S02 · P1 | ERFÜLLT — CODE/TEST | [`classify` und `handleRequest`](supabase/functions/coach-chat/handler.ts) stoppen Bild+Text bei unbrauchbarer Klassifikation vor der Antwortgenerierung. Auch eine benigne Kategorie benötigt ausdrücklich `finish_reason=stop`; fehlend/null wurde vorher rot und danach grün getestet. Erkannte Gefahren bleiben konservativ gesperrt. | Deployment; reale semantische Qualität einschließlich bildlicher Manipulation bleibt gesonderte Modell-/Fachprüfung. |
| S03 · P2 | ERFÜLLT — CODE/TEST | [`SecureSessionLocalStorage`](lib/src/config/supabase_config.dart), [`SessionRevocations`](lib/src/services/session_revocations.dart), [`SupabaseAuthRepository`](lib/src/auth/auth_repository.dart): tokenfreie Logout-Marker, geordnete Speicherung und Bindung an den aktuellen SDK-Token. Native Legacy-Löschbestätigung vor Markerabbau; Vorbereitung vor Datenbereinigung; Kompensation des PKCE-Fehlerpfads. 26 [Storage-/SDK-Regressionen](test/services/session_logout_restore_test.dart) sowie vier [echte App-Fehler-/Retry-Flows](test/sign_out_failure_test.dart) grün; ursprüngliche Wiederherstellung, Preferences-Cachefehler, fehlendes SDK-Ereignis und verfrühte Fotolöschung zuvor nachgewiesen. | Geräte-/Backup-Prüfung mit synthetischen Konten; bei SDK-Updates den an gotrue 2.27.2 gebundenen Kompensationspfad erneut prüfen. |
| S04 · P2 | ERFÜLLT — CODE/TEST | [`EatovaApp`](lib/src/app/eatova_app.dart) hält `SecureScreenGuard` um den Navigator aktiv. [`app_private_screen_test.dart`](test/app_private_screen_test.dart) prüft alle fünf Tabs, gepushte/nested Routen, restaurierte Sitzung, Login/Logout und A→B. Beide Regressionen schlugen vor dem Fix fehl. | Installierter Android-/iOS-Build: Android-Screenshot/Screen-Sharing und iOS-App-Switcher prüfen. iOS-Screenshots werden dadurch nicht generell verhindert. |
| S05 · P2 | ERFÜLLT — CODE/TEST | [`image_type.ts`](supabase/functions/analyze-meal/image_type.ts) prüft kanonisches Base64 und begrenzte JPEG-/PNG-/WebP-Containermerkmale vor Tages-/Globalkontingent und Provider. [`image_validation_test.ts`](supabase/functions/analyze-meal/image_validation_test.ts) prüft 19 gültige/ungültige Fälle und tatsächliche Gate-/Provideraufrufe. | `analyze-meal` bereitstellen. Kein vollständiger Bilddecoder und kein abschließender Schutz gegen Dimensions-/EXIF-/Decoderprobleme; D05 bleibt offen im Prüfumfang. |
| S06 · P2 | ERFÜLLT — CODE/TEST | [`sseAnswerResponse`](supabase/functions/coach-chat/handler.ts) prüft die komplette Antwort vor dem ersten Textdelta. Die 64-Zeichen-Sicherheitsschranke entfällt. [`handler_stream_test.ts`](supabase/functions/coach-chat/handler_stream_test.ts) prüft lange Leerzeichen, späte Filter, ungültige Frames, fehlenden Abschluss, Abbruch, positive Antworten und Unicode-Grenzen. | Deployment; keine Garantie, dass heuristische Promptmuster jede semantische Manipulation erkennen. |
| S07 · P1 | TEILWEISE — App korrigiert, Website vorbereitet | Beide [`ARBs`](lib/l10n/app_de.arb), [`Coach-Infosheet-Test`](test/coach_ai_disclosure_test.dart) und [`PRIVACY.md`](PRIVACY.md) nennen OpenRouter/Google/Gemini und die tatsächlich übertragenen Kontextarten. Vier DE/EN-Regressionen vorher rot, danach grün. Die byteidentische Quelle der veröffentlichten Website wurde gefunden; [Einzeldatei-Patch und Prüfung](docs/PRIVACY-WEBSITE-CORRECTION-2026-09-14.md) sind vorbereitet. | App ausliefern; Website nach abgestimmtem Backend-Rollout und ausdrücklicher Veröffentlichungsfreigabe aktualisieren. Rechtsgrundlagen, Verträge und tatsächliche Anbieter-Kontoeinstellungen bleiben gesondert zu prüfen. |

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
| Fehlernachweise | Fünf getrennte Arbeitsbäume und Gegenreviews; Tests verlangten nachweislich sichere Gegenbedingungen zum alten Verhalten | Alle sieben ursprünglichen Befunde mit gezielten Vorher-/Nachher-Nachweisen; zusätzlich Classifier-Abschluss, PKCE-Ereignis, native Preferences-Fehler und UI-Cleanup korrigiert. S07-Website nur vorbereitet. |
| Dokumente / Secrets | Alle 58 Markdown-Dateien: 325 lokale Links/Anker, Quellen/Versionen; redigierter Gitleaks-Scan 8.30.1 des getrackten Quellbaums plus neuer Dateien | Keine kaputten Links oder Secret-Treffer. Der historische B01-Scan bleibt getrennt; CI scannt zusätzlich die Git-Historie. |
| Website | Einzeldatei-Patch gegen byteidentische öffentliche Quelle; isoliertes Chromium bei 320/390/768/1440 Pixeln | Keine Überbreite, fehlenden Ressourcen oder JS-Fehler; 26 eindeutige IDs und gültige Sprungziele. Keine Veröffentlichung. |

**Git-Auslieferung:** Topic-Branch `fix/security-audit-findings`; Push/geschützter PR und Merge nach grüner CI sind autorisiert. Zum Dokument-Commit sind lokale Tests und Reviews abgeschlossen; der zugehörige PR enthält den anschließend verifizierten CI-/Merge-Nachweis. Acht bindende Main-Checks und `enforce_admins=true` wurden vor Auslieferung über die GitHub-API gelesen. Keine Tests oder Schutzregeln wurden abgeschwächt.

Der SDK-Folgefix greift ausschließlich bei ausgelassenem `signedOut` und bereits leerer SDK-Sitzung ein; kein `await` zwischen Nullprüfung und Benachrichtigung. Ein nachträglicher Widerrufsversuch verwendet nur den vor dem SDK-Aufruf erfassten A-Token (lokaler Scope, maximal ein Versuch, 10 Sekunden Wartebudget). Ein zwischenzeitlich angemeldeter B wird nicht abgemeldet. Verweigert die dauerhafte Vorbereitung den Logout, läuft keine lokale Datenbereinigung; die Oberfläche zeigt einen neutralen DE/EN-Fehler und lässt einen neuen Versuch zu.

**Bisher nicht erfolgt:** Supabase-Function-Deployment, Änderung von Policies/Grants/Authsettings, Veröffentlichung der Datenschutz-HTML-Datei, Store-Publikation oder Installation eines Gerätebuilds. Ein GitHub-Merge ist kein Nachweis einer dieser Aktionen. Aktuelle Live-RLS-, Auth-, Providerbudget-, Alarm- und Restore-Nachweise bleiben entsprechend A11/C/F/I/K unvollständig.

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

## Vollständiges Checkbuch

Alle **91** angefragten IDs sind enthalten. Die Breitenprüfung stammt aus Runde 1; die betroffenen Einträge werden um Runde-2-Nachweise ergänzt. Nur V1–V5 wurden in der Bestandsaufnahme gezielt vertieft. Kurze Dateiangaben sind projektbezogen: Migrationsnamen unter `supabase/migrations/`, Flutter-Services unter `lib/src/services/`, Auth unter `lib/src/auth/`, `security.yml` unter `.github/workflows/`. `handler.ts` in F/G/H bezeichnet `supabase/functions/coach-chat/handler.ts`. S01–S07 sind unten dokumentierte ursprüngliche Befunde, T1–T6 historische Testnachweise, M1–M5 manuelle Prüfverfahren.

### A. Supabase: RLS und Datenbankberechtigungen

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| A01 | RLS-Abdeckung aller erreichbaren Tabellen | ERFÜLLT | P1 | CODE/TEST: 43 Migrationen auf PostgreSQL 16.15; 16/16 öffentliche Tabellen mit RLS; `20260814120000_audit_rls_guard.sql:49,93,127`. | LIVE: exponierte Schemas/Tabellen und Event-Trigger mit M1 abgleichen. |
| A02 | CRUD, USING und WITH CHECK | ERFÜLLT | P1 | CODE/TEST: 34 Eigentümer-Policies im Endzustand; passende USING/WITH CHECK oder bewusst keine Client-Schreibrechte; V1. | Rechte-Matrix zusätzlich über echten PostgREST im freigegebenen Testprojekt. |
| A03 | Nutzer-/Mandantentrennung, Verknüpfungen | ERFÜLLT | P1 | CODE/TEST: V1, vollständige SQL-Suite + beidseitige A/B-CRUD-Proben, Negativkontrolle erkennt offene Policy. | REST/RPC mit echten Staging-Tokens ergänzen; LIVE separat A11. |
| A04 | Geschützte Eigentümer-/Rollen-/Kontingentfelder | ERFÜLLT | P1 | CODE/TEST: Profile-Spaltengrants `20260819100000_profiles_column_grants.sql:16`; direkte Chat-/Quota-/Lifetime-Schreibversuche gesperrt (`rls_cross_user.sql:242`). | Live-Spaltenrechte prüfen; keine Admin/Premium/Tenant-Felder im geprüften Modell. |
| A05 | Zu offene Policies | ERFÜLLT | P1 | CODE/TEST: final 34 Policies ohne USING(true)/WITH CHECK(true); `SCHEMA_STATE.md:116`; Negativkontrolle V1. | Zusätzliche/geänderte Live-Policies nach M1 prüfen. |
| A06 | Minimale Schema-/Tabellen-/Funktionsrechte | TEILWEISE | P1 | CODE/TEST: anon ohne App-Tabellenrechte; authenticated ohne TRUNCATE; beide ohne CREATE public; Default-Revoke `20260809120000_pin_function_execute_defaults.sql:15`. | LIVE: Rollenmitgliedschaften, Owner und Defaults je Ersteller/Schema, M1. |
| A07 | Views und materialisierte Views | NICHT RELEVANT | P2 | CODE/TEST: keine App-Views/materialisierten Views; lokaler Katalog 0 public Views. | Live-Zusatzobjekte mit M1 ausschließen; dann Owner/security_invoker/Grants prüfen. |
| A08 | RPCs, SECURITY DEFINER, search_path | TEILWEISE | P1 | CODE/TEST: 33 öffentliche Funktionen, feste search_paths/explizite Grants; kritische RPCs getestet; `20260609120000_chat_rpc_least_privilege.sql:49`, V1. | Einzelmatrix aller 33 Signaturen/Grenzen und Live-Definitionen vervollständigen. |
| A09 | Vertrauenswürdige Rolleninformationen/JWT | ERFÜLLT | P1 | CODE: Rechte aus auth.uid(); raw_user_meta_data nur Anzeigename (`20260516150000_create_profiles.sql:65`), keine rollenbasierte Freischaltung. | Bei neuen Rollen JWT-Aktualität prüfen; Kontosperre/Session weiter C04. |
| A10 | Unangemeldet vs. Anonymous Sign-ins | TEILWEISE | P1 | TEST: anon gesperrt; synthetischer is_anonymous-Claim unter authenticated nur eigene Daten; kein Gast-UI. Functions erlauben solche validierten Gäste. | M2: Anonymous Sign-ins live aktiviert? Gewünschte Gast-/AI-Rechte und Anmelderaten prüfen. |
| A11 | Bereitgestellte Policies/Grants/Advisor | NICHT PRÜFBAR | P1 | Kein aktueller Live-Katalog/Advisor. `security.yml:482,501` vergleicht nur registrierte Migrationsnummern, keine Definitionen. | M1: Policies/Grants/Funktionen/extra Schemas und Security Advisor nur lesend abgleichen. |

### B. Backend, Edge Functions und Secrets

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| B01 | Keine privilegierten Secrets im Client/Repo | TEILWEISE | P1 | TEST: Gitleaks 8.30.1, 543 Git-Commits und aktueller Quellbaum ohne Treffer; siehe Scanprotokoll | Ausgelieferte Binärdateien und externe Buildlogs gesondert prüfen |
| B02 | Öffentliche Supabase-Keys korrekt einordnen | TEILWEISE | P1 | CODE/TEST: öffentlicher anon-Key wird in allen drei Handlern als User-Bearer abgewiesen; Such-Key siehe `search-key/index.ts:273`. | Reale Meilisearch-Key-Metadaten actions/indexes/expiry ohne Keywert lesen. |
| B03 | Echte serverseitige Tokenvalidierung | TEILWEISE | P1 | CODE: projektspezifisches `/auth/v1/user`, z. B. `analyze-meal/handler.ts:626`; TEST: Auth-Ablehnung und Ausfall. | Signatur, Ablauf, falscher Issuer/Audience gegen isolierten echten Auth-Dienst prüfen. |
| B04 | Objekt-/Aktionsautorisierung jedes Endpoints | TEILWEISE | P1 | CODE/TEST: drei Handler, sechs zusätzliche A/B-/Auth-Proben; Vertiefung V2. | Aktuelle deployed Funktionsliste und End-to-End-Nachweis im Testprojekt ergänzen. |
| B05 | Keine vertrauten Client-Behauptungen | ERFÜLLT | P1 | CODE/TEST: verifizierte Auth-ID; manipulierte user_id/role/isAdmin/model ohne Wirkung, V2. | Bei neuen Aktionen/Clientfeldern denselben negativen Test ergänzen; LIVE unbewiesen. |
| B06 | Auth-Konfiguration aller Edge Functions | TEILWEISE | P1 | CODE: drei Entrypoints mit eigener Auth-Prüfung; kein `supabase/config.toml`. Kommentare beweisen verify_jwt nicht. | LIVE: nur Metadaten slug/version/status/verify_jwt aller Funktionen lesen, alte Endpoints einschließen. |
| B07 | Privilegierte Backend-Clients | TEILWEISE | P1 | CODE/TEST: privilegierte Chat-REST-Aufrufe ownergebunden (`coach-chat/handler.ts:1956,2028,2063`); keine geteilte Request-Identität gefunden. | Service-Rechte und bereitgestellte Handler/Grants nach M1/M2 abgleichen. |
| B08 | Serverseitige Eingabevalidierung | TEILWEISE | P2 | CODE/TEST: begrenzte Bodies/Normalisierung; fremde Privilegfelder ohne Rechtewirkung. S05 in Runde 2 durch Base64-/Containerprüfung vor bezahlter Analyse geschlossen. | Deployment S05; vollständige serverseitige Feld-/Grenzmatrix ergänzen. |
| B09 | SQL-/Shell-/Inhalt-Injection | TEILWEISE | P1 | CODE: keine Edge-Shell/eval-Senke; UUID-Prüfung vor PostgREST-Interpolation (`coach-chat/handler.ts:2334`); SQL durch DB-Prüfung ergänzt. | Restliche dynamische Abfragen und unerwartete SQL-Eingaben systematisch abdecken. |
| B10 | SSRF/externe Requests/Weiterleitungen | ERFÜLLT | P2 | CODE: untersuchte Edge-Requests verwenden feste OpenRouter-Ziele, Server-Supabase-URL und Bild-Data-URLs; kein frei abrufbares Client-/LLM-Ziel. | Externer Mirror/Importer liegt außerhalb Repo; dessen SSRF-Schutz ist NICHT PRÜFBAR. |
| B11 | Webhooks/Replay/Idempotenz | NICHT RELEVANT | P2 | CODE-Inventar: genau drei User-Endpoints, keine Webhook-/Zahlungsempfänger. | Bei zusätzlichem Deployment/Integration neu eröffnen; unbekannte Live-Endpoints siehe B06. |

### C. Login, Account-Schutz und Sessions

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| C01 | Registrierung/E-Mail/Passwortschutz | NICHT PRÜFBAR | P1 | CODE: Signup/OTP in `auth_repository.dart:184,284`; lokale Passwortregeln beweisen keine Auth-Serverpflicht. | M2: E-Mail-Bestätigung, Passwortregeln, Breached-Password-Schutz nur lesend kontrollieren. |
| C02 | Login-/Recovery-Missbrauch | NICHT PRÜFBAR | P1 | Historische Angaben in `supabase/AUTH_EMAIL_OTP.md:22`; keine CAPTCHA-Anbindung im untersuchten Client. | M2: aktuelle Auth-/SMTP-Limits/Botschutz; synthetische Enumerationtests im Testprojekt. |
| C03 | PKCE/Redirects/Magic-/Recovery-Links | TEILWEISE | P1 | CODE/TEST: `supabase_config.dart:134` bindet Callback an Scheme/Host und Code; keine Token-Query/-Fragments; PKCE sicher verdrahtet. | LIVE-Redirect-Allowlist/Mailtemplates und echte Google-/Browserrückkehr im Testprojekt. |
| C04 | Sessionablauf/Refresh/Logout/Sperren | TEILWEISE | P2 | CODE/TEST: SDK-Lebenszyklus und S03 in Runde 2 mit Neustart-/A/B-/Speicherfehlern geprüft. Lokaler Logout beweist keinen sofortigen JWT-Widerruf. | Gerätenachweis und tatsächliche JWT-Laufzeit/Refresh-Reuse/Kontosperre/Offline-Logout prüfen. |
| C05 | Reauthentifizierung sensibler Änderungen | TEILWEISE | P1 | CODE/TEST: `20260815120000_delete_account_reauth.sql:14` erzwingt frische OTP/recovery-AMR ≤5min; Löschsuite bestanden. | Livefunktion/Secure Email Change; dokumentierte 24h-Ausnahme der Passwort-Nonce separat bewerten. |
| C06 | MFA für Administration und App-Nutzer | NICHT PRÜFBAR | P1 | Kontoeinstellungen nicht eingesehen | MFA-/Teamrichtlinien ohne Recoverycodes dokumentieren |
| C07 | Accountverknüpfung/Wiederherstellung | TEILWEISE | P1 | CODE/TEST: `auth_session_mutation.dart:36` bindet asynchrone Mutation an Benutzer+Session; A→B-Fälle grün. Kein eigener Link-/Unlinkpfad. | Automatisches Provider-Linking und sichere E-Mail-Änderung im Testprojekt prüfen. |

### D. Dateien, Storage und Realtime

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| D01 | Private Dateien/Buckets | NICHT PRÜFBAR | P1 | CODE: keine Supabase-Storage-Nutzung; Bilder lokal (`recipe_image_store.dart:147,261`), AI-Fotos als Request. Live-Buckets unbekannt. | M3: Bucket-Metadaten lesen; unerwartete öffentliche Buckets verfolgen. |
| D02 | Storage-Policies für alle Operationen | NICHT PRÜFBAR | P1 | CODE: keine Storage-Policies/SDK-Operationen; Abwesenheit im Repo beweist keine leere Live-Installation. | M3: storage.objects-Policies/Grants lesen; bei Nutzung isolierte A/B-Matrix. |
| D03 | Signed URLs/Berechtigung/Laufzeit | NICHT RELEVANT | P2 | CODE-Inventar: keine Signed-Storage-URL-Erzeugung/-Weitergabe; lokale Bilder. | Bei unerwartetem Live-Storage oder neuer Funktion erneut prüfen. |
| D04 | Uploadgröße und tatsächlicher Dateityp | TEILWEISE | P2 | CODE/TEST: Client reencodiert; Server prüft Base64 und JPEG-/PNG-/WebP-Container vor Tages-/Globalkontingent, Runde 2/S05. | Deployment und erlaubte/unerlaubte Direktaufrufe im freigegebenen Testsystem; D05 bleibt getrennt. |
| D05 | Bildverarbeitung/Dimensionen/EXIF | TEILWEISE | P2 | CODE: EXIF-Entfernung `meal_photo_compressor.dart:67`, Decode vor Resize (:31/:55), Bilder ebenfalls Scrubbing; Direktaufruf umgeht Client. | Synthetische Header/Metadaten und Dekodierungs-/Dimensionsbudget vertiefen. |
| D06 | Postgres Changes vs. Broadcast/Presence | NICHT PRÜFBAR | P1 | CODE: keine Channels/Postgres Changes/Broadcast/Presence oder Publication-Migration; Live-Zustand unbekannt. | M3: Publications, realtime.messages-Policies und private Channel-Einstellungen lesen. |
| D07 | Private API-/Dateicaches | TEILWEISE | P1 | CODE/TEST: `local_cache.dart:244`, Cache-AAD `secure_cache_store.dart:152`, Bildscope `recipe_image_store.dart:147`; SSE no-store. | Gesamte Proxy-/CDN-Konfiguration und native A→B-Ausfall-/Neustartfälle prüfen. |

### E. Flutter und Endgerät

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| E01 | Tatsächliche sichere Tokenablage | TEILWEISE | P2 | CODE/TEST: sichere Session-/PKCE-Adapter tatsächlich am SDK; V3 und Runde 2/S03. Marker statt Wiederherstellung aus nicht löschbaren Bytes. | S03-Geräte-/Backup-/Neustartnachweis; kein Hardware-/Powerloss-Nachweis aus Stubs ableiten. |
| E02 | Lokale sensible Daten/Schlüsselschutz | TEILWEISE | P2 | CODE: AES-GCM-Cache ohne Klartextfallback (`local_cache.dart:244`); Bilder sind JPEG-Dateien in App-Documents (`recipe_image_store.dart:294`). | Dateiinventar inkl. Fototemps/Backups auf synthetischem Gerät; nicht alle Dateien als verschlüsselt bezeichnen. |
| E03 | Logout und Accountwechsel | TEILWEISE | P2 | CODE/TEST: Cache/Bilder nach Nutzer getrennt, Outbox bewusst pro UID erhalten. Runde 2/S03 ergänzt persistente Logout-Sperren und geordnete A/B-Speicherung. | Native Fehler-/Backup-/Neustartfälle und kompletter lokaler Datenbestand bei Accountwechsel. |
| E04 | Logs/Crash/Clipboard/Push/Vorschau/Backup | TEILWEISE | P2 | CODE/TEST: Sentry-Allowlist und expliziter Exportclipboard; Navigator-Vorschauschutz S04 in Runde 2 durchgehend verdrahtet und getestet. | Native Crash-Envelopes, App-Switcher/Screenshots und Backupinhalt mit synthetischen Daten prüfen. |
| E05 | TLS/Release-Zertifikatsprüfung | TEILWEISE | P2 | CODE-Suche: keine Zertifikats-Bypässe/Cleartext-/ATS-Ausnahmen; Mirror erzwingt HTTPS (`search_credentials.dart:67,232,644`). | Zusammengeführte Releasekonfiguration und Geräte-Netzwerkverkehr isoliert prüfen. |
| E06 | Deep Links/Intents/exportierte Komponenten | TEILWEISE | P2 | CODE/TEST: Callback-Prädikat und Route-Guard (`eatova_app.dart:119`); exportierte Callback-/HealthPrivacy-Activities zweckgebunden. | Installierte Manifest-/Entitlementwerte und direkte synthetische Intents prüfen. |
| E07 | WebViews und Bridges | NICHT RELEVANT | P2 | CODE-Inventar: kein eingebetteter JS-/Datei-WebView; OAuth nutzt Systembrowseroberfläche `LaunchMode.inAppBrowserView` (`auth_repository.dart:326`). | Bei Einführung eines eingebetteten WebView neu prüfen. |
| E08 | Minimale Plattformberechtigungen | TEILWEISE | P2 | CODE: Android READ_STEPS, entfernte unnötige Manifestextras; iOS HealthKit READ Schritte/READ_WRITE Gewicht (`apple_health_service.dart:160`). | Releaseberechtigungen sowie Verweigerung/Widerruf auf Android/iOS nachweisen. |
| E09 | Release-Signierung/Debug/Testkonfiguration | TEILWEISE | P2 | CODE: Debug-Preview nur Debug (`auth_repository.dart:698`); Android-Release blockiert fehlende Signingdatei (`build.gradle.kts:109`), R8 aktiv. | Tatsächlich ausgeliefertes APK/AAB/IPA auf Signatur, Debug, Endpoints und Assets prüfen. |

### F. Missbrauch, Rate Limits und AI-Kosten

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| F01 | Eigene API-/AI-Limits | TEILWEISE | P1 | CODE/TEST: Coach IP120/600s, Nutzer60/h (`coach-chat/handler.ts:2339`), Tagesclaim; Fotoanalyse besitzt User-/IP-/Tages-/Global-Gates. | LIVE: wirksame Overrides und direkte End-to-End-Ablehnungen prüfen. |
| F02 | Nutzer-/globale Budgets und neue Accounts | TEILWEISE | P1 | CODE: Coach5/Konto/UTC-Tag, keine eigene globale Coach-Budgetreservierung; Fotoanalyse global5000/Tag (`analyze-meal/handler.ts:145`). | M4: Provider-Geldlimit/Autoaufladung, Konto-/IP-Farmen und nicht erstattbares Spendbudget vertiefen. |
| F03 | Größen/Pagination/Kontext/Output/Parallelität | TEILWEISE | P2 | CODE/TEST: vorhandene Request-/Kontext-/Tokenlimits; Runde 2 ergänzt 512-KiB-Grenze erfolgreicher Coach-Textenvelopes/SSE, 8 MiB für Rezeptbildantworten. | Nicht erfolgreiche Providerkörper sowie globale Parallelität weiter prüfen; Header-Timeout allein begrenzt keine Bytes. |
| F04 | Kostenprüfung und Verbuchung vor Ausführung | TEILWEISE | P1 | CODE/TEST: Claim vor erstem Classifier (`coach-chat/handler.ts:2522`); ausgeschöpfte Quota ohne Providercall. Refund kann 5/Tag-Grenze wieder öffnen. | Nicht rückzahlbares Kostenbudget separat von Nutzerfragenlimit prüfen; LIVE-Budget M4. |
| F05 | Atomare Kontingente/Race Conditions | ERFÜLLT | P1 | CODE/TEST: V4, atomarer Claim, 10 parallel →5 erlaubt/5 abgewiesen; used=5. Refund-Untergrenze0, Clientzugriff gesperrt. | Keine per-Request-Refundidempotenz bewiesen; deployed Ledger/Grants und weiteren Retrypfad prüfen. |
| F06 | Timeouts/Retry-/Agenten-/Toolgrenzen | TEILWEISE | P2 | CODE/TEST: bestehende Provider-/DB-Zeitlimits; Runde 2 testet SSE-Abbruch vor/während Freigabe ohne Refund und mit lokalem Fetch-Abbruch. | Provider-Billingstopp ist nicht bewiesen und für Google laut OpenRouter nicht unterstützt; gesamte Verarbeitung pro Modus prüfen. |
| F07 | Alarme und serverseitige Notabschaltung | NICHT PRÜFBAR | P1 | Kein eigener AI-Abschaltflag gefunden; COACH_DAILY_LIMIT=0 fällt auf positiven Default zurück (`_shared/env.ts:42`). Externe Alarme/Key-Sperren unbekannt. | M4: Budget, Alarm und serverseitiges Deaktivierungsverfahren nachweisen. |

### G. AI-Coach und Guardrails

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| G01 | Pflichtschutz auf allen Endpoint-/Moduspfaden | TEILWEISE | P1 | CODE/TEST: gemeinsame Vorprüfung vor allen Modi; S01/S02 in Runde 2 korrigiert, Klassifikations- und Antwortabschlüsse fail closed. | Bereitgestellte Varianten/alte Endpoints sowie reine Bildanfragen und semantische Modellqualität nachweisen. |
| G02 | Direkte/indirekte Prompt Injection | TEILWEISE | P1 | CODE: gekappter User-Kontext `handler.ts:2429`, Prefilter `prefilter.ts:16`, TrainingContext zusätzlich klassifiziert (:2551). | Echte versionierte Modell-Eval direkter/indirekter, bildlicher, mehrstufiger Injection fehlt als Nachweis. |
| G03 | Vertrauenswürdige Rollen/Modellparameter | ERFÜLLT | P1 | CODE/TEST: Rollen/Modelle serverbestimmt (`handler.ts:604,622,626`); ownergebundene History-Rollenallowlist; manipulierte Bodyfelder ohne Wirkung V2. | Bei neuen Nachrichtentypen/Modelloptionen erneut prüfen; LIVE offen. |
| G04 | Keine Geheimnisse/unnötigen Daten im Kontext | TEILWEISE | P1 | CODE: Keys nur Authorization, keine Modellnachricht (`handler.ts:327,703`); Profil-/Tageskontext `home_store.dart:358`. | I02/I06: Notwendigkeit aller Kontextfelder und Providerretention prüfen. |
| G05 | Begrenzte Tool-Rechte | NICHT RELEVANT | P2 | CODE: kein LLM-Toolexecutor, SQL/Shell/URL-Tool; nur Nachrichten/Modellparameter (`handler.ts:621,1152,1461`). Bildgenerierung feste Serveraktion. | Bei Einführung von Tools/RAG neu eröffnen. |
| G06 | Datenrechte außerhalb des LLM | ERFÜLLT | P1 | CODE/TEST: Identität/Objektbesitz vor LLM, History/Sitzung doppelt gebunden; Modell kann keine Datenrechte vergeben, V1/V2. | Neue Modellaktionen erneut serverseitig autorisieren; kein Live-Beweis. |
| G07 | Geprüfte Ausgaben/Darstellung/Links/Bilder | TEILWEISE | P1 | CODE/TEST: Schema-/Typgrenzen und Textdarstellung vorhanden; S01 in Runde 2 blockiert gefilterte Antworten/Entwürfe vor Übergabe und Bildfolgeaufruf. | Schemas bis bestätigte Aktion und externe Medien vollständig prüfen; Deployment offen. |
| G08 | Nutzertrennung in Chat/Memory/Caches | TEILWEISE | P1 | CODE/TEST: owner+session-Filter `handler.ts:1956`, History-Rollenallowlist (:1982), Refusalpaare entfernt; kein RAG/Embedding-Antwortcache. | Lokale Chat-/Bild-Ausfallfälle und bereitgestellte Isolation ergänzen. |
| G09 | Echte Bestätigung folgenreicher Aktionen | TEILWEISE | P1 | CODE: Rezeptconfirm muss true sein (`coach_chat_screen.dart:1407`), Planeditor/onSave (:1342); Server speichert Vorschlag. | Aktuelle Bestätigungs-/Doppelklick-/Accountwechseltests dieses UI-Pfads noch offen. |
| G10 | Verhalten bei Schutz-/Providerfehlern | TEILWEISE | P1 | CODE/TEST: Runde 2 deckt Bild+Text-Parsefehler, fehlend/null/unerwarteten Abschluss, content_filter, Streamfehler/-abbruch und positive Fälle ab; S01/S02 korrigiert. | Echte versionierte Modell-Eval und Auth-/Provider-Ausfälle im freigegebenen Testsystem; keine semantische Garantie aus Stubs. |
| G11 | Sicherheit bereits ausgegebener Streamteile | TEILWEISE | P1 | CODE/TEST: Runde 2/S01/S06 hält die gesamte Antwort bis zur technischen Freigabe zurück; kein spekulativer Präfix und kein ungeprüfter Assistant-Teiltext im Verlauf. | Bereitgestellte Funktion und reales Modell-/Proxyverhalten im freigegebenen Testsystem nachweisen. |
| G12 | Adversariale und legitime Regressionstests | TEILWEISE | P1 | TEST: ursprüngliche 289 Coachtests plus dauerhaft aufgenommene Fehler-/Abschluss-/Abbruchregressionen der Runde 2; legitime Gegenproben bleiben grün. | Stubs beweisen Mechanik, keine semantische Robustheit. Versionierte adversariale Modell-Eval/fachliche Abnahme. |

### H. Fitness-spezifische Nutzersicherheit

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| H01 | Grenzen bei Diagnosen/Medikamenten/Heilung | TEILWEISE | P1 | CODE/TEST: Prefilter/Krisenkategorien und Refusaltexte; technische Ausfallpfade S01/S02 in Runde 2 geschlossen. | Fachlich geprüfte tatsächliche Antworten; Prompt/Disclaimer und technische Stubs sind kein klinischer Sicherheitsnachweis. |
| H02 | Fachlich geprüfte Risikosituationen | NICHT PRÜFBAR | P1 | Technische Tests vorhanden, keine belegte medizinisch/ernährungsfachlich freigegebene Risikomatrix. | Zuständige Fachprüfung, versionierte Fälle für Symptome/Verletzung/Essstörung/Extremziele. |
| H03 | Minderjährige und Einschränkungen | TEILWEISE | P1 | CODE: Alter16..100 (`20260807090000_profiles_age_minimum_16.sql:27`, `model_limits.dart:62`); Coach-Kontext ohne Altersband (`home_store.dart:358`). | Konzept für16-/17-Jährige und Einschränkungen fachlich prüfen; keine Rechtsverletzung daraus behaupten. |
| H04 | Plausible Profile und Empfehlungen | TEILWEISE | P1 | CODE: Profile-/Planvalidatoren für technische Wertebereiche; effektives Gewichtsziel (`home_store.dart:379`). | Medizinische Plausibilität von Zielen/Belastungen fachlich prüfen; technische Grenzen sind keine klinischen Grenzwerte. |

### I. Datenschutz und Gesundheitsdaten

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| I01 | Dateninventar inkl. Ableitungen und Empfänger | TEILWEISE | P1 | CODE: Exporttabellen `data_export.dart:43`, Coachkontext `home_store.dart:358`; Datenflussinventar oben und I-Details unten. | Betreiber-/Providerdaten, Logs und Aufbewahrung mit technischem Inventar abgleichen. |
| I02 | Datensparsamkeit AI/Analytics/Support | TEILWEISE | P1 | CODE: Gewicht/Ziel/Tagesbilanz und begrenzte Essensnamen, keine expliziten Namens-/E-Mailfelder; Sentry-Allowlist (`crash_reporter.dart:188,285`). | Synthetische Payloads je Modus/native Telemetrie erfassen; Notwendigkeit automatischer Körperdaten prüfen. |
| I03 | Einwilligungen und zutreffende Information | TEILWEISE | P1 | CODE/TEST: DE/EN-Infosheet korrigiert, vier tatsächliche Sheet-Regressionen. Öffentliche Website noch alt; verifizierter Einzeldatei-Patch vorbereitet, Runde 2/S07. | Website abgestimmt veröffentlichen; Live-Empfänger/Settings bestätigen; Rechtsgrundlagen/Einwilligung fachlich prüfen. |
| I04 | Vollständige Löschung/Anbieter/Backups | TEILWEISE | P1 | CODE/TEST: frische Reauth vor auth.users-Löschung, Cascades; lokale Bereinigung `home_store_sync.dart:1544`; A-Löschung/B-Erhalt lokal geprüft. | Vollständigkeit inkl neuer Domänen, Provider- und Backupfristen/Verfahren vertiefen. |
| I05 | Sicherer vollständiger Eigenexport | TEILWEISE | P1 | CODE: nutzergebundener Client+UID-Filter (`data_export.dart:160,189`); Kappung/Fehler sichtbar; explizite Clipboardaktion, kein verdrahtetes Filesharing. | Isolierter Export A/B und Accountwechsel während Export; Clipboard-/Bildschirmschutz. |
| I06 | Anbieter, Aufbewahrung, Orte, Verträge | NICHT PRÜFBAR | P1 | Keine aktuellen OpenRouter-Privacysettings, DPAs, Sentry-Retention, Regionen/DSFA; `PRIVACY.md:175,295,324` beschreibt Abhängigkeiten. | M5: Settings/Verträge, Retention/Training/Orte getrennt und fachlich prüfen. |

### J. Abos und Zahlungen, falls vorhanden

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| J01 | Serverseitig verifizierte Käufe | NICHT RELEVANT | P2 | CODE-Inventar: keine Kauf-/Abo-SDKs, Receipts, Entitlements oder Zahlungstabellen; AI-Providerkosten fallen unter F. | Bei Zahlungsintegration neu prüfen. |
| J02 | Geschützte Premium-/Credits-Freischaltung | NICHT RELEVANT | P2 | CODE-Inventar: keine Premium-/bezahlte Credits-Felder oder Freischaltung; Tagesquota ist F04/F05. | Bei Monetarisierung serverseitige Freischaltung prüfen. |
| J03 | Ablauf/Refund/Restore/Ereigniskonsistenz | NICHT RELEVANT | P2 | CODE-Inventar: keine Abo-, Kauf-Refund-/Restore-Ereignisse oder Zahlungswebhooks. | Bei Zahlungsintegration erneut prüfen. |
| J04 | Trials/Gutscheine/Empfehlungen/Guthaben | NICHT RELEVANT | P2 | CODE-Inventar: keine Trials/Gutscheine/Referrals/gekauftes Guthaben. | Neue Geschäftslogik und Parallelität dann gesondert prüfen. |

### K. Betrieb, Dependencies und Release

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| K01 | Getrennte Entwicklung/Test/Produktion | TEILWEISE | P1 | CODE/TEST: CI-Dummydefines `security.yml:39`, isolierter Postgres (:364), Deno ohne Netz (:290); aktuelle Audit-Isolation T1–T6. | Reale Dev/Stage/Prod- und Secretmanager-Zuordnung nur lesend nachweisen. |
| K02 | Infrastruktur-/CI-Rechte, MFA, DB-Netz/TLS | NICHT PRÜFBAR | P1 | CODE: CI contents:read, SHA-Pins, joblokales SARIF-Schreibrecht; main/environment für Drift. Tatsächliche Team-/Netzrechte unbekannt. | M5: Rollen/MFA, Branch-/Environment-Regeln, Datenbank-TLS/Netzbeschränkungen lesen. |
| K03 | Bekannte Schwachstellen der Abhängigkeiten | TEILWEISE | P2 | TEST: OSV API1.0,153 Pub+9 öffentliche native Revisionen =162 Ergebnisse ohne Advisory-Treffer; T6. | Native Android-Auflösung/SBOM und Wartungszustand ergänzen; fehlender Treffer ist keine Vollgarantie. |
| K04 | Secret-/statische-/RLS-Prüfungen in CI | TEILWEISE | P1 | CODE/TEST: strikte Flutter-/Deno-/RLS-, Secret- und Dependency-CI. Runde 2 liest acht bindende GitHub-Checks samt enforce_admins; Codeprüfung folgt geschützt über PR. | Grüne CI des konkreten PR-Heads dokumentieren; Migrationsnummerncheck ersetzt keinen Live-Policyabgleich. |
| K05 | DB-/Storage-Backup und Restore-Nachweis | NICHT PRÜFBAR | P1 | Kein aktuelles Restoreprotokoll | Isolierte Wiederherstellung mit synthetischen Daten planen |
| K06 | Nachvollziehbare, sparsame Sicherheitslogs | TEILWEISE | P1 | CODE: technische Rate-/Fehlerlogs, z. B. `analyze-meal/handler.ts:409`, Provider-Metadatenallowlist `_shared/provider_log.ts:35`; Sentryfilter. | LIVE: Admin-/Berechtigungs-Auditlogs, Zugriffsrechte/Retention; synthetische Logkontrolle. |
| K07 | Alarme für Kosten/Fehler/Datenmissbrauch | NICHT PRÜFBAR | P1 | Keine Alarmkonfiguration eingesehen | Alarmregeln, Zuständigkeit und Testnachweis |
| K08 | Rotation/Sperre/Rollback/Notabschaltung | TEILWEISE | P1 | CODE/DOKU: `SECURITY.md:13`, Such-Key-Sentinel disabled (`search-key/index.ts:25`); kein vollständiger Incident-/Rollback-/Restoreablauf nachgewiesen. | M4/M5: Rotation, Sperre, serverseitiger AI-Stopp, Rollback und Verantwortliche dokumentiert nachweisen. |

### L. Web-Version und zusätzliche Härtung

| ID | Prüfpunkt | Status | Priorität | Nachweis | Nächster Schritt |
| --- | --- | --- | --- | --- | --- |
| L01 | Flutter Web/XSS/CSP/Browser-Tokenablage | NICHT RELEVANT | P2 | CODE-Inventar: kein web/-Projekt oder Flutter-Webrelease; nur Android/iOS. Transitive Webpakete sind kein Webclient. | Bei Webrelease CSP/XSS/Browserstorage neu prüfen; Marketingwebsite getrennt. |
| L02 | CORS und gegebenenfalls Cookie-CSRF | TEILWEISE | P2 | CODE: exakter EATOVA_ALLOWED_ORIGINS-Match, Vary:Origin, kein Credential-CORS; Bearer statt eigener Cookieauth (`coach-chat/handler.ts:195`). | Isolierte Origin-Matrix und LIVE-Allowlist; CORS nie als Auth bewerten. |
| L03 | Certificate Pinning nach Bedrohungsmodell | OFFEN | P2 | Keine Pinningimplementierung gefunden; das ist keine nachgewiesene Pflichtlücke. | Bedrohungsmodell sowie Zertifikatswechsel/Ausfallkosten bewerten. |
| L04 | Geräteintegrität/Attestation | OFFEN | P2 | Keine eigene Attestation-Durchsetzung gefunden; transitive app-check-Abhängigkeit beweist sie nicht. | Konkreten Missbrauchsnutzen und Gerätekompatibilität bewerten; Backend bleibt maßgeblich. |
| L05 | Obfuscation | TEILWEISE | P2 | CODE: Android R8/Resource Shrinking (`build.gradle.kts:74`, CI:182); kein Dart --obfuscate im geprüften Workflow. | Optional nach Bedrohungsmodell; kein Ersatz für Autorisierung oder Secretschutz. |

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
