# Eatova – Review wichtiger Feature-Lücken

Stand: 2026-09-10, geprüfter Code `1b03c18de87746e4b84192051088e5dc6e48125c`.
Ausgangslage: sauberes lokales `main`. Drei Subagents prüften Ernährung/Rezepte,
Training/Coach und Onboarding/Integrationen. Die Hauptinstanz glich ihre Befunde
mit dem aktuellen Code, späteren Handoff-Einträgen und historischen Entscheidungen ab.

Eatova deckt das Erfassen von Ernährung bereits breit ab. Den größten zusätzlichen
Nutzen erwarten wir beim Weiterverwenden eigener Rezepte, beim dauerhaften
Trainingsfortschritt und bei der Android-Schrittanbindung. Diese Gewichtung ist
eine Produktempfehlung, keine durch Nutzungsdaten oder Interviews bestätigte Nachfrage.

Die Prüfung war ein Quelltext- und Dokumentationsreview. Es wurden keine App-Flows
ausgeführt, Tests gestartet oder Live-Systeme geprüft. Alte Testergebnisse sind
keine neue Verifikation. Änderungen beschränken sich auf diesen Bericht und den
gemeinsamen Handoff; keine Implementierung, kein Commit oder Deployment.

Die anschließend beauftragte Umsetzung der sechs ausgewählten Funktionen ist in
[CORE-FEATURES-IMPLEMENTATION-2026-09-10.md](CORE-FEATURES-IMPLEMENTATION-2026-09-10.md)
dokumentiert. Die folgenden Befunde beschreiben weiterhin den Ausgangsstand.

## Priorisierte Übersicht

P1 = nächste sinnvolle Erweiterungen, P2 = danach oder als begrenzter Nebenpunkt.
Die Kennzeichnung bezeichnet Produktpriorität, keine Sicherheits-Schwere.
S/M/L sind relative Umfänge einschließlich Speicherung, Lokalisierung und
passender Verifikation; sie sind keine Tages- oder Kostenzusage.

| ID | Fehlende Fähigkeit | Priorität | Umfang | Kernnutzen |
| --- | --- | --- | --- | --- |
| F1 | Gespeicherte eigene Rezepte bearbeiten und Zubereitung ergänzen | P1 | M | Vorhandene Rezepte korrigieren und weiterentwickeln |
| F2 | Abgeschlossene Trainings speichern und Ist-Leistung vergleichen | P1 | M, mit Satzwerten L | Beim nächsten Training wissen, was zuletzt geschafft wurde |
| F3 | Android-Schritte über Health Connect | P1 bei Android-Zielgruppe | M für Schritte | Vorhandene Schritt- und Aktivitätsanzeige auch auf Android nutzen |
| F4 | Zutatenrechner mit mehreren Kochportionen | P1 | L | Selbst gekochtes Essen ohne externe Nährwertrechnung erfassen |
| F5 | Strukturierte Planabfrage und ausgewählten Plan mit Coach besprechen | P2 | M | Passendere Trainingsvorschläge mit weniger Wiederholungen |
| F6 | Eine Mahlzeit aus mehreren Tagebucheinträgen gemeinsam übernehmen | P2 | M | Wiederkehrendes Frühstück mit einer Aktion erfassen |
| F7 | Speiseplanung, später eine daraus erzeugte Einkaufsliste | P2 | M, mit Einkaufsliste L | Essen für kommende Tage vorbereiten |
| F8 | Ernährungsform nach dem Onboarding ändern | P2 | S | Empfehlungen an geänderte Vorlieben anpassen |
| F9 | Vorhandenen Datenexport als Datei speichern/teilen | P2 | S | Daten ohne Umweg über die Zwischenablage mitnehmen |

Die fehlenden Fähigkeiten F1–F9 sind im geprüften Code mit hoher Sicherheit
belegt. Die Reihenfolge bleibt eine Einschätzung: Bei reinem Ernährungsfokus
rücken F4/F6 vor F2; bei einem Android-Start rückt F3 nach vorne.

## F1 – Eigene Rezepte vervollständigen

**Ist:** Die Detailansicht bietet Eintragen und Löschen. Das Erstellungsformular
nimmt kein bestehendes Rezept an, erzeugt beim Speichern eine neue Slug und
speichert eine leere Zubereitung. Das betrifft auch die fehlende spätere
Bearbeitung bereits übernommener Coach-Rezepte.

**Belege:** [Detailaktionen](../lib/src/screens/recipes/recipe_detail.dart#L7),
[Detailroute](../lib/src/screens/recipes/recipes_screen.dart#L538),
[Neuanlage und leere Zubereitung](../lib/src/screens/recipes/recipe_create_sheet.dart#L394).

**Erste Version:** Vorhandenes Formular vorbefüllen, „Bearbeiten“ anbieten,
Zubereitung erfassen und unter derselben Slug speichern. Vorhandene Fotos und
die Kennzeichnung generierter Bilder erhalten. Bereits geloggte Mahlzeiten
bleiben historische Momentaufnahmen. Die Speicherung besitzt bereits einen
[Rezept-Upsert](../lib/src/services/user_recipes_sync.dart#L51); die Änderung
braucht trotzdem eine Prüfung der UI-, Foto- und Offline-Pfade.

**Abnahme:** Ein Rezept offline korrigieren, App neu öffnen und später synchronisieren;
es bleibt genau ein Rezept, das Foto bleibt erhalten und gestrige Einträge ändern sich nicht.

## F2 – Vom Trainingsplayer zum Trainingsverlauf

**Ist:** „Beenden“ und „Verwerfen“ führen beide zum Löschen des lokalen
Recovery-Checkpoints. Ein bestätigter Trainingsabschluss wird nicht als Verlauf
gespeichert. Das Satzmodell kennt erledigt/übersprungen, aber keine tatsächlich
erreichten Wiederholungen oder verwendeten Gewichte. Die im Juni dokumentierten
Workout-Logs wurden im August entfernt; sie sind kein aktuell vorhandenes Feature.

**Belege:** [Endaktionen](../lib/src/screens/training/training_player_screen.dart#L241),
[Checkpoint-Speicherung](../lib/src/app/home_store_training.dart#L95),
[Satzstatus](../lib/src/models/training_session.dart#L107),
[Übungsvorgaben](../lib/src/models/training_exercise.dart#L39),
[Entfernung alter Tabellen](../supabase/migrations/20260803120000_drop_removed_feature_tables.sql#L18).

**Erste Version:** Bestätigte Abschlüsse mit Datum, unveränderlichem Workout-Abbild,
absolvierten/übersprungenen Sätzen und optionaler Notiz speichern; Verlauf und
Detailansicht anbieten. Danach Ist-Wiederholungen und Last je Satz sowie
„Letztes Mal“ im Player ergänzen. Dafür stabile Übungsidentitäten vorsehen,
damit Umbenennungen und Planänderungen Vergleiche nicht verfälschen.

**Abnahme:** Ein Offline-Abschluss erscheint nach Neustart und Synchronisierung
genau einmal. Verwerfen erzeugt keinen Abschluss. Planänderung oder Planlöschung
verändert keine Vergangenheit; übersprungene Sätze bleiben erkennbar.
Das bestehende Kalorienmodell wird durch Trainingsabschlüsse nicht verändert.

Als Funktionsreferenz zeigt [Hevy frühere Satzwerte direkt beim nächsten Training](https://www.hevyapp.com/features/track-exercises/).
Das belegt einen etablierten Bedienweg, nicht dessen Nachfrage bei Eatova.

## F3 – Android-Schritte anbinden

**Ist:** Der Einstieg injiziert `AppleHealthService`. Außerhalb iOS liefert
dieser `unsupported`; ohne Schrittquelle gibt der Store `null` zurück und die
Heute-Karte wird ausgeblendet. Das ist eine tatsächliche Plattformlücke und
erklärt die bereits im Handoff dokumentierte Android-Beobachtung.

**Belege:** [Service-Auswahl](../lib/main.dart#L92),
[Plattformgrenze](../lib/src/services/apple_health_service.dart#L268),
[fehlende Schrittdaten](../lib/src/app/home_store_tracking.dart#L105),
[Kartenanzeige](../lib/src/screens/today/today_screen.dart#L129).

**Erste Version:** Health Connect für Schritte, verständlicher Verbindungs- und
Berechtigungsstatus und Anschluss an die bestehende Tagesberechnung.
Fehlende Messwerte müssen von gemessenen null Schritten unterscheidbar bleiben.
Gewichtsimport/-rückschreiben für iOS-Parität kann anschließend folgen.

**Abnahme:** Plattform nicht unterstützt, keine Quelle, verweigerte/entzogene
Berechtigung und erfolgreiche Verbindung prüfen; mehrere Datenquellen dürfen
keine doppelten Schritte erzeugen. Das bestehende Kalorienmodell bleibt erhalten.
Google dokumentiert [Verfügbarkeit und Berechtigungen](https://developer.android.com/health-and-fitness/health-connect/get-started)
und die [Aggregation von Gesundheitsdaten](https://developer.android.com/health-and-fitness/health-connect/aggregate-data).

## F4 – Rezepte aus Zutaten berechnen

**Ist:** Zutaten und Portion sind Freitext. Kalorien und drei Makros werden
getrennt eingegeben. Produktmengen sind nicht rechnerisch mit dem Rezept verknüpft;
eine numerische Anzahl der Kochportionen fehlt. Bereits vorhandene Grammkorrekturen
von Tagebucheinträgen lösen diese Aufgabe nicht.

**Belege:** [Rezeptdaten](../lib/src/models/fitness_recipe.dart#L76),
[manuelle Nährwerte](../lib/src/screens/recipes/recipe_create_sheet.dart#L404),
[Eintragen des gespeicherten Rezepts](../lib/src/screens/recipes/recipe_detail.dart#L29).

**Erste Version:** Zutaten aus Produktsuche oder manueller Eingabe auswählen,
Gramm erfassen, Nährwerte addieren und auf eine frei gewählte Anzahl Portionen
verteilen. Eine halbe oder mehrere Portionen vor dem Eintragen wählen.
Bekannte Nährwerte berechnen, fehlende Werte sichtbar unvollständig lassen.
Freitextrezepte und die bisherige manuelle Eingabe bleiben kompatibel.

**Abnahme:** Ein Rezept mit vier Portionen liefert beim Eintragen einer halben
Portion ein Achtel der bekannten Gesamtnährwerte. Neue Zutaten verändern weder
alte Tagebucheinträge noch unbemerkt die als unbekannt geführten Nährwerte.
Bei späterem Eintragen nach gekochtem Gewicht muss der tatsächliche Ertrag
berücksichtigt werden; Rohgewicht ist dafür kein verlässlicher Ersatz.
Eine vergleichbare Zutaten-/Portionsführung beschreibt [Cronometers Rezepteditor](https://support.cronometer.com/hc/en-us/articles/360019870111-Mobile-Create-a-Custom-Recipe).

## F5–F9 – Gezielte nächste Ergänzungen

**F5: Trainingskontext für Coach.** Normaler Chat kennt Profil und heutige
Ernährung. `/plan` übergibt nur den aktuellen Wunsch, Modus, Sprache und Session-ID;
die Generierung erhält keine Gesprächshistorie und keinen bestehenden Plan.
Eine kurze Abfrage nach Ziel, Erfahrung, Equipment und Zeit sowie „Diesen Plan
besprechen“ sind sinnvolle Erweiterungen. Die erste Version braucht keinen
Trainingsverlauf; leistungsbezogene Empfehlungen setzen F2 voraus. Planänderungen
bleiben prüfbare Vorschläge mit expliziter Übernahme. Belege:
[heutiger Kontext](../lib/src/app/home_store.dart#L318),
[Plananfrage](../lib/src/services/coach_chat_service.dart#L865),
[Generierung](../supabase/functions/coach-chat/handler.ts#L1420),
[bewusst übersprungene Historie](../supabase/functions/coach-chat/handler.ts#L2467).

**F6: Mahlzeit gemeinsam übernehmen.** Favoriten enthalten ein einzelnes
Analyseergebnis, das auch mehrere Bestandteile haben kann. Mehrere getrennt
geloggte Lebensmittel gemeinsam auswählen und auf einen Zieltag/-slot übernehmen
geht derzeit nicht. Erste Version: „Dieses Frühstück übernehmen“, Vorschau mit
abwählbaren Einträgen und danach weiterhin einzeln bearbeitbaren Mahlzeiten.
Neue IDs und eine klare Behandlung teilweise fehlgeschlagener Offline-Schreibvorgänge
sind Teil des Umfangs. Belege: [Favoritmodell](../lib/src/models/favorite_meal.dart#L3),
[Tagebuchaktionen](../lib/src/widgets/kcal/diary_meal_card.dart#L38),
[einzelner Schreibweg](../lib/src/app/home_store_meals.dart#L91).

**F7: Speiseplanung mit späterer Einkaufsliste.** Heute und Tagebuch enden bei
heute; Rezepte werden unmittelbar als gegessen eingetragen. Eine einfache
Sieben-Tage-Planung könnte gespeicherte Rezepte und Portionen vormerken.
Erst „Gegessen“ übernimmt sie ins Tagebuch; geplante Mahlzeiten zählen nicht zu
Verbrauch oder Streak. Eine rechnerisch zusammengeführte Einkaufsliste folgt
nach F4, weil heutige Zutaten Freitext sind. Ein Trainings-`/plan` ist kein
Speiseplan. Belege: [Datumsgrenze](../lib/src/screens/today/today_day_strip.dart#L31),
[Tagebucheditor](../lib/src/widgets/kcal/edit_meal_sheet.dart#L249),
[direktes Rezeptlogging](../lib/src/screens/recipes/recipe_detail.dart#L29).

**F8: Ernährungsform später ändern.** Die Auswahl keine/vegetarisch/vegan/
pescetarisch wird im Onboarding gespeichert und für Rezeptempfehlungen verwendet.
Ein späterer Editor in Profil/Ziele/Settings fehlt. Die vorhandene Auswahl
ergänzen und Empfehlungen nach dem Speichern aktualisieren; dafür ist kein
neues Präferenzmodell nötig. Eine Allergieprüfung wäre ein separates Feature,
das diese Auswahl nicht verspricht. Belege:
[Onboarding](../lib/src/screens/onboarding_screen.dart#L428),
[Empfehlungsfilter](../lib/src/screens/recipes/recipes_screen.dart#L277),
[bestehende Zieleoberfläche](../lib/src/screens/settings/goals_screen.dart#L778).
Die Suche nach `DietPreference`, `diet:` und `.diet` in den aktuellen
Nutzeroberflächen ergab keinen späteren Bearbeitungsweg.

**F9: JSON-Export als Datei.** Export und vollständiges Kopieren existieren.
Die Dateifreigabe ist als Callback vorbereitet, wird von Settings jedoch nicht
übergeben; der Button bleibt dadurch unsichtbar. Erste Version: explizites
Speichern/Teilen der vorhandenen JSON-Datei. Hinweise auf unvollständige oder
gekappte Daten bleiben erhalten. Das ist noch keine Import-/Backup-Wiederherstellung
und beinhaltet keine lokalen Rezeptbilder. Belege:
[Settings-Aufruf](../lib/src/screens/settings/settings_screen.dart#L352),
[bedingter Dateibutton](../lib/src/widgets/shared/data_export_sheet.dart#L288),
[exportierte Tabellen](../lib/src/services/data_export.dart#L43).

## Empfohlene Umsetzung

1. **Bestehende Abläufe schließen:** F1 Rezeptbearbeitung. F8 Ernährungsform und
   F9 Dateiexport sind kleinere, separat abnehmbare Ergänzungen.
2. **Kernnutzen vertiefen:** F2 zuerst als Abschlussverlauf, danach Satzwerte;
   F3 für Android. F4 ist das nächste größere Ernährungspaket.
3. **Daten für bessere Planung nutzen:** F5 und F6; danach F7 einschließlich
   Einkaufsliste auf Basis strukturierter Zutaten. Planung allein benötigt F4 nicht.

Die Empfehlung erteilt keinen Implementierungsauftrag. Es gibt keine neue
Entscheidung, entfernte Funktionen vollständig wiederherzustellen.

## Bereits vorhanden und bewusst zurückgestellt

Bereits vorhanden: Fotoscan mit Kontext und Korrektur, Barcode, Produktsuche,
manuelle Eingabe, Favoriten, Portionskorrektur, Rezeptkatalog und bestätigte
Coach-Übernahme, Trainingspläne mit Editor/Player/Recovery, Offline-Sync,
7/30/90-Tage-Trends, Gewichtsverlauf, manuelle Kalorien-/Makroziele, lokale
Streak-Erinnerung, JSON-Datenexport und Kontolöschung.

Die README-Aussage „Auth nur Deutsch“ ist inzwischen veraltet:
[Auth verwendet l10n](../lib/src/screens/auth_screen.dart#L478),
[englische Auth-Texte existieren](../lib/l10n/app_en.arb#L1461).
Manuelle Makroziele sind auch tatsächlich
[in der Oberfläche editierbar](../lib/src/screens/settings/goals_screen.dart#L790).
Beides wurde als möglicher Feature-Befund verworfen.

Später prüfenswert: selbst gewählte Erinnerungszeiten statt fest 20 Uhr
([Reminder](../lib/src/services/streak_reminder_planner.dart#L12)); ein einfacher
Trainingsrhythmus nach F2; datierte Zielphasen und ein Wochen-Check-in auf den
vorhandenen Trends; zusätzliche Nährwerte zunächst als optionale Ballaststoffdaten
mit sichtbarer Datenvollständigkeit. Dafür liegt noch keine bestätigte Nachfrage vor.

Vorerst keine Priorität: Social Feed, umfassende Übungsvideos, mehrere direkte
Wearable-Anbindungen, automatische Kalorien-/Trainingsprogression, großes
Vitamin-/Supplement-Dashboard und automatischer Cloud-Upload lokaler Rezeptbilder.
Wasser, Schlaf und Habits wurden bewusst entfernt; übrig gebliebene Felder sind
kein Beleg, dass diese Funktionen versehentlich vergessen wurden.

## Review-Abdeckung

- `review_nutrition`: Diary, Favoriten, Rezepte, Mengen/Portionen, Planbarkeit und Nährstoffmodell.
- `review_training_coach`: Player-Abschluss, Recovery, Trainingsmodelle, Coach-Requests und Planungsgrenzen.
- `review_onboarding_integrations`: Onboarding/Ziele, Health, Erinnerungen, Export, Kontofunktionen und Lokalisierung.
- Hauptinstanz: Priorisierung, Gegenlesen zentraler Schreib-/Request-Pfade,
  Abgleich historischer Rückbauten und wenige aktuelle Herstellerdokumentationen.

Nicht geprüft: tatsächliche Nutzungshäufigkeit, Zahlungsbereitschaft, installierte
Geräteversion, aktuelle Backend-Konfiguration oder vollständige Laufzeit-/Security-Korrektheit.
