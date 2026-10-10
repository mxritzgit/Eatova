# Eatova – Feature-Lücken, zweite Runde

> Historical record: statements and open items below describe the dated
> source, not the current product. See the [current feature inventory](FEATURES.md)
> and [documentation index](README.md) for implemented behavior.

Stand: 2026-10-10, geprüfter Code `e59f812` (main `2ddf1e0` plus Handoff-Eintrag).
Fünf Subagents prüften je einen Bereich: Essen erfassen, Rezepte/Planung/Einkauf,
Training/Körper/Health, Coach/Insights, Wachstum/Release. Die Hauptinstanz
glich die tragenden Befunde stichprobenartig mit dem Code ab und führte doppelte
Befunde zusammen.

Seit dem [Review vom 2026-09-10](FEATURE-REVIEW-2026-09-10.md) sind dessen
Kernlücken geschlossen (Rezepte bearbeiten, Trainingsverlauf mit Ist-Werten,
Health Connect, Zutatenrechner, Speiseplan, Einkaufszettel). Offen geblieben
sind F6 (mehrere Einträge kopieren), F8 (Ernährungsform später ändern) und
F9 (Export als Datei teilen).

Die Prüfung war ein Quelltext- und Dokumentationsreview mit wenigen Websuchen
zu Wettbewerbern und Store-Regeln. Keine App-Flows, Tests oder Live-Systeme.
Die Gewichtung ist eine Produktempfehlung, keine belegte Nachfrage und kein
Umsetzungsauftrag. Wasser, Schlaf und Habits bleiben bewusst entfernt; das
Kalorienmodell (Gewichtstrend plus wöchentliche Kalibrierung) bleibt unverändert.

## Priorisierte Übersicht

P1 = als Nächstes sinnvoll, P2 = danach, P3 = später. S/M/L sind relative
Umfänge einschließlich Speicherung, Lokalisierung und Tests.

| ID | Lücke | Prio | Umfang | Kernnutzen |
| --- | --- | --- | --- | --- |
| R1 | Sign in with Apple und Release-Lane (TestFlight, Play-Upload) | P1 | M | App-Store-Freigabe (Guideline 4.8) |
| R2 | Einwilligung vor KI-Datenweitergabe, KI-Antwort melden | P1 | S–M | Apple 5.1.2(i), Play-KI-Richtlinie, DSGVO Art. 9 |
| R3 | Abo, Paywall und Quoten je Stufe | P1 vor Wachstum | L | Umsatz; globale KI-Grenze, Standard 1.000 Aufrufe/Tag |
| E1 | Mahlzeiten kopieren (Slot, Tag, Mehrfachauswahl) | P1 | M | Größter täglicher Zeitgewinn |
| E2 | Mahlzeit per Text oder Sprache beschreiben | P1 | M | Erfassen ohne Foto und ohne Suche |
| E3 | Eigene Historie durchsuchen, längere Zuletzt-Liste | P1 | S–M | Schnell wieder eintragen |
| C1 | Wöchentlicher Check-in, jede Woche | P1 | S–M | Fortschritt sichtbar, Bindung |
| C2 | Coach kennt mehr als heute | P1 | M | „Warum nehme ich nicht ab?“ beantwortbar |
| C3 | Essensvorlieben, Allergien, Ernährungsform ändern | P1 | M | Passende Rezepte und Antworten |
| C4 | Erinnerungen mit Uhrzeit und Anlass | P1 | S–M | Bindung |
| P1 | Tagessummen gegen Ziel im Wochenplan | P1 | S | Plan prüfbar |
| P2 | Eigene Artikel, Vorrat, „schon zu Hause“ | P1 | M | Echte Einkaufsliste |
| P3 | Liste und Rezept als Text teilen | P1 | S | Einkauf mit Partner |
| T1 | Übungsfortschritt und Bestleistungen | P1 | M | Kern-Motivation im Training |
| T2 | Gewicht aus Waage/Health mit Messzeit, Einträge bearbeiten | P1 | M | Trend ohne manuelle Eingabe |
| E4 | Schnell-Eintrag mit Gesamt-kcal und Makros | P2 | S | Restaurantessen |
| E5 | Eigene Lebensmittel, unbekannte Barcodes merken | P2 | M | Lücken der Datenbank schließen |
| E6 | Portionseinheiten (Stück, Scheibe, ml, EL) | P2 | M | Natürliche Mengen |
| E7 | Ballaststoffe, Zucker, gesättigte Fette, Salz | P2 | M | Ernährungsqualität |
| P4 | Schneller planen: aus Rezept, Woche kopieren, Reste | P2 | S–M | Weniger Tippen |
| P5 | Gleiche Zutaten zusammenfassen, nach Gang sortieren | P2 | M | Kürzere Liste |
| P6 | Kochmodus mit Portionsregler und Timern | P2 | M | Rezepte nutzen |
| P7 | Tags und Sammlungen für eigene Rezepte | P2 | S–M | Eigene Rezepte auffindbar |
| P8 | Import von Rezeptseiten und Fotos | P2 | M–L | Mehr Quellen als TikTok |
| C5 | Coach plant eine Woche in den Plan | P2 | L | Planung auf Knopfdruck |
| C6 | Sichtbares, editierbares Coach-Gedächtnis | P2 | M | Persönlicher Coach |
| T3 | Steigerungshinweis beim nächsten Training | P2 | S | Fortschritt |
| T4 | Körpermaße und Fortschrittsfotos | P2 | M | Erfolg jenseits der Waage |
| T5 | Gewichtsdiagramm mit Zeitachse und Bereichen | P2 | S–M | Trend lesbar |
| T6 | Satztypen, Supersätze, RPE | P2 | L | Ernsthaftes Krafttraining |
| T7 | Training live und nachträglich ändern | P2 | M | Flexibilität |
| X1 | Imperiale Einheiten | P2 | M | US/UK-Markt |
| X2 | Weitere Sprachen | P2 | L je Sprache | Neue Märkte |
| X3 | Bewertungsdialog, Support/Feedback, Neuigkeiten | P2 | S | Bewertungen, Kontakt |
| X4 | Widgets, Quick Actions, Live Activity | P2–P3 | M–L | Präsenz außerhalb der App |
| T8 | Workouts und Nährwerte mit Health austauschen | P3 | M–L | Ökosystem |
| E8 | Ziele je Tag (Trainings-/Ruhetag) | P3 | M–L | Fortgeschrittene Nutzer |
| X5 | Erfolge, iPad, Watch | P3 | M–L | Spätere Reichweite |

## Kleine Lücken, fast Fehler

Diese sind klein, im Code belegt und fühlen sich für Nutzer wie Fehler an:

- **Export als Datei (F9 offen):** Der Teilen-Knopf erscheint nur mit
  `dateiTeilen`, das die Einstellungen nie übergeben
  ([Exportblatt](../lib/src/widgets/shared/data_export_sheet.dart#L295),
  [Einstellungen](../lib/src/screens/settings/settings_screen.dart#L450)).
- **Unbekannter Barcode:** Die manuelle Eingabe öffnet ohne den Code; ein
  zweiter Scan desselben Produkts findet nichts
  ([Barcode-Pfad](../lib/src/widgets/kcal/add_meal_sheet.dart#L947)).
- **Health-Gewicht mit Importzeit:** Der Gewichtswert aus Apple Health wird
  angeboten und mit `clock.now()` gespeichert, nicht mit der Messzeit
  ([Angebot](../lib/src/app/home_store_tracking.dart#L127),
  [Speichern](../lib/src/app/home_store_tracking.dart#L344)).
- **Gestrige Planmahlzeit zählt für heute:** Abhaken loggt immer mit `now`,
  auch bei vergangenen Plantagen ([Umwandlung](../lib/src/app/home_store_meal_plan.dart#L83)).
  Der Text sagt „heute“; ob das gewollt ist, entscheidet der Owner.
- **Eigene Rezepte nur „Eigene“:** Eigene, importierte und Coach-Rezepte
  erhalten keine weiteren Kategorien
  ([Kategorien](../lib/src/screens/recipes/recipe_create_sheet.dart#L600)) und
  erscheinen deshalb nie unter Frühstück, Vegetarisch oder High Protein.
- **Ernährungsform (F8 offen):** Nur im Onboarding wählbar
  ([Inventar](FEATURES.md)).

## Release und Geschäft

**R1 – Apple-Login und Auslieferung.** Die Anmeldung bietet nur Google
([Auth](../lib/src/screens/auth_screen.dart#L343)); ein Apple-Wert in
`auth_repository.dart` ist ungenutzt, die Entitlements enthalten kein
`applesignin`. iOS-CI baut mit `--no-codesign`; es gibt keinen TestFlight-
oder Play-Upload. Kontolöschung muss das Apple-Token widerrufen.

**R2 – KI-Einwilligung.** Der Coach nennt Anthropic nur im Info-Blatt, der
Meal-Scan schickt Fotos ohne Hinweis im Ablauf. Eine pro Konto gespeicherte
Einwilligung vor der ersten KI-Nutzung fehlt, ebenso „Antwort melden“. Die
veröffentlichte Datenschutzerklärung nennt noch OpenRouter/Google (siehe
Handoff „Claude Sonnet 5.5“).

**R3 – Monetarisierung.** Kein Kauf-Code im Repo. Alle Nutzer haben dieselben
Grenzen: Coach 5/Tag ([Grenze](../supabase/functions/coach-chat/handler.ts#L109)),
Scans 100/Tag. Die Berechtigung muss serverseitig bleiben; der Server lehnt
`isPremium` vom Client bereits ab.

## Essen erfassen

**E1 – Kopieren.** Wischen löscht nur, das Bearbeitungsblatt ändert Portion,
Slot und Tag. „Frühstück von gestern“, ganzer Tag oder Mehrfachauswahl fehlen.
Ein Stapel `SyncOp.mealInsert` mit neuen UUIDs, keine Migration.

**E2 – Beschreiben.** `analyze-meal` verlangt ein Bild
([missing_image](../supabase/functions/analyze-meal/handler.ts#L910)); `/log`
im Coach gilt nur für Training. Vorschlag: ein Textmodus, der eine bearbeitbare
Vorschau öffnet; geschrieben wird erst mit „Hinzufügen“ wie bei `/log`.

**E3 – Historie.** Nur fünf automatische Zuletzt-Einträge
([Grenze](../lib/src/app/home_store_meals.dart#L352)); die Suche im
Hinzufügen-Blatt fragt nur die Produktdatenbank, nicht eigene Einträge oder Rezepte.

**E4–E8.** Manuelle Eingabe verlangt kcal pro 100 g und Gramm. Portionen
nur in Gramm. Nur Protein, Kohlenhydrate und Fett werden gelesen, obwohl Open
Food Facts Ballaststoffe, Zucker, gesättigte Fette und Salz liefert. Ziele je
Tag müssen im Wochenmittel dem Planziel entsprechen, damit die Kalibrierung gilt.

## Rezepte, Planung, Einkauf

**P1 – Tagessummen.** Jede Planzeile zeigt kcal, der Tageskopf keine Summe
([Kopf](../lib/src/screens/recipes/meal_plan_week.dart#L8)). Gegen das
Grundziel vergleichen; nicht berechenbare Mahlzeiten als unvollständig zeigen.

**P2 – Eigene Artikel.** Die Liste entsteht nur aus geplanten Mahlzeiten;
der Server speichert nur Häkchen. Eigene Artikel und Vorrat brauchen Migration,
Sync-Op, Export und Löschkaskade.

**P3 – Teilen.** Kein Share-Paket in `pubspec.yaml`. Text reicht für Liste und
Rezept; generierte Bilder bleiben auf dem Gerät. Eine gemeinsam bearbeitete
Liste widerspricht dem RLS-Modell pro Konto und ist zurückgestellt.

**P4–P8.** Planen geht nur aus dem Planer. Zusammenfassen nur bei strukturierten
Zutaten mit gleichem Schlüssel; die 30 Katalogrezepte je Sprache haben keine.
Zusammenfassen nur bei identischem Namen und Einheit, mit Herkunft. Kochmodus
kann `ScreenAwake` und die Timer-Infrastruktur des Trainings nutzen. Import
von beliebigen Seiten braucht SSRF-Schutz.

## Coach und Insights

**C1 – Wochen-Check-in.** Der Energie-Check erscheint nur bei einem
Anpassungsvorschlag. Ein wöchentlicher Bericht mit Durchschnitt, Gewichts-
änderung gegen Plan, Protein-Tagen und Erfassungstreue ist rein clientseitig.

**C2 – Kontext.** Der Coach erhält nur heute, begrenzt auf 1.200 Zeichen
([Grenze](../supabase/functions/coach-chat/guardrails.ts#L147)). Es fehlen
7-Tage-Mittel, tatsächliche Gewichtsrate, Wochenplan und Training. Mehr Daten
an Anthropic heißt auch: Info-Blatt und Datenschutzerklärung anpassen.

**C3 – Vorlieben.** Allergien, Unverträglichkeiten und Abneigungen kommen nur
als „keine Allergie-Garantie“ vor
([Profil](../lib/src/models/user_profile.dart#L65)). `/recipe` sieht die
Ernährungsform nicht. Als „berücksichtigt, nicht garantiert“ kennzeichnen.

**C4 – Erinnerungen.** Fest 20 Uhr
([Planer](../lib/src/services/streak_reminder_planner.dart#L12)); keine
Uhrzeit, keine Mahlzeit-, Wiege- oder Wochenerinnerung.

**C5–C7.** Wochenplan vom Coach nur als Vorschlag mit ausdrücklicher Übernahme
und Prüfung der Rezept-IDs. Gedächtnis nur mit Bestätigung, Export und Löschung.
Zieländerung aus dem Chat nur über die bestehenden Unter- und Obergrenzen.

## Training und Körper

**T1 – Bestleistungen.** e1RM wird berechnet, aber nur als „2 PRs“ in der
Liste gezeigt ([Insights](../lib/src/models/training_insights.dart#L460)).
Rekorde gelten je Plan; Übungen sind nur über den Namen identifiziert.

**T2 – Gewicht.** iOS liest 90 Tage, nutzt aber nur den neuesten Wert; Android
liest kein Gewicht ([Manifest](../android/app/src/main/AndroidManifest.xml#L6)).
Gewichtseinträge lassen sich nicht datieren, ändern oder löschen; RLS erlaubt
Löschen bereits. Eigene Rückschreibungen nach HealthKit beim Import ausfiltern.

**T3–T7.** Steigerungshinweis nur als Vorschlag mit Tap; automatische
Progression wurde am 2026-09-10 bewusst zurückgestellt. Körperfotos bleiben wie
Rezeptbilder auf dem Gerät. Satztypen brauchen ein Planformat v2 in Dart, TS
und SQL mit Migration vor dem Client.

## Reichweite

Nur Deutsch und Englisch, auch im Backend. Nur metrisch. Nur iPhone im
Hochformat. Kein Bewertungsdialog, keine Kontakt- oder Feedbackzeile, keine
Widgets oder Quick Actions. Widget-Daten liegen außerhalb des verschlüsselten
Caches und müssen beim Abmelden gelöscht werden.

## Empfohlene Reihenfolge

1. Vor dem Store-Start: R1 und R2.
2. Ein Paket kleiner Lücken: die Liste oben plus E4, P1, P3.
3. Erfassen beschleunigen: E1, E3, dann E2.
4. Bindung: C1, C4, T1, T2.
5. Vor bezahlter Reichweite: R3.

## Bereits vorhanden

Fotoscan mit Kontext, Barcode mit manueller Eingabe, Produktsuche, Favoriten
mit Suche und Sortierung, Einträge bearbeiten und verschieben, Kalender zwei
Jahre zurück, 7/30/90-Tage-Trends, Makroziele, Schrittgutschrift, wöchentliche
Kalibrierung, Rezepte mit Versionen und strukturierten Zutaten, TikTok-Video-
und Fotoimport, Wochenplan, Einkaufszettel pro Zeile, Trainingsverlauf mit
Ist-Werten und „Letztes Mal“, Pausen-Timer mit Hintergrundalarm, Coach mit
`/recipe`, `/plan`, `/log` und Bestätigung, Kontolöschung, JSON-Export,
Privacy Manifest und gute Barrierefreiheit.

## Nicht geprüft

Nutzungsdaten, Zahlungsbereitschaft, Store-Konsolen (Play Data safety,
Health-Connect-Erklärung, Löschungs-URL), installierte Geräteversion und der
Meilisearch-Import auf dem Server. Wettbewerberangaben stammen aus wenigen
Websuchen und Produktwissen.
