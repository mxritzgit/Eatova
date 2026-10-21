# Eatova – Test-Review mit 20 Agenten (2026-10-21)

> Historical record: statements and open items below describe the dated
> source, not the current product. The rules that came out of it live in
> [CONTRIBUTING.md, "Writing tests"](../CONTRIBUTING.md#writing-tests).

Stand: 2026-10-21, geprüfter Code `23e4ee0b`, umgesetzt in
[PR #162](https://github.com/mxritzgit/Eatova/pull/162). Auftrag des Owners:
jeden Test durchgehen, falsche Tests sofort reparieren, unnötige und veraltete
Tests entfernen, nur behalten, was Fehler wirklich findet ("wenn du sagst, wir
brauchen das alles, okay, dann ist das so").

## Ergebnis

| | Vorher (`main`) | Nachher (PR #162) |
|---|---:|---:|
| Flutter-Tests, wie die CI sie ausführt | 8.233 | 6.591, dazu 4 für die Lücken |
| Deno-Testfälle, ausgeführt | 1.143 | 776 |
| Testdeklarationen (Dart, Deno, Python) | 8.399 | 7.283 |
| Testdateien | 907 | 862 |
| Zeilen Testcode | – | etwa 20.000 weniger |
| Flutter-Coverage (Floor 95 %) | 97,18 % | 97,13 % (vor den Lücken) |
| Testzeit aller vier CI-Shards | 38,8 min | 33,6 min |
| Langsamster CI-Shard | 10,5 min | 10,0 min |

- **111 Tests repariert.** Die meisten blieben grün, wenn das Verhalten, das
  ihr Name verspricht, kaputt war: sie prüften ihren eigenen Fake, einen Wert,
  den der Test selbst gesetzt hatte, einen Pfad, den die App nicht nimmt, oder
  eine Bedingung, die nach einem Redesign immer stimmt. Dazu kommen falsche
  Namen, Reihenfolge-Abhängigkeiten, Tests mit echter Uhr und ein Test, der
  bei jedem Lauf PNGs schrieb. Inhaltliche Reparaturen sind mit einer
  absichtlichen Störung im App-Code belegt (alter Test grün, neuer Test rot);
  reine Umbenennungen nicht.
- **541 Löschungen, 228 Zusammenlegungen** (einzelne Tests, Gruppen oder
  ganze Dateien). Für jede Löschung nennt der Agent den Test, der das
  Verhalten weiter abdeckt, oder warum es das Verhalten nicht mehr gibt.
- **Coverage Zeile für Zeile gegen `main`:** nach dem ersten CI-Lauf hatten 43
  Zeilen keinen Test mehr. 23 davon sind toter Code (der unerreichbare
  Trends-Fallback, das In-Memory-Auth-Double, ein ungenutztes
  Datumsauswahl-Theme, `SpeechInput.available`, ein Test-Hook, jetzt
  entfernt). 19 waren echte Lücken und sind wieder geschlossen, jede mit
  Mutationsprobe: Zwei Agenten hatten denselben Netzfehler-Test auf dem
  Code-Screen gelöscht und dabei auf die Kopie des jeweils anderen verwiesen;
  eine gescheiterte Hydration muss sauber abbrechen; die Info-Zeilen der
  Analyse stapeln sich bei 2× auf Englisch, nicht auf Deutsch, wie ein Agent
  annahm. Eine Zeile (`meals_sync.dart`, Archivseite in falscher Reihenfolge)
  war schon vorher nur zufällig erreicht und bleibt offen.
- **Kein Funktionsfehler in der App gemeldet.** Gemeldet wurde nur toter
  oder falsch kommentierter Code. Entfernt: `ImagePlaceholder`, `shoppingLineChecked`,
  `shoppingProgress`, `UserRecipeLimits.hasDbUpperBound` (sein Kommentar
  stimmte seit der Bereichsprüfung `20260819140000` nicht mehr).
- **Gegenseitige Störung:** Der prozessweite `RecipeImageStore` blieb von einem
  Test zum nächsten gebunden; in zufälliger Reihenfolge hing dadurch eine
  Flow-Suite zehn Minuten. `test/flutter_test_config.dart` setzt ihn jetzt nach
  jedem Test zurück.

Woher die Masse kam (aus allen 20 Berichten): eine neue Datei pro
Review-Runde statt eines Falls in der Feature-Datei; dieselbe Regel auf
mehreren Ebenen (Funktion, Store, Widget, Flow); Matrizen über Hell/Dunkel, Sprache und
Textgröße, obwohl der Code dort nicht verzweigt; ein Test pro Tabellenzeile;
Pixel-, Farb- und Textpins alter Designs; Tests des eigenen Fakes. Daraus ist
die Regel in `CONTRIBUTING.md` entstanden.

## Vorgehen

Die 907 Testdateien wurden nach Thema in 20 gleich große Pakete geteilt
(17 Dart, 2 Deno, 1 Python/SQL); jede Datei gehörte genau einem Agenten, die
gemeinsamen Test-Helfer dem Paket `misc`. Jeder Agent arbeitete in einem
eigenen Worktree von `23e4ee0b`, las jeden Test zusammen mit dem App-Code,
den er prüft, und machte für verdächtige und kritische Tests eine
Mutationsprobe (App-Code absichtlich brechen, Test laufen lassen,
zurücksetzen). App-Code hat kein Agent committet. Die Hauptsession hat die 20
Commits zusammengeführt, die Eigentumsgrenzen geprüft, Analyzer, Deno-Suite,
CI-Verträge und Shard-Planung lokal laufen lassen und die Coverage aus der CI
Zeile für Zeile mit `main` verglichen.

Grenzen: Mutationsproben gab es stichprobenartig, nicht für jeden behaltenen
Test; welche Dateien nur gelesen wurden, steht in den Berichten der Agenten
(Workflow `wf_e5e3c4a9-f86`). Die SQL-RLS-Suites liefen lokal nicht (kein
Docker); sie blieben unverändert und laufen in der CI.

## Pro Paket

| Paket | Dateien | Testdeklarationen | Repariert | Gelöscht | Zusammengelegt |
|---|---:|---:|---:|---:|---:|
| auth_account | 59 → 57 | 413 → 346 | 6 | 31 | 15 |
| coach-1 | 36 → 35 | 346 → 286 | 3 | 43 | 14 |
| coach-2 | 36 → 34 | 383 → 353 | 4 | 14 | 10 |
| design_theme | 67 → 67 | 494 → 387 | 8 | 39 | 13 |
| food-1 | 59 → 57 | 428 → 396 | 6 | 27 | 4 |
| food-2 | 64 → 61 | 557 → 426 | 7 | 53 | 29 |
| health_trends | 74 → 66 | 632 → 554 | 5 | 37 | 9 |
| home_app | 44 → 42 | 377 → 305 | 4 | 25 | 15 |
| meal_plan | 23 → 23 | 125 → 113 | 5 | 11 | 3 |
| misc | 35 → 33 | 339 → 308 | 9 | 27 | 6 |
| recipes | 60 → 58 | 460 → 427 | 3 | 24 | 16 |
| settings_profile | 50 → 46 | 366 → 308 | 5 | 20 | 16 |
| sync_storage-1 | 56 → 51 | 394 → 332 | 8 | 20 | 9 |
| sync_storage-2 | 52 → 50 | 463 → 366 | 10 | 32 | 12 |
| tooling | 33 → 29 | 325 → 290 | 4 | 26 | 8 |
| training-1 | 27 → 24 | 243 → 241 | 4 | 4 | 3 |
| training-2 | 22 → 20 | 308 → 281 | 8 | 16 | 5 |
| deno-coach-chat | 20 → 19 | 426 → 329 | 4 | 38 | 24 |
| deno-other-functions | 45 → 45 | 465 → 387 | 7 | 48 | 16 |
| python-sql | 45 → 45 | 855 → 848 | 1 | 6 | 1 |
| **Summe** | 907 → 862 | 8399 → 7283 | 111 | 541 | 228 |

## Nachtrag: Folgepunkte, PR #164

Der Owner hat entschieden: was sich überschneidet, fliegt raus; was bleibt,
muss die Weiterentwicklung absichern; doppelte Sicherheitstests dürfen weg.

- **Design-Capture-Suites:** 27 der 30 Dateien in `test/design/` sind raus
  (265 → 19 Tests, rund 9.600 Zeilen, etwa 160 s Suite-Zeit in der CI). Ein
  voller Lauf ohne `test/design` verlor 107 abgedeckte Zeilen. Jede davon, die
  Verhalten schützt, hat jetzt einen mutationsgeprüften Fall in der Testdatei
  ihres Features: ungültige E-Mail bleibt lokal, englische Alt-Konfidenz, Pflicht-
  Titel beim Import, Geschlechts-Auswahl rechnet das Ziel neu, Trainingsverlauf
  (Laden, Fehler mit Wiederholen, leer mit „Training eintragen"), Kalendertag im
  Speiseplan-Editor, Ausweg aus der leeren Rezeptsuche, geschützte Leerzeichen
  in der Bearbeiten-Zusammenfassung. Geblieben: `onboarding_capture_test` (jeder
  Onboarding-Schritt bei 320 px und 2x in de/en; die Layout-Sweep erreicht das
  Onboarding nicht), `boot_error_capture_test` (die Startfehler-Seite) und
  `soft_controls_test` (Verhaltenstests). `test/support/design_capture.dart`
  bleibt für PNG-Aufnahmen; gelöschte Suites lassen sich aus `7a05b818`
  wiederherstellen. `LoadingCard` ist gelöscht.
- **`renderMatrix` nur dunkel:** Standard ist jetzt die dunkle Palette; Farb-
  und Kontrastaussagen geben `bothBrightnesses` an.
  `food_sheets_light_dark_test` heißt jetzt `food_sheets_render_test`.
- **Doppelte Sicherheitstests (Python):** drei entfernt (zwei in
  `scripts/security/test_auth_config_drift.py`, einer in
  `test/tooling/local_auth_transport_test.py`).
- **Ergebnis:** Flutter-Tests 6595 → 6325, Coverage 97,16 % → etwa 97,1 %.
  30 Zeilen ohne Test sind reine Anzeige-Varianten, `meals_sync.dart:120` (war
  schon vorher nur zufällig erreicht) und `InAppMealCameraLauncher.launch`
  (fünf Zeilen Verdrahtung zum direkt getesteten `MealCameraSheet`; offen).

## Offen

- **Doppelte SQL-Sicherheitsprüfungen:** der Konto-Löschungs-Glücksfall steht
  in `rls_cross_user.sql`, `training_plans_rls.sql` und
  `training_history_rls.sql` noch einmal neben `privacy_deletion.sql`;
  `recipe_ingredients_rls.sql` und `weight_log_edit.sql` wiederholen
  Tabellen-RLS aus `rls_cross_user.sql`. Der Auto-Mode-Klassifikator hat das
  Löschen trotz Owner-Freigabe blockiert.
- **`bootUntilIdle`** (`test/outbox/outbox_test_helpers.dart`): bei Offline-Boot
  wartet er still die vollen 5 s ab; etwa 15 Training-Store-Tests verlieren so
  je 5–11 s. Besser auf Hydration warten oder laut scheitern.
- **Fakes geben ganze Profilzeilen zurück** (`FixlaufServer`, `FakeServer`):
  sie ignorieren `select`, daher merkt kein Store-Test eine fehlende Spalte;
  heute fängt das nur `profile_columns_contract_test`.
- **Ein gemeinsamer `openGoalsRoute`-Helfer** statt fünf Kopien eines
  40-Zeilen-Harness, die zudem Overflow-Fehler schlucken.
- **Toter Code, der bleibt:** der Fallback
  `MealAnalysisScreen.trendBurnedKcalFor`, den die Schale nie erreicht.
- **Review-Präfixe** in Deno-Testnamen (`P6-02`, `F5-xx`, `Fund 1`) und
  `test/support/fixlauf_a_helpers.dart` (rund 45 Importe) tragen noch Namen
  von Review-Runden.
- **Shard-Verteilung:** `tool/flutter_ci_timings.json` stammt vom 2026-09-27
  und hat kein Skript zum Neuerzeugen; Laufzeit-Hinweise aus einem aktuellen
  `main`-Lauf würden den langsamsten Shard etwa auf 8,5 min bringen.

## Kurzurteil je Paket

Aus den Berichten der Agenten (englisch).

- **auth_account:** The security-critical core of this slice is solid and mutation-proven: session isolation, recovery-proof scope, scoped deletion, the logout journal and the deeplink guard all fail when the behavior breaks. Two tests were wrong. One classifier test stayed green with its typed branch removed. The store's deletion-rejection tests only ran a fallback that no production caller uses. Both now fail on the faulty behavior. 67 declarations (126 test runs) were duplicates, tests of the fake, copy pins or matrix axes that cannot change the outcome. The remaining tests are needed.
- **coach-1:** The slice is in good shape now. The controller unit tests from 2026-10-18 are sharp and caught every fence mutation I tried. Most of the cut came from widget tests that pinned the same fences again through the screen, plus design, colour and copy pins. Three tests were vacuous and are fixed. 43 were deleted and 17 folded into existing tests (346 -> 286 declarations, 36 -> 35 files). Four review-round files were renamed by behaviour. Everything else I kept is needed: consent and privacy gates, quota rules, late-answer and slot protection, dictation lifecycle and accessibility.
- **coach-2:** Most of this slice protects real requirements: account isolation of /plan and /log, privacy of crash reports, no write before confirmation, outbox-aware coach context, and the parity between the workout-log server and client. Those tests survived mutation checks and stay. I found one wrong test: the week-summary "same rate as the weekly check" test never called the code it names. It is fixed. The rest of the bloat was copies of shared-code tests (transport, fence, fixture bounds), one-row-per-test tables and duplicate theme or platform loops. That is 30 test declarations and 2 files fewer, and about 622 → 482 test runs in the normal pass.
- **design_theme:** Most of the slice guards real requirements and stays: auth throttle and quota, boot and outbox integrity, cache close fences, a11y semantics and contrast, reject-not-clamp inputs. Two tests were wrong and stayed green on the break: the shell-trends wiring test and the coach /recipe privacy test. Both are now fixed. The bloat came from review-round files re-asserting feature and design-library contracts and from brightness/locale/scale matrices. Those duplicates, dead-theme tests and history pins were removed: 494 -> 387 declarations (452 runtime cases after the cut), and 41 files were renamed by behaviour.
- **food-1:** Most of the slice is sound. The store, outbox, account-isolation, privacy cleanup, search-throttle and copy tests caught every break I tried, so they stay. Six tests were wrong and are now fixed: they stayed green when the behavior they name broke, or they asserted on a key that no longer exists. The removals are duplicates, re-pinned translated copy, pixel pins, light/dark copies of layouts that have no palette-specific branch, and capture states shot twice. Counts: 428 -> 396 test declarations; at runtime 488 -> 432 test cases.
- **food-2:** Most of the slice guards real requirements: privacy (EXIF/GPS scrubbing, temp photo cleanup), account isolation during scans, calorie and DB-limit integrity, product-search error classification and the search kill switch. Those tests stay. Four tests were wrong and one name was wrong: two were partly vacuous, one used a re-implemented parser plus source greps, one pinned tuning constants, and one name did not match its assertions. The slice was also bloated (557 -> 426 declarations, 630 -> 466 tests at runtime) by one-value-per-test cases, brightness/locale matrices, review-round re-tests and copy or geometry pinning.
- **health_trends:** Most of this slice tests real requirements and holds up: sync and outbox, account isolation in the health services, DST arithmetic, and the energy-check property tests. The main problems were two vacuous B6 tests (the complete-day rule made their fixtures meaningless), one file plus several tables that duplicated Today's calorie card, review-named files, and many hand-written examples sitting next to property tests that already cover them. Test declarations went from 632 to 554 and files from 74 to 66. Everything that remains passes in randomized order and analyzes clean.
- **home_app:** Most of the slice catches real failures: shell tabs, the secure-screen guard, the outbox and store lifecycle, onboarding maths and the settings flows all failed when I broke them on purpose. I fixed four tests that stayed green while the thing they claim to guard was broken: the midnight timer re-arm, the GDPR minimum age, the DB-limit drift guard, and store tests that read the live clock. The slice was mostly bloated by matrices crossing palette, language and text size, and by the same contract being asserted at several layers. Counts: declarations 377 -> 305, runtime tests 462 -> 354, files 44 -> 42.
- **meal_plan:** Most of this slice is needed and catches real failures. The model tests for the receipt, amounts and ingredient keys, plus the tests for the outbox, encrypted cache, plan quota, idempotent editor retry and account purge, failed on every mutation I tried. The extra tests came from older widget tests that later tests duplicate, tests of dead code, and old-design assertions that could no longer fail. I removed or merged 12 declarations (15 run cases) and fixed 5 tests.
- **misc:** The tests that guard real requirements are sound and stay: RLS and grant invariants (with their own self-tests), account isolation in userRpc, outbox stop after dispose, the overflow collector, and accessibility semantics. Seven tests were wrong: one depended on test order and failed under random seeds 2 and 5, five could not fail on the behaviour their name claims (each now fails on its mutation), and one had a misleading name. The rest was duplication: brightness, locale and size matrices around layout with no brightness branch, contrast math repeated from app_tokens_test, source greps already covered by mounted tests, and tests of dead code. Runtime cases went from 478 to 387 (declarations 339 to 308).
- **recipes:** The recipes slice was mostly sound. Sync, account-isolation, EXIF, outbox and avoidance tests all caught sampled mutations. I found two vacuous tests (a photo keep-set check that passed without the history references, and an "exactly one toast" check that can never fail), one order-dependent test, one test reading the wall clock, and a lot of growth from loops over palette and language that change nothing. Counted as declarations: 460 before, 427 after. Counted as executed tests (loops expanded): 600 before, 462 after. All remaining files pass in random order and analyze clean.
- **settings_profile:** Most of this slice guards real requirements: account isolation, rest alerts after a session ends, notification races, GDPR export completeness and validation. Mutations confirm those tests. Five tests could not fail for the behavior they name, and they are now fixed and mutation-proven. Most of the volume came from matrices and one test per value. Result: 50→46 files, 366→308 declarations, 496→344 executed tests. All 46 remaining files pass in random order and the analyzer reports no issues.
- **sync_storage-1:** The slice holds real durability, account-isolation, encrypted-cache and privacy guarantees, and the critical kept tests failed on every sampled production mutation (M1, M11-M14, M17-M22). What it did not need was the same scenario pinned three to five times. The clearest case was the unreadable outbox slot, covered by 12 tests in 5 files. On top of that, several regression tests were written for an older design and could no longer fail: the A1 snapshot guard, P1-02 and the in-pass append test. Those are now fixed and proven red on a mutation. Declarations drop from 394 to 332 and files from 56 to 51. No production bug was found.
- **sync_storage-2:** The slice's critical guarantees hold up. Mutation checks broke outbox durability, account isolation, encrypted writes, write/remove ordering, the purge race, the lease clamp, the DEK strike budget and the queue cap, and a kept test went red each time. But seven tests named a guarantee they did not check, and the crypto area repeated the same assertions in three files (113 tests, now 72). After 10 fixes, 71 deletions and 26 merges, the remaining 366 declarations (378 runtime tests, down from 504) are needed.
- **tooling:** Most of the slice is sound. The native, manifest and privacy guards and the shell flow tests check real outcomes, so they stay. Three guards were vacuous: the trends step bonus was tested through a route the shell never takes, the "live" apply_sync_operation check read a superseded migration, and the user_recipes column-bound check read only the frozen create-table file. All three are fixed, and mutation runs show each fix fails on the real regression. Net change is 35 fewer test declarations and 4 fewer files, mostly SQL-text checks that the rls-postgres job and rls_invariants_test already prove.
- **training-1:** Almost every test in this slice is needed. Most of them pin outbox durability, account isolation, encrypted-cache, deletion-receipt and incarnation rules, and 18 of 19 realistic mutations made at least one of them fail. The one that got through exposed a vacuous re-save in the head-conflict test, which is now fixed. The real problems were that one test never checked its result, one flow test hung depending on test order (pre-existing on main), one test wrote PNG files on every run, and some bloat: fake self-tests and variant combinations. These are fixed or trimmed (243→241 declarations, 299→294 runtime tests, 27→24 files). The largest remaining duplication sits across the two training slices and is listed under cross_slice.
- **training-2:** Most of this slice is needed: it covers durability, account isolation, legacy recovery and player timing. 8 tests were wrong or vacuous; each is fixed and proven with a mutation check. 27 declarations were redundant and are gone (308 to 281, 22 to 20 files). What remains is weighted toward training_store_test and training_player_screen_test, which cover real outbox, checkpoint and alert requirements.
- **deno-coach-chat:** Most coach-chat tests pin real requirements: quota and refund rules, auth caching, account isolation, sanitized logs, the provider budget and stream approval. Every sampled mutation of those failed as it should. The bloat came from duplication: shared-helper behaviour re-tested through the handler, one test per category, locale or status, generic pre-mode cases repeated in each mode, and a parallel QA file. On top of that, four tests could not fail for what their names claim. I cut the slice from 426 to 329 declarations (503 to 385 cases), and line coverage is unchanged. handler_deadline, recipe_preferences, training_context and week_prompt are all needed and stay as they are.
- **deno-other-functions:** The slice had real substance but roughly 40% redundancy: Deno.test( declarations went from 465 to 387 and executed cases from 640 to 391 (functions 621 to 372, coach eval unchanged at 19). Most of the cut came from handler-level copies of checks the _shared tests already pin, the same scenario tested in two or three files, and per-row Deno.test loops. Three tests were weak or wrong and are fixed; each fix was shown green on a production mutation before the fix and red after. The recipe-import caption-parser regression tests and the offline coach eval cost guards are all needed and stay as they are.
- **python-sql:** Mostly sound. The Python tooling and operations tests check that the CI and ops scripts reject bad input instead of passing it, and all 17 mutations I made to kept tests were caught; I removed 6 duplicates, merged 1 and renamed 1 misnamed test. The SQL RLS, privacy-deletion and sync suites are thorough and check their own fixtures, but I could only read them (no Docker here), so they are unchanged. A few redundant security tests remain because the auto-mode classifier blocks security-test removal; the owner decides on those.

## Reparierte Tests

Datei, Test (bei Umbenennung alter → neuer Name) und das Problem. Die Mutationsbelege stehen in den Berichten der Agenten und in den Commit-Texten von PR #162.

**auth_account**

- `test/auth/h_account_change_classifier_test.dart`: email_exists als CODE bestaetigt keine fremde Kontoexistenz -> die Konto-Codes bestaetigen keine fremde Kontoexistenz — Vacuous.
- `test/delete_account_wire_test.dart`: HomeStore.deleteAccount bei serverseitiger Ablehnung (2 tests) -> HomeStore.deleteAccount: eine Server-Ablehnung liefert false, raeumt nich… — Called store.deleteAccount() without deleteRemote, so it ran the sync?.deleteAccount() fallback.
- `test/auth/h_account_change_classifier_test.dart`: Passwort anfordern: das Kontingent nennt die halbe Stunde -> Passwort anfordern: das Mail-Kontingent ist kein „Moment" — The name contradicts the assertion: the copy now says 'ein paar Minuten', and a sibling test forbade 'halbe Stunde'.
- `test/delete_account_session_rotation_test.dart`: verified deletion continues through same-owner OTP rotation -> a verified deletion keeps the app session under AuthGate and completes once — The name describes a removed design.
- `test/password_change_contract_copy_test.dart`: $language password sheet explains required credential and recovery ... — findsNothing on 'ohne ihn lässt sich das Passwort nicht ändern' / "without it, the password can't be changed".
- `test/account_studio_layout_test.dart`: daily macro segments retain their visible height — Pinned the exact incidental height 9 px; the requirement is only that the segments are visible.

**coach-1**

- `test/coach/coach_chat_controller_test.dart`: return to the tab / a quota answer of the old account is dropped — Vacuous: the fake returns a const ChatQuotaSnapshot, so the old account's quota answer is the identical canonical instance, and `same(quota)` held even when the account fence was removed.
- `test/ai_consent/ai_trust_controller_test.dart`: nur ein Einwilligungsblatt fuer gleichzeitige Anfragen — The final 'Closed: the next request asks again' step called promptOnce with a different closure and re-asserted asked == 1, which held whether or not the prompt slot was cleared.
- `test/ai_consent/coach_ai_consent_test.dart`: Antwort melden / Screenreader erreichen Melden als eigene Aktion — Only checked that a custom semantics action with the right label exists and never invoked it, so a no-op callback passed.

**coach-2**

- `test/coach_week/coach_week_summary_test.dart`: dieselbe Rate wie der Wochen-Check, nicht eine eigene (now: der Block zeigt die Rate des Wochen-Checks, nicht eine eigene) — The test never called coachWeekSummary.
- `test/design/coach_cards_capture_test.dart`: recipe card without a photo, then added — expect(find.byType(ImagePlaceholder), findsNothing) could never fail.
- `test/coach_training_plan_flow_test.dart`: Late generation is not shown in a different conversation (now: A late plan stays out of another chat; its quota counts) — The name hid the test's last assertion, a locked composer.
- `test/services/coach_chat_service_reporting_test.dart`: * (renamed from coach_chat_fix_2026_08_19_service_test.dart) — The file was named after a review round, not by behaviour.

**design_theme**

- `test/widgets/shell_trends_step_bonus_test.dart (was test/widgets/fixwelle_shell_trends_test.dart)`: die Trends aus der Schale rechnen mit dem Schritt-Bonus des Stores — Asserted MealAnalysisScreen.trendBurnedKcalFor, a prop the shell still passes but never reads (onOpenTrends is set, so the food tab opens Trends via the shell's _openTrends).
- `test/coach/fixlauf_p5_coach_test.dart`: der Screen reicht keinen user_context an requestRecipe — Vacuous: CoachChatService.requestRecipe has no userContext parameter, so the fake's extra optional param is always null whatever the client sends.
- `test/widgets/kcal/fixlauf_c_add_sheet_mirror_test.dart`: Archivtag: die gespiegelte Zeile trägt den Tag des Sheets und überlebt eine Slot-Änderung im Bearbeiten-Sheet — Its last assertion `expect(localDayKey(DateTime(2026, 8, 20)), '2026-08-20')` checked a helper on a constant, not the mirrored row's day.
- `test/widgets/kcal/meal_analysis_sheet_retry_test.dart (was fixlauf_d_meal_analysis_sheet_retry_test.dart)`: dispose bei laufendem Request cancelt; der sofort scheiternde Future trifft keinen toten State — The old 'dispose-Cancel ...
- `test/theme/review0829_selection_contrast_test.dart`: DatePicker group; 'Die Zahlen der Auswahlsprache' (2); 'forest bleibt als Zustandstraeger disqualifiziert' — The DatePicker group tested datePickerTheme, but the app shows no Material date picker (it uses FoodDatePicker), so it guarded dead config.
- `test/theme/macro_tile_and_dock_contrast_test.dart (was review0829_welle4_kontrast_test.dart)`: 'rohe Makro-Toene sind keine Schriftfarben auf surf2', 'readableOnTint traegt den Punkt auf surf2 in beiden Modi' — Token maths against surf2, but MacroTile now sits on proteinSurface/carbsSurface/fatSurface.
- `test/app/boot_load_window_writes_test.dart (was fixlauf_a_boot_race_test.dart)`: file header / contract description — The header claimed these cases pin the merge of a raced load (_mergeRacedLoad).
- `test/coach/fixlauf_e_coach_client_test.dart`: file header — The header listed F5-05 (mic renders on iOS only) as covered; no test in the file checks it.

**food-1**

- `test/food_thumb_first_test.dart`: Listed meals keep the real edit route and stable identity — Only checked that some edit sheet opened after tapping food-history-entry-9; it never checked which meal was opened, and the `removed` variable was never exercised.
- `test/food/recent_portion_test.dart`: die neue Portion wird die des Recents, Schluessel und Platz bleiben — `recent.addedAt == key.addedAt` was vacuous: the add and the re-portion both ran under the same Clock.fixed, so a re-portion that bumps the recent's date still matched.
- `test/design/food_states_capture_test.dart`: Choose day: the keyboard pages past the 1st (and -320-x2) — `if (landed.evaluate().isNotEmpty)` skipped the step when the arrow key did nothing, so both variants stayed green and the capture showed the unpaged month.
- `test/add_meal_sheet_favorites_row_test.dart, test/flows/favorites_menu_flow_test.dart`: gepinnte Favoriten stehen nicht inline...; Favorites menu logs a favorite into the chosen slot; Unpin in the favorites menu updates the fav… — Asserted findsNothing on ValueKey('favorite-pinned-0').
- `test/add_meal_sheet_favorites_inline_test.dart -> test/add_meal_sheet_favorites_row_test.dart`: * — The file name and header described the inline top three by recency, which the app no longer has.
- `test/food_kcal_db_test.dart`: beide Summen stimmen ueber eine Matrix von Gesamtwerten (P2-06) — The old matrix only asserted isNotEmpty, so a split that returned a single item satisfied both sum checks trivially.

**food-2**

- `test/meal_suggestion_zero_kcal_guard_test.dart`: 0-kcal-Favorit lässt sich nicht ins Tagebuch legen — Two vacuous assertions.
- `test/meal_analysis_scan_cancel_test.dart`: Scan-Kamera abbrechen: kein Crash, keine Vorschau, keine Analyse (was '... kein Ergebnis-Sheet') — It asserted that the result card and 'Analyse prüfen' are absent, but since the scan-preview step was added the result sheet can no longer appear right after the camera, so those assertions held regardless.
- `test/models/logged_meal_clamp_invariante_test.dart`: Invariante: JEDER Erzeuger liefert ein schreibbares Ergebnis / jede Spalte der logged_meals-Zeile ist hier begruendet — The invariant checked macro columns through a test-side re-implementation of _macro (_macroZuNumeric).
- `test/slot_durchstich_test.dart`: nach dem Schliessen oeffnet ein Tab-Wechsel kein Geister-Fenster (was 'ein zweiter Tap auf denselben Slot oeffnet kein zweites Fenster') — The name described a second tap on the same slot.
- `test/services/produktsuche_gesamtfrist_test.dart`: die Fallback-Kette deckelt die Summe ihrer Beine, statt sie zu addieren (was 'die abgestimmten Ketten-Budgets stehen fest') — Pinned three tuning constants (12/24/30 s), so any legitimate retune turned it red.
- `test/services/produktsuche_leeres_ergebnis_test.dart`: file header — The header described a chain-budget carve-out (when the budget runs out, the clean answer already in hand stands).
- `test/meal_totals_test.dart`: file header — The header claimed 'the kcal override must preserve fields' is tested; no test does that.

**health_trends**

- `test/trends/trend_report_test.dart`: der laufende Tag zaehlt in keinem Schnitt, steht aber im Fenster — Today's 300 kcal is below the complete-day rule (half the goal), so it never reached the averages.
- `test/widgets/trends_screen_test.dart`: B6: der laufende Teiltag verwaessert die Kennzahlen nicht — Same vacuity: the 350 kcal breakfast is a partial day, so the averages were never diluted, whatever B6 does
- `test/widgets/goals_energy_adjustment_test.dart`: no offset or manual mode: no row / manual mode keeps its own goals and hides the row — The first name claims manual mode but tests only adjustment 0.
- `test/trends/trend_totals_cache_test.dart`: Tageswechsel laedt das Trendfenster neu (injizierte Uhr) — The name still said '90-Tage-Fenster', but the trend window is 182 days
- `test/home_store_day_load_test.dart`: Alt-Tag waehlen…, isLoadingFoodDay…, Fehler beim Nachladen…, Outbox-sicher…, Cache-Write-Through…, Naechste Session… — Six tests ran the 35-day window logic on the wall clock (unpinned clock.now() in both test and store), against the project rule 'tests never read the wall clock'

**home_app**

- `test/home_store_rollover_test.dart`: ein verarbeiteter Tageswechsel setzt den Timer neu -> ein Resume nach Tagen stellt den Timer auf die naechste Mitternacht — Only asserted debugMidnightTimerIsActive after a rollover.
- `test/onboarding_screen_test.dart`: age is clamped to a minimum of 16 (DSGVO Art. 8) -> merged into test/onboarding_flow_test.dart 'ein Stepper am Rand ist gesperrt, nicht tot… — Asserted only the picker's displayed '16'.
- `test/models/model_limits_test.dart`: Drift-Waechter: Konstanten == Endzustand der SQL-Migrationen (8 literal tests -> 4 migration-reading tests) — The comment said a migration change turns the group red, but every test compared a Dart constant with a hard-coded literal.
- `test/home_store_daily_activity_test.dart, test/home_store_edit_details_test.dart, test/home_page_lifecycle_test.dart, test/home_store_rollover_test.dart`: all 7 daily-activity tests, 8 edit-details tests, 'ohne Tageswechsel loest kein Notify einen Refresh aus', 'start() armiert den Timer, disp… — Date-dependent tests ('today', 'yesterday', archive days, the midnight timer) read the live clock through clock.now().

**meal_plan**

- `test/meal_plan/shopping_lines_test.dart`: section labels are shown but never checked -> section labels are no ingredients: the receipt leaves them out — The name describes the retired per-recipe receipt, which showed section labels.
- `test/design/meal_plan_capture_test.dart`: German weekly receipt: merged rows, pantry collapsed and expanded, ticked off to its stamp — `find.text('FÜR DEN PIZZABODEN:') findsNothing` matched only the uppercase section heading of the old receipt.
- `test/meal_plan/meal_plan_weekly_receipt_test.dart`: dieselbe Zutat aus zwei Mahlzeiten: eine Zeile mit Summe und Tagen, ein Tipp schreibt genau einen Haken — `find.text('HÄHNCHENPFANNE') findsNothing` matched only the retired uppercase recipe heading, so a recipe heading in any other casing would pass.
- `test/meal_plan/meal_plan_test.dart`: snapshot preserves original recipe and rejects malformed plans — `source.copyWith(title: 'Edited').title == 'Edited'` and the repeated `saved.recipe.title` check tested FitnessRecipe immutability, not the plan snapshot.
- `test/meal_plan/meal_plan_day_planning_test.dart`: die Tageszeile bleibt bei 320 px und doppelter Schrift lesbar — `getRect(line).right <= 320` is always true for a Text inside Expanded.

**misc**

- `test/support/harness_self_test.dart`: renderMatrix der skipOverflowCheck-Negativfall wurde ausgefuehrt — Read a global flag set by another test; under random ordering it ran first and failed.
- `test/support/harness_self_test.dart`: pumpLocalized setzt textScale und reducedMotion ueber dem Navigator — Read MediaQuery from the child, which sits below the Navigator.
- `test/widgets/design/rows_test.dart`: PageHeader onBack ersetzt das Poppen (now: onBack am backKey ersetzt das Poppen) — There was no route to pop, so a PageHeader that called onBack AND popped stayed green.
- `test/widgets/design/rows_test.dart`: PageHeader trailing landet rechts — Only asserted that the icon exists, not that it sits on the right.
- `test/widgets/design/surfaces_test.dart`: SectionHeading setzt den Titel links und den gedaempften Text rechts — Asserted text styles only; the left/right order named in the test was never checked.
- `test/widgets/design/sheets_test.dart`: SheetField suffix haengt rechts im Feld (merged into 'reicht Controller, onChanged, obscure, enabled und suffix an das Feld durch') — Only asserted that the suffix exists, not its position.
- `test/widgets/design/sheets_test.dart`: SheetField errorText erscheint in der Warnfarbe (now: in der Fehlerfarbe) — The name says warning colour but the test asserts t.danger.
- `test/describe/ui/describe_fakes.dart`: FakeSpeech (helper) — The fake differed from SpeechInput.listen: cancel ended with SpeechEnd.stopped instead of dismissed (both native sides answer reason 'cancel'), and a blank transcript came back as '' instead of null (lib/src/services/sp…
- `test/support/sync_operation_fake.dart`: SyncOperationFake weightInsert / favoriteUpsert (helper) — Accepted rows whose id or favorite_key differs from p_entity_id.

**recipes**

- `test/recipes_redesign_details_test.dart`: a very long shelf title stops at two lines and does not stretch the other cards — Order-dependent: the `< 200` px height pin only held after the text-scale group's setUpAll(loadDesignFonts) had loaded real fonts.
- `test/recipe_photo_delete_test.dart`: zugestellte Loeschung bewahrt das referenzierte Historienfoto -> 'ein Foto, das nur noch die Versionshistorie nennt, bleibt im Behalte-Satz… — The claimed guarantee was that history references keep the photo.
- `test/flows/recipes_flow_test.dart`: Recipe detail can add a meal into kcal and macro tracker; Recipe lands on the day selected in the food tab — Both flows ran on the real wall clock and computed the expected archive day from clock.now() (unpinned), so a run across midnight could flip the date-dependent expectations.

**settings_profile**

- `test/widgets/export_paket_export_sheet_test.dart`: die Karte zeigt hoechstens eine Vorschau — samt Hinweis — The name promises the 'preview shortened' hint for a large export, but no test anywhere asserted that the hint appears (only that it is absent for a short export).
- `test/reminders/reminder_settings_row_test.dart`: Schalter und Uhrzeit in den Einstellungen wirken sofort, Profil & Ziele zeigt dieselbe Zeit — The final 'goals page shows the same time' check used find.text, and the settings row shows the identical sentence, so it passed even if settings-open-goals never opened the goals page.
- `test/diet_preference_test.dart`: vegetarisch: kein Lachs/Rindersteak im Ziel-Match-Carousel / none: Lachs darf weiterhin als Ziel-Match erscheinen — For these macros salmon and steak never rank in the top 3 (chicken/turkey do; #1 is the hero, which is not in the carousel), so the PROD-6 vegetarian test passed with no diet filter at all.
- `test/services/notification_permission_state_test.dart`: abgelehnt: das persistierte Flag ist NICHT true und der Zustand ist blockiert, nicht aus — The name claims the state is blocked, but the test never asserted the state (a second test with the identical setup did).
- `test/services/notification_replan_test.dart`: eine neue Uhrzeit: erst alle Nudges weg, dann der neue Plan (moved from test/reminders/reminder_time_replan_test.dart) — 21:30 -> 06:45 at 09:00 moves the first slot to tomorrow and changes every day id, so a plan equality that ignores the time still saw a 'changed' plan.

**sync_storage-1**

- `test/home_store_snapshot_guard_test.dart`: A1: an offline boot never replaces an unusable profile blob with the ctor defaults (replaces 'A1: Lesefehler + Offline-Boot ...' and 'Kontr… — The old A1 test used a non-atomic KeyValueStore, and commitStoreSnapshot cannot write to that store at all, so the guard was never exercised.
- `test/outbox/outbox_replay_kursor_test.dart`: an op committed while a delivery is in flight runs in that same pass (replaces 'new entity appended during an in-flight pass is delivered i… — The name claimed delivery in the same pass.
- `test/outbox/outbox_replay_test.dart`: P1-02: ein Pass mit Erfolg UND liegengebliebener Op laesst den Wecker gestellt — The test held a hanging recipe request, so the pass never ended before the assertion.
- `test/services/favorites_pinned_sync_test.dart`: loadFavorites liest pinned zurueck (true und fehlend->false) — The name promised the missing-flag case, but the row sent 'pinned': false explicitly.
- `test/outbox/outbox_gift_budget_test.dart`: exhausted deletion stays hidden after cold start including archive age 60 — A row 60 days old is outside the boot load window, so it was never shown and 'stays hidden' could not fail.
- `test/pending_commit_input_test.dart`: pending manual commit blocks already focused keyboard editing — `if (hadInputClient)` silently skipped typing, so the test did not show that the keyboard was ever attached.
- `test/flows/offline_sync_flow_test.dart`: Offline geloggt: UI hält die Zeile, Outbox trägt sie, Replay stellt sie genau einmal zu — `requestsTo('logged_meals', method: 'POST') isEmpty` could never fail: the fake drops offline requests before recording them, and writes go through /rpc/apply_sync_operation.
- `test/clobber_guard_test.dart`: Offline-Kaltstart OHNE Cache: Verbindungs-Screen statt Onboarding, kein profiles-Write mit 78kg — The name promised the onboarding gate, but the test asserts the boot-unanswered screen and no onboarding.

**sync_storage-2**

- `test/services/local_cache_test.dart`: Zahlen-Muell im Blob liefert null statt erfundener Werte — The blob held only weight_kg, so the missing-field rule returned null and an unreadable number was never tested.
- `test/services/open_food_facts_wire_test.dart`: Barcode ohne kcal-Feld liefert nie ein 0-kcal-Ergebnis -> Barcode ohne kcal-Feld wird aus kJ umgerechnet, nie 0 kcal — anyOf accepted an exception or a result, so removing the kJ fallback stayed green; the code is deterministic.
- `test/services/secure_cache_store_test.dart`: InvalidCipherTextException ueberlebt den Isolate-Hop + manipulierter Ciphertext wirft -> Tag-Fehler kommen auch ueber den Isolate-Hop als I… — A 60-character payload is below inlineMaxChars (2000), so decrypt ran inline and never crossed the isolate the test name claims.
- `test/services/sync_outbox_test.dart`: isDelete erkennt genau die drei Loesch-Familien -> isDelete erkennt genau die Loesch-Familien, keine ausgelassen — Wrong name and incomplete: there are six delete kinds; weightDelete, trainingPlanDelete and trainingHistoryDelete were unchecked.
- `test/services/privacy_cache_deletion_test.dart`: account deletion clears every A slot ... / logout preserves only durable recovery slots ... — The 'independent inventory' left out the health_prompt slot.
- `test/wire_persisted_key_names_test.dart`: jeder Slot traegt exakt seinen erwarteten Namen — The comment claimed completeness, but the test wrote only 12 of 21 per-user slots, so renaming training_plans and 8 others went unnoticed.
- `test/services/sync_operation_sync_test.dart`: loadReceipt / invalid operation and changed account issue no HTTP request (moved from sync_receipt_read_test) — throwsA(isA<Exception>()) accepted any exception.
- `test/settings/settings_ai_data_test.dart`: Export: "Als Datei teilen" bekommt den ganzen Export -> ... nutzt den Teilen-Weg der Einstellungen — The name claimed the full export, but the test only checks the call count and the file name.
- `test/services/local_cache_snapshot_fence_test.dart`: nur bewachte Slots werden nicht dekodiert -> ein nur bewachter, nicht geschriebener Slot wird nicht dekodiert — The name said the opposite of what the test asserts.
- `test/wire_meals_sync_window_test.dart`: Boot-Fenster / Zeilen-Deckel / LoggedMeal-Konstruktion — Rows and the code under test both used an unpinned clock.now(), i.e.

**tooling**

- `test/widgets/trends_step_bonus_wiring_test.dart (replaces test/widgets/fixwelle_trends_wiring_test.dart)`: the Food tab opens Trends with the store's step bonus — The old tests mounted MealAnalysisScreen alone and drove its own _openTrends fallback through trendBurnedKcalFor.
- `test/migrations/profile_columns_contract_test.dart (replaces fixlauf_g_manual_energy_migration_test.dart)`: the live apply_sync_operation inserts and updates every column the client sends — 'Live-Profil-Operation transportiert und schreibt manual_energy' read 20260920101000_sync_operation_receipts.sql.
- `test/migration_user_recipes_limits_test.dart`: JEDE client-beschreibbare Spalte von user_recipes hat eine Grenze — The column list came only from the frozen 20260530 create-table file and the bounds only from 20260819.
- `test/wiring_meal_camera_capture_scrub_test.dart`: C4-Verdrahtung: das mit der IN-APP-KAMERA aufgenommene Foto verlaesst das Sheet ohne EXIF/GPS und auf 1600 px gekappt — Set the global CameraPlatform.instance and never restored it (global state left behind).

**training-1**

- `test/training/training_adoption_store_test.dart (merged from training_adoption_frontier_store_test.dart)`: a live head-conflict receipt protects durable completion — The durable-completion branch called store.saveTrainingSession(saved, generation, sourcePlanId) and ignored the result.
- `test/flows/training_shell_flow_test.dart`: sign out during recovery repair cannot open a player — Order dependence: after 'Training opens its brief on first and cached Coach mount without sending' the test hung until the 10-minute timeout, and the following tests then timed out too.
- `test/training/training_history_screen_test.dart`: actual input, last time, failed completion and retry preserve one immutable candidate; history and detail reflow at 320 px and 2x text in d… — _saveImage wrote PNGs to build/training-history-qa on every normal and CI run, and nothing reads that folder.
- `test/models/training_log_test.dart`: loggedWorkoutTimes an earlier day keeps the local time of day across DST — `if (naive.hour != 9) expect(naive.hour, 10)` tested Dart's DateTime arithmetic, not the app.

**training-2**

- `test/training/training_store_test.dart`: unrelated deletion keeps the active route checkpoint generation valid — Ignored the save result and asserted trainingSession isNotNull, which was already true before the save, so a refused save stayed green.
- `test/training/training_store_test.dart`: unreadable recovery cannot resurrect an acknowledged delete on offline reboot -> a source delete refused while its recovery is unreadable s… — try/catch either/or test.
- `test/training/training_store_test.dart`: unknown plan library preserves full recovery across offline reboot; stale cached library preserves newer full recovery: $mirror — Called saveTrainingSession without checking the result, then asserted a session that was already equal, so a refused save passed.
- `test/training/training_player_screen_test.dart`: external route removal queues a final checkpoint that keeps the running deadline — Only compared writes.last.phaseEndsAt with the earlier checkpoint's deadline, which also holds when no final checkpoint is written.
- `test/training/training_history_test.dart`: reject duplicate identities, timestamp inversion, mismatched IDs and missing actuals -> rejects a mismatched row ID, a finish before the st… — The name claims 'missing actuals' but nothing in the test asserts it.
- `test/training_qa/readoption_online_flow_test.dart`: the same Coach proposal can be adopted again after an online delete — The tail replayed the original RPC through client.rpc into the FixlaufServer fake and asserted the fake's rows.
- `test/training/training_volume_card_test.dart`: German captions and share line -> a picked week names its date in the app language — Mostly re-pinned ARB copy.
- `test/training/training_store_test.dart`: failed local deletion never starts HTTP, keeps the plan and its selection and never retires confirmed recovery (merge target) — The selection assertion merged in from 'failed offline deletion leaves the last confirmed plan visible' was vacuous with one plan: selectedTrainingPlan falls back to the first plan.

**deno-coach-chat**

- `supabase/functions/coach-chat/handler_cors_test.ts`: * (module setup; both remaining CORS tests) — The file set EATOVA_ALLOWED_ORIGINS before importing handler.ts and never restored it.
- `supabase/functions/coach-chat/handler_test.ts`: Begruessung und Rezeptname umgehen keine Sicherheitskategorie -> Chat-Text: jede Sicherheitskategorie lehnt mit ihrem Katalogtext ab, ohne … — The name claims that greeting or recipe-name text cannot bypass a safety category.
- `supabase/functions/coach-chat/handler_stream_test.ts`: A3: ein __REFUSE__-Kopf erzeugt NULL deltas (+ 'Marker ueber mehrere Bloecke', 'fuehrender Leerraum', 'auch die Refusal ohne deltas gibt de… — These tests are named after the head check, but since #90 nothing leaves before final approval.
- `supabase/functions/coach-chat/handler_plan_test.ts`: plan handler: empty command, unsafe text and photo combination never buy a paid call — The photo cases checked only status 400.

**deno-other-functions**

- `supabase/functions/_shared/provider_budget_test.ts`: provider budget abort before execution cannot reserve or start work — The assertion sat inside the catch block.
- `supabase/functions/recipe-import/handler_test.ts`: recipe-import P7-02: a replayed revoked token costs exactly two lookups (was '... at most two lookups') — `lookups <= 2` also passed with one strike, so losing the two-strike tolerance for GoTrue flakes stayed green here.
- `supabase/functions/analyze-meal/handler_test.ts`: Erfolgsfall -> 200 mit normalisiertem Ergebnis und Rate-Limit-Stand — The assertion labelled 'MIME-Typ aus den Bytes, nicht aus dem Praefix' sent data:image/png with PNG bytes, so it could never tell the bytes from the label.
- `supabase/functions/_shared/rate_limit_prune_test.ts`: REGRESSION: ein rejectender fetch schlaegt nicht nach aussen durch — Half the test asserted that naiverPrune, a test-local replica of the old code, rejects.
- `supabase/functions/_shared/provider_log_test.ts`: P6-04c: Kappen ist kein Ersatz (merged into 'P6-04b: alles andere wird zur Kategorie verdichtet, nie zitiert oder gekappt') — `!leak.slice(0, 32).includes(String(logged))` cannot fail once `logged === 'other'` has been asserted, and the rest repeated P6-04b.
- `supabase/functions/_shared/claude_test.ts`: a cut emoji never reaches the API as a lone surrogate — One assertion compared JSON.stringify of a literal with its own toWellFormed(), which tests the JS runtime, not claude.ts.
- `supabase/functions/analyze-meal/handler_test.ts`: F9-01: User-Tageslimit erschoepft -> 429 vor dem globalen Gate — Coverage preservation, not a defect: the deleted describe-mode gate test was the only check that a day-gate denial reserves no shared provider budget.

**python-sql**

- `test/operations/release_test.py`: test_a_release_without_a_sentry_dsn_is_refused -> test_a_release_without_required_defines_or_with_broken_json_is_refused — The name said only a missing Sentry DSN is refused, but the test also asserts missing or blank SUPABASE_URL, missing or blank SUPABASE_ANON_KEY, and broken JSON.
