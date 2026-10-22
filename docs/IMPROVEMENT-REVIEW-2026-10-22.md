# Eatova – Was die App richtig gut macht (zwei Agenten)

> Historical record: statements and open items below describe the dated
> source, not the current product. See the [current feature inventory](FEATURES.md)
> and [documentation index](README.md) for implemented behavior.

Stand: 2026-10-22, geprüfter Code `ecd189b5` (main nach #159 bis #165).

Die Punkte sind am selben Tag gebaut worden, siehe [Umsetzung, 2026-10-22](#umsetzung-2026-10-22-zehn-agenten).

**Vorgehen**
- Zwei Subagents prüften nur lesend, mit zwei Blickwinkeln:
  - **Produkt und Nutzer:** die Wege durch die App vom Onboarding bis zum zweiten Monat, verglichen mit MacroFactor, Yazio, Lifesum und MyFitnessPal (Herstellerseiten, 2026).
  - **Tiefe und Qualität:** halbe Funktionen, Sackgassen, widersprüchliche Zahlen, Offline- und Fehlerzustände, Android gegen iOS.
- Die Hauptinstanz hat die tragenden Belege im Code nachgelesen: Favoriten-Schlüssel, Erinnerungen ohne Ziel, Einstellungs-Knopf, Apple-Health-Intro pro Konto, Trainingszähler, Zeilen im Speiseplan, Gewichtsrate, Tagesziel.
- Keine App-Flows, Tests, CI-Läufe oder Live-Abfragen.

Baut auf der [Review vom 2026-10-19](IMPROVEMENT-REVIEW-2026-10-19.md) auf; deren Punkte ohne Owner-Bedarf sind mit #159 gebaut. Die Reihenfolge ist eine Empfehlung, kein Umsetzungsauftrag.

Die Leitplanken gelten weiter:
- Wasser, Schlaf und Habits bleiben entfernt.
- Das Kalorienmodell mit Wochen-Check bleibt.
- Funktionen mit dünner Datenlage werden vorher gemessen.
- Coach-Vorschläge schreiben nichts ohne Bestätigung.

**Kurzurteil**
- Das Erfassen selbst ist stark: Foto, Beschreiben, „Deine Lebensmittel“, „Wie gestern“, „Kopieren nach …“, Schnell-Eintrag und eigene Barcodes.
- Die Lücken liegen drumherum:
  - ein Fehler, der gepinnte Favoriten überschreibt;
  - Erinnerungen, die ins Leere führen;
  - der Wochenrhythmus, von dem der Wochen-Check lebt, aber an den nichts erinnert;
  - Zahlen, die sich zwischen Today, Trends und Montagskarte widersprechen;
  - mehrere Stellen, an denen man einen Eintrag, einen Plan oder ein Training nicht mehr korrigieren kann.

## 1. Fehler, die Vertrauen kosten (zuerst)

| Punkt | Prio | Umfang |
| --- | --- | --- |
| Gepinnter Favorit wird von gleichnamigem Essen überschrieben | P1 | S |
| Erinnerungen: blockierte Berechtigung ist eine Sackgasse | P1 | S |
| Apple Health ist nicht pro Konto getrennt | P1 (Garantie) | S–M |
| Training zeigt „4 von 2“ | P2 | S |
| Zielgewicht erreicht: Ziel springt hin und her, ohne Moment | P2 | S–M |
| Drei verschiedene Gewichtsraten | P2 | S |
| Offline- und Fehlerzustände ohne Ausweg | P2 | S je Stelle |
| Abmelden löscht eigene Rezeptfotos ohne Warnung | P2 | S (Warnung) |

### Gepinnter Favorit wird überschrieben (P1, S)

**Was passiert:**
- Favoriten ohne Barcode haben nur den Namen als Schlüssel ([`favorite_meal.dart`](../lib/src/models/favorite_meal.dart#L68)).
- Jeder Eintrag schreibt die Werte des neuen Essens in den gefundenen Favoriten und behält dabei das Pin ([`home_store_meals.dart`](../lib/src/app/home_store_meals.dart#L166)).

**Folgen:**
- Ein gepinnter Latte „Kaffee“ mit 45 kcal wird nach einem Scan, der ebenfalls „Kaffee“ heißt, zu 2 kcal. Das „+“ trägt danach 2 kcal ein.
- Alle namenlosen Schnell-Einträge heißen gleich und überschreiben sich gegenseitig.

**Vorschlag:**
- Ein gepinnter Favorit aktualisiert beim Eintragen nur „zuletzt benutzt“.
- Ein Verlaufseintrag wird nur bei gleichem Barcode oder bei gleichem Namen und ähnlichen kcal/100 g überschrieben, sonst bekommt er einen eigenen Schlüssel.
- Ein Store-Test, der auf dem heutigen Code rot ist.

### Erinnerungen: Sackgasse bei blockierter Berechtigung (P1, S)

Erinnerungen sind der einzige Kanal, der Nutzer zurückholt.

**Was passiert:**
- Nach einem harten „Nicht erlauben“ zeigen die Einstellungen einen gesperrten Schalter mit „erlaube sie in den Systemeinstellungen“, aber keinen Knopf ([`settings_reminder_row.dart`](../lib/src/screens/settings/settings_reminder_row.dart#L68)).
- Der Ziele-Screen hätte einen Knopf, aber die App übergibt `onOpenSystemSettings` nie (nur in [`goals_screen.dart`](../lib/src/screens/settings/goals_screen.dart#L74) definiert).
- Die Hilfsfunktion zum Öffnen der Systemeinstellungen gibt es schon ([`rest_alert_guard.dart`](../lib/src/services/rest_alert_guard.dart#L43)).

**Vorschlag:** den Knopf in der Einstellungszeile, im Ziele-Screen und im „verweigert“-Snack anbieten. Geplante Erinnerungen neu einplanen, wenn die Sprache wechselt.

### Apple Health ist nicht pro Konto getrennt (P1 als Garantie, S–M)

**Was passiert:**
- Health Connect merkt sich die Freigabe pro Konto. HealthKit verbindet automatisch, wenn für das Konto kein Intro-Zustand gespeichert ist ([`home_store_tracking.dart`](../lib/src/app/home_store_tracking.dart#L131), [`eatova_home_page.dart`](../lib/src/app/eatova_home_page.dart#L228)).
- Die HealthKit-Freigabe gilt für das ganze Gerät.

**Beispiel:** Meldet sich ein zweites Konto, das sein Onboarding woanders abgeschlossen hat, auf demselben iPhone an,
- liest es die Schritte der ersten Person in sein Kalorienbudget,
- bekommt es deren Waagenwerte angeboten,
- schreibt es seine Wiegungen in deren Apple Health.

**Vorschlag:**
- Ein Merker „HealthKit verbunden“ pro Konto wie bei Android.
- Neue Konten sehen die Intro-Karte.
- Das Zurückschreiben des Gewichts hängt am Merker.

### Training zeigt „4 von 2“ (P2, S)

- „Diese Woche x von y“ nimmt die Anzahl der Workouts im Plan als Sitzungen pro Woche. Der Code nennt das selbst eine Annahme ([`training_insights.dart`](../lib/src/models/training_insights.dart#L296)).
- Der Coach baut aber 2–3 Workouts für 4–5 Einheiten zum Rotieren ([`training_plan.ts`](../supabase/functions/coach-chat/training_plan.ts#L201)).
- **Vorschlag:** die Einheiten pro Woche aus dem Plan-Brief speichern, mit einem Stepper im Plan-Editor. Bis dahin „von N“ weglassen.

### Zielgewicht erreicht (P2, S–M)

**Was passiert:**
- „Erreicht“ hängt am gerundeten Gewichtstrend und schaltet ohne Puffer auf Halten ([`user_profile.dart`](../lib/src/models/user_profile.dart#L294)).
- Liegt der Trend um X,5 kg, springt das Tagesziel von Tag zu Tag um etwa 500 kcal hin und her.
- Jeder Wechsel zeigt nur den allgemeinen Snack „Neues Tagesziel …“. „Ziel erreicht!“ steht nur auf der Ziele-Seite.

**Vorschlag:**
- Ein Puffer: Halten bleibt, bis der Trend etwa 1–1,5 kg über das Ziel hinausläuft.
- Eine einmalige Today-Karte „Ziel erreicht – halten oder neues Ziel?“.

**Owner:** wie breit der Puffer ist.

### Drei verschiedene Gewichtsraten (P2, S)

- Trends rechnet „kg pro Woche“ aus erster und letzter Rohwiegung ([`trend_report.dart`](../lib/src/services/trend_report.dart#L102)).
- Montagskarte und Coach nehmen die Steigung über 21 Tage ([`energy_check.dart`](../lib/src/services/energy_check.dart#L303)).
- Das Profil nimmt den geglätteten Trend.
- So kann Trends „+0,3 kg/Woche“ zeigen und die Montagskarte „−0,4“.
- **Vorschlag:** Trends nimmt die Steigung des Wochen-Checks und zeichnet die Trendlinie.

### Offline- und Fehlerzustände ohne Ausweg (P2, S je Stelle)

- **Produktsuche offline:** endet nach den stillen Wiederholungen in einer leeren Fläche, ohne Meldung und ohne „Manuell eintragen“ ([`add_meal_sheet.dart`](../lib/src/widgets/kcal/add_meal_sheet.dart#L711)).
- **Trends offline:** zeigt „konnten nicht geladen werden“, obwohl 35 Tage lokal vorliegen und die 7-Tage-Karte auf Today daraus rechnet.
- **Coach:** Banner ohne „Erneut versuchen“, wenn der erste Besuch offline ist oder der Verlauf nicht lädt.
- **Barcode:** Der Fehler offline hat keinen Retry. Wird ein Produkt ohne Nährwerte gefunden, öffnet das Formular mit leerem Namen, obwohl der Name bekannt ist.

### Abmelden löscht eigene Rezeptfotos (P2, S für die Warnung)

- Eigene Rezeptfotos liegen nur auf dem Gerät.
- Abmelden und Sitzungsverlust leeren sie bewusst ([`home_store_sync.dart`](../lib/src/app/home_store_sync.dart#L991)), auch beim Wiederanmelden desselben Kontos.
- Sie stehen nicht im Export, und die Abmelden-Zeile fragt nicht nach.
- **Vorschlag:** eine Bestätigung, die ungesendete Änderungen und die lokalen Fotos nennt.
- **Owner/Sicherheit:** Die Fotos für dasselbe Konto verschlüsselt zu behalten, wäre eine Abkehr von der bisherigen Sicherheitsentscheidung.

## 2. Was Nutzer bindet: der Wochenrhythmus

**Wiege-Erinnerung und Montags-Nachricht (P1, S–M)**
- Der Wochen-Check braucht 14 vollständige Tage und 4 Wiegetage über mindestens 14 Tage ([`energy_check.dart`](../lib/src/services/energy_check.dart#L151)).
- Wer das Wiegen vergisst, bekommt nie einen Check.
- Die Ergebniskarte erscheint nur montags in der App ([`home_store_energy_check.dart`](../lib/src/app/home_store_energy_check.dart#L62)).
- Der Planer kennt nur die Serien-Erinnerung.
- **Vorschlag:** eine Wiege-Erinnerung zum Einschalten (z. B. Mo und Do morgens) und eine Montags-Nachricht, die die Ergebniskarte öffnet. Höchstens zwei zusätzliche Nachrichten pro Woche.
- **Owner:** Tage und Anzahl.

**Erfassen von außen (P1, S)**
- Die Abend-Erinnerung sagt „ein Foto genügt“, öffnet beim Antippen aber nur die App. Nachrichten tragen kein Ziel ([`notification_service.dart`](../lib/src/services/notification_service.dart#L24)), die App kennt nur das Ziel der Pausen-Erinnerung ([`eatova_home_page.dart`](../lib/src/app/eatova_home_page.dart#L1582)).
- Es gibt keine App-Icon-Kurzbefehle.
- MacroFactor, Lifesum und Yazio starten das Erfassen mit einem Tipp von außen.
- **Vorschlag:**
  - Die Erinnerung öffnet das Hinzufügen-Sheet für die aktuelle Mahlzeit.
  - Langes Drücken auf das App-Icon bietet Foto, Barcode, Beschreiben und Gewicht.
  - Dafür kommt ein Plugin dazu.

**Waagenwerte automatisch (P2, M; P1 für Waagen-Besitzer)**
- iOS bietet nur den neuesten Wert der letzten 7 Tage einmal an.
- Android liest gar kein Gewicht, nur Schritte ([`android_health_service.dart`](../lib/src/services/android_health_service.dart#L26)).
- Dadurch fehlen genau die Wiegungen, die der Wochen-Check braucht.
- **Vorschlag:** Nach einmaliger Zustimmung alle Werte seit dem letzten Lesen übernehmen, ohne Doppelte. Auf Android das Gewicht aus Health Connect lesen.
- **Extern:** Play-Erklärung und Datenschutztext anpassen.

**Android bekommt die versprochene Schritt-Gutschrift nicht angeboten (P2, S)**
- Das Onboarding verspricht „Gezählte Schritte kommen jeden Tag obendrauf“.
- iOS bekommt eine Intro-Karte, Android nicht.
- Today zeigt dort dauerhaft „Noch keine Schrittdaten – Prüfe die Verbindung“. Das wirkt wie ein Defekt.
- **Vorschlag:** dieselbe Karte mit „Nicht jetzt“ für Health Connect. Wer ablehnt, sieht die Zeile nicht mehr.

**Erinnerungsangebot ab Tag 1 (P2, S, vorher messen)**
- Das Angebot kommt erst nach Einträgen an zwei Tagen. Wer am ersten Tag einträgt und nicht wiederkommt, sieht es nie.
- **Vorschlag:** Angebot am Abend des ersten Tages, weiter als bewusstes Opt-in.
- **Messen:** Anteil der Konten mit genau einem Eintragstag.

## 3. Tiefe der vorhandenen Funktionen

**Coach kann kein Essen eintragen lassen (P1, M)**
- „Ich hatte 2 Eier und Toast“ verbraucht eine der fünf Tagesanfragen und trägt nichts ein.
- „/log 2 Eier“ geht in die Trainings-Erkennung, wird abgelehnt und bleibt berechnet.
- Der Coach nennt das Tagebuch selbst „Log“ („Sieht dein heutiges Log“), `/log` meint aber nur Trainings.
- **Vorschlag:**
  - Ein Befehl „/meal“ (oder ein Chip), der ohne Coach-Anfrage das Beschreiben-Blatt mit dem Text öffnet. „Hinzufügen“ dort ist die Bestätigung.
  - Eine Prompt-Regel und eine Ablehnung bei `/log`, die auf „/meal“ verweisen.
- **Owner:** Name des Befehls.

**Speiseplan: Zeile ist eine Sackgasse, Abhaken endgültig (P1 für die Sackgasse, S; P2 für Rückgängig)**
- Today öffnet bei einem geplanten Gericht den Speiseplan, aber dessen Zeilen sind nicht antippbar ([`meal_plan_week.dart`](../lib/src/screens/recipes/meal_plan_week.dart#L217)). Zutaten und Schritte erreicht man von dort nicht.
- „Als heute gegessen abhaken“ trägt immer für heute ein und lässt sich nicht zurücknehmen.
- **Vorschlag:**
  - Die Zeile öffnet die schon vorhandene Rezeptansicht, skaliert auf die geplanten Portionen.
  - An vergangenen Tagen fragen: „geplanter Tag oder heute?“
- **Owner:** Die Entscheidung zum geplanten Tag ist seit dem 2026-10-10 offen.

**Einträge nachträglich korrigieren (P2, M)**
- **Portionen:** Rezepte mit Zutaten werden mit 0 g eingetragen, die Zeile zeigt „1 Portion“ auch bei zwei. Es gibt keinen Portionen-Stepper.
- **Werte und Namen:**
  - „Werte ändern“ gibt es nur für Schnell-Einträge.
  - Ein Tippfehler in einem manuellen Eintrag oder eigenen Produkt lässt sich nur umskalieren und bleibt im gepinnten Produkt.
  - KI-Namen lassen sich nicht umbenennen.
- **Vorschlag:**
  - Portionen im Mahlzeiten-JSON speichern (keine Migration), mit einem Stepper in halben Schritten.
  - „Werte ändern“ und ein Namensfeld für manuelle Einträge, eigene Produkte und Favoriten.

**Allergien im Onboarding, mehr passende Rezepte (P2; Onboarding S, Inhalte M)**
- Das Onboarding fragt nur die Ernährungsform. Die 13 Unverträglichkeiten stehen nur unter Profil → Ernährung. Wer eine Nussallergie hat, bekommt bis dahin Nussrezepte vorgeschlagen.
- **Katalog:**
  - 30 Rezepte pro Sprache.
  - Alle 6 Frühstücke enthalten Milch, es gibt 0 Snacks und kein veganes Frühstück.
  - Der Tipp auf Today rotiert nicht.
- **Vorschlag:**
  - Die Chips im Onboarding-Schritt „Deine Küche“ anbieten.
  - 12–15 passende Rezepte in DE und EN ergänzen: laktosefrei, glutenfrei und vegan zum Frühstück, dazu Snacks.
  - Eine Rotation pro Tag.
- **Messen:** Verteilung von Ernährungsform und Unverträglichkeiten.

**Unbekannte Makros zählen als 0 g (P2, S–M, vorher messen)**
- Fehlt einer Zeile in „Beschreiben“ oder einem Schnell-Eintrag ein Makro, addieren die Tagessummen 0 g ([`macro_progress.dart`](../lib/src/models/macro_progress.dart#L16)).
- Protein-Kachel, Trends und Coach zählen dann zu wenig, ohne es zu sagen.
- **Vorschlag:** in „Beschreiben“ das fehlende Makro aus der KI-Schätzung ergänzen; wo Unbekanntes drinsteckt, „≥ 48 g“ oder „2 Einträge ohne Makros“ anzeigen.

**Vergangene Tage gegen das heutige Ziel (P2, M)**
- Es gibt keinen Zielverlauf. Food-Tageskarte, Trends („Ziel getroffen x von y“) und Coach messen jeden vergangenen Tag am aktuellen Ziel ([`home_store_derivations.dart`](../lib/src/app/home_store_derivations.dart#L28)).
- Nach einem Wechsel auf Abnehmen werden drei Monate gehaltene Tage nachträglich zu „über dem Ziel“.
- **Vorschlag:** das Grundziel pro Tag festhalten.

**Coach: Limit, Rezept-Budget, Kontext (P2, S–M)**
- **Limit:**
  - Jede Nachricht kostet, auch „Danke“.
  - Der Zähler erscheint erst bei 1–2 übrigen Anfragen.
  - Nach einem Kaltstart ist das Limit unbekannt, man schreibt und bekommt „Nicht gesendet“.
- **/recipe:** kennt das Restbudget nicht und schlägt etwa 850 kcal vor, wenn noch 640 übrig sind.
- **Kontext:** Speiseplan und Wochen-Check fehlen.
- **Vorschlag:**
  - Das letzte Limit pro Konto merken und „3/5 heute“ dauerhaft zeigen.
  - Optional Mahlzeit und Restbudget an /recipe geben.
  - Zwei kurze Kontextzeilen.
- **Owner:** ob Plan und Check-Zahlen an Anthropic gehen (Datensparsamkeit).
- **Später (P3):** eine vorausgefüllte Coach-Frage aus der Montagskarte und aus Trends („Warum stagniert mein Gewicht?“).

**Training (P2–P3, M)**
- Der Verlauf lässt sich nur löschen. Ein Tippfehler von 800 kg füllt die nächste Einheit vor und blockiert echte Rekorde.
- Rekorde hängen an Plan und Übungs-ID; ein angepasster Plan oder ein freies Training zählt nie. Die UI zeigt nur „2 Rekorde“.
- **Vorschlag:**
  - „Bearbeiten“ im Verlauf.
  - Rekorde nach Übungsnamen.
  - Den Rekord im Abschluss-Blatt nennen und einen Verlauf pro Übung zeigen.

**Kleinere Punkte (je S, P3)**
- Einkaufsliste und Rezept über das Teilen-Menü statt nur über die Zwischenablage (`share_plus` ist schon da).
- Food zeigt 24-Stunden-Zeiten auch im englischen 12-Stunden-Format.
- Die 7-Tage-Karte auf Today öffnet Trends auf 30 Tagen.
- Der Anzeigename lässt sich nicht ändern. Wer nur mit Google angemeldet ist, sieht „Passwort ändern“.
- Der Rezept-Picker im Speiseplan zeigt keine kcal und kein Protein.
- Coach-Nachrichten haben für Screenreader keinen Sprecher („Du“/„Coach“).
- Ein gespeichertes Coach-Rezept hat keinen „Öffnen“-Knopf.
- Eigene Makroziele gibt es nur im manuellen Modus, der den Wochen-Check abschaltet.
- Die Montagskarte lässt sich nicht für die Woche wegklicken.

## 4. Größere Funktionen, nach dem Messen

| Funktion | Prio | Umfang | Warum, und was vorher klar sein muss |
| --- | --- | --- | --- |
| Home- und Sperrbildschirm-Widget: kcal und Protein übrig, Kamera-Knopf | P2 | M–L | MacroFactor und Yazio haben es. **Owner:** Zahlen auf dem Sperrbildschirm. Die Daten liegen außerhalb des verschlüsselten Caches und müssen bei Abmelden und Löschung weg. Signierung prüfen. |
| Scan mit einem Satz korrigieren („Hafermilch, nicht Vollmilch“) | P2 | S–M | Heute nur Gramm ändern oder neu scannen. **Messen:** Anteil der Foto-Mahlzeiten mit `isAdjusted`. Braucht eine Änderung und ein Deploy der Edge Function. |
| Nährwert-Etikett fotografieren bei unbekanntem Barcode | P2–P3 | M | MacroFactor kann das seit Juli 2026. **Messen:** eigene Produkte nach einem Barcode-Fehlschlag. |
| Nährwerte nach Apple Health / Health Connect schreiben | P3 | M | Heute wird nur das Gewicht geschrieben, nur auf iOS. **Extern:** Berechtigungen und Datenschutztext. |
| Größerer Rezeptkatalog oder Import von Rezept-Websites (schema.org) | P3 | M | **Messen:** Nutzung von Katalogrezepten in Tagebuch und Speiseplan. |

**Messen ohne Analytics-Client:** Jede Messung oben geht mit SQL auf vorhandenen Tabellen, mit Freigabe des Owners.
- Trichter: Konten → Onboarding fertig → erste Mahlzeit → zweiter Tag.
- Wie oft aktive Nutzer sich wiegen.
- `isAdjusted` bei Foto-Mahlzeiten.
- Eigene Produkte mit Barcode.
- Nutzung von Speiseplan und Katalog.
- Anteil der Mahlzeiten mit „–“-Makros.
- Verteilung von Ernährungsform und Unverträglichkeiten.

Bei wenigen Nutzern kann das Rauschen sein.

## 5. Empfohlene Reihenfolge

1. **Paket Vertrauen (alles S, ohne Migration):**
   - Favoriten-Fehler;
   - Erinnerungen mit Einstellungs-Knopf und Ziel beim Antippen;
   - App-Icon-Kurzbefehle;
   - Apple Health pro Konto;
   - „x von y“ im Training;
   - Abmelde-Warnung;
   - Offline-Zustände;
   - eine Gewichtsrate;
   - Puffer und Karte beim Zielgewicht.
2. **Paket Wochenrhythmus:**
   - Wiege-Erinnerung und Montags-Nachricht;
   - Health-Connect-Karte;
   - Waagen-Import auf beiden Plattformen;
   - Hinweis auf unbekannte Makros.
3. **Paket Tiefe:**
   - „/meal“ im Coach;
   - Speiseplan-Zeile öffnen und Abhaken;
   - Portionen und Werte nachträglich ändern;
   - Allergien im Onboarding und neue Rezepte;
   - Coach-Limit sichtbar.
4. **Nach dem Messen:**
   - Widget;
   - Scan-Korrektur per Satz;
   - Etikett-Foto;
   - Ziel pro Tag;
   - Rekorde und Verlauf im Training.

## 6. Entscheidungen für den Owner

- **Benachrichtigungen:** wie viele zusätzliche Nachrichten pro Woche, an welchen Tagen; Erinnerungsangebot ab Tag 1 statt ab Tag 2 (die Zwei-Tage-Regel war eine Agenten-Entscheidung in #155).
- **Zielgewicht:** wie breit der Puffer ist, bevor das Ziel wieder auf Abnehmen springt.
- **Coach:** Name von „/meal“; ob ein Essen unter `/log` berechnet wird; ob Speiseplan- und Check-Zahlen an Anthropic gehen.
- **Speiseplan:** ob ein vergangener Plan am geplanten Tag eingetragen wird (offen seit 2026-10-10).
- **Widget:** ob Zahlen auf dem Sperrbildschirm stehen dürfen.
- **Rezeptfotos:** ob sie beim Wiederanmelden desselben Kontos bleiben dürfen (Sicherheitsentscheidung).
- **Entscheidungen aus #159:**
  - „Mit Laktose gemieden bleibt kein Katalog-Frühstück“ ist für Nutzer schlecht. Beheben über neue Rezepte, oder der leere Zustand sagt, warum.
  - Die Montagskarte sollte „Verstanden“ für die Woche bekommen.
  - Die übrigen Entscheidungen aus #159 hält der Qualitäts-Agent für richtig.

## 7. Weiter offen, außerhalb der App

- **Apple:** Sign in with Apple, Widerruf des Apple-Tokens bei Löschung und TestFlight brauchen das bezahlte Apple-Programm. Ohne das erreicht die App keine iOS-Nutzer im Store.
- **Supabase:** Backups und Plan (Owner).
- **GitHub:** die Umgebung `release` mit Secrets und `SENTRY_DSN`.
- **Play Console:** Erklärungen und Datenschutztext auf der Website.
- **Server:** Einwilligung serverseitig durchsetzen (sobald alte Builds raus sind), Handshake mit der Client-Version.
- **Betrieb:** Coach-Diktat auf Android, 5xx-Alarm und tägliche `ai_call`-Summen.
- **Geräte:** App-Build und Geräte-Checks für #159, #163 und #165.

## Bewusst nicht empfohlen

- **Apple-Watch-App:** groß; Widget und Kurzbefehle decken Blick und Erfassen zuerst ab.
- **Live Activity für den Pausen-Timer:** Die Pausen-Erinnerung funktioniert bei gesperrtem Handy schon, und es wäre nur iOS.
- **Körpermaße und Fortschrittsfotos:** wieder ein Tracker nach dem Entfernen von Wasser, Schlaf und Habits.
- **Teilen von Fortschritt, Social:** kein konkretes Nutzerproblem, Kosten beim Datenschutz.
- **Gastmodus:** groß, Risiko für KI-Kontingent und RLS; erst den Trichter messen.
- **Kalorien aus Workouts auf Today:** Die Aktivitätsstufe enthält Sport schon; es würde doppelt zählen.
- **Wöchentlicher Coach-Rückblick an alle:** kostet Kontingent für jeden; die vorausgefüllte Frage reicht.
- **Paywall:** eine Geschäftsentscheidung, keine Nutzerfunktion.
- **lb/ft, kJ, weitere Sprachen:** Der Start ist DACH.
- **Weiter gültig vom 2026-10-19:** Fasten-Timer, Zucker/Ballaststoffe/Salz, BLS-Datenbank, Abzeichen, Coach plant eine ganze Woche.
- **Geprüft und in Ordnung:**
  - Kontrast (ink2/ink3 ≥ 4,5:1);
  - Namen für Icon-Knöpfe;
  - Textgröße bis 2×;
  - gleiche Schlüssel in DE und EN;
  - Rückgängig bei Löschen, Bearbeiten und Kopieren.

## Nicht geprüft

- **Geräte:**
  - Zustellung und Zeitpunkt von Benachrichtigungen;
  - ob „Systemeinstellungen öffnen“ auf Android 13+ und iOS bei Eatova landet;
  - das stille Lesen von HealthKit für ein zweites Konto;
  - Health-Connect-Verlauf über 30 Tage;
  - VoiceOver/TalkBack;
  - das Kamera-Panel aus #163.
- **Live-Daten:** alle Messungen in Abschnitt 4, das Live-Limit des Coaches, was das Modell auf „Ich hatte 2 Eier und Toast“ antwortet.
- **Wettbewerber:** Angaben nach Herstellerseiten, nicht in den Apps selbst geprüft.

Quellen der Wettbewerber-Angaben:
[MacroFactor Widgets](https://macrofactor.com/widgets-announcement/),
[MacroFactor Juli 2026](https://macrofactor.com/mm-july-2026/),
[Yazio iOS](https://www.yazio.com/de/ios-app),
[Lifesum Hilfe](https://help.lifesum.com/de/article/bt4auv/),
[Nutrola Fix Result](https://nutrola.app/nl/help/fix-result-ai-correction).

## Umsetzung, 2026-10-22 (zehn Agenten)

Owner-Auftrag: alles aus dieser Review „komplett mit 10 Sub-Agents“ bauen und dabei die KI-Abläufe (Foto-Analyse, Beschreiben, Rezept-Import, Coach-Chat) auf Fehler prüfen und sie direkt beheben. Zehn Agenten arbeiteten in eigenen Worktrees mit festen Dateien, ohne Migrationen, neue Sync-Arten, Deploys oder Live-Abfragen. Die Hauptinstanz hat die 43 Commits zusammengeführt, die Überschneidungen gelöst, die Integrationsfehler behoben und kleine Restfunde selbst gebaut. Stand und Belege: [Handoff](PROJECT_HANDOFF.md#review-items-built-with-ten-agents-2026-10-22).

**Gebaut (App, braucht einen App-Build):**
- **Vertrauen:**
  - Ein gleichnamiges anderes Essen überschreibt keinen Favoriten mehr. Gleich ist: derselbe Barcode, oder derselbe Name mit höchstens 20 % Energieabstand. Ein anderes Essen bekommt `name:x#2`.
  - Erinnerungen bei blockierter Berechtigung zeigen „Systemeinstellungen öffnen“, auch auf der Zielseite.
  - Ein Tipp auf die Abend-Erinnerung öffnet das Hinzufügen für die aktuelle Mahlzeit.
  - Ein Sprachwechsel plant die Erinnerungen neu.
  - Apple Health wird pro Konto verbunden und vorher weder gelesen noch beschrieben. Bestehende Nutzer bleiben verbunden.
  - Training zeigt „4 erledigt“ statt „4 von 2“.
  - Abmelden fragt vorher und nennt ungesendete Änderungen und die Rezeptfotos, die gelöscht werden.
  - Suche und Barcode bieten offline „Erneut versuchen“.
  - Es gibt eine einzige Gewichtsrate, die Linie des Wochen-Checks, auch in Trends.
  - Ist das Zielgewicht erreicht, hält der Plan es in einem Band von 1,5 kg. Eine Karte fragt „halten oder neues Ziel?“.
- **Wochenrhythmus:**
  - Wiege-Erinnerung zum Einschalten, Montag und Donnerstag um 07:30. Der Montagstext nennt den Wochen-Check.
  - App-Icon-Kurzbefehle: Foto, Barcode, Beschreiben, Gewicht eintragen.
  - Eine Health-Connect-Karte mit „Nicht jetzt“.
  - Waagen-Import nach einmaliger Zustimmung, auf iOS und Android (READ_WEIGHT).
  - Das Erinnerungsangebot kommt ab dem Abend des ersten Tages.
  - Unbekannte Makros zeigen „≥“ und einen Hinweis: auf Today, in der Food-Tageskarte und den P/K/F-Zeilen, in den Trends-Schnitten und auf der 7-Tage-Karte. Der Coach sagt „höchstens … Protein übrig“, und seine Wochenübersicht nennt Untergrenzen. Beschreiben ergänzt fehlende Makros aus der KI-Schätzung.
  - Die Montagskarte hat „Verstanden“ für die Woche.
  - Trends öffnet von Today auf 7 Tagen und zeigt offline die Geräte-Tage.
- **Tiefe:**
  - Coach `/meal` und ein Chip öffnen Beschreiben, ohne eine Frage zu kosten. `/log` mit Essen verweist auf `/meal`.
  - Der Coach zeigt „3/5 heute frei“ und merkt sich das Limit pro Konto.
  - `/recipe` kennt Mahlzeit und Restbudget.
  - Zwei Kontextzeilen: Wochen-Check nur als Zustand, ohne Zahlen, und die geplanten Gerichte.
  - Fehlerbanner mit „Erneut versuchen“, Sprecher für Screenreader, „Öffnen“ am gespeicherten Rezept.
  - Vorbereitete Fragen aus der Montagskarte und aus Trends.
  - Speiseplan-Zeilen öffnen das Rezept mit den geplanten Portionen. Ein vergangener Tag fragt „geplanter Tag oder heute?“.
  - Portionen-Stepper, „Werte ändern“ für alle manuellen Einträge und „Name ändern“ für KI-Einträge. „Bearbeiten“ am Favoriten.
  - Allergien im Onboarding.
  - 11 neue Katalogrezepte und eine Kategorie Snack. Jede Ernährungsform und jede Unverträglichkeit behält ein Frühstück. Der Tipp rotiert täglich.
  - Rekorde nach Übungsname, im Abschluss-Blatt genannt, und ein Verlauf pro Übung.
- **Kleinere Punkte:**
  - Teilen statt Kopieren.
  - 12/24-Stunden-Zeiten in Food und beim Coach-Limit.
  - Picker mit kcal und Protein.
  - „Passwort ändern“ ist für reine Google-Konten ausgeblendet.
  - Der Export nennt die Gerätefotos.
  - Die Ziele-Seite sagt im Halteband, bis wann der Plan das Ziel hält.
  - Dialoge mit drei Knöpfen zeigen auf 320 px bei 2× Text zuerst die Nachricht.

**KI-Abläufe geprüft, Fehler behoben:**
- **Foto-Scan (App):** Ein Makro, das schwerer ist als die gemessene Portion oder negativ, ist jetzt unbekannt („–“). Vorher floss z. B. 250 g Kohlenhydrate auf 200 g Teller in die Tagessumme.
- **`analyze-meal`:** Ein negatives Makro vom Modell wird `null` statt eines gemessenen 0 g.
- **`recipe-import`:**
  - Kein bezahlter zweiter Versuch mehr, wenn das Request-Budget ihn nicht mehr trägt.
  - Die Prüfung bricht beim ersten Zitat ab, das nicht in der Quelle steht. Vorher kostete das bis zu 3 s Edge-CPU.
  - Bidi-Steuerzeichen werden aus Titeln entfernt.
- **`coach-chat`:**
  - Englische Antworten, die die App-Daten erklären, wurden zur Leck-Ablehnung und kosteten trotzdem eine Frage (P2).
  - Die Vorfilter-Ebene lehnte „anabolic“ und jedes „HGH“ ab und warf bei einem so benannten Essen den ganzen Tageskontext weg (P2).
  - Die deutschen Ablehnungstexte haben echte Umlaute.
- **Coach-Kontext (App):** Lange Namen werden nicht mehr mitten im Emoji gekürzt.
- **Geprüft ohne weiteren Befund:**
  - Auth, Limits, Budgets, Einwilligung vor jedem Aufruf, Konto-Grenzen;
  - Streaming, Rückerstattungen, `/recipe`, `/plan`, `/log`;
  - Bildgrenzen, Zeitlimits, Fehlercodes;
  - die Verträge zwischen App und Server.

**Braucht ein Deploy (Owner):** `analyze-meal`, `recipe-import` und `coach-chat`. Alle Änderungen sind rückwärtskompatibel; die App-Änderungen funktionieren auch gegen die heute laufenden Functions.

**Agenten-Entscheidungen (zur Durchsicht):**
- 20 % Toleranz für „dasselbe Essen“.
- Band von 1,5 kg; „Halten“ speichert Halten als Ziel.
- Wiege-Erinnerung Mo/Do 07:30, nicht einstellbar.
- Angebot ab 17:00 am ersten Tag.
- Kurzbefehle ohne Icons.
- `/meal` heißt in beiden Sprachen so; Essen unter `/log` bleibt berechnet.
- An Anthropic gehen nur Plan-Titel und der Check-Zustand, keine Zahlen.
- Der Zähler zeigt „3/5 heute frei“.
- Der vergangene Plan-Tag ist die erste Wahl.
- Snacks sind eine eigene Kategorie.
- Teilen ersetzt Kopieren.
- Abmelden fragt immer.
- „x von y“ entfällt, bis der Plan Sitzungen pro Woche speichert.
- Health Connect fragt Gewicht zusammen mit den Schritten an.
- Bestehende iPhone-Nutzer bleiben mit Apple Health verbunden.

**Nicht gebaut:**
- **Braucht eine Migration oder neue Sync-Art:**
  - Ziel pro vergangenem Tag;
  - Sitzungen pro Woche im Trainingsplan;
  - ein abgehaktes Plan-Gericht zurücknehmen;
  - ein abgeschlossenes Training bearbeiten;
  - Rückerstattung von Limits bei Providerfehlern.
- **Owner-Entscheidung:**
  - Anzeigename ändern: nur Auth-Metadaten, oder eine Migration für `profiles.display_name`.
  - Antwort trotz Verbindungsabbruch während der Klassifizierung: mehr Providerkosten gegen eine verlorene Frage.
  - Globales Tageslimit als „Dienst nicht verfügbar“ statt „zu viele Analysen“.
  - Eigene Makroziele im Live-Modus.
- **Inhalte:** Fotos für die 11 neuen Rezepte; Icons für die Kurzbefehle.
- **Abschnitt 4:** Widget, Scan-Korrektur per Satz, Etikett-Foto, Nährwerte nach Health schreiben, größerer Katalog. Sie bleiben „nach dem Messen“.
- **Montags-Nachricht als eigene Benachrichtigung:** Der Montagstext der Wiege-Erinnerung nennt den Check schon. Mehr als zwei Nachrichten pro Woche wollte die Review nicht.
