# Korrekturtexte für die öffentliche Datenschutzerklärung

Vorbereitet am 14.09.2026 für [eatova.de/datenschutz](https://eatova.de/datenschutz).
**Noch nicht veröffentlicht.** Diese Datei enthält die sachlichen Änderungen für
die bestehende deutsche Seite. Die lokale Quelle wurde inzwischen zugeordnet:
`EatovaTest21st/public/datenschutz.html` stimmt am 14.09.2026 exakt mit dem per
HTTPS abgerufenen öffentlichen Datenschutz-HTML überein. Der Projektordner
`EatovaTestCodex` enthält eine lokale Neugestaltung und eine identische archivierte
Referenz; seine gestaltete Rechtsseite ist nicht der veröffentlichte HTML-Stand.
Der Commit dieser Datei verändert die öffentliche Seite nicht.

Der [vorbereitete Ein-Datei-Patch](PRIVACY-WEBSITE-CORRECTION-2026-09-14.patch)
wendet die Änderungen auf `public/datenschutz.html` an. Er wurde gegen eine
isolierte Kopie erstellt; das bestehende Website-Projekt mit seinen uncommitteten
Designänderungen wurde nicht verändert. `git apply --check` ist gegen die
zugeordnete lokale Quelle erfolgreich. Ein späterer Gesamtbuild oder Upload des
Website-Projekts würde weitere vorhandene Änderungen einschließen und ist nicht
Teil dieser Korrekturvorbereitung.

SHA-256 des ursprünglichen, veröffentlichten HTML nach LF-Normalisierung:
`ffc51f782bc1a1e1150ff3dca59345b0814be267316362a51b2b5b1818409877`.
Vor einer späteren Anwendung die Quelle erneut abgleichen, den Patch nur auf die
Datenschutzdatei anwenden und ausschließlich das geprüfte Ergebnis zur
Veröffentlichung vorlegen. Das Änderungsdatum im Patch ist das Vorbereitungsdatum
und muss zum tatsächlichen Veröffentlichungsstand passen.

Die isolierte HTML-Fassung wurde mit den vorhandenen lokalen Website-Styles
in Chromium bei 320, 390, 768 und 1440 Pixel Breite geprüft: keine horizontale
Überbreite, keine fehlenden Ressourcen oder JavaScriptfehler; alle 26 IDs sind
eindeutig und alle internen Sprungziele vorhanden. Neue Anbieter-/Trainings-/Health-
Connect-/Exportangaben sind im gerenderten Text enthalten. Die Originaldatei hat
nach den Tests weiterhin denselben Hash. Das ist ein lokaler HTML-Nachweis,
kein vollständiger Site-Build oder Veröffentlichungsnachweis.

Die Texte folgen den aktuellen Datenflüssen im App-Repository. Vor Veröffentlichung
müssen die tatsächlich bereitgestellten Modellanbieter und etwaige Serveroverrides
mit diesen Angaben übereinstimmen; siehe [Backend](BACKEND.md#ai-configuration).
Die genaue Modellversion gehört nicht in die statische App-Information.

Die bestehende rechtliche Bewertung wird hier nicht ersetzt: Rechtsgrundlagen,
Einwilligung und Widerruf, Verträge, konkrete Verarbeitungsorte und
Aufbewahrungsfristen benötigen einen gesonderten fachlichen bzw. betrieblichen
Nachweis. Insbesondere wird weder ausschließliche EU-Verarbeitung noch eine
garantierte Löschung oder ein Trainingsausschluss bei Dritten zugesagt.

## Abschnitt 5.1 – Google-Anmeldung abgrenzen

Den Satz zur ausschließlichen Beteiligung von Google bei der Anmeldung ersetzen:

> Bei der Anmeldung mit E-Mail und Passwort nutzen wir Google Sign-In nicht.
> Davon unabhängig können freiwillig genutzte KI-Funktionen Daten an
> Gemini-Modelle von Google übermitteln; die Einzelheiten stehen in Abschnitt 5.3.

## Abschnitt 5.2 – Profil, Planung und Training aktualisieren

Den Eintrag zu Profil- und Körperdaten ersetzen:

> **Profil- und Körperdaten:** Anzeigename, E-Mail-Adresse, Gewicht, Größe,
> Alter, biologisches Geschlecht, Aktivitätsniveau, Zielgewicht, Gewichtsziel,
> Ernährungspräferenz sowie die aktuellen Tagesziele für Kalorien,
> Makronährstoffe und Schritte. Wasser- und Schlafziele gehören nicht mehr zu
> den aktuellen Einstellmöglichkeiten der App.

Die gespeicherten Daten um folgende Einträge ergänzen:

> **Mahlzeitenplanung und Einkaufsliste:** von dir geplante Mahlzeiten mit Datum,
> Mahlzeit und Portion sowie abgehakte Einkaufspositionen. Ein geplanter Eintrag
> gelangt erst nach deiner ausdrücklichen Verbrauchsaktion ins Ernährungstagebuch.
>
> **Training:** gespeicherte Trainingspläne mit Workouts und Übungen sowie
> abgeschlossene Trainingseinheiten mit den tatsächlich erfassten Sätzen.
> Abgeschlossene Einheiten behalten eine eigene Kopie der damaligen Trainingsdaten.
> Wird eine Einheit gelöscht, bleibt eine technische Kennung bis zur
> Konto-Löschung erhalten, damit ein älterer Offline-Eintrag die Einheit nicht
> erneut anlegt. Ein Zwischenstand zum Fortsetzen eines laufenden Trainings wird
> auf deinem Gerät gespeichert.
>
> **Coach-Vorschläge:** vom Coach erzeugte Rezepte und Trainingsvorschläge werden
> mit dem jeweiligen Chat gespeichert. Zu deinen eigenen Rezepten bzw.
> gespeicherten Trainingsplänen werden sie erst, wenn du sie ausdrücklich
> übernimmst. Bilder zu Rezepten bleiben auf deinem Gerät.

Die bisherige Beschreibung einer direkt weitergereichten Modellantwort und der
Speicherung ausschließlich empfangener Teilantworten in 5.2 und 5.3 ersetzen:

> **Antwortprüfung und Chatverlauf:** Der Server sammelt und prüft eine erzeugte
> Antwort vollständig, bevor er Antworttext an die App sendet. Freigegebene
> Antworten werden danach in kurzen Abschnitten über die Streaming-Verbindung
> ausgeliefert; andernfalls kann eine sichere Ablehnung erscheinen. Im Verlauf
> werden nur freigegebene Antworten oder Ablehnungshinweise gespeichert.
> Brichst du vor der Freigabe ab, entsteht keine teilweise gespeicherte
> Coach-Antwort; deine Frage kann im Chat verbleiben. Nach der Freigabe kann die
> vollständige geprüfte Antwort bereits im Verlauf stehen, auch wenn dein Gerät
> wegen eines Verbindungsabbruchs nicht den gesamten Text empfangen hat.

## Abschnitt 5.3 – KI-Anbieter und Datenflüsse berichtigen

Die Beschreibung von Coach, Rezept-Generator und KI-Empfängern durch folgende
Absätze ersetzen; den Foto-Scan damit abgleichen:

> **KI-Anbieter:** Unsere KI-Funktionen laufen über eigene Supabase Edge Functions.
> Diese übermitteln die jeweilige Anfrage an OpenRouter, das sie an Gemini-Modelle
> von Google weiterleitet. Für Textantworten, Fotoanalyse und Rezeptbilder kommen
> unterschiedliche Modelle derselben Familie zum Einsatz. Die KI-Funktionen
> werden durch deine jeweilige Anfrage ausgelöst.
>
> **Essensfoto-Analyse:** Das ausgewählte oder aufgenommene Essensfoto und
> gegebenenfalls von dir ergänzte Hinweise werden zur Erkennung von Mahlzeit,
> Portion und Nährwerten übermittelt. Du kannst das Ergebnis vor dem Speichern
> im Ernährungstagebuch prüfen und verändern.
>
> **Coach-Chat:** Übermittelt werden deine aktuelle Frage und bei gewöhnlichen
> Coach-Antworten eine begrenzte Zusammenfassung deiner Ziele und Tageswerte:
> App-Sprache, Gewicht und Zielgewicht, wirksame Zielrichtung, Kalorienbilanz,
> offene Makronährstoffe, Summen je Mahlzeit sowie bis zu zehn protokollierte
> Mahlzeiten mit gekürzten Namen. Außerdem können bis zu zehn vorherige
> Nachrichten desselben Chats und ein von dir angehängtes Foto verarbeitet werden.
> Die automatisch zusammengestellte Tageszusammenfassung enthält keinen Namen,
> keine E-Mail-Adresse und keine Schrittzahl. Angaben, die du selbst in einer
> Nachricht oder einem Foto mitteilst, können diese Informationen trotzdem
> enthalten.
>
> **Rezept-Vorschläge:** Für einen Rezeptwunsch wird dein Nachrichtentext
> verarbeitet; die gewöhnliche Profil- und Tageszusammenfassung wird dem
> Rezeptentwurf nicht beigefügt. Das Rezept mit Zutaten, Zubereitung und
> Nährwerten wird mit dem Chat gespeichert. Die separate Bildgenerierung erhält
> den erzeugten Titel und die Beschreibung. Das erzeugte Bild wird auf deinem
> Gerät gespeichert und nicht in unsere Datenbank hochgeladen.
>
> **Trainings-Vorschläge und Planbesprechung:** Verarbeitet werden deine Frage,
> die Angaben aus dem Trainingsbrief und gegebenenfalls die Informationen des
> von dir ausgewählten Trainingsplans. Ein erzeugter Vorschlag wird im Chat
> angezeigt und gespeichert. Er verändert deinen gespeicherten Plan erst nach
> deiner ausdrücklichen Übernahme.
>
> **Empfänger und Verarbeitung außerhalb der EU:** OpenRouter und Google sind
> Empfänger der jeweiligen KI-Anfragen. Dabei können Daten auch außerhalb der
> EU, einschließlich der USA, verarbeitet werden. Ein EU-Standort unserer
> Supabase-Datenbank bedeutet nicht, dass die nachgelagerte KI-Verarbeitung
> ausschließlich in der EU stattfindet.
>
> **Datenverwendung bei den Anbietern:** OpenRouter und die jeweiligen
> Modellanbieter haben eigene Regelungen und Einstellungen zur Verarbeitung,
> Protokollierung, Aufbewahrung und möglichen Nutzung von Anfragen für das
> Modelltraining. Diese Punkte sind getrennt zu betrachten. Das Löschen eines
> Chats in Eatova ist kein Nachweis dafür, dass sämtliche bei einem Anbieter
> gegebenenfalls aufbewahrten Kopien sofort gelöscht wurden.

Die bisherigen Aussagen über Grok/xAI als Coach- und Rezeptanbieter entfernen.
Rechtliche Angaben zu Übermittlungsgrundlagen erst nach fachlichem Abgleich mit
den tatsächlich geltenden Verträgen ändern. Bestehende Beschreibungen der
Metadatenbereinigung, Schutzmaßnahmen und Aufbewahrungsfristen müssen außerdem
zum jeweils veröffentlichten Backend- und App-Stand passen.

## Abschnitt 5.5 – Health Connect ergänzen

Apple Health als iOS-Funktion beibehalten und um den Android-Datenfluss ergänzen:

> **Health Connect auf Android, freiwillig:** Wenn du die Berechtigung erteilst,
> liest Eatova bei Aktualisierungen im Vordergrund die zusammengefassten Schritte
> für den ausgewählten Tag. Sie dienen der Tagesanzeige und der Schätzung deiner
> Aktivität. Die App fordert auf Android keinen Zugriff auf Gewichtsdaten an
> und schreibt keine Gesundheitsdatensätze in Health Connect. Schrittzahlen
> werden nicht in unserer Supabase-Datenbank gespeichert. Du kannst die
> Berechtigung in Health Connect wieder entziehen.

## Abschnitte 2 und 8 – Umfang des Exports richtig beschreiben

Die Zusage eines vollständigen Downloads und den bisherigen Exportabsatz ersetzen:

> Unter Today → Einstellungen → Daten exportieren kannst du eine JSON-Auskunft
> über die vom Server geladenen Kontodaten anzeigen und kopieren. Sie umfasst
> Profil, Ernährungstagebuch, Favoriten, eigene Rezepte, Gewichtsverlauf,
> Gesamtstatistiken, Trainingspläne, Mahlzeitenplanung, Einkaufscheckzustände,
> Trainingshistorie mit technischen Löschkennungen, Coach-Sitzungen und
> -Nachrichten sowie tägliche Coach-Kontingentzähler.
>
> Das Ernährungstagebuch wird seitenweise geladen. Andere Abschnitte sind auf
> höchstens 10.000 Zeilen begrenzt; der Server kann eine niedrigere Grenze setzen.
> Nicht geladene oder gekürzte Abschnitte werden im Export gekennzeichnet.
> Nur auf dem Gerät gespeicherte Bilder und noch nicht synchronisierte Änderungen
> sind in dieser Serverauskunft nicht enthalten. Die App kopiert die JSON-Auskunft
> auf deine Aktion hin in die Zwischenablage; einen nativen Datei-Download oder
> Dateiversand bietet dieser Dialog derzeit nicht. Für weitere Auskünfte kannst
> du dich an support@eatova.de wenden.

## Quellen und Veröffentlichungskontrolle

- [Aktuelles Dateninventar](../PRIVACY.md) und [Funktionsmatrix](FEATURES.md).
- AI-Empfänger: `supabase/functions/coach-chat/handler.ts` und
  `supabase/functions/analyze-meal/handler.ts`.
- Coach-Snapshot: `lib/src/app/home_store.dart`, `coachContext`.
- Training: `supabase/functions/coach-chat/training_context.ts` und
  `lib/src/screens/coach/coach_training_brief.dart`.
- Android-Schritte: `lib/src/services/android_health_service.dart`.
- Export: `lib/src/services/data_export.dart`,
  `lib/src/screens/settings/settings_screen.dart` und
  `lib/src/widgets/shared/data_export_sheet.dart`.

Nach Veröffentlichung die tatsächliche öffentliche Seite auf Deutsch prüfen:
neue Empfänger, Planung/Training, Health Connect, Exportgrenzen und zutreffendes
Änderungsdatum. Den veröffentlichten URL-/Versionsnachweis getrennt vom
App-Commit dokumentieren. Änderungen an Verträgen oder Einwilligungen werden
durch diesen technischen Textentwurf nicht freigegeben.
