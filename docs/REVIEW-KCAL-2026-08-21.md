# Eatova — Review der Kalorien-Berechnungen (2026-08-21)

**Anlass.** Frage des Produktverantwortlichen: „Ist unsere Formel für den
Tagesbedarf gut so? Stimmen die verbrannten Kalorien aus Schritten (7000
Schritte → knapp 400 kcal)? Helfen diese Zahlen Leuten wirklich beim
Abnehmen?"

**Methode.** 10 unabhängige Recherche-Agents, je ein Themengebiet, mit
Internet-Recherche in Primärquellen (FAO/WHO/UNU, DGE, EFSA, IOM, ACSM,
Academy of Nutrition and Dietetics, NHLBI/NIH, PubMed/PMC) plus
Hilfe-Center der Wettbewerber (MyFitnessPal, Yazio, Lifesum, Cronometer,
MacroFactor, Lose It!, Noom, Fddb) und numerischer Kreuzcheck gegen
calculator.net, tdeecalculator.net und den NIH Body Weight Planner
(Modellcode lokal nachgebaut). 861 Tool-Aufrufe, 1,39 M Tokens,
Stand des Codes: `243d9d3` (PR #46).

**Ergebnis in einem Satz.** Die Arithmetik war korrekt (BMR/TDEE auf die
Kalorie identisch mit allen externen Rechnern), aber vier **Konventionen**
waren falsch oder irreführend — und genau die entscheiden darüber, ob jemand
abnimmt: der PAL-Sockel 1,2, die blinde Addition der Schritt-Kalorien, die
Unisex-Untergrenze 1200 kcal und die Protein-Formel nach Ist-Gewicht.

---

## 1 · Die konkrete Frage: 7000 Schritte = 400 kcal?

| | Formel | 100 kg / 180 cm / 7000 Schritte |
|---|---|---|
| **bis Juni 2026** (Commit 2b41335) | `Schritte × kg × 0,00057` | **399 kcal** |
| **Juni–August 2026** (478bae9 … 243d9d3) | Schrittlänge 0,415 × Größe → 5,23 km × 0,5 kcal/kg/km | 261 kcal |
| **ab diesem PR** | wie oben, aber nur Schritte **über der Basis der Aktivitätsstufe** (sitzend: 5000) | **75 kcal** |

Die 399 kcal waren kein Zufall: 0,00057 kcal/Schritt/kg ist exakt der Faktor
des Omni-Calculators (3,5 MET **brutto** bei 4,8 km/h) — also inklusive des
Ruheumsatzes, den das Tagesziel über BMR × PAL schon enthält. Beim Addieren
wurden so 110–130 kcal pro Tag doppelt gezählt. Der Wechsel auf die
ACSM-Netto-Komponente (0,5 kcal/kg/km) war richtig; die Messliteratur liegt
mit 0,52–0,63 kcal/kg/km (Weyand 2010, Ludlow & Weyand 2016) sogar leicht
darüber — 0,5 ist die konservative Untergrenze.

**Der eigentliche Fehler lag aber nicht in der Umrechnung, sondern im
Modell:** Das Tagesziel enthält über den PAL-Faktor bereits Alltagsbewegung.
FAO/WHO/UNU-„sedentary" (1,40–1,69) enthält laut FAO-Tabelle 5.1 rund eine
Stunde Gehen pro Tag (≈ 5000–6000 Schritte); Doubly-Labeled-Water-Daten
zeigen PAL 1,73 bei ~10 000 Schritten. Wer „leicht aktiv" wählte und 7000
Schritte ging, bekam 190–370 kcal gutgeschrieben, die schon im Ziel steckten
— das frisst die Tempo-Stufe −0,25 kg/Woche komplett und −0,5 zur Hälfte.
Alle untersuchten Wettbewerber verhindern das aktiv (Lose It!:
Schritt-Schwelle je Stufe; MyFitnessPal: Differenz zur Stufen-Projektion,
negativ möglich; Cronometer: Tracker ersetzt die Stufe; Lifesum/Yazio:
erzwingen bzw. empfehlen die niedrigste Stufe bei Tracker-Kopplung).

---

## 2 · Befunde nach Thema

Legende: ✅ korrekt · ⚠️ vertretbar mit Einschränkungen · ❌ falsch/irreführend

### 2.1 BMR-Formel (Mifflin-St Jeor) — ✅

* Koeffizienten (10·kg + 6,25·cm − 5·Alter; +5 m / −161 w) exakt Mifflin
  et al. 1990 (n = 498, 19–78 J.).
* Von der Academy of Nutrition and Dietetics für normal-, über- und adipöse
  Erwachsene empfohlen („Strong, Conditional"); in Validierungen
  (Frankenfield 2005/2013, Weijs 2008, Cancello 2018) durchgehend die beste
  einfache Gleichung. Harris-Benedict überschätzt systematisch.
* DGE (Müller 2004) und UK (Henry 2005) rechnen anders, die Abweichung
  liegt bei den Beispielprofilen aber nur bei −46 … +63 kcal.
* ⚠️ Der „neutral"-Offset −78 (Mittelwert) ist rechnerisch vertretbar
  (±83 kcal = 4–6 % BMR, innerhalb des Formelrauschens), hat aber keine
  Leitliniengrundlage; MyFitnessPal fragt stattdessen nach dem körperlichen
  Geschlecht bzw. einer Hormontherapie. → Folgepunkt.
* ⚠️ Die Unschärfe (±10 % bei 70–82 % der Personen; bei BMI ≥ 40, < 18,5
  und > 65 J. nur 43–61 %) wurde nirgends kommuniziert. → Footnote ergänzt.

### 2.2 PAL-Faktoren 1,2 / 1,375 / 1,55 / 1,725 / 1,9 — ❌

* Die fünf Werte sind eine **Online-Rechner-Konvention** (arithmetische
  Reihe, Schrittweite 0,175) ohne Primärquelle — weder Harris-Benedict noch
  FAO/WHO/UNU (1985: 1,55/1,78/2,10 m bzw. 1,56/1,64/1,82 w; 2004:
  1,40–1,69 / 1,70–1,99 / 2,00–2,40).
* **1,2 ist in allen Leitlinien der Wert für bettlägerige bzw.
  rollstuhlgebundene Menschen** (DGE „gebrechlich, immobil"; Black 1996
  „chair- or bed-bound"; FAO 2004: 1,21 als Kurzzeit-Überlebensniveau). Der
  Bürojob ohne Sport liegt bei DGE 1,4–1,5, EFSA 1,4, NIH-BWP-Minimum 1,4,
  gemessen (DLW) bei 1,55–1,70.
* Die Stufentexte („1–2× / 3–5× / 6–7× Sport/Woche") widersprachen der
  eigenen Überschrift („Alltag OHNE gezähltes Training") und dem
  Branchenkonsens, Stufen über Beruf/Alltag zu definieren.
* Produktfolge des 1,2-Sockels: Frauen bis ~75 kg landeten mit „Kaum aktiv"
  schon bei −0,5 kg/Woche in der 1200-kcal-Klemme.

### 2.3 Doppelzählung Schritte + PAL — ❌

Siehe Abschnitt 1. Zusätzlich: Im Default-Fall (1,2 + alle Schritte) gab es
keine Doppelzählung, sondern das Gegenteil — 1,2 × BMR + 7000 Schritte ergab
beim 100-kg-Mann effektiv PAL 1,33, also 130–330 kcal **unter** dem
DGE-Wert für Büroangestellte; für Android-Nutzer (keine HealthKit-Schritte)
war der Bedarf damit ~15 % zu niedrig.

### 2.4 Umrechnung Schritte → kcal — ⚠️ (Formel ok, Modell nicht)

* ACSM-Herleitung sauber (0,1 ml O2/kg/m × 5 kcal/L = 0,5 kcal/kg/km
  netto). Messwerte 0,52–0,63 — 0,5 ist konservativ.
* Schritte statt Geräte-Kalorien zu nutzen ist richtig: Apple-Watch-
  Energieverbrauch hat in 8 Studien MAPE 10–152 % (Shcherbina 2017:
  27–93 %).
* Schrittlänge 0,415/0,413 × Größe: Industrie-Heuristik für ~1,3 m/s,
  trifft CADENCE-Adults-Daten (0,414–0,422) und Apples Validierungskohorte
  (0,410). Bei langsamem Alltagsgehen überschätzt sie die Distanz um ~27 %,
  der höhere Netto-Aufwand pro km gleicht das bei den kcal aber weitgehend
  aus. **Nicht** auf 0,43/0,45 wechseln. → HealthKit
  `distanceWalkingRunning`/`walkingStepLength` als Folgepunkt.

### 2.5 Defizit, 7700 kcal/kg, Sicherheitsklemme — ⚠️/❌

* 7700 kcal/kg (Wishnofsky) als Umrechnung ist branchenüblich, aber die
  **lineare Prognose „Wochen bis Ziel" ist systematisch zu optimistisch**:
  Hall 2011 (Lancet): statische Regel sagt 22 kg im ersten Jahr voraus, real
  ~11 kg; Thomas 2013: 27,6 lb vorhergesagt, 20,1 lb gemessen. NIH BWP für
  100 → 85 kg bei −550 kcal: 41 Wochen statt linear 30.
* Stufen −275/−550/−825 liegen im Leitlinienkorridor (AHA/ACC/TOS 500–750,
  NHLBI 500–1000, DGE/DAG 500–600). **−1100 kcal/Tag überschreitet alle
  Leitlinien** und ist unter 100 kg schneller als 1 % Körpergewicht/Woche
  (ISSN/Garthe-Obergrenze für Muskelerhalt). Kein Wettbewerber geht über
  1000.
* ❌ **Unisex-Untergrenze 1200 kcal:** für Frauen leitlinienkonform, für
  Männer nennen AHA/ACC/TOS und die Academy 1500–1800 kcal (Klasse I,
  Evidenz A), NHLBI 1200–1600; MyFitnessPal, Lose It! und Noom erzwingen
  1500 für Männer. Ein 100-kg-Mann landete bei Eatova durch Rundung exakt
  auf 1200 — ohne Warnung (calculator.net warnt bei 1316 „consult a doctor").
* „Nicht unter den BMR essen" ist keine Leitlinienregel — kein Kriterium.

### 2.6 Makros (1,6 g/kg Protein, 25 % Fett, Rest KH) — ❌ bei Adipositas

* Für Normalgewichtige solide: 1,6 g/kg = Morton-2018-Breakpoint, ISSN
  1,4–2,0; 25 % Fett innerhalb AMDR/EFSA 20–35 %.
* ❌ Protein nach **Ist-Gewicht** bei Adipositas widerspricht DGE („ein
  Körpergewicht zugrunde legen, bei dem die Person Normalgewicht hätte"),
  Weijs 2025 und ESPEN-Praxis (adjustiertes Gewicht). Bei 130 kg und
  1200 kcal: 208 g Protein = 69 % der Energie (AMDR-Obergrenze 35 %), 17 g
  Kohlenhydrate; ab ~141 kg wurden die Kohlenhydrate **negativ** und nur vom
  DB-Clamp auf 0 gehoben. Die 400-g-Klemme griff erst ab 251 kg.
* Eine Nieren-Obergrenze für Gesunde ist nicht belegt (Devries 2018,
  Antonio 2016) — die Klemme war nie ein Sicherheitsfeature.

### 2.7 Unterstützen die Zahlen das Abnehmen? — ⚠️

* Selbstmonitoring per App ist der am besten belegte Wirkmechanismus (Burke
  2011: 22 Studien; Carter 2013: App −4,6 kg vs. Papier −2,9 kg). Entscheidend
  ist Konsistenz (≥ 2 Mahlzeiten/Tag), nicht Rechengenauigkeit; eine nur
  ausgehändigte App bringt nichts (Laing 2014: −0,3 kg).
* ❌ „Verbrannt" 1:1 ins Budget: der Körper kompensiert im Schnitt 28 % der
  Aktivitätsenergie (Careau 2021); Energieverbrauchs-Feedback führt zum
  Mehressen („licence to eat", McCaig 2016); IDEA-Trial (Jakicic 2016):
  Wearable-Gruppe −3,5 kg vs. −5,9 kg ohne Wearable.
* Eingabeseite systematisch nach unten verzerrt (Lichtman 1992: −47 % bei
  „Diät-Resistenten"; KI-Bildmodelle MAPE 36–64 %, stärker bei großen
  Portionen). Konsequenz laut Evidenz: nicht pauschal konservativer rechnen,
  sondern **am Gewichtstrend nachkalibrieren** (MacroFactor, NIH BWP).

### 2.8 Wettbewerber — wo Eatova abwich

| Aspekt | Eatova (vorher) | Feld |
|---|---|---|
| BMR | Mifflin | Mifflin (MFP, Yazio, Lifesum, Cronometer); HB nur Fddb/Noom; adaptiv: MacroFactor |
| Stufen | „x Sport/Woche", Sockel 1,2 | Beruf/Alltag (DGE-Wortlaut), Sockel 1,25–1,4 |
| Schritte | blind addiert | Schwelle je Stufe (Lose It!), Differenz (MFP), Faktor 0,5 (Noom) |
| max. Defizit | 1100 | MFP/Lose It! 1000, Yazio 750, FatSecret 500, MacroFactor ≤ 1 % KG |
| Untergrenze | 1200 unisex | MFP/Lose It!/Noom 1500 m / 1200 w |
| Makros | 1,6 g × Ist-Gewicht | MacroFactor: Magermasse + Fett-Untergrenze |

### 2.9 Numerischer Kreuzcheck — ✅ Arithmetik

BMR und TDEE für alle fünf Testprofile auf die Kalorie identisch mit
calculator.net, tdeecalculator.net, NASM und NIH BWP (±3 kcal). Abweichungen
ausschließlich durch Konventionen (2.2–2.6).

---

## 3 · Was dieser PR ändert

Alle Änderungen in `lib/src/services/kcal_calculator.dart`,
`lib/src/models/user_profile.dart`, `lib/src/app/home_store_tracking.dart`,
den Prognose-Anzeigen (Onboarding-Zusammenfassung, Profil-Plan-Karte) und den
ARB-Texten. **Keine DB-Migration nötig** — `activity_level` und `weight_goal`
bleiben dieselben Enum-Werte, nur ihre Bedeutung ändert sich; die App ist
noch nicht veröffentlicht, Bestandsprofile sind Testprofile.

| # | Änderung | Vorher | Nachher |
|---|---|---|---|
| 1 | **PAL-Leiter** an FAO/DGE angelehnt | 1,2 / 1,375 / 1,55 / 1,725 / 1,9 | **1,4 / 1,55 / 1,7 / 1,85 / 2,0** |
| 2 | **Stufentexte** nach Beruf/Alltag (DGE), Überschrift „Beruf und Alltag – im Zweifel eine Stufe tiefer" | „1–2× Sport/Woche" … | „Überwiegend sitzend: Büro, Homeoffice …" … |
| 3 | **Schritt-Basis je Stufe** (Tudor-Locke-Bänder): nur Schritte darüber zählen als „Verbrannt" | alle Schritte | 5000 / 7500 / 10 000 / 12 500 / 15 000 |
| 4 | **Untergrenze geschlechtsabhängig** | 1200 für alle | **1200 w / 1500 m / 1350 divers** |
| 5 | **1-%-Defizitdeckel**: max. 1 % Körpergewicht/Woche = kg × 11 kcal/Tag, auf 0,05 kg/Woche abgerundet ((kg ÷ 5) × 55, min. 275), mit eigenem Hinweistext | −1100 für alle | 60 kg → 660 (0,6), 70 kg → 770 (0,7), 78 kg → 825 (0,75), 99 kg → 1045, ≥ 100 kg → 1100 |
| 6 | **Protein nach Referenzgewicht** (bis BMI 25 Ist-Gewicht, darüber Gewicht bei BMI 25 + 25 % des Überschusses), **Energie-Deckel 35 %** (hart 40 %, falls sonst < 1,2 g/kg) | 1,6 g × Ist-Gewicht, Klemme 400 g | KH garantiert ≥ 35 % der Energie (≥ 105 g) |
| 7 | **Prognose als Spanne** linear … dynamisch (Bedarf sinkt 22 kcal/Tag pro verlorenem kg, Hall); „frühestens", wenn das Defizit vor dem Ziel aufgebraucht ist | „in ca. 14 Wochen" | „in ca. 14–16 Wochen" |
| 8 | Footnote: „Schätzung nach Mifflin-St Jeor (typisch ±10 %)" | — | ✓ |
| 9 | **Tempo-Labels auf 0,05-Raster** (die 50er-Rundung des Ziels verschiebt die Rate um ≤ 0,023; „−0,48" für ein gewähltes „−0,5" wäre falsche Präzision) und eigener Satz, wenn die Klemme das Defizit ganz frisst („Damit bleibt dein Gewicht praktisch stabil, statt −0,25 kg/Woche zu erreichen.") | „−0,48 kg/Woche"; „… ist damit Gewicht stabil statt −0,25 kg/Woche" | „−0,5 kg/Woche" |

### Zahlenbeispiele vorher → nachher

| Profil | Erhaltung | Ziel −0,5 kg/Wo | Ziel −1 kg/Wo | 7000 Schritte „Verbrannt" |
|---|---|---|---|---|
| Standard 78 kg / 178 cm / 30 J. / divers / sitzend | 1997 → **2330** | 1450 → **1800** | 1200 (Klemme) → **1500** (Deckel 825, −0,75 kg/Wo) | 10 000 Schritte: 288 → **144** |
| P1 Frau 70 kg / 165 cm / 30 J. / sitzend | 1704 → **1988** | 1200 (Klemme!) → **1450** | 1200 → **1200** (Deckel 770 statt 1100: 1218 → 1200, −0,7 kg/Wo) | 167 → 48 |
| P3 Mann 100 kg / 180 cm / 40 J. / sitzend | 2316 → **2702** | 1750 → **2150** | 1200 ohne Warnung → **1600** | 261 → **75** |
| P5 Mann 130 kg / 175 cm / 45 J. / leicht | 2989 → **3369** | 2450 → 2800 | 1900 → 2250; Protein 208 g → **144 g** | — |

### Tests

* `test/kcal_calculator_test.dart`, `test/services/kcal_effective_pace_test.dart`,
  `test/services/kcal_macro_split_test.dart` komplett auf die neuen Zahlen
  umgestellt, neue Gruppen für Schritt-Basis, Deckel, Referenzgewicht,
  Prognose-Spanne und Prognose-Texte.
* Rundgang über den gesamten Eingaberaum sichert jetzt zusätzlich: KH ≥ 100 g,
  Protein ≤ 40 % der Energie, kcal ≥ Untergrenze des Geschlechts, Deckel nie
  in Zunahme-Richtung, dynamische Prognose ≥ linear.

---

## 4 · Bewusst NICHT in diesem PR (Folgepunkte, nach Wirkung sortiert)

1. **Re-Anchoring am Gewichtstrend.** Gewichts-Logs aktualisieren
   `profile.weightKg` heute nicht; Tagesziel und Prognose bleiben auf dem
   Onboarding-Gewicht stehen, bis der Nutzer es unter Ziele ändert. Dazu
   kommt: die Ziele-Seite erkennt „manuell gesetzt" per Vergleich
   gespeichert ↔ gerechnet — ändert sich das Gewicht, kippt sie fälschlich in
   den Manuell-Modus. Evidenzbasiert wäre ein Wochen-Check-in nach
   MacroFactor-Muster (geglätteter Gewichtstrend + geloggte Aufnahme →
   Erhaltungsbedarf in 100–200-kcal-Schritten nachziehen). Das ist die
   Maßnahme mit der größten Wirkung auf echten Abnehmerfolg, braucht aber eine
   Produktentscheidung (automatisch vs. Nachfrage, Umgang mit Manuell-Modus).
2. **HealthKit-Distanz statt Schrittlängen-Formel**
   (`distanceWalkingRunning`, Fallback `walkingStepLength`) — tempo-adaptiv,
   an 64–95-Jährigen validiert. Braucht neue HealthKit-Berechtigungen und
   einen Nachtrag in der Datenschutzerklärung (Website + App).
3. **Workouts** (Kraft, Rad, Schwimmen) fließen gar nicht ein; Geh-/Lauf-
   Workouts über `HKWorkout` importieren und deren Schritte aus der Tagessumme
   herausrechnen.
4. **Schalter „Schritt-Kalorien ins Ziel rechnen"** (Default an; bei aus
   weiter anzeigen, aber nicht in „verbleibend"). Option: Kompensationsfaktor
   0,5–0,7 statt 1:1 für Abnehmziele (Careau 2021, Noom-Modell).
5. **Geschlecht „divers"**: Folgefrage „für die Berechnung eher männlicher /
   weiblicher Stoffwechsel / Mittelwert" mit Hormontherapie-Hinweis,
   Bereichsanzeige w–m; optional Körperfett-Eingabe für Katch-McArdle.
6. **Plausibilitäts-Guards**: Zielgewicht ≥ BMI 18,5; Abnehmziele bei
   BMI < 18,5 nicht anbieten; Hinweis „Schätzung hier ungenauer" bei BMI ≥ 40
   oder Alter ≥ 65; Alter < 18 (Mifflin gilt ab 19; `ageYearsMin` ist 16).
7. **Android-Schrittquelle** (Health Connect) — heute iOS-only; ohne
   Schrittquelle gilt nur der PAL (jetzt mit 1,4 wenigstens leitlinienkonform).
8. **Adhärenz** statt Rechengenauigkeit: Wochen-Streak „Tage mit ≥ 2
   Mahlzeiten", Re-Engagement in Woche 3–10, Wochen- statt Tagesbilanz,
   neutrale Farben bei Überschreitung, „Zahlen ausblenden"-Option.

---

## 5 · Quellen (Auswahl)

**BMR.** Mifflin et al. 1990, Am J Clin Nutr 51:241 (PMID 2305711) ·
Academy EAL Adult Weight Management (andeal.org, key 4341/621) · Frankenfield
2005 (PMID 15883556), 2013 (PMID 23631843) · Weijs 2008 (PMID 18842782) ·
Cancello 2018 (PMC6068274) · DGE FAQ Energie 2015 (dge.de) · SACN 2011.

**PAL.** FAO/WHO/UNU 2004, Human Energy Requirements, Kap. 5
(fao.org/4/y5686e/y5686e07.htm) · FAO 1985 (fao.org/4/aa040e/AA040E06.htm) ·
Black 1996 (archive.unu.edu/unupress/food2/UID01E/UID01E08.HTM) · DGE
Referenzwerte Energie · IOM/DRI Energy 2023 (NBK591020) · Tudor-Locke &
Bassett 2004; Tudor-Locke 2011 (PMC3197470).

**Schritte → kcal.** ACSM Metabolic Calculations (Walking equation) ·
Weyand 2010, J Exp Biol 213:3972 · Ludlow & Weyand 2016 (PMID 26679617) ·
Weyand 2013 (PMID 23928111) · Browning & Kram 2006 (J Appl Physiol) ·
Compendium of Physical Activities 2011 · Shcherbina 2017 (J Pers Med) ·
Apple HealthKit `distanceWalkingRunning`, `walkingStepLength`.

**Defizit/Klemme.** Hall 2008 (PMC2376744) · Hall 2011, Lancet (PMC3880593)
· Thomas 2013/2014 (ijo2013112, PMC4024447) · NIH Body Weight Planner
(niddk.nih.gov/bwp, Modellcode bodymodel.js/intervention.js) · AHA/ACC/TOS
2013 Obesity Guideline (PMC5819889) · NHLBI Practical Guide
(prctgd_c.pdf) · NHS Obesity Treatment · ISSN/Garthe 2011 (PMC5470183).

**Makros.** Morton 2018 (PMC5867436) · Leidy 2015 (PMID 25926512) · ISSN
Protein Position Stand 2017 (PMC5477153) · DGE FAQ Protein · Weijs 2025
(PMID 39514335) · IOM DRI Summary Tables (NBK56068) · EFSA DRV Summary ·
Devries 2018 (PMID 30383278) · Antonio 2016 (PMC5078648).

**Verhalten.** Burke 2011 (J Am Diet Assoc) · Carter 2013 (JMIR) · Laing
2014 (Ann Intern Med, PMID 25402403) · Patel 2019 (JMIR mHealth) · Jakicic
2016 IDEA (JAMA, PMID 27554186) · Careau 2021 (Curr Biol) · McCaig 2016 ·
Lichtman 1992 (NEJM, PMID 1454084).

**Wettbewerber.** MyFitnessPal Help (Calorie Adjustment, Negative
Adjustments, updated nutrition goals) · Yazio Help (activity level, Polar
double-counting) · Lifesum Help (exclude exercise calories) · Cronometer
(Energy Expenditure) · Lose It! (Calorie Bonus, Low Budget Warning, Apple
Watch) · Noom (step count & weight-loss zone) · MacroFactor (algorithms,
expenditure modifiers) · Fddb Help.

Vollständige Agent-Berichte mit allen URLs: Workflow-Run
`wf_b1dc141f-ad7` (Session 0761e99b, 2026-08-21).
