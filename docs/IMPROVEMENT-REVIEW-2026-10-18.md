# Eatova – Verbesserungs-Review mit zwei Agenten

> Historical record: statements and open items below describe the dated
> source, not the current product. See the [current feature inventory](FEATURES.md)
> and [documentation index](README.md) for implemented behavior.

Stand: 2026-10-18, geprüfter Code `5ff0958a` (main nach #152 und #153).
Zwei Subagents prüften nur lesend: einer Produkt und Nutzererlebnis, einer
Technik, Backend und Release. Die Hauptinstanz glich die tragenden Belege
stichprobenartig im Code ab. Keine App-Flows, Tests, CI-Läufe oder Live-Systeme;
eine Websuche zu Apples KI-Regeln. Die Reihenfolge ist eine Empfehlung, kein
Umsetzungsauftrag. Wasser, Schlaf und Habits bleiben entfernt, das Kalorienmodell
bleibt, Features mit dünner Datenlage werden vorher gemessen.

## Was seit dem 2026-10-10 erledigt ist

Aus der [Feature-Lücken-Review](FEATURE-REVIEW-2026-10-10.md) sind E2
(Mahlzeit beschreiben, #146) und die Health-Messzeit (`77575f2b`) erledigt,
P2 (Vorrat) teilweise durch den Wochen-Einkaufszettel (#152). Aus dem
Zehn-Agenten-Review vom 2026-10-11 sind REC-3, BE-2 und COACH-4 in #153 umgesetzt.
Alle übrigen P1-Punkte sind offen, ebenso F8, F9 und der unbekannte Barcode.

## Empfohlene Reihenfolge

### 1. Vor dem Store-Start

| Punkt | Umfang | Beleg |
| --- | --- | --- |
| KI-Einwilligung pro Konto vor dem ersten Scan, Beschreiben, Coach oder Import, widerrufbar; „Antwort melden“ am Coach (R2) | S–M | Das Beschreiben-Blatt nennt die KI gar nicht: „Eatova sucht die Nährwerte dazu“ ([ARB](../lib/l10n/app_de.arb#L3360)). Apple verlangt seit 11/2025 eine ausdrückliche Erlaubnis für Drittanbieter-KI. |
| Sign in with Apple, Apple-Token bei Kontolöschung widerrufen (R1) | M | Nur `_GoogleButton` ([Auth](../lib/src/screens/auth_screen.dart#L345)); kein Apple-Eintrag in `Runner.entitlements`. |
| Release-Lane: signiertes AAB in den Play Internal Track, später TestFlight, Git-Tag pro Build | M | Kein Store-Upload in `.github/workflows`, keine Tags; Buildnummer nur über `device_build.py`. |
| Abmelden im Onboarding (AUTH-3) | S | Abmelden nur in den Einstellungen; über den vorhandenen `signOutCleanup`-Pfad. |

### 2. Bindung rund ums Kalorienmodell

- **Wiegen und Wochen-Check sichtbar machen (neu, C1).** Der Check braucht
  14 erfasste Tage aus 21 und 4 Wiegetage über 14 Tage
  ([Energy Check](../lib/src/services/energy_check.dart#L51)) und erscheint
  sonst still nicht; „Gewicht loggen“ gibt es nur im Profil. Vorschlag:
  Gewichts-Chip auf Today, Fortschrittszeile („Wochen-Check in 5 Tagen, noch 2
  Wiegungen“), montags ein Rückblick auch ohne Anpassungsvorschlag.
- **Erinnerungen auffindbar und mit Uhrzeit (C4).** Fest 20 Uhr
  ([Planer](../lib/src/services/streak_reminder_planner.dart#L12)), der einzige
  Schalter liegt in „Profil & Ziele“. Vorschlag: nach dem zweiten erfassten Tag
  eine Karte „Soll ich dich erinnern?“ mit Uhrzeit, eigene Zeile in den
  Einstellungen, optional Wiege-Erinnerung; alles weiter lokal.
- **Gewichtseinträge korrigieren (T2-Rest).** Ein Tippfehler geht sofort nach
  Apple Health; Android liest kein Gewicht.

### 3. Schneller erfassen

- **Mahlzeiten kopieren (E1):** „Gestern wiederholen“ pro Slot, „Kopieren
  nach …“ im Bearbeiten-Blatt. Heute kann Wischen nur löschen.
- **Eigene Historie durchsuchen (E3):** nur 5 Zuletzt-Einträge
  (`_maxAutoRecents`, [Store](../lib/src/app/home_store_meals.dart#L376));
  die Suche fragt nur die Produktdatenbank.
- **Schnell-Eintrag mit Gesamt-kcal (E4):** heute nur pro 100 g; ohne KI-Kontingent und offline.
- **Unbekannten Barcode merken (E5) zusammen mit FOOD-6:** den Code an die
  manuelle Eingabe übergeben, beim Scan und bei der Eingabe auf GTIN-13
  normalisieren, Favoriten über beide Formen finden statt `favorite_key` zu migrieren.

### 4. Coach

- **Vorlieben, Unverträglichkeiten, Ernährungsform ändern (C3, F8)** und ein
  7-Tage-Kontext mit Gewichtsrate (C2). Heute bekommt der Coach nur den
  heutigen Tag, `/recipe` keine Ernährungsform; das Onboarding verspricht eine
  spätere Änderung, die es nicht gibt. Als „berücksichtigt, nicht garantiert“
  kennzeichnen, Datenschutzerklärung anpassen.
- **PERF-5:** `ensureSession` und `loadHistory` bei bekannter Session parallel (S).
- **PERF-4 (Owner-Entscheid):** Deltas schon vor dem finalen Safety-Verdikt
  senden und bei Refusal zurückziehen; der Client behandelt Deltas bereits als
  Vorschau. Sonst bringt Streaming keine schnellere erste Antwort.
- **Coach-Diktat auf Android (neu, P3):** Der Composer lädt Diktat nur auf iOS;
  das Beschreiben-Blatt hat den Android-Weg schon.

### 5. Technisches Fundament

| Punkt | Prio | Umfang | Beleg und Vorschlag |
| --- | --- | --- | --- |
| AI-Telemetrie pro Aufruf und zwei Alerts | P1 | M | `coach-chat` loggt `usage` nie, `analyze-meal` nur im Fehlerpfad (`loggableUsage`, [normalize](../supabase/functions/analyze-meal/normalize.ts#L383)). Ob der Prompt-Cache-Breakpoint ([claude.ts](../supabase/functions/_shared/claude.ts#L46)) bei dünnem Traffic je gelesen wird, ist unbekannt. Eine JSON-Zeile ohne Inhalte (Route, Status, Latenz, Input/Output/Cache-Tokens, Effort, `finish_reason`, Refund); Alerts für 5xx-Rate und Budget bei 80 %. Liefert auch die Daten für BE-3 und die Haiku-Frage. |
| Deploy-Workflow für Functions und Migrationen | P1 | M | Heute manuell von Windows (CRLF-Uploads, ein unprotokollierter Redeploy). `workflow_dispatch` auf `main` mit Environment-Freigabe, danach automatisch Live-Quelle vergleichen, Boot-Probe, Deploy-Record; Rollback = alter SHA. |
| Gemeinsame Edge-Module | P1 | M | `consume_edge_rate_limits` wird in allen vier Functions eigenständig aufgerufen, CORS und Fehlerhelfer mehrfach. `_shared/rate_limit.ts`, `_shared/http.ts`; `coach-chat/handler.ts` (3.156 Zeilen) in Session/History, Quote und Stream teilen. |
| Coach-Zustand in einen Controller | P1 | L | `_CoachChatScreenState` ab [Zeile 180](../lib/src/screens/coach/coach_chat_screen.dart#L180) bis fast zum Dateiende (3.470 Zeilen), 64 `setState`; vier Coach-Zustandsbugs am 2026-10-11. Ein `CoachController` für Sessions, Senden, Warten und Quote. |
| Client-Version-Handshake | P2 | S–M | Clients senden keine Build-Nummer; Liefer-Reihenfolgen werden von Hand eingehalten. Header plus `min_supported_build` und Update-Hinweis. |
| Typisierter Selector für die Shell | P2 | M | `eatova_home_page.dart` (1.772 Zeilen) ist die meistgeänderte Datei und blockiert parallele Arbeit; Builder lesen trotz Selector den Store direkt. |
| Async-Lints | P2 | S–M | `unawaited_futures` 24 und `discarded_futures` 89 Verstöße laut [analysis_options](../analysis_options.yaml#L65); erst die 13 Stellen in `lib/` beheben, dann `unawaited_futures` scharf schalten. |
| Receipt-Kontingent beobachten | P3 | S, später L | 100.000 permanente Receipts pro Konto, am Limit stoppt `PT507` jeden Sync ([Offline Sync](OFFLINE_SYNC.md)). Erst eine Metrik bei 50 %, später ein Prune-Fence. |

### 6. Tests und CI

- **Flakiness-Klassen:** `DateTime.now()` in 48 Testdateien, Wall-Clock-Grenzen
  von 20 ms, echte 2-s-Wartezeiten. Eine Repo-Regel gegen `DateTime.now()` in
  `test/` mit Allowlist, Zeitmessung über eine injizierte Uhr.
- **Ordnung:** 81 von 722 Testdateien sind nach Review-Runden benannt
  (`fixlauf_*`, `review_31/`). Mechanisch nach `test/<feature>/` verschieben,
  deutsche Namen bleiben. `tool/flutter_ci_timings.json` vom 2026-09-27 neu
  erzeugen; `training_store_test.dart` mit 276 s profilieren (Ursache nicht verifiziert).
- **CI:** `security.yml` ohne Workflow-`concurrency`, `pub-outdated` bei jedem
  PR, doppelter Android-Compile. Die Coverage-Untergrenze steht bei 88 %,
  erreicht werden 97 %; auf 95 % anheben.

## Quick Wins (je höchstens ein Tag)

- Deutsche Begriffe vereinheitlichen: „Carbs“ ([ARB](../lib/l10n/app_de.arb#L328))
  gegen „KH“, „Streak“ gegen „Serie“, „Log/geloggt“ und „Tracker“ gegen
  „Tagebuch“ (DSB-10). Der Tab „Food“ ist Owner-Entscheid.
- 24-h-Zeiten im englischen Trainingsverlauf (DSB-12): `DateFormat.jm` oder
  `alwaysUse24HourFormatOf`.
- Export als Datei teilen (F9): Die Einstellungen übergeben `dateiTeilen` nie
  ([Einstellungen](../lib/src/screens/settings/settings_screen.dart#L453));
  braucht ein Share-Paket.
- Einkaufsliste und Rezept als Text in die Zwischenablage (erster Schritt zu P3).
- Coach-Limit mit lokaler Uhrzeit statt „Mitternacht (UTC)“.
- Sichtbarer „Verlauf ›“-Hinweis zu den Trends auf der Food-Tageskarte.
- Feedback- und Supportzeile (`mailto`) in den Einstellungen; deckt „KI-Antwort
  melden“ vorläufig ab.
- Kategorien für eigene Rezepte wählbar machen.
- FOOD-7 (Recent nach Umportionieren) und TRN-9 (Trends überlagern Outbox-Tage)
  sind kleine Store-Änderungen.
- SYNC-5: 2xx-Antworten ohne JSON (Captive Portal) nicht gegen das
  Acht-Versuche-Budget zählen; zusammen mit der 5xx-Entscheidung.
- `PROJECT_HANDOFF.md` (3.732 Zeilen) in einen aktuellen Stand und ein
  datiertes Archiv teilen.

## Bewusst nicht empfohlen

- Preise im Einkauf und Sortierung nach Gang: Für Deutschland gibt es keine
  dichteren offenen Daten als Open Prices.
- Instagram-Import (fragil, rechtlich heikel); wenn mehr Quellen, dann
  Rezeptseiten mit schema.org und SSRF-Schutz (P8).
- Gemeinsame Einkaufsliste: widerspricht dem RLS-Modell pro Konto; Text teilen reicht.
- Mehr Coach-Fragen ohne Abo (R3), Widgets, Watch, imperiale Einheiten und
  weitere Sprachen vor dem DACH-Start.
- 55 Migrationen zusammenfassen: Der Drift-Job vergleicht Versionen mit live,
  das Replay dauert Sekunden.
- State-Library wechseln oder HomeStore aufteilen; Anthropic-SDK statt `fetch`;
  Klassifikator auf Haiku, solange keine Telemetrie vorliegt; natives
  Kompressions-Plugin; AES-Fallback, DATA-7 und `list_chat_sessions` bleiben.

## Nicht geprüft

Echte Flows auf Geräten, Nutzungsdaten, Store-Konsolen, Live-Stand von
Migrationen und Functions, echte CI-Laufzeiten, Supabase-Plan und Log-Retention.
„Pflicht nach Guideline 4.8“ ist eine Auslegung, keine Apple-Aussage.
