# Skill-Audit und Feature-Review, 2026-11-01

Stand: main @ `138f0046` (#174). Zwei Reviews am selben Tag, beide nur lesend:

1. **Skill-Audit:** zehn Agents prüften die Codebase gegen die zehn lokal
   installierten Flutter-Agent-Skills (`.claude/skills/flutter-*`, nicht
   eingecheckt). Die wichtigsten Befunde wurden im Code nachgeprüft.
2. **Feature-Review:** fünf Agents mit je einer Perspektive (täglicher Loop,
   KI und Premium, Markt, Training und Health, Rezepte und Planung).

Der Build am selben Tag (zehn Worktree-Agents, Branch
`feat/review-build-2026-11-01`) setzte um, was ohne Owner-Entscheidung und
ohne externe Schritte ging; „gebaut (`slug`)" nennt den Agent-Branch
`build/2026-11-01-<slug>`. Lieferstand und offene Owner-Entscheidungen stehen
im [Handoff](PROJECT_HANDOFF.md#review-items-built-with-ten-agents-2026-11-01).

## 1. Skill-Audit

| Skill | Ergebnis |
| --- | --- |
| Architektur | Kern erfüllt (ChangeNotifier-Controller, unidirektionaler Fluss, reine Logik in services). Keine eigene Repository-Schicht und kein DI-Container: dokumentierte Entscheidung. `HomeStore` 7.601 Zeilen in 14 Parts. |
| Routing | Ohne `go_router` erreicht: Routen-Push der Plattform wird geschluckt, Auth-Redirect, Tab-Zustand, Predictive Back. |
| JSON | Strenger als der Skill (Typprüfungen, `FormatException`, Lesegrenzen). |
| HTTP | Plattform erfüllt, Statusprüfung, keine Secrets in Logs; GoTrue ohne Timeout. |
| Lokalisierung | 2113 = 2113 Keys, typisierte Platzhalter, Wächter gegen harte Texte. |
| Responsive | `ReadableWidth`, Layout-Sweep; Hochformat-Sperre dokumentiert, Owner-Entscheidung offen. |
| Layout-Fehler | Muster des Skills vermieden; zwei Badges brechen bei großer Schrift. |
| Widget-Tests | Harness, Uhr-Regel, keine schädlichen Tautologien; CI ohne Zufallsreihenfolge. |
| Integrationstests | keine (abgelehnt 2026-09-28); keine CI-Ausführung auf Gerät. |
| Widget-Previews | 3 Previews, niedrige Priorität. |

Befunde und Status:

| Befund | Beleg | Status |
| --- | --- | --- |
| GoTrue-Requests ohne Timeout | `supabase_config.dart:101-115` | gebaut (`auth-timeout`) |
| Rezept-Editor sucht nur in Open Food Facts | `recipe_ingredient_editor.dart:30` | gebaut (`app-fixes`) |
| CI ohne `--test-randomize-ordering-seed` trotz CONTRIBUTING | `tool/flutter_ci.py` | gebaut (`ci-tests-texts`) |
| Fester 2-s-Wait im Kamera-Test | `wiring_meal_camera_capture_scrub_test.dart:199` | gebaut (`ci-tests-texts`) |
| Kamera-Sperre auf Android nicht No-op | `meal_camera_sheet.dart:157-163` | gebaut (`app-fixes`) |
| Unbekannte Profil-Enums werden überschrieben | `sync_outbox.dart:853-891` | gebaut (`parse-robustness`) |
| Unbekannter Abo-Status verwirft PlanStatus | `plan_status.dart:450-468` | gebaut (`parse-robustness`) |
| kcal ohne Tausendertrennung, „Portion(en)" | `app_de.arb:243`, `:3434` | gebaut (`ci-tests-texts`, `servings-basis`) |
| Trainings-Badges bei 2x Schrift | `player_set_row.dart:192`, `player_exercise_card.dart:380` | gebaut (`app-fixes`) |
| `RecipeHistoryScreen` ohne Breitenbegrenzung | `recipe_history_screen.dart:151` | gebaut (`app-fixes`) |
| `_BootErrorApp` ohne Routen-Wächter | `main.dart:162` | gebaut (`app-fixes`) |
| Zweites Kamera-Sheet über Einstieg von außen | `eatova_home_page.dart:1919` | gebaut (`app-fixes`) |
| l10n-Wächter deckt training/premium nicht ab | `repo_rules_test.dart:357-400` | gebaut (`ci-tests-texts`) |
| Cache verwirft ganze Liste bei einem kaputten Datensatz | `local_cache.dart:497-571` | offen: dokumentierte Entscheidung (`local_cache.dart:544-547`), Owner |
| Hochformat-Sperre auf Android-Tablets | `AndroidManifest.xml:80`, `main.dart:43` | offen: Owner (`PROJECT_HANDOFF.md:2106`) |
| Kein Gerät/Emulator in CI | `security.yml` | offen: `integration_test` 2026-09-28 abgelehnt; Begründung fehlt im Repo |

## 2. Feature-Review

Alle Vorschläge wurden gegen `docs/FEATURES.md` und die Reviews vom
2026-09-10, 2026-10-10, 2026-10-18, -19 und -22 abgeglichen.

| Vorschlag | Agents | Stufe | Status |
| --- | --- | --- | --- |
| Woche vorschlagen (deterministisch) | Rezepte, KI | Free | gebaut (`week-plan`) |
| Steigerungshinweis im Workout-Player | Training, Markt | Free | gebaut (`training`) |
| Sitzungen pro Woche („2 von 4") | Training | Free | gebaut (`training`, Migration) |
| Erster Eintrag am Tag 0 | Loop | Free | gebaut (`first-entry`) |
| Abend-Erinnerung mit Aktionen | Loop | Free | gebaut (`first-entry`) |
| „Oft zum Frühstück" pro Mahlzeit | Loop | Free | gebaut (`own-food-suggestions`) |
| „Was passt noch?" aus eigenen Lebensmitteln | KI | Free | gebaut (`own-food-suggestions`) |
| Grundmenge eigener/Coach-Rezepte, Vorkochen | Rezepte | Free | gebaut (`servings-basis`) |
| Kochmodus | Rezepte | Free | gebaut (`cooking-mode`) |
| Nährwert-Etikett fotografieren | KI, Markt | Free (Analyse-Kontingent) | offen: Einwilligungstext prüfen (Owner/juristisch) |
| Widget (zuerst ohne Zahlen) | Loop, Markt | Free | offen: nativ, nur auf Gerät prüfbar; Owner-Frage Zahlen auf dem Sperrbildschirm |
| Workouts nach Health schreiben | Training | Free | offen: Store-Deklarationen, mit READ_WEIGHT bündeln |
| Muskelgruppen-Volumen | Training | Free | offen: Vokabular-Coverage zuerst |
| Rezeptseiten über schema.org | Rezepte | Import-Kontingent | offen: Urheberrecht, Datenschutztext |
| Kalorien auf Trainingstage verschieben | Markt | Free | offen: Migration, Bedarf unbekannt |
| `/woche` mit Wunschtext (Premium) | KI | Premium | offen: erst echte `ai_call`-Daten |
| Speisekarte im Coach | KI | Coach-Kontingent | offen: kleinster Abstand zum Bestand |

Bewusst nicht (deckungsgleich mit früheren Reviews): gemeinsamer Haushalt
(neues RLS-Modell), Vorrat/Supermarkt/Preise (Open-Prices-Muster),
Fasten-Timer, Körpermaße/Fotos, Workout-kcal und Schlaf aus Health (doppelte
Zählung), Streak-Freeze, Allergen-Check per Foto (Garantie-Missverständnis),
Wochen-Rückblick an alle (Free-Pool), Stück/Scheibe aus Open Food Facts (10 von
100 Top-Produkten nennen eine natürliche Einheit).

## 3. Markt (deutscher App Store, abgerufen 2026-11-01)

Eatova 49,99 €/Jahr; MyFitnessPal 87,99 €, Lifesum 99,99 €, MacroFactor
73,99 €, Cronometer 69,99 € (Tarifzuordnung der Store-Listen unsicher).
Abheben: alles ohne KI kostenlos (MyFitnessPal verlangt für den Barcode ein
Abo), Ernährung und Training in einer App.

Open Food Facts, Filter Deutschland, Stichprobe 2026-11-01: 94 von 100
meistgescannten Produkten mit kcal und Makros, 22 von 100 kürzlich
angelegten. Zucker, gesättigte Fette, Salz: 93–95 % bzw. 15–18 %.

Sign in with Apple ist kein Feature, aber Voraussetzung für die
App-Store-Freigabe (Guideline 4.8); geführt als R1 in
`FEATURE-REVIEW-2026-10-10.md:32`.
