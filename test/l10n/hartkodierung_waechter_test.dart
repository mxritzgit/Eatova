import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Schrumpfender Hartkodierungs-Wächter (i18n-design.md §6).
///
/// Pendant zu `test/theme/hell_modus_audit_test.dart`, nur umgekehrt: dort
/// schrumpft eine AUSNAHMEliste auf leer (Sterbe-Muster von
/// `app_colors.dart`), hier WÄCHST eine DECKUNGSliste — jedes fertig
/// migrierte i18n-Paket (docs/I18N_PAKETE.md) hängt sein Verzeichnis unten an
/// [_migriertePfade]. Am Ende der Migration deckt die Liste `lib/` komplett.
///
/// HEURISTIK (bewusst einfach, s. Bericht des ersten Pakets):
///   * Nur EINFACH gequotete String-Literale (`'...'`) — deckt den
///     durchgängigen Code-Stil dieses Repos: `"..."` kommt für UI-Text nicht
///     vor, ebenso wenig Raw- oder Triple-Quoted-Strings für Texte.
///   * Kommentare (`//`, `///`, `/* */`) werden vorher entfernt — sonst
///     schlägt ein erklärender Kommentar mit einem deutschen Wort die
///     Prüfung los (dieselbe Falle wie im Hell-Modus-Audit).
///   * Ein FUND ist ein Literal, das mindestens eines der Zeichen
///     ä/ö/ü/Ä/Ö/Ü/ß/„ trägt. Diese Zeichen kommen in diesem Repo NUR in
///     echtem deutschem Fließtext vor: ValueKeys, Asset-Pfade, Importe und
///     Log-/Sentry-Texte sind hier durchgängig ASCII-kebab-case bzw. reines
///     Englisch und fallen deshalb schon durch den Zeichenfilter — eine
///     separate ValueKey-/Pfad-Erkennung ist nicht nötig. Trüge ein Key
///     jemals eines dieser Zeichen, wäre das ohnehin ein eigener Fehler
///     (Keys sind sprachneutral und bleiben unverändert, Spec §4).
///
/// Was die Heuristik NICHT fängt (bewusste Lücke, s. Bericht): deutsche
/// Wörter ganz ohne Umlaut/ß (z. B. „Hallo", „Fett", „Makros"). Die
/// vollständige Extraktion ist Handarbeit pro Paket — dieser Test ist ein
/// Rückfallnetz, kein Ersatz dafür.
///
/// Paket 1 (Heute, 2026-08-10) ist der erste Eintrag. Spätere Pakete hängen
/// hier einfach an (docs/I18N_PAKETE.md, Paketzuschnitt-Tabelle) — NICHT
/// ersetzen, nur ergänzen.
///
/// Paket 2 (Food, 2026-08-10): die fünf Datei-Einträge (statt Verzeichnisse)
/// decken die Screen-Dateien ohne eigenen Ordner sowie die beiden
/// Handover-Dateien aus Paket 1 ab (`kcal_format.dart` jetzt locale-bewusst,
/// `meal_slot_style.dart` jetzt ARB-gestuetzt) — [dartDateien] akzeptiert
/// seitdem sowohl Verzeichnisse als auch einzelne Dateien.
/// `models/logged_meal.dart` bleibt bewusst AUSSEN — `MealSlotLabel.germanLabel`
/// traegt weiterhin hartkodiertes Deutsch fuer den nicht-UI-Aufrufer
/// (KI-Kontext, `HomeStore._todaysFoodSummary`), s. Paket-2-Bericht.
///
/// Paket 3 (Rezepte, 2026-08-10): `lib/src/screens/recipes/` komplett dazu.
/// `lib/src/models/fitness_recipe.dart` bleibt bewusst AUSSEN — der
/// Bestandskatalog (30 Rezepte: Titel/Zutaten/Zubereitung) und `recipeFilters`
/// sind Content, keine Screen-Texte, und bekommen ihr eigenes Paket (Spec §5).
///
/// Paket 4 (Coach, 2026-08-10): `lib/src/screens/coach/` komplett dazu
/// (inkl. `coach_speech.dart` — `part of`, kein eigener Import, aber ein
/// eigenstaendiger Fund-Kandidat). `lib/src/services/coach_chat_service.dart`
/// bleibt bewusst AUSSEN — die Fallback-Meldungen dort (nur sichtbar, wenn
/// der Server keinen eigenen `reply`-Text liefert) haengen an
/// `test/coach_error_mapping_test.dart`, das den Service KONTEXTFREI
/// (ohne BuildContext/l10n) direkt aufruft; eine l10n-Anbindung dort haette
/// die `send()`-Signatur geaendert und jeden Test-Override in
/// coach_design_test.dart/coach_image_privacy_test.dart mitgerissen. S.
/// Paket-4-Bericht.
///
/// Paket 5 (Profil, 2026-08-10): `lib/src/screens/profile_screen.dart`,
/// `lib/src/widgets/profile/` (alle acht Dateien, inkl. `profile_format.dart`
/// — `part of`, kein eigener Import) und `lib/src/screens/trends_screen.dart`
/// komplett dazu. Bewusst NICHT migriert (ausserhalb des Paket-Scopes):
/// `lib/src/models/user_profile.dart` — `WeightGoal.label`/
/// `ActivityLevel.label`/`BiologicalSex.label` bleiben hartkodiertes Deutsch,
/// s. Paket-5-Bericht (dokumentierte Ripple-Uebergabe, analog zum
/// `MealSlot.label`-Fund aus Paket 1).
///
/// Paket 6 (Einstellungen, 2026-08-10 — LETZTES Screen-Paket):
/// `lib/src/screens/settings/` (alle sieben Dateien), `lib/src/widgets/shared/`
/// (alle vier Dateien) und `lib/src/screens/onboarding_screen.dart` komplett
/// dazu. Dazu die Ripple-Uebergabe aus Paket 5: `lib/src/models/user_profile.dart`
/// zieht jetzt mit — `BiologicalSex.label`/`ActivityLevel.label`/
/// `.description`/`DietPreference.label`/`.description`/`WeightGoal.label`/
/// `.menuLabel` nehmen alle ein [AppLocalizations] entgegen (Persistenz bleibt
/// `enumWert.name`, unveraendert). `WeightGoal.paceLabel` war zu diesem
/// Zeitpunkt noch bewusst hartkodiertes Deutsch — es haengt an
/// `KcalTargets.effectivePaceLabel`/`.paceWarning` in `kcal_calculator.dart`
/// (B2-Kopplung, beide muessen synchron bleiben). Paket 7 unten zieht beide
/// nach; die Formulierung „das noch aussteht" stimmt seither nicht mehr.
/// Zwei inhaltlich uebernommene Service-Handovers (dokumentierte, NICHT
/// migrierte Einzelfaelle wie schon bei Paket 4s `coach_chat_service.dart`):
///  * `lib/src/services/sync_error_messages.dart` — der Store (`HomeStore`,
///    ARCH-4: haelt nie einen BuildContext) reicht sein aufgeloestes
///    `AppLocalizations` per `setLocalizations()` durch
///    (`_EatovaHomePageState.didChangeDependencies`); alle Funktionen nehmen
///    ein optionales `[AppLocalizations? l10n]` mit Deutsch-Default, damit
///    `test/services/sync_error_messages_test.dart` als kontextfreie API
///    weiterlaeuft.
///  * `lib/src/services/coach_chat_service.dart` — jetzt AUSSERHALB der Deny-
///    Liste unten (die Fallback-Meldungen sind migriert), bleibt aber wegen
///    `test/coach_error_mapping_test.dart` (kontextfrei) nicht in
///    [_migriertePfade]: `send()`s Signatur ist unveraendert, ein Setter
///    (`svc.l10n = ...`) traegt das Sprachpaket, Default bleibt Deutsch.
/// Paket 7 (Nachzügler, 2026-08-11): der letzte offene Fund aus dem
/// Paket-6-Review. `lib/src/services/kcal_calculator.dart`
/// (`KcalTargets.effectivePaceLabel`/`.paceWarning`) kommt jetzt dazu — die
/// beiden Service-Einzelfaelle aus Paket 6 (`sync_error_messages.dart`,
/// `coach_chat_service.dart`) waren inhaltlich schon migriert (optionales
/// `[AppLocalizations? l10n]`, Default Deutsch) und bleiben ab jetzt ebenfalls
/// bewacht — nur `kcal_calculator.dart` musste vorher noch mitziehen, weil
/// `paceLabelForWeeklyRateKg`/`effectivePaceLabel`/`paceWarning` an der
/// B2-Kopplung haengen (`WeightGoalInfo.paceLabel` in `user_profile.dart`
/// rechnet mit derselben Funktion — beide liefen sonst auseinander).
///
/// Review-Fixwelle (Finding 2, 2026-08-11): der Store haelt sein `_l10n`
/// zwar seit Paket 6 (s.o.), die eigenen Store-Snacks in `lib/src/app/`
/// waren aber nie Teil eines Pakets — kein Screen-Ordner, durch die
/// Paketzuschnitt-Tabelle gefallen. Vier Fundstellen ziehen jetzt nach:
/// `home_store_meals.dart` (`commonMealDeleted`/`commonUndo`),
/// `home_store_sync.dart` (`commonUndo` wiederverwendet; die einzige
/// verbleibende Ausnahme dort ist `'Konto-Löschung'` — ein reiner
/// dev.log/CrashReporter-Diagnosetext, s. [_bekannteAusnahmen]),
/// `home_store_tracking.dart` (Apple-Health-Uebernahme-Snack, plus das
/// deutsche Dezimalkomma jetzt ueber `NumberFormat` statt hartem
/// `replaceAll('.', ',')`) und `lib/src/widgets/design/rows.dart`
/// (`PageHeader`s Zurueck-Semantics — wiederverwendet `onboardingBackSemanticLabel`
/// statt einen zweiten, gleichbedeutenden Key anzulegen).
///
/// Die vorherige Schlussbehauptung an dieser Stelle („`_migriertePfade`
/// deckt `lib/` vollstaendig ab bis auf Auth + `fitness_recipe.dart`") war
/// FALSCH — sie unterschlug einen ganzen Bereich. Ehrliche Restliste, Stand
/// nach Finding 2 (alle bewusst NICHT in [_migriertePfade], mit Zielort):
///  * `lib/src/app/` bleibt bis auf die vier oben genannten Dateien
///    unbewacht: `home_store.dart` selbst traegt in `coachContext`/
///    `_todaysFoodSummary` noch hartes Deutsch — das ist aber kein UI-Text,
///    sondern Freitext-KONTEXT fuer den Coach-Prompt (geht an die Edge
///    Function, nie direkt gerendert); `home_store_profile.dart`,
///    `eatova_home_page.dart`, `eatova_app.dart`, `auth_gate.dart` und
///    `locale_controller.dart` sind noch nicht durchsucht. Ziel: Scan/Coach-PR
///    (haengt am Coach-Prompt-Kontext).
///  * `lib/src/services/meal_analyzer.dart` — Scan-Fehlermeldungen (Bild zu
///    gross, Rate-Limit). Ziel: Scan-PR.
///  * `lib/src/services/open_food_facts_product_service.dart` —
///    Produkt-Fundtexte (Naehrwertangabe unplausibel/fehlend). Ziel: Scan-PR.
///  * `lib/src/models/meal_analysis_result.dart` — `sourceLabel`/
///    `portionLabel`/die Anpassungs-Beschreibungen des Scan-Ergebnisses.
///    Haengt inhaltlich an `meal_analyzer.dart`/dem OFF-Service. Ziel: Scan-PR.
///  * `lib/src/services/notification_service.dart` und
///    `lib/src/services/streak_reminder_planner.dart` — Notification-Kanal-
///    und Erinnerungs-Body-Texte. Ziel: eigene Notifications-Runde im
///    Scan/Coach-PR (Streak-Erinnerung haengt am Engagement-Teil des Coachs).
///  * `main.dart` — der Boot-Fehlerschirm („Eatova konnte nicht starten" …)
///    bleibt BEWUSST hartkodiertes Deutsch: er laeuft, bevor Flutter/l10n
///    ueberhaupt initialisiert ist — `AppLocalizations.of` waere dort
///    strukturell nicht erreichbar. Keine Migrationsluecke, sondern eine
///    dauerhafte Ausnahme (analog zu Log-/Sentry-Texten, Spec §4).
///  * `lib/src/screens/coach/coach_sessions.dart` — `_humanizeTimestamp`s
///    Datumsfallback (Nachrichten >= 7 Tage alt) gibt ein rohes `DD.MM.YYYY`
///    aus. Bewusst sprachneutral (nur Ziffern, s. Kommentar dort), aber
///    NICHT locale-abhaengig formatiert — ein EN-Leser koennte Tag/Monat
///    vertauschen. Kein Hartkodierungs-Fund im engeren Sinn (keine deutschen
///    Woerter), aber eine offene Anschlussfrage fuer den Scan/Coach-PR.
///  * Unveraendert seit Paket 3/dem Vertrag: die Auth-Screens (eigene Runde)
///    und der `fitness_recipe.dart`-Katalog (30 Rezepte, Content statt
///    Screen-Text) — beide Ziel: Inhalte-PR.
const List<String> _migriertePfade = <String>[
  'lib/src/screens/today/',
  'lib/src/screens/meal_analysis_screen.dart',
  'lib/src/screens/barcode_scanner_sheet.dart',
  'lib/src/screens/meal_camera_sheet.dart',
  'lib/src/widgets/kcal/',
  'lib/src/widgets/meal/',
  'lib/src/services/kcal_format.dart',
  'lib/src/theme/meal_slot_style.dart',
  'lib/src/screens/recipes/',
  'lib/src/screens/coach/',
  'lib/src/screens/profile_screen.dart',
  'lib/src/widgets/profile/',
  'lib/src/screens/trends_screen.dart',
  'lib/src/screens/settings/',
  'lib/src/widgets/shared/',
  'lib/src/screens/onboarding_screen.dart',
  'lib/src/models/user_profile.dart',
  'lib/src/services/kcal_calculator.dart',
  'lib/src/services/sync_error_messages.dart',
  'lib/src/services/coach_chat_service.dart',
  'lib/src/app/home_store_meals.dart',
  'lib/src/app/home_store_sync.dart',
  'lib/src/app/home_store_tracking.dart',
  'lib/src/widgets/design/rows.dart',
];

/// Dokumentierte Einzelausnahmen (Datei -> Literale), NICHT dieselbe Idee wie
/// [_migriertePfade]: das hier sind bewusst NICHT migrierte Einzelfunde in
/// sonst vollstaendig migrierten Dateien — keine wachsende Deckungsliste,
/// sondern eine kurze, begruendete Deny-Liste. Paket 2 traegt den ersten
/// Eintrag: `_supabaseTrendLoader()` (meal_analysis_screen.dart) ist eine
/// `static` Funktion ohne `BuildContext` — der Wurf wird von TrendsScreen
/// stets abgefangen und NIE roh angezeigt (Kommentar dort: „Der Service hat
/// bereits geloggt — hier nur in den Retry-Zustand uebersetzen, keine rohe
/// Exception in die UI durchreichen"). Eine echte l10n-Anbindung braeuchte
/// einen Context, den diese Stelle strukturell nicht hat — kein uebersehener
/// Fund, sondern dieselbe Kategorie wie Log-/Sentry-Texte (Spec §4).
const Map<String, List<String>> _bekannteAusnahmen = <String, List<String>>{
  'lib/src/screens/meal_analysis_screen.dart': [
    "'Kein angemeldeter Nutzer für die Trend-Ansicht.'",
  ],
  // Finding 2 (Review-Fixwelle, 2026-08-11): das `operation`-Argument von
  // `_reportSyncError`/`_syncOrQueue` geht NUR an `dev.log` und
  // `CrashReporter.capture(context: ...)` — reiner Diagnose-Text, nie in der
  // UI sichtbar (dieselbe Kategorie wie Log-/Sentry-Texte, Spec §4). Alle
  // anderen Operation-Labels in dieser Datei ('Mahlzeit', 'Favorit',
  // 'Rezept', ...) tragen ohnehin keinen Umlaut und fallen schon durch den
  // Zeichenfilter — nur 'Konto-Löschung' braucht die dokumentierte Ausnahme.
  'lib/src/app/home_store_sync.dart': [
    "'Konto-Löschung'",
  ],
};

void main() {
  final RegExp literal = RegExp(r"'[^'\n]*'");
  final RegExp deutschesZeichen = RegExp('[äöüÄÖÜß„]');

  String ohneKommentare(String quelle) => quelle
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((zeile) {
        final i = zeile.indexOf('//');
        return i < 0 ? zeile : zeile.substring(0, i);
      })
      .join('\n');

  /// Akzeptiert sowohl einen Verzeichnis-Pfad (endet auf `/`, rekursiv
  /// durchsucht) als auch den Pfad einer einzelnen `.dart`-Datei — Paket 2
  /// hat Screen-Dateien ohne eigenen Ordner (z. B.
  /// `meal_analysis_screen.dart`) und Handover-Dateien wie `kcal_format.dart`.
  List<File> dartDateien(String pfad) {
    final einzelDatei = File(pfad);
    if (einzelDatei.existsSync()) {
      return <File>[einzelDatei];
    }
    final dir = Directory(pfad);
    if (!dir.existsSync()) {
      fail('$pfad fehlt (aufgelöst von ${Directory.current.path}) — '
          'Tippfehler in _migriertePfade?');
    }
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  test('die migrierten Pfade tragen keine deutschen Hartkodierungen mehr',
      () {
    final funde = <String>[];
    for (final pfad in _migriertePfade) {
      for (final datei in dartDateien(pfad)) {
        final relativ = datei.path.replaceAll(r'\', '/');
        final quelle = ohneKommentare(datei.readAsStringSync());
        final ausnahmen = _bekannteAusnahmen[relativ] ?? const <String>[];
        for (final match in literal.allMatches(quelle)) {
          final text = match.group(0)!;
          if (deutschesZeichen.hasMatch(text) && !ausnahmen.contains(text)) {
            funde.add('$relativ: $text');
          }
        }
      }
    }
    expect(
      funde,
      isEmpty,
      reason: 'Diese String-Literale tragen noch deutsche Hartkodierungen '
          '(Umlaut/ß/„) unter einem als migriert gemeldeten Pfad — entweder '
          'fehlt die ARB-Extraktion, oder der Pfad wurde zu früh '
          'eingetragen:\n${funde.join('\n')}',
    );
  });

  test('die migrierten Pfade existieren wirklich (kein Tippfehler)', () {
    for (final pfad in _migriertePfade) {
      expect(
        Directory(pfad).existsSync() || File(pfad).existsSync(),
        isTrue,
        reason: pfad,
      );
    }
  });
}
