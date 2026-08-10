# i18n-Grundgerüst (Deutsch + Englisch) — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nach diesem Plan ist die App-Sprache in den Einstellungen umschaltbar
(System / Deutsch / English), die `gen_l10n`-Pipeline steht, und zwei echte
Text-Gruppen (Nav-Labels, Sprach-Zeile) laufen als Beweis durch sie hindurch.

**Architecture:** `gen_l10n` mit `app_de.arb` als wortgleicher Vorlage;
`LocaleController`/`LocaleScope` als struktureller Spiegel von
`ThemeModeController`/`ThemeModeScope`; Auflösung „Gerät deutsch → de, sonst
en". Spec: `docs/superpowers/specs/2026-08-10-i18n-design.md`.

**Tech Stack:** Flutter 3.44 (lokal: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat`),
`flutter_localizations` + `intl` (beide schon im Dependency-Baum), SharedPreferences.

## Global Constraints

- Befehle immer mit vollem Pfad: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat`.
- Volle Suite immer mit den CI-Defines fahren:
  `flutter test --dart-define=SUPABASE_URL=https://ci.invalid --dart-define=SUPABASE_ANON_KEY=ci-dummy-key`
- **Keine neue Dependency.** `intl` wird nur von transitiv auf direkt gehoben
  (liegt schon im Lockfile, Version 0.20.2 — von flutter_localizations gepinnt).
- **Deutsche Texte bleiben wortgleich** (DESIGN_REFACTOR §6). `app_de.arb`
  übernimmt Bestandstexte Byte für Byte. Bestehende ValueKeys unverändert.
- `lib/src/screens/auth_screen.dart` und `auth_code_screen.dart` NICHT anfassen.
- Kein `Color(0x…)`, keine `app_colors.dart`-Importe (Token-Vertrag gilt weiter).
- main ist geschützt: Am Ende PR erstellen (kein `gh` — REST per `py -3`,
  Token aus `C:\Users\morit\Desktop\Bridgespace\.env`), Merge-Stil: Squash,
  Commit-Titel = PR-Titel ohne (#N).
- Arbeitsbranch: `feat/i18n-grundgeruest` ab aktuellem `main`.

---

### Task 1: l10n-Gerüst (l10n.yaml, ARB-Startbestand, Paritäts-Wächter)

**Files:**
- Create: `l10n.yaml` (Repo-Root)
- Create: `lib/l10n/app_de.arb`, `lib/l10n/app_en.arb`
- Create: `test/l10n/arb_parity_test.dart`
- Modify: `pubspec.yaml` (generate-Flag, intl direkt)
- Modify: `.gitignore` (generierter Output)

**Interfaces:**
- Produces: generierte Klasse `AppLocalizations` unter
  `lib/src/l10n/generated/app_localizations.dart` mit den Gettern
  `settingsLanguageTitle`, `settingsLanguageSubtitle`, `languageSystem`,
  `languageGerman`, `languageEnglish`, `navToday`, `navFood`, `navRecipes`,
  `navCoach` (alle `String`, nicht nullable).

- [ ] **Step 1: Branch anlegen**

```powershell
git switch main; git pull --ff-only; git switch -c feat/i18n-grundgeruest
```

- [ ] **Step 2: Failing Test — ARB-Parität**

`test/l10n/arb_parity_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Wächter der Spec §6: app_en.arb muss exakt die Keys von app_de.arb tragen.
/// Fehlt ein Key, fiele der Text still auf Deutsch zurück — das soll die CI
/// brechen, nicht der Nutzer finden.
void main() {
  Set<String> keysOf(String pfad) {
    final json = jsonDecode(File(pfad).readAsStringSync())
        as Map<String, dynamic>;
    // @-Einträge sind Metadaten (Beschreibungen, Platzhalter), keine Texte.
    return json.keys.where((k) => !k.startsWith('@')).toSet();
  }

  test('app_en.arb traegt exakt die Keys von app_de.arb', () {
    final de = keysOf('lib/l10n/app_de.arb');
    final en = keysOf('lib/l10n/app_en.arb');
    expect(de, isNotEmpty, reason: 'app_de.arb ist die Vorlage');
    expect(en.difference(de), isEmpty,
        reason: 'app_en.arb hat Keys, die die Vorlage nicht kennt');
    expect(de.difference(en), isEmpty,
        reason: 'Diese Keys sind noch nicht uebersetzt');
  });
}
```

- [ ] **Step 3: Test läuft rot** (Dateien existieren nicht)

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/l10n/arb_parity_test.dart`
Expected: FAIL (PathNotFoundException)

- [ ] **Step 4: l10n.yaml + ARB-Dateien anlegen**

`l10n.yaml`:

```yaml
arb-dir: lib/l10n
template-arb-file: app_de.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
output-dir: lib/src/l10n/generated
nullable-getter: false
```

`lib/l10n/app_de.arb` (deutsche Texte wortgleich; die Sprach-Zeile ist neu,
ihr Untertitel spiegelt die Formulierung der Erscheinungsbild-Zeile):

```json
{
  "@@locale": "de",
  "settingsLanguageTitle": "Sprache",
  "settingsLanguageSubtitle": "System folgt der Sprache deines Geräts.",
  "languageSystem": "System",
  "languageGerman": "Deutsch",
  "languageEnglish": "English",
  "navToday": "Heute",
  "navFood": "Food",
  "navRecipes": "Rezepte",
  "navCoach": "Coach"
}
```

`lib/l10n/app_en.arb` (Sprachnamen bewusst in ihrer EIGENEN Sprache, Spec §3):

```json
{
  "@@locale": "en",
  "settingsLanguageTitle": "Language",
  "settingsLanguageSubtitle": "System follows your device's language.",
  "languageSystem": "System",
  "languageGerman": "Deutsch",
  "languageEnglish": "English",
  "navToday": "Today",
  "navFood": "Food",
  "navRecipes": "Recipes",
  "navCoach": "Coach"
}
```

- [ ] **Step 5: pubspec.yaml — generate-Flag und intl direkt**

In der `flutter:`-Sektion (Zeile ~158, neben `uses-material-design: true`):

```yaml
  generate: true
```

In `dependencies:` direkt unter dem `flutter_localizations:`-Block (~Z. 39),
im Kommentar-Stil der Nachbarn (pointycastle/path_provider):

```yaml
  # Schon transitiv da (flutter_localizations pinnt 0.20.2) — aber der von
  # gen_l10n generierte Code importiert package:intl direkt. Ohne diese Zeile
  # bricht der Build, sobald das Paket aus der transitiven Kette fiele.
  intl: ^0.20.2
```

- [ ] **Step 6: .gitignore — generierter Output bleibt draußen** (Spec §2)

```
lib/src/l10n/generated/
```

- [ ] **Step 7: Generierung prüfen**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat gen-l10n`
Expected: `lib/src/l10n/generated/app_localizations.dart` (+ `_de`/`_en`)
existiert; keine Warnungen über fehlende Übersetzungen.

- [ ] **Step 8: Paritäts-Test grün**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/l10n/arb_parity_test.dart`
Expected: PASS

- [ ] **Step 9: Commit**

```powershell
git add l10n.yaml lib/l10n pubspec.yaml .gitignore test/l10n docs/superpowers/plans/2026-08-10-i18n-grundgeruest.md
git commit -m "feat(i18n): gen_l10n-Geruest - app_de.arb als wortgleiche Vorlage, Paritaets-Waechter"
```

---

### Task 2: LocaleController + LocaleScope + Auflösungsregel

**Files:**
- Create: `lib/src/app/locale_controller.dart`
- Test: `test/app/locale_controller_test.dart`

**Interfaces:**
- Consumes: nichts aus anderen Tasks (reines Dart + SharedPreferences).
- Produces:
  - `class LocaleController extends ChangeNotifier` mit
    `Locale? get override` (null = System), `Future<void> load()`,
    `Future<void> setOverride(Locale? locale)`,
    `@visibleForTesting void setOverrideSync(Locale? locale)`,
    `static const String storageKey = 'eatova.v1.locale'`.
  - `class LocaleScope extends InheritedNotifier<LocaleController>` mit
    `static LocaleController? maybeOf(BuildContext context)`.
  - Top-Level `Locale resolveEatovaLocale(List<Locale>? deviceLocales)`.

- [ ] **Step 1: Failing Tests** — Spiegel von `test/theme/theme_mode_controller_test.dart`

`test/app/locale_controller_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocaleController', () {
    test('Default ist System (override null)', () {
      expect(LocaleController().override, isNull);
    });

    test('load liest den gespeicherten Wert', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'en'});
      final c = LocaleController();
      await c.load();
      expect(c.override, const Locale('en'));
    });

    test('kaputter Prefs-Eintrag faellt still auf System zurueck', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'klingonisch'});
      final c = LocaleController();
      await c.load();
      expect(c.override, isNull);
    });

    test('setOverride persistiert und benachrichtigt', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = LocaleController();
      var pings = 0;
      c.addListener(() => pings++);
      await c.setOverride(const Locale('en'));
      expect(c.override, const Locale('en'));
      expect(pings, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LocaleController.storageKey), 'en');
    });

    test('setOverride(null) speichert system', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{LocaleController.storageKey: 'en'});
      final c = LocaleController();
      await c.load();
      await c.setOverride(null);
      expect(c.override, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LocaleController.storageKey), 'system');
    });

    test('unveraenderter Wert loest keine Benachrichtigung aus', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = LocaleController();
      var pings = 0;
      c.addListener(() => pings++);
      await c.setOverride(null);
      expect(pings, 0);
    });
  });

  group('resolveEatovaLocale (Spec §3: Geraet deutsch -> de, sonst en)', () {
    test('deutsches Geraet bekommt Deutsch', () {
      expect(resolveEatovaLocale(const [Locale('de', 'DE')]),
          const Locale('de'));
    });

    test('russisches Geraet bekommt Englisch', () {
      expect(resolveEatovaLocale(const [Locale('ru')]), const Locale('en'));
    });

    test('Praeferenzliste wird der Reihe nach gelaufen', () {
      expect(resolveEatovaLocale(const [Locale('fr'), Locale('de')]),
          const Locale('de'));
      expect(resolveEatovaLocale(const [Locale('en'), Locale('de')]),
          const Locale('en'));
    });

    test('leere/fehlende Liste faellt auf Englisch', () {
      expect(resolveEatovaLocale(const []), const Locale('en'));
      expect(resolveEatovaLocale(null), const Locale('en'));
    });
  });
}
```

- [ ] **Step 2: Rot sehen**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/app/locale_controller_test.dart`
Expected: FAIL (locale_controller.dart existiert nicht)

- [ ] **Step 3: Implementierung** — `lib/src/app/locale_controller.dart`
(Struktur, Doc-Kommentare und Fehlerverhalten spiegeln
`lib/src/theme/theme_mode_controller.dart`; bei Abweichung dort nachsehen):

```dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Haelt die Anzeigesprache (System/Deutsch/Englisch) und persistiert sie.
///
/// Bewusst SharedPreferences und NICHT der verschluesselte LocalCache oder
/// die Supabase-Profil-Zeile: die Sprache muss vor dem Login greifen und ist
/// eine Geraete-, keine Konto-Eigenschaft (Spiegel von ThemeModeController).
///
/// `override == null` heisst System: die Aufloesung uebernimmt
/// [resolveEatovaLocale] ueber die Geraete-Sprachliste.
class LocaleController extends ChangeNotifier {
  LocaleController({Locale? initial}) : _override = initial;

  static const String storageKey = 'eatova.v1.locale';

  Locale? _override;
  Locale? get override => _override;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final gelesen = _parse(prefs.getString(storageKey));
      if (gelesen != _override) {
        _override = gelesen;
        notifyListeners();
      }
    } catch (_) {
      // Prefs nicht verfuegbar: System bleibt.
    }
  }

  Future<void> setOverride(Locale? locale) async {
    if (locale == _override) return;
    _override = locale;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, locale?.languageCode ?? 'system');
    } catch (_) {
      // Nicht persistiert — die Sitzung laeuft trotzdem in der Wahl.
    }
  }

  @visibleForTesting
  void setOverrideSync(Locale? locale) {
    if (locale == _override) return;
    _override = locale;
    notifyListeners();
  }

  static Locale? _parse(String? wert) => switch (wert) {
        'de' => const Locale('de'),
        'en' => const Locale('en'),
        _ => null,
      };
}

/// Spec §3: Geraet spricht Deutsch -> de, alles andere -> en. Die
/// Praeferenzliste des Geraets wird der Reihe nach gelaufen, damit
/// [fr, de] bei Deutsch landet und [en, de] bei Englisch.
Locale resolveEatovaLocale(List<Locale>? deviceLocales) {
  for (final locale in deviceLocales ?? const <Locale>[]) {
    if (locale.languageCode == 'de') return const Locale('de');
    if (locale.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}

/// Reicht den [LocaleController] an tiefe Screens durch (der Schalter sitzt
/// in den Einstellungen, gesetzt wird er ganz oben) — Spiegel von
/// [ThemeModeScope].
class LocaleScope extends InheritedNotifier<LocaleController> {
  const LocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LocaleScope>()
      ?.notifier;
}
```

- [ ] **Step 4: Grün sehen**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/app/locale_controller_test.dart`
Expected: PASS (10 Tests)

- [ ] **Step 5: Commit**

```powershell
git add lib/src/app/locale_controller.dart test/app/locale_controller_test.dart
git commit -m "feat(i18n): LocaleController nach dem Hell-Modus-Muster (eatova.v1.locale)"
```

---

### Task 3: App-Verdrahtung + Test-Harnesse

**Files:**
- Modify: `lib/src/app/eatova_app.dart` (MaterialApp-Block, Z. 91–148)
- Create: `lib/src/l10n/l10n.dart` (Barrel + Extension)
- Modify: `test/widgets/design/design_harness.dart` (Delegates + locale)
- Modify: `test/flows/flow_test_helpers.dart` (falls dort ein eigenes
  MaterialApp gepumpt wird — Delegates ergänzen; sonst unberührt lassen)
- Test: `test/l10n/locale_app_wiring_test.dart`

**Interfaces:**
- Consumes: `LocaleController`, `LocaleScope`, `resolveEatovaLocale` (Task 2);
  generierte `AppLocalizations` (Task 1).
- Produces:
  - `EatovaApp` hat neuen optionalen Konstruktor-Parameter
    `LocaleController? localeController` (Spiegel von `themeModeController`).
  - `lib/src/l10n/l10n.dart` exportiert `AppLocalizations` und stellt
    `extension L10nX on BuildContext { AppLocalizations get l10n; }` bereit.
  - `designHarness(...)` akzeptiert `Locale locale = const Locale('de')` und
    hängt IMMER alle Delegates (inkl. `AppLocalizations.delegate`) an.

- [ ] **Step 1: Barrel + Extension** — `lib/src/l10n/l10n.dart`:

```dart
import 'package:flutter/widgets.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// Zugriff im build(): `context.l10n.settingsLanguageTitle` — dasselbe
/// Muster wie `context.t` fuer die Design-Tokens.
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
```

- [ ] **Step 2: Failing Test** — `test/l10n/locale_app_wiring_test.dart`
(Spiegel von `test/theme/theme_mode_app_wiring_test.dart`; dessen
Pump-Aufbau fuer EatovaApp uebernehmen — dort steht, wie AuthRepository/
Supabase im Test gestellt werden):

```dart
// Kernaussagen (Pump-Geruest aus theme_mode_app_wiring_test.dart kopieren):
testWidgets('Override en schaltet die App auf Englisch', (tester) async {
  final controller = LocaleController(initial: const Locale('en'));
  // ... EatovaApp(localeController: controller, ...) pumpen wie im Vorbild ...
  final ctx = tester.element(find.byType(Scaffold).first);
  expect(Localizations.localeOf(ctx), const Locale('en'));
});

testWidgets('System + russisches Geraet landet auf Englisch', (tester) async {
  tester.platformDispatcher.localesTestValue =
      const [Locale('ru'), Locale('ru', 'RU')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  // ... EatovaApp ohne Override pumpen ...
  final ctx = tester.element(find.byType(Scaffold).first);
  expect(Localizations.localeOf(ctx), const Locale('en'));
});

testWidgets('System + deutsches Geraet bleibt Deutsch', (tester) async {
  tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  // ...
  expect(Localizations.localeOf(ctx), const Locale('de'));
});
```

- [ ] **Step 3: Rot sehen** (EatovaApp kennt localeController nicht)

- [ ] **Step 4: EatovaApp umbauen** — exakt das themeModeController-Muster:

1. Feld + Konstruktor-Parameter `this.localeController` mit Doc-Kommentar.
2. Im State: `late final LocaleController _locale;` + `_eigenerLocale`-Flag,
   in `initState` analog `unawaited(_locale.load())`, in `dispose` analog.
3. `build()`: `LocaleScope(controller: _locale, child: ...)` UM den
   bestehenden `ThemeModeScope` legen; der `ListenableBuilder` hört auf
   `Listenable.merge([_themeMode, _locale])`.
4. Im `MaterialApp` den gepinnten Block ersetzen:

```dart
      // Sprache: Override aus den Einstellungen; null = System, dann
      // entscheidet resolveEatovaLocale (deutsch -> de, sonst en). Der alte
      // Pin auf de stammte aus der Zeit ohne App-Lokalisierung.
      locale: _locale.override,
      supportedLocales: const [Locale('de'), Locale('en')],
      localeListResolutionCallback: (locales, supported) =>
          _locale.override ?? resolveEatovaLocale(locales),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateTitle: (context) => 'Eatova',
```

   Import: `import '../l10n/l10n.dart';`

- [ ] **Step 5: designHarness erweitern** — in
`test/widgets/design/design_harness.dart` bekommt `designHarness` den
Parameter `Locale locale = const Locale('de')` und das MaterialApp:

```dart
    locale: locale,
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
```

(Imports: `flutter_localizations` + `package:eatova/src/l10n/l10n.dart`.)

- [ ] **Step 6: Grün sehen + Regression**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/l10n/ test/theme/ test/widgets/design/`
Expected: PASS überall (der Theme-Wiring-Test beweist, dass der Umbau nichts
am Modus-Verhalten geändert hat).

- [ ] **Step 7: Commit**

```powershell
git add lib/src/app/eatova_app.dart lib/src/l10n/l10n.dart test/l10n/locale_app_wiring_test.dart test/widgets/design/design_harness.dart test/flows/flow_test_helpers.dart
git commit -m "feat(i18n): LocaleScope in der App-Schale, Aufloesung Geraet-deutsch->de sonst en"
```

---

### Task 4: Nav-Labels aus der ARB, Keys entkoppelt (Spec §4)

**Files:**
- Modify: `lib/src/widgets/design/controls.dart` (`AppNavItem`, Z. ~340–358;
  `AppNavBar.build`, Z. ~404)
- Modify: `lib/src/app/eatova_home_page.dart` (`_navItems`, Z. 499–522 + die
  Stelle, die `AppNavBar(items: _navItems, ...)` baut)
- Test: `test/widgets/design/controls_test.dart` (ergänzen),
  `test/home_page_tabs_test.dart` (muss unverändert grün bleiben)

**Interfaces:**
- Consumes: `context.l10n` (Task 3).
- Produces: `AppNavItem` hat neues Feld `final String keyId` (Konstruktor:
  `String? keyId` — Default ist das Label). Der Test-Key wird
  `ValueKey('nav-${item.keyId}')`.

- [ ] **Step 1: Failing Test** — in `controls_test.dart`, Gruppe `AppNavBar`:

```dart
testWidgets('englische Labels, aber die Keys bleiben deutsch',
    (tester) async {
  await tester.pumpWidget(
    designHarness(
      AppNavBar(
        index: 0,
        onChanged: (_) {},
        items: const <AppNavItem>[
          AppNavItem(
            icon: Icons.restaurant_outlined,
            activeIcon: Icons.restaurant_rounded,
            label: 'Recipes',
            keyId: 'Rezepte',
          ),
        ],
      ),
      locale: const Locale('en'),
    ),
  );

  // Der Vertrag aus DESIGN_REFACTOR §6: der Key ist API und bleibt deutsch,
  // auch wenn das sichtbare Label uebersetzt ist.
  expect(find.byKey(const ValueKey<String>('nav-Rezepte')), findsOneWidget);
  expect(find.text('Recipes'), findsOneWidget);
});
```

- [ ] **Step 2: Rot sehen** (AppNavItem kennt keyId nicht)

- [ ] **Step 3: AppNavItem + AppNavBar anpassen** — in `controls.dart`:

```dart
  const AppNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    String? keyId,
  }) : keyId = keyId ?? label;

  /// Traegt den Testschluessel (`ValueKey('nav-$keyId')`). Bleibt DEUTSCH,
  /// auch wenn [label] uebersetzt wird — Keys sind API (DESIGN_REFACTOR §6).
  final String keyId;
```

und in `build()`: `key: ValueKey<String>('nav-${item.keyId}'),`

- [ ] **Step 4: Home-Page umstellen** — `_navItems` wird von der statischen
Konstante zu einer Methode (die Keys bleiben fest deutsch, nur die Labels
laufen über die ARB):

```dart
  /// Die keyIds tragen die Testschluessel (`nav-Heute` & Co.) und bleiben
  /// deutsch; die sichtbaren Labels kommen aus der ARB (Spec §4).
  List<AppNavItem> _navItems(BuildContext context) {
    final l10n = context.l10n;
    return <AppNavItem>[
      AppNavItem(
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
        label: l10n.navToday,
        keyId: 'Heute',
      ),
      AppNavItem(
        icon: Icons.restaurant_outlined,
        activeIcon: Icons.restaurant_rounded,
        label: l10n.navFood,
        keyId: 'Food',
      ),
      AppNavItem(
        icon: Icons.menu_book_outlined,
        activeIcon: Icons.menu_book_rounded,
        label: l10n.navRecipes,
        keyId: 'Rezepte',
      ),
      AppNavItem(
        icon: Icons.auto_awesome_outlined,
        activeIcon: Icons.auto_awesome_rounded,
        label: l10n.navCoach,
        keyId: 'Coach',
      ),
    ];
  }
```

Aufrufstelle: `AppNavBar(items: _navItems(context), ...)`.
Import in `eatova_home_page.dart`: `import '../l10n/l10n.dart';`

- [ ] **Step 5: Grün sehen + Regression**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/widgets/design/controls_test.dart test/home_page_tabs_test.dart test/flows/navigation_flow_test.dart`
Expected: PASS — die bestehenden `nav-Food`/`nav-Rezepte`/`nav-Coach`-Tests
beweisen die Key-Kontinuität unter `de`.

- [ ] **Step 6: Commit**

```powershell
git add lib/src/widgets/design/controls.dart lib/src/app/eatova_home_page.dart test/widgets/design/controls_test.dart
git commit -m "feat(i18n): Nav-Labels aus der ARB, Testschluessel von Labels entkoppelt"
```

---

### Task 5: Settings-Zeile „Sprache" (System / Deutsch / English)

**Files:**
- Modify: `lib/src/screens/settings/settings_controls.dart`
  (neue `SettingsLanguagePill` direkt unter `SettingsThemeModePill`, Z. ~226)
- Modify: `lib/src/screens/settings/settings_screen.dart`
  (`_praeferenzenGruppe()`, Z. 264–297)
- Test: `test/settings_language_test.dart`

**Interfaces:**
- Consumes: `LocaleController`/`LocaleScope` (Task 2), `context.l10n` (Task 3).
- Produces: `SettingsLanguagePill({required Locale? value, required
  ValueChanged<Locale?> onChanged})` mit den Options-Keys
  `settings-language-system` / `settings-language-de` / `settings-language-en`;
  Zeilen-Key `settings-language`.

- [ ] **Step 1: Failing Tests** — `test/settings_language_test.dart`
(Pump-Gerüst aus `test/settings_theme_mode_test.dart` übernehmen, nur mit
`LocaleScope` statt `ThemeModeScope` und der `designHarness`-Delegates):

```dart
// Kernaussagen:
testWidgets('Sprach-Pill setzt den Override auf Englisch', (tester) async {
  final controller = LocaleController();
  addTearDown(controller.dispose);
  // SettingsScreen in LocaleScope pumpen (Geruest siehe settings_theme_mode_test)
  await tester.tap(find.byKey(const ValueKey('settings-language-en')));
  await tester.pumpAndSettle();
  expect(controller.override, const Locale('en'));
});

testWidgets('ohne LocaleScope faellt die Zeile ersatzlos weg', (tester) async {
  // SettingsScreen OHNE LocaleScope pumpen
  expect(find.byKey(const ValueKey('settings-language')), findsNothing);
});

testWidgets('Settings-Screen rendert englisch in beiden Modi', (tester) async {
  // Screen unter locale en + Brightness.light und .dark pumpen;
  // expect(find.text('Language'), findsOneWidget);
  // expect(tester.takeException(), isNull);
});
```

- [ ] **Step 2: Rot sehen**

- [ ] **Step 3: SettingsLanguagePill** — Spiegel von `SettingsThemeModePill`
(gleicher Aufbau, gleiche Optik; nur Werte und Keys unterscheiden sich).
Die Options-Liste wird im `build()` gebaut, weil die Labels aus `context.l10n`
kommen:

```dart
class SettingsLanguagePill extends StatelessWidget {
  const SettingsLanguagePill({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// null = System (Geraetesprache).
  final Locale? value;
  final ValueChanged<Locale?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final optionen = <(Locale?, String, String)>[
      (null, l10n.languageSystem, 'settings-language-system'),
      (const Locale('de'), l10n.languageGerman, 'settings-language-de'),
      (const Locale('en'), l10n.languageEnglish, 'settings-language-en'),
    ];
    // Rendering 1:1 wie SettingsThemeModePill (settings_controls.dart:226 ff.).
    // NICHT kopieren: den Baukoerper der ThemeMode-Pill in einen gemeinsamen
    // privaten Unterbau ziehen (z. B. `_SettingsChoicePill` mit einer
    // (Wert, Label, Key)-Optionsliste), den beide Pills nutzen. Keys, Optik
    // und die bestehenden settings-theme-mode-Tests bleiben dabei
    // unveraendert gruen.
    ...
  }
}
```

- [ ] **Step 4: Zeile im Settings-Screen** — in `_praeferenzenGruppe()` unter
der Erscheinungsbild-Zeile, mit demselben Scope-Wächter-Muster:

```dart
    final localeController = LocaleScope.maybeOf(context);
    ...
      if (localeController != null)
        SettingsRow(
          title: context.l10n.settingsLanguageTitle,
          subtitle: context.l10n.settingsLanguageSubtitle,
          chevron: false,
          trailing: SettingsLanguagePill(
            key: const ValueKey('settings-language'),
            value: localeController.override,
            // Geraeteeinstellung: sofort persistiert, nichts zu verwerfen.
            onChanged: localeController.setOverride,
          ),
        ),
```

Imports: `../../app/locale_controller.dart`, `../../l10n/l10n.dart`.

- [ ] **Step 5: Grün sehen + Settings-Regression**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test test/settings_language_test.dart test/settings_screen_render_test.dart test/settings_screen_test.dart test/settings_erreichbarkeit_test.dart test/settings_theme_mode_test.dart`
Expected: PASS

- [ ] **Step 6: Commit**

```powershell
git add lib/src/screens/settings/settings_controls.dart lib/src/screens/settings/settings_screen.dart test/settings_language_test.dart
git commit -m "feat(i18n): Sprachwahl in den Einstellungen (System/Deutsch/English), sofort wirksam"
```

---

### Task 6: Abschluss — volle Suite, Analyze, PR

**Files:** keine neuen; nur Verifikation + PR.

- [ ] **Step 1: Analyze**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

- [ ] **Step 2: Volle Suite mit CI-Defines**

Run: `C:/Users/morit/Desktop/Flutter/flutter/bin/flutter.bat test --dart-define=SUPABASE_URL=https://ci.invalid --dart-define=SUPABASE_ANON_KEY=ci-dummy-key`
Expected: alle Tests grün. Rote Tests werden ehrlich repariert oder gemeldet —
nie gelöscht, nie geskippt (DESIGN_REFACTOR §7).

- [ ] **Step 3: Push + PR**

```powershell
git push -u origin feat/i18n-grundgeruest
```

PR per REST (Muster: `spec_pr.py` aus der Session vom 2026-08-10; Token aus
`C:\Users\morit\Desktop\Bridgespace\.env`): Titel
`feat(i18n): Grundgeruest Mehrsprachigkeit - Sprachwahl in den Einstellungen`,
Base `main`. Auf die Pflicht-Checks warten (Polling-Skript-Muster ebenda),
dann Squash-Merge im Repo-Stil (Commit-Titel = PR-Titel, ohne (#N)-Suffix).

- [ ] **Step 4: Nacharbeit**

Memory `eatova-design-refactor.md` (bzw. neues i18n-Memory) aktualisieren:
Grundgerüst gemergt, nächster Schritt Screen-Paket-Extraktion.

**Bewusste Auslassung gegenüber Spec §8 Nr. 1:** Der „schrumpfende
Hartkodierungs-Grep" (Spec §6 Wächter Nr. 3) kommt erst mit dem ERSTEN
Screen-Paket — im Grundgerüst wäre sein Geltungsbereich leer (noch kein
Bereich ist fertig migriert), ein Wächter ohne Prüfgebiet wäre totes Gerüst.
Der Paritäts-Wächter (Task 1) und die Sprachwahl-Tests (Task 5) sind die
Wächter dieser Runde.
