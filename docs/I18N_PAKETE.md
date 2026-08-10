# i18n-Screen-Pakete — Briefing (2026-08-10)

Dieses Dokument ist der Vertrag für die Extraktion der ~2.000 deutschen
Bestandstexte in die ARB-Dateien. Grundlage:
`docs/superpowers/specs/2026-08-10-i18n-design.md` (§4–§6). Das Grundgerüst
(PR #29) liegt auf main: `context.l10n`, `app_de.arb`/`app_en.arb`,
Sprachwahl in den Einstellungen.

## Die eine Regel, die alles trägt

**`app_de.arb` übernimmt jeden Bestandstext Byte für Byte.** Tests pumpen
fest `de` — deshalb bleibt jeder bestehende Erwartungstext gültig. Kein
deutscher Text wird beim Umzug „verbessert". `app_en.arb` bekommt von dir
eine saubere, natürliche englische Übersetzung (kein Wort-für-Wort-Deutsch).

## Arbeitsschritte pro Paket

1. Alle nutzersichtbaren String-Literale der Paket-Dateien finden
   (auch Snacks/Fehlermeldungen/Semantics-Labels/Tooltips; NICHT: ValueKeys,
   Asset-Pfade, Log-/Sentry-Texte, SQL, Debug-Strings).
2. Pro Text ein ARB-Key: camelCase `<bereich><Element>` mit Domänen-Präfix
   (`today*`, `food*`, `recipes*`, `coach*`, `profile*`, `settings*`,
   `onboarding*`; Geteiltes generisch: `common*`). Platzhalter/Plurale über
   ICU (`{count, plural, ...}`), niemals String-Konkatenation für Sätze.
3. Code auf `context.l10n.<key>` umstellen. Widgets ohne BuildContext-Zugriff
   bekommen den String als Parameter gereicht (kein globales Lookup bauen).
4. `flutter gen-l10n`, dann die Paket-Tests + betroffene Suiten grün.
5. Der Hartkodierungs-Wächter (`test/l10n/hartkodierung_waechter_test.dart`)
   bekommt die fertig migrierten Verzeichnisse/Dateien in seine Liste.

## Bekannte Fallen (alle schon einmal passiert)

- Sobald ein Screen `context.l10n` ruft, brechen ALLE seine Tests mit nacktem
  MaterialApp-Harness (AppLocalizations.of-Nullcheck). Minimaler,
  assertion-neutraler Harness-Fix nach dem Muster von
  `test/home_page_tabs_test.dart` (Delegates + locale de + supportedLocales).
  Besser: wo möglich die generierten `AppLocalizations.localizationsDelegates`
  / `.supportedLocales` verwenden statt den Block zu kopieren.
- `AppNavItem` immer mit explizitem `keyId`.
- Datums-/Zahlenformate: Anzeige über `intl` mit der aktiven Locale, RECHNUNG
  bleibt bei `day_math.dart`. Unter `de` muss jedes Format byte-gleich zu
  heute sein („2.200 kcal", „MONTAG").
- Texte, die Tests als API nutzen (DESIGN_REFACTOR.md §6), bleiben unter de
  wortgleich — der ARB-Umzug ändert daran nichts, solange Regel 1 gilt.
- Keys sind sprachneutral und bleiben unverändert.

## Paketzuschnitt (sequenziell, ein Commit pro Paket)

| # | Paket | Dateien |
|---|---|---|
| 1 | Heute | `lib/src/screens/today/**` (inkl. `today_texts.dart`-Tabellen → intl) |
| 2 | Food | `lib/src/screens/meal_analysis_screen.dart`, `lib/src/widgets/kcal/**`, `lib/src/widgets/meal/**`, `barcode_scanner_sheet.dart`, `meal_camera_sheet.dart` |
| 3 | Rezepte | `lib/src/screens/recipes/**` |
| 4 | Coach | `lib/src/screens/coach/**` |
| 5 | Profil | `lib/src/screens/profile_screen.dart`, `lib/src/widgets/profile/**`, `trends_screen.dart` |
| 6 | Einstellungen | `lib/src/screens/settings/**`, `lib/src/widgets/shared/**`, `onboarding_screen.dart` |

Geteilte Kleinteile (`lib/src/widgets/common/**`, `app_snack.dart`,
`sync_error_messages.dart`) übernimmt das Paket, das sie zuerst braucht —
mit `common*`-Keys. Auth-Screens bleiben unangetastet (eigene Runde).

## Abschluss-Pflicht pro Paket

`flutter analyze --fatal-infos --fatal-warnings` ohne Befund, Paket-Tests +
ARB-Paritätstest grün, EN-Render-Smoke des Paket-Hauptscreens in beiden
Modi. Am Branch-Ende: volle Suite mit CI-Defines.
