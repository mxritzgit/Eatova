# Abarbeitung des Reviews vom 2026-08-08 — Design

**Basis:** `docs/REVIEW-2026-08-08.md` (61 Funde) · **Branch:** `fix/review-2026-08-08` · **Ausgangs-Commit:** `7f895f9`
**Baseline vor der ersten Änderung:** `flutter test` → **442 passed, 0 failed**, 31 s.

---

## 1 · Problem

Der Review listet 61 Funde. Eine naive Aufteilung „ein Agent pro Fund" ist unmöglich: die Funde verteilen sich nicht auf 61 Dateien, sondern ballen sich auf wenigen.

| Datei | Funde |
|---|---|
| `app/eatova_home_page.dart` | A4, B4, C8, D6, D7, G11 |
| `app/home_store_sync.dart` | A2, A4, A6, A8, D9 |
| `models/meal_analysis_result.dart` | B1, B7, B8 |
| `services/local_cache.dart` | A2, A7, G9 |
| `widgets/shared/settings_sheet.dart` | B2, C1, D5 |
| `android/.../AndroidManifest.xml` | D1, E1, E4 |

Zusätzlich sind zwei Funde echte Querschnitte: **B5** (DST-Datumsarithmetik) berührt fünf Dateien, die vier anderen Funden gehören; die **Clamps** aus Runde 1 gehören an fünf verschiedene Modellgrenzen.

## 2 · Lösung

### Grundprinzip

**Datei-Eigentum statt Fund-Zuteilung.** Ein Agent besitzt einen Dateisatz exklusiv und erledigt alle Funde darin. Innerhalb einer Welle sind die Dateisätze disjunkt — Schreibkonflikte sind konstruktiv ausgeschlossen, nicht durch Absprache.

### Querschnitte werden zu Fundamenten

Statt sie aufzuteilen, bekommen sie in Welle 1 je eine eigene neue Datei, die spätere Wellen nur noch anwenden:

- **`lib/src/services/day_math.dart`** — Kalenderarithmetik (`DateTime(y, m, d ± n)` statt `Duration`), Tagesdifferenz über `(y,m,d)`-Tripel. Welle 1 baut Utility + Tests, ändert **keine** Aufrufer.
- **`lib/src/models/model_limits.dart`** — die DB-Constraint-Grenzen als Konstanten plus Clamp-Helfer. Welle 1 baut Konstanten + Tests, ändert **keine** Aufrufer.

### Wellen mit zentralem Gate

Fünf Wellen. Zwischen den Wellen läuft zentral `flutter analyze` + die volle Suite; erst bei Grün startet die nächste Welle und wird committet. Fünf Commits = fünf Rollback-Punkte.

---

## 3 · Die 30 Agents

### Welle 1 · Fundament & Datenverlust (7)

| # | Besitzt | Funde |
|---|---|---|
| W1-01 | `services/secure_cache_store.dart`, `config/supabase_config.dart` | A1, G9a, C5 |
| W1-02 | `services/sync_outbox.dart`, `services/sync_error_messages.dart` | A3, A5, `23514`→`retryCounted` |
| W1-03 | `app/home_store_sync.dart` | A2, A4, A6, A8, D9 |
| W1-04 | `services/local_cache.dart` | A7, A2-Gegenstück, G9b |
| W1-05 | **neu** `services/day_math.dart` | B5-Fundament |
| W1-06 | **neu** `models/model_limits.dart` | Clamp-Fundament |
| W1-07 | `services/crash_reporter.dart` + Test | C1, G3 |

### Welle 2 · Modelle & Domänenlogik (8)

| # | Besitzt | Funde |
|---|---|---|
| W2-01 | `supabase/functions/analyze-meal/**` | B1-Server |
| W2-02 | `models/meal_analysis_result.dart`, `models/meal_component.dart` | B1-Client, B7-Modell, B8 |
| W2-03 | `services/kcal_calculator.dart`, `models/user_profile.dart` | B2, G4 |
| W2-04 | `services/apple_health_service.dart`, `widgets/profile/profile_widgets_actions.dart` | B3 |
| W2-05 | `services/trend_service.dart`, `screens/trends_screen.dart` | B6, B5-Anwendung |
| W2-06 | `app/home_store.dart`, `app/home_store_meals.dart`, `app/home_store_tracking.dart`, `models/lifetime_stats.dart` | B4, B5-Anwendung, `workouts`-Leiche |
| W2-07 | `app/home_store_profile.dart`, `services/notification_service.dart`, `services/streak_reminder_planner.dart` | D10, D11 |
| W2-08 | `services/open_food_facts_product_service.dart`, `services/fallback_product_service.dart` | B7-Service, G2-Schalter 2 |

### Welle 3 · UI, Navigation, Zustand (9)

| # | Besitzt | Funde |
|---|---|---|
| W3-01 | `app/eatova_home_page.dart`, `widgets/common/store_selector.dart` | D6, D7, G11 |
| W3-02 | `screens/onboarding_screen.dart` | D4 |
| W3-03 | `screens/meal_camera_sheet.dart`, `services/meal_photo_compressor.dart` | D3, C4 |
| W3-04 | `widgets/shared/settings_sheet.dart` | D5, C1-Feldclamps, B2-Anzeige |
| W3-05 | `widgets/kcal/edit_meal_sheet.dart`, `screens/recipes/recipe_create_sheet.dart` | D5, B5-Anwendung |
| W3-06 | `screens/recipes/recipes_header.dart`, `screens/recipes/recipes_screen.dart` + parts | D6-Suchfeld |
| W3-07 | `screens/meal_analysis_screen.dart`, `widgets/kcal/meal_analysis_sheet.dart`, `widgets/meal/meal_widgets_adjust.dart` | B5-Datumsleiste, B1-Speicherpfad, G2-Schalter 5 |
| W3-08 | `app/auth_gate.dart`, `widgets/kcal/calories_overview_card.dart` | D8, G10 |
| W3-09 | `services/coach_chat_service.dart` + Test, `screens/coach/**` | D2, G1, C8 |

### Welle 4 · Plattform (4)

| # | Besitzt | Funde |
|---|---|---|
| W4-01 | `android/app/src/main/AndroidManifest.xml` | D1, E1, E4 |
| W4-02 | `android/gradle.properties`, `android/app/proguard-rules.pro`, `android/app/build.gradle.kts` | E2, E5 |
| W4-03 | `ios/Podfile`, `ios/Runner.xcodeproj/project.pbxproj` | F1, F7 |
| W4-04 | `ios/Runner/Info.plist`, **neu** `ios/Runner/PrivacyInfo.xcprivacy`, `ios/Runner/AppDelegate.swift` | F3, F4, F5, F6 |

### Welle 5 · CI & Wire-Tests (2)

| # | Besitzt | Funde |
|---|---|---|
| W5-01 | `.github/workflows/security.yml` | G6, G8 |
| W5-02 | `test/services/**` (nur neue Dateien) | G2 — die fünf Ein-Token-Schalter |

---

## 4 · Agent-Vertrag

Für alle 30 identisch:

1. Eigenen Abschnitt in `docs/REVIEW-2026-08-08.md` lesen.
2. **Nur in den eigenen Dateisatz schreiben**, plus eigene neue Testdateien. Wird eine fremde Datei gebraucht → im Bericht melden, nicht anfassen.
3. **Rot zuerst.** Test schreiben, der das Fehlerszenario aus dem Review nachstellt. `flutter test <eigene Testdatei>` laufen lassen. **Die rote Ausgabe wörtlich in den Bericht.** Ohne rote Ausgabe gilt der Fix als unbelegt.
4. Fix umsetzen, grüne Ausgabe zitieren.
5. **Niemals die volle Suite laufen lassen** — der Baum gehört zeitgleich anderen Agents.

Flutter: `C:\Users\morit\Desktop\Flutter\flutter\bin\flutter.bat` (nicht auf PATH).

## 5 · Festgelegte Schnittstellen zwischen Agents

Wo zwei Agents in derselben Welle gegen dieselbe Signatur bauen, ist sie hier verbindlich festgelegt — beide schreiben dagegen, das Gate löst die transiente Inkonsistenz auf.

**A2 (W1-03 ↔ W1-04):**
```dart
// local_cache.dart — W1-04 implementiert
Future<void> clear({bool preserveOutbox = false});
// preserveOutbox: true  → _outboxKey und _pendingStatsKey bleiben erhalten,
//                         alles andere wird gelöscht

// home_store_sync.dart — W1-03 ruft auf
Future<void> signOutCleanup() async {
  await _replayOutbox();                      // Zustellversuch vor dem Verwerfen
  final rest = /* verbleibende Ops */;
  await notificationService.cancelAll();       // D9
  await _cache.clear(preserveOutbox: rest > 0);
}
```

## 6 · Verifikation

Fünf Agents mit fünf verschiedenen Linsen, nach Welle 5:

| | Linse |
|---|---|
| V1 | Funde A + B einzeln am Code nachvollziehen — ist das Szenario noch reproduzierbar? |
| V2 | Funde C – G dito |
| V3 | **Mutationstest**: jeden Fix einzeln zurücksetzen, belegen dass der zugehörige Test rot wird, byte-identisch wiederherstellen |
| V4 | Kollateral-Review über den vollen Diff: Nebenwirkungen ohne Testabdeckung |
| V5 | Werkzeugkette: `flutter analyze`, volle Suite, `deno test`, `flutter build appbundle --release` |

## 7 · Bewusst ausgeklammert

| Fund | Grund |
|---|---|
| **F2** `Podfile.lock` | Braucht `pod install` auf einem Mac. F1 (Deployment-Target) wird gesetzt, der Lock bleibt bis dahin inkonsistent. |
| **G5** Branch-Protection, **G7** Supabase-Secrets | GitHub-Einstellungen außerhalb des Repos. Befehle/Klickpfade werden am Ende geliefert. |
| **C2/C3** `PRIVACY.md`, eatova.de | Die maßgebliche Fassung liegt auf der Website, außerhalb des Repos. `PRIVACY.md` kann auf Zuruf nachgezogen werden. |
| **C6** getrennte Art.-9-Einwilligung, **C7** vollständiger Export, **C9** Löschfristen | Produkt-/UX-Entscheidungen, keine Bugfixes. |
| **C10** Alters-Migration | Bereits angewendet; nachträglich nicht reparierbar. |
| **E3**, **E6** | Feststellung bzw. Responsive-Umbau — eigenes Projekt. |

## 8 · Risiken

- **Welle-interne Kompilierfehler.** Testdatei von Agent A importiert eine Datei, die Agent B gerade editiert. Agents versuchen einmal erneut; das Gate fängt den Rest. Eingeplant, kein Fehlerfall.
- **W1-03 ist der dickste Brocken** — fünf Funde in einer Datei, mit einer Schnittstelle zu W1-04 (siehe §5).
- **Der Aufwand ist erheblich.** 30 Agents mit TDD-Pflicht ist der Preis dafür, dass am Ende jeder Fix durch einen Test belegt ist, der ohne ihn rot wird.
