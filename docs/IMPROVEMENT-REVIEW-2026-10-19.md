# Eatova – Was die App noch braucht (zwei Agenten)

> Historical record: statements and open items below describe the dated
> source, not the current product. See the [current feature inventory](FEATURES.md)
> and [documentation index](README.md) for implemented behavior.

Stand: 2026-10-19, geprüfter Code `aa41c34e` (main nach #155 und #157).
Zwei Subagents prüften nur lesend: einer Produkt, Nutzererlebnis und Bindung,
einer Technik, Backend, Release, Datenschutz und Betrieb. Die Hauptinstanz hat
die tragenden Belege im Code nachgelesen (Einwilligung, Neuinstallation,
Export, KI-Kontingent, Rezeptfilter, Import, Serie, Trends-Paging). Keine
App-Flows, Tests, CI-Läufe oder Live-Abfragen. Baut auf der
[Review vom Vortag](IMPROVEMENT-REVIEW-2026-10-18.md) auf; deren Blöcke 2–6
sind mit #155 gebaut, Block 1 nicht. Die Reihenfolge ist eine Empfehlung,
kein Umsetzungsauftrag. Wasser, Schlaf und Habits bleiben entfernt, das
Kalorienmodell bleibt, Funktionen mit dünner Datenlage werden vorher gemessen.

## 1. Vor dem Store-Start

| Punkt | Prio | Umfang | Beleg und Vorschlag |
| --- | --- | --- | --- |
| **KI- und Gesundheitsdaten-Einwilligung, „Antwort melden“** (beide Agenten) | P1 | S–M | Die Datenschutzerklärung nennt als Rechtsgrundlage „the permission you grant in-app (Art. 6(1)(a), Art. 9)“ ([PRIVACY](../PRIVACY.md#L319)), in `lib/src` gibt es aber keine Einwilligung außer dem Anmelde-Hinweis. #155 schickt zusätzlich Unverträglichkeiten (laut Migration Art.-9-Daten) und sieben Tage Kontext an Anthropic; `PRIVACY.md` nennt beides nicht. Coach-Antworten sind nur eine `SelectionArea` ([Liste](../lib/src/screens/coach/coach_message_list.dart#L392)), ohne Melden; Google Play verlangt das für KI-Chats. Vorschlag: versionierte Einwilligung pro Konto vor der ersten KI-Nutzung (Anthropic, USA, was gesendet wird), eigenes Häkchen für Gesundheitsdaten, Widerruf unter Einstellungen → „KI & Daten“; „Antwort melden“ per Long-Press (Nachrichten-ID und Grund, kein Inhalt), bis dahin eine `mailto`-Zeile. Danach `PRIVACY.md`, Website und Health-Connect-Begründung angleichen. |
| **Release-Lane mit stabiler Buildnummer** | P1 | M | `pubspec.yaml` steht auf `1.1.0+4`, `device_build.py` nimmt die Commit-Anzahl (heute 401), `DEVELOPMENT.md` beschreibt noch ein einfaches `flutter build appbundle` – ein solcher Build wäre nach einem 401-Upload für Play zu niedrig. Keine Git-Tags, kein Upload von R8-Mapping oder dSYM; ohne `SENTRY_DSN` ist Crash-Reporting still aus. `Info.plist`/`pubspec` gehen vom kostenlosen Apple-Team aus: TestFlight und Sign in with Apple brauchen das bezahlte Programm (Owner-Entscheid). Vorschlag: `release.yml` nur auf `main` in einer geschützten Umgebung, Buildnummer = Commit-Anzahl von `main`, Tag `v<name>+<n>`, signiertes AAB in den Internal Track, Symbole hochladen, ohne DSN abbrechen; ein erster TestFlight-Upload von Hand. |
| **Backups und Plan** | P1 | S–M | Laut Handoff (2026-09-15) kein abgeschlossener Recovery-Point, PITR aus; das Speicherbudget pro Konto ([Vorschlag D1](STORAGE-BUDGET-PROPOSAL-2026-10-04.md)) ist nicht umgesetzt. Auf dem Free-Plan kann ein Konto das Projekt über 500 MB und damit für alle in den Nur-Lese-Modus bringen. Vorschlag: Plan vor dem Start festlegen; auf Free ein geplanter, verschlüsselter `pg_dump` außer Haus und eine Warnung bei 70 % Plattenbelegung. Live-Stand prüfen. |
| Sign in with Apple, Apple-Token bei Löschung widerrufen | P1 (iOS) | M | Unverändert offen; hängt am Apple-Programm oben. |
| Abmelden im Onboarding (AUTH-3) | P2 | S | `onboarding_chrome.dart` hat nur einen Zurück-Knopf. |

## 2. Sofort, weil Daten oder Vertrauen leiden

- **Jede Geräte-Installation löscht die App-Daten (neu, P2, S).**
  [`device_build.py`](../scripts/operations/device_build.py#L90) ruft
  `flutter install --release` auf; Flutter 3.47.2 deinstalliert dabei standardmäßig
  zuerst die alte Version (`installApp(..., uninstall = true)`). Damit gehen
  ungesendete Outbox-Einträge, der verschlüsselte Cache, Erinnerungen und
  Health-Connect-Freigaben verloren, und der echte Update-Pfad (alter Cache,
  neuer Build) läuft nie auf einem Gerät. Vorschlag: `adb install -r` bzw.
  `xcrun devicectl device install app`; „Update über den vorigen Build mit
  offenem Outbox-Eintrag“ in die Geräte-Checks aufnehmen.
- **Was der Nutzer meidet, ignorieren alle Rezeptvorschläge (neu, P1, S–M).**
  Today-Tipp, „Für dich“ und „Passt zu deinem Ziel“ filtern nur nach
  Ernährungsform ([Store](../lib/src/app/home_store_derivations.dart#L51));
  `foodAvoidances` erreicht nur den Coach. Das Blatt verspricht „Für passende
  Rezepte …“ ([ARB](../lib/l10n/app_de.arb#L3518)). Wer „Fisch“ oder „Nüsse“
  wählt, bekommt trotzdem Lachs als Abendessen-Tipp; bei Allergien ein
  Sicherheitsthema. Vorschlag: die Katalogrezepte mit den 13 Codes taggen,
  Vorschläge so filtern wie `matchesDiet`, in „Alle Rezepte“ ein Hinweis-Chip
  statt Ausblenden.
- **Rezept-Import verspricht Websites, kann aber nur TikTok-Links (P1 Text,
  P2 Funktion).** „Von einer Website, aus einer Videobeschreibung oder als
  Text“ ([ARB](../lib/l10n/app_de.arb#L3290)); Server und Client akzeptieren
  nur TikTok-Hosts ([source.ts](../supabase/functions/recipe-import/source.ts#L19)).
  Ein Chefkoch-Link scheitert mit TikTok-Wortlaut. Jetzt: Text ändern und eine
  klare Meldung für andere Links. Später schema.org-Rezeptseiten mit SSRF-Schutz
  (P8), vorher messen, wie viele der großen DACH-Rezeptseiten die Daten liefern.
- **Export kappt alle Abschnitte außer dem Tagebuch bei 1.000 Zeilen (P2, S).**
  Jeder Abschnitt ist eine Seite mit `limit(10000)`
  ([Export](../lib/src/services/data_export.dart#L212)), live liefert PostgREST
  höchstens 1.000. Der Export markiert das ehrlich als `gekappt`, ist aber bei
  aktiven Coach-Nutzern nach rund 100 Tagen dauerhaft unvollständig. Vorschlag:
  Keyset-Paging wie `_alleLoggedMeals` für alle Abschnitte.
- `docs/FEATURES.md` sagte noch, es gebe keinen späteren Ernährungsform-Editor;
  seit #155 gibt es ihn (in diesem PR korrigiert).

## 3. Bindung rund ums Kalorienmodell

- **Eine Regel für „vollständiger Tag“ (P2, M).** Die Serie zählt ab einer
  Mahlzeit, die Trends mitteln über jeden Tag mit Eintrag, der Wochen-Check
  verlangt 50 % des Ziels ([Energy Check](../lib/src/services/energy_check.dart#L111)).
  Die Erinnerung entfällt, sobald irgendetwas eingetragen ist
  ([Planer](../lib/src/services/streak_reminder_planner.dart#L66)). Folge: 30 Tage
  Serie, während Today „noch 4 Tage eintragen“ sagt; halbe Tage ziehen die
  Trend-Mittel nach unten. Vorschlag: die Regel des Wochen-Checks überall,
  Trends mitteln nur vollständige Tage und nennen die ausgelassenen, die
  Erinnerung fragt bei unter 50 % nach („Heute erst 640 kcal – fehlt noch was?“).
- **Wochen-Check erklären und ein Ergebnis zeigen (P2, S–M).** Mit genug Daten
  und ohne Vorschlag bleibt nur „Wochen-Check aktiv · deine Daten reichen“
  ([Today](../lib/src/screens/today/today_weigh.dart#L22)), nicht antippbar.
  Vorschlag: Zeile öffnet eine kurze Erklärung; wöchentlich eine Ergebniskarte
  („Verbrauch ≈ 2.350 kcal – Ziel passt · −0,4 kg/Woche, Plan −0,5“); ein Satz
  zum Wochen-Check und zum Wiegen im Onboarding.
- **Wiegungen korrigieren, Waagen-Daten übernehmen (P2, M).** Kein Bearbeiten,
  Löschen oder Datum; das Onboarding-Gewicht wird keine Wiegung; Android liest
  kein Gewicht, iOS bietet nur den letzten Wert an, obwohl der Health-Text
  „automatisch aktuell“ verspricht. Vorschlag: Wiege-Liste mit Bearbeiten und
  Datum, Import aller Waagenwerte seit dem letzten Öffnen nach einmaligem
  Opt-in, optionale Wiege-Erinnerung.
- **Gestern nachtragen rettet die Serie nicht (P2, S).** Rückdatierte Einträge
  verlängern die Serie bewusst nicht
  ([LifetimeStats](../lib/src/models/lifetime_stats.dart#L85)). Vorschlag: ein
  nachgetragenes Gestern zählt, wenn die Kette am Vortag endete; Today weist vor
  dem ersten Eintrag auf ein leeres Gestern hin.

## 4. Schneller erfassen und planen

- **Leere Produktsuche → „Beschreiben“ (P2, S).** Heute nur „Manuell eintragen“
  pro 100 g ([Sheet](../lib/src/widgets/kcal/add_meal_sheet.dart#L1459)); ein
  Knopf öffnet das Beschreiben-Blatt mit dem Suchtext.
- **Speiseplan als Tagesplanung (P2, S–M).** Tagessumme gegen das Ziel,
  „Zum Speiseplan“ im Rezeptdetail, „An dem Tag eintragen“ für vergangene Tage
  (Owner-Entscheid vom 2026-10-10 offen).
- **Teilen und Support (P2, S).** Einkaufsliste und Rezept als Text teilen,
  Export als JSON-Datei (F9), Zeile „Feedback & Support“ mit Version und Build.
- **Portionen als Packung/Stück (P2, M).** Chips aus den Open-Food-Facts-Feldern
  für Portion und Packung; vorher messen, wie viele geloggte Produkte sie haben.
- **Health-Abfrage auf iOS beim Onboarding (P2, S, am Gerät prüfen).**
  `connectHealth()` läuft nach dem ersten Frame, auch wenn die Seite gerade das
  Onboarding zeigt ([Shell](../lib/src/app/eatova_home_page.dart#L212)).
  Vorschlag: erst nach dem Onboarding hinter einer kurzen Erklärkarte fragen.
- **Trainings-Rekorde zeigen (P3, M).** Das beste geschätzte 1RM pro Übung wird
  berechnet, die UI zeigt nur „2 Rekorde“; Verlauf pro Übung und ein Badge im
  Abschluss-Blatt.

## 5. Betrieb und Technik

| Punkt | Prio | Umfang | Beleg und Vorschlag |
| --- | --- | --- | --- |
| Alerts | P2 | S–M | [OPERATIONS](OPERATIONS.md#L223) sagt selbst, dass keiner eingerichtet ist. Das globale KI-Kontingent hat den Standard 1.000 Aufrufe pro Tag für alle ([Migration](../supabase/migrations/20260915091000_ai_provider_budgets.sql#L8), Live-Wert nicht geprüft); eine Coach-Frage reserviert laut Agent zwei. Ist es erschöpft, merkt das niemand bis 00:00 UTC. `ai_call`-Zeilen verschwinden mit der Log-Retention. Vorschlag: stündliches `ops-watch.yml` in geschützter Umgebung (`readiness.py --budget-warning-percent 80`, Boot-Probe ohne bezahlte Aufrufe, 5xx-Abfrage), GitHub-Mail bei Fehlschlag, tägliche `ai_call`-Summe als Artefakt. |
| Leitplanken im Deploy-Workflow | P2 | S | Migrationen sind ausgenommen, jeder Vorfahr von `main` gilt als Rollback. Eine Function ohne ihre Live-Migration liefert RPC-5xx; ein Rollback unter `a3a7263b` lässt `coach-chat` neue Clients mit `preferences` per 400 abweisen. Vorschlag: vor dem Deploy die Drift-Abfrage aus `security.yml` gegen den Ziel-SHA, pro Function ein niedrigster sicherer Rollback-SHA. |
| Schritt-Nachladen für sechs Monate | P3 | S | Bis zu 181 Einzeltage nacheinander, jeder mit eigenem `_mutate` und vollem verschlüsselten Cache-Write; ohne Verlaufsberechtigung liefert Health Connect über ~30 Tage ohnehin nichts. Vorschlag: auf Android 30 Tage, Ergebnisse in einem Schritt speichern, Overlay memoisieren. Am Gerät profilieren. |
| Trends-Paging bricht bei kurzer Seite ab | P3 | S | [trend_service](../lib/src/services/trend_service.dart#L92) stoppt bei weniger als 1.000 Zeilen; wird `max_rows` live gesenkt, kommt die stille Kürzung zurück. Erst bei leerer Seite stoppen. |
| Google-Freigabe nie widerrufen | P3 | S | Kein `disconnect()` nach Kontolöschung, kein `signOut()` beim Abmelden. |
| Berechtigungen im gemergten Manifest | P3 | S | Der Test prüft nur das Quell-Manifest; Play-Data-Safety muss zum gemergten passen. CI-Abgleich des Release-AAB mit einer Allowlist. |

## Stand der offenen Punkte vom 2026-10-18

| Punkt | Stand |
| --- | --- |
| KI-Einwilligung, Melden, Sign in with Apple, Release-Lane, AUTH-3 | offen (oben) |
| Wochen-Rückblick ohne Vorschlag, Wiege-Erinnerung, Wiegungen korrigieren | offen (Abschnitt 3) |
| AI-Telemetrie und Alerts | teilweise: `ai_call` gebaut, keine Alerts |
| Deploy-Workflow | teilweise: nur Functions, erster echter Lauf steht aus |
| Gemeinsame Edge-Module | teilweise: `rate_limit.ts`/`http.ts` da, `coach-chat/handler.ts` weiter 3.165 Zeilen |
| Coach-Controller, Wall-Clock-Regel, Testordner, 95-%-Untergrenze | erledigt |
| Client-Version-Handshake, typisierter Shell-Selector (Datei jetzt 1.960 Zeilen), Async-Lints, Receipt-Metrik | offen |
| CI: `security.yml`-Concurrency, `pub-outdated` pro PR, doppelter Android-Compile | offen |
| SYNC-5 | offen |
| Deutsche Begriffe (Carbs/KH, Streak/Serie, Ausloggen/Abmelden, Tracker) | offen |
| 24-h-Zeiten im englischen Trainingsverlauf | offen (`DateFormat.Hm`) |
| Export als Datei, Einkaufsliste/Rezept als Text, Support-Zeile | offen (Abschnitt 4) |
| Coach-Limit in lokaler Zeit | offen; „Morgen geht's weiter“ ist zwischen 00:00 und 01:59 Ortszeit falsch |
| Kategorien für eigene Rezepte | offen (immer „Eigene“) |
| FOOD-7 | vermutlich offen (`updateLoggedMealDetails` schreibt kein Recent) |
| TRN-9 | auf der Trends-Seite erledigt (#157) |
| Coach-Diktat auf Android | offen (Composer nur iOS) |
| Handoff teilen | offen (3.900 Zeilen) |

## Bewusst nicht empfohlen

- Fasten-Timer: ein Habit-Tracker wie die entfernten, speist das Trend-Modell nicht.
- Zucker, Ballaststoffe, Salz jetzt: Schema-, Sync- und Exportänderung bei
  schwachen KI-Schätzungen; erst die Abdeckung in Open Food Facts messen.
- Generische Lebensmitteldatenbank (BLS): lizenzpflichtig; „Beschreiben“ aus
  der leeren Suche deckt Hausmannskost ab. Erst leere Suchen zählen.
- Abzeichen: Serien-Nachtrag und Wochen-Ergebnis belohnen ohne neuen Screen.
- Coach füllt eine ganze Woche in den Plan: groß, erst nach Tagessummen und
  echten KI-Nutzungsdaten.
- Staging-Projekt oder Branching (Kosten; CI-Replay und Dry-Run decken das
  meiste ab), `max_rows` anheben (versteckt den Fehler), Sentry in den Edge
  Functions (Abhängigkeiten, PII), automatischer Rollback im Deploy-Workflow.

## Nicht geprüft

Echte Geräte (Zeitpunkt der Health-Abfrage, Benachrichtigungen,
VoiceOver/TalkBack, große Schrift, Leistung des Schritt-Nachladens),
Supabase-Plan, Backups, PITR, Log-Retention, Plattenbelegung und Live-Werte
von `max_rows` und KI-Kontingent, `SENTRY_DSN` in Release-Builds,
Play-Console (Data Safety, Health-Erklärung, Lösch-URL), Apple-Programm und
ITMS-Warnungen, was ein Chefkoch-Link live liefert, Nutzungsdaten zu halben
Tagen, die Datenschutzerklärung auf der Website. „Pflicht nach Play-Richtlinie“
und Art. 9 sind Auslegungen, keine Rechtsberatung.
