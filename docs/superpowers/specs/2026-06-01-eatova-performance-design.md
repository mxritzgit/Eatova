# Eatova — Performance-Härtung (60 FPS, saubere Übergänge, robuste Listen)

**Datum:** 2026-06-01
**Status:** Genehmigt (autonom, im Auftrag des Users freigegeben — User ist AFK, hat
delegiert: „Brainstorme zuerst, beantworte die Fragen selbst, dann führ es aus,
committe und pushe.")
**Scope:** Rein additive, test-sichere Render-Performance. Keine Logik-/UI-Änderung,
keine Test-Pins angefasst.

## Ziel

Die App soll flüssig mit 60 FPS laufen, Tab-Übergänge sauber sein und das Rendering
auch bei langen Listen robust bleiben. Kein Feature-Umbau, keine sichtbare
Designänderung — nur die Render-Pipeline härten.

## Ist-Analyse (gegen den echten Code, nicht gegen Annahmen)

Architektur: Ein zentraler `_ShiftFitHomePageState` hält den gesamten App-State.
`buildSelectedScreen()` baut den aktiven Tab über ein `switch (selectedTab)` — pro
Tab-Wechsel wird der alte Screen verworfen und der neue frisch gebaut, eingehüllt in
`LivelyEntrance` (Key pro Tab → Auftritt spielt bei jedem Wechsel neu).

Befunde:

1. **`LivelyEntrance` (`lib/src/widgets/common/lively.dart`)** animiert ein rohes
   `Opacity`-Widget über die **gesamte Seite**. Ein animiertes `Opacity` mit
   wechselndem Wert erzwingt pro Frame ein `saveLayer` (Offscreen-Rasterung des
   kompletten Tab-Inhalts) — 60×/s über 320 ms, **bei jedem Tab-Wechsel**. Das ist
   der teuerste, am leichtesten vermeidbare Jank-Verursacher.

2. **0 `RepaintBoundary` im gesamten Repo** (per grep verifiziert), aber **8 Dateien
   mit `CustomPainter`** (Kalorien-Ring, Mini-Ringe, Tages-Ring, Koffein-Halbwerts-
   Kurve, Gewicht-Sparkline, Profil-Charts: Weight-Line/BMI-Gauge/Shift-Donut/Mini-
   Ring). Die Painter haben zwar korrektes `shouldRepaint`, liegen aber ohne eigene
   Layer-Grenze neben scrollenden/animierten Geschwistern → werden bei jedem
   Parent-Repaint mit-rasterisiert.

3. **Glass-Karte** (`CaloriesOverviewCard`, `BackdropFilter` sigma 20 + zusätzliches
   `ImageFiltered` sigma 40) ohne Layer-Isolation → teures Blur-Re-Raster bei jedem
   umgebenden Repaint.

4. **Coach-Typing-Indikator** (einzige `.repeat()`-Dauer-Animation, in
   `coach_chat_screen.dart`) ohne `RepaintBoundary` → invalidiert dauerhaft seine
   Geschwister (inkl. Chat-Liste) während er läuft.

5. **Lange Listen — bereits robust:** Die einzigen unbegrenzt wachsenden Listen
   (Mahlzeiten-Verlauf `MealsTodayCard`, Coach-Chat) sind schon `ListView.builder`
   (virtualisiert; `addRepaintBoundaries`+`addAutomaticKeepAlives` default true,
   stabile Keys vorhanden). Die Rezeptliste ist eager (`ListView(children:[…])`),
   aber **begrenzt** (gebündelter Asset-Datensatz + kleine session-lokale User-Liste).

## Entscheidungen

- **Tab-Hosting bleibt `switch`-basiert** (kein `IndexedStack`): IndexedStack hielte
  alle 6 Tabs samt Timern/Controllern (Coach-Chat, Health-Polling) dauerhaft am
  Leben und würde die Entrance-Transition killen — Verhaltensänderung mit Nachteilen.
  Stattdessen: die Transition selbst billig machen.
- **Rezeptliste bleibt eager** (kein Sliver-Umbau): Die Widget-Tests rufen
  `find.byKey('recipe-tile-<slug>')` **vor** `ensureVisible` — eine lazy Liste baut
  Off-Screen-Tiles nicht, `find` schlägt fehl → 2 Tests bräche. Daten sind ohnehin
  begrenzt. Dokumentierter Follow-up unten.

## Geplante Änderungen (alle additiv, test-sicher)

1. **`lively.dart`:** `Opacity` → `FadeTransition` (effiziente Opacity-Layer-Pipeline,
   kein `saveLayer`), Kind als gecachtes `child` in `RepaintBoundary` gehüllt (Seite
   wird einmal gerastert, der Auftritt komponiert nur den fertigen Layer neu statt ihn
   60×/s neu zu rastern), `Transform.translate` für den Slide bleibt (reine
   Transform-Layer, billig). Fade+Slide-Verhalten optisch identisch; Keys/Hit-Testing
   unberührt (Kind bleibt immer im Baum).

2. **`RepaintBoundary` um jeden `CustomPaint`-Painter** (Kalorien-Ring, Mini-Ring,
   Tages-Ring, Koffein-Kurve, Gewicht-Sparkline, 4 Profil-Charts) → eigene Layer, die
   bei Scroll/Geschwister-Rebuild nicht neu rastern.

3. **`RepaintBoundary` um die Glass-`CaloriesOverviewCard`** → Blur-Layer isoliert.

4. **`RepaintBoundary` um den Coach-Typing-Indikator** → Dauer-Animation invalidiert
   die Chat-Liste nicht mehr.

## Nicht-Ziele / bewusst ausgelassen

- Kein State-Management-Umbau (Provider/Riverpod) — out of scope, riskant, kein
  Auftrag.
- Kein `IndexedStack`, kein Sliver-Rezept-Umbau (s. Entscheidungen).
- Keine Design-/Text-/Logik-Änderung.

## Verifikation

`flutter analyze` → 0 Issues und `flutter test` → 33/33 grün (lokal, SDK unter
`C:\Users\morit\Desktop\Flutter\flutter`), vor Commit. Danach commit + push auf `main`.

## Follow-ups (offen, nicht in diesem Durchlauf)

- Rezeptliste auf `CustomScrollView`/`SliverList` umstellen, sobald der Rezept-
  Datensatz wächst — erfordert die 2 Rezept-Tests von `ensureVisible` auf
  `scrollUntilVisible` umzustellen (Keys bleiben erhalten).
