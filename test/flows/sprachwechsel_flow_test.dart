// Language switch flow: start the app in German, walk the core screens (Today,
// Recipes, Coach, Settings), flip the language pill in the settings to English
// and walk the SAME screens again — every text now English, no German leftover,
// no overflow — then back to German.
//
// Until now i18n was only checked per widget; this is the round trip through
// the live [LocaleController] that the settings pill drives.
//
// Two things make the assertions precise instead of decorative:
//  * The device language is pinned to en_US while the controller starts on de,
//    so German on screen can only come from the OVERRIDE, never from
//    `resolveEatovaLocale`.
//  * Every expectation is a pair: the ACTIVE bundle's string must be there and
//    the OTHER bundle's string must be gone. Hard-coded sentences would rot
//    with the next ARB edit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/l10n/l10n.dart';

import '../support/harness.dart' hide testWidgetsRobust;
import 'flow_test_helpers.dart';

/// One core screen of the tour: how to reach it, how to recognise it, and the
/// texts that must follow the language.
class _Kernscreen {
  const _Kernscreen(this.navKey, this.screenKey, this.texte);

  final String navKey;
  final String screenKey;
  final List<String Function(AppLocalizations)> texte;
}

const List<_Kernscreen> _tour = <_Kernscreen>[
  _Kernscreen('nav-Heute', 'screen-today', <String Function(AppLocalizations)>[
    _budgetEyebrow,
    _makros,
  ]),
  _Kernscreen(
    'nav-Rezepte',
    'screen-recipes',
    <String Function(AppLocalizations)>[_empfehlungen, _alleRezepte],
  ),
  _Kernscreen('nav-Coach', 'screen-coach', <String Function(AppLocalizations)>[
    _coachTitel,
    _coachStatus,
  ]),
];

// Tear-offs instead of closures: a const list may hold no lambdas.
String _budgetEyebrow(AppLocalizations l) => l.todayKcalBudgetEyebrow;
String _makros(AppLocalizations l) => l.todayMacrosTitle;
String _empfehlungen(AppLocalizations l) => l.recipesRecommendedTitle;
String _alleRezepte(AppLocalizations l) => l.recipesAllTitle;
String _coachTitel(AppLocalizations l) => l.coachTitle;
String _coachStatus(AppLocalizations l) => l.coachStatusLine;

/// Settings texts, checked on the pushed route rather than in the tab tour.
const List<String Function(AppLocalizations)> _einstellungenTexte =
    <String Function(AppLocalizations)>[
  _einstellungenTitel,
  _praeferenzen,
  _sprache,
  _zieleZeile,
];

String _einstellungenTitel(AppLocalizations l) => l.settingsPageTitle;
String _praeferenzen(AppLocalizations l) => l.settingsGroupPreferences;
String _sprache(AppLocalizations l) => l.settingsLanguageTitle;
String _zieleZeile(AppLocalizations l) => l.goalsPageTitle;

/// The nav labels that actually differ between the two languages — "Food" and
/// "Coach" are identical in both and would prove nothing.
const List<String Function(AppLocalizations)> _navTexte =
    <String Function(AppLocalizations)>[_navHeute, _navRezepte];

String _navHeute(AppLocalizations l) => l.navToday;
String _navRezepte(AppLocalizations l) => l.navRecipes;

/// Bounded settle for the coach tab: the CoachOrb repeats forever while its
/// tab is visible, so pumpAndSettle would never return there.
Future<void> _pumpFrames(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tippe(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Asserts every text of [texte] in [aktiv] and none of them in [andere].
void _erwarteSprache(
  List<String Function(AppLocalizations)> texte,
  AppLocalizations aktiv,
  AppLocalizations andere,
  String wo,
) {
  for (final text in texte) {
    expect(find.text(text(aktiv)), findsWidgets,
        reason: '$wo: „${text(aktiv)}" fehlt');
    expect(find.text(text(andere)), findsNothing,
        reason: '$wo: „${text(andere)}" ist ein Rest der anderen Sprache');
  }
}

/// Walks Today, Recipes and Coach and checks both directions per screen.
Future<void> _rundgang(
  WidgetTester tester,
  AppLocalizations aktiv,
  AppLocalizations andere,
) async {
  for (final screen in _tour) {
    await tester.tap(find.byKey(ValueKey(screen.navKey)));
    if (screen.screenKey == 'screen-coach') {
      await _pumpFrames(tester);
    } else {
      await tester.pumpAndSettle();
    }
    expect(find.byKey(ValueKey(screen.screenKey)), findsOneWidget,
        reason: '${screen.navKey} fuehrt nicht auf ${screen.screenKey}');
    _erwarteSprache(screen.texte, aktiv, andere, screen.screenKey);
    _erwarteSprache(_navTexte, aktiv, andere, 'Navigationsleiste');
  }
  // Leave the coach tab: its ticker keeps pumpAndSettle from returning for
  // whatever the caller does next.
  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await tester.pumpAndSettle();
}

/// Opens the settings route from the food tab.
Future<void> _oeffneEinstellungen(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-Food')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('topbar-settings')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
}

/// Scrolls the settings list back to its header.
///
/// Taking the language pill drags the lazy [ListView] far enough for the page
/// header to leave the build range — and a title that is not built reads like
/// a missing translation.
Future<void> _zumSeitenanfang(WidgetTester tester) async {
  final kopf = find.byKey(const ValueKey('settings-back'));
  if (kopf.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      kopf,
      find.byKey(const ValueKey('screen-settings')),
      const Offset(0, 200),
    );
  }
  await tester.ensureVisible(kopf);
  await tester.pumpAndSettle();
}

/// Closes the settings route.
Future<void> _schliesseEinstellungen(WidgetTester tester) async {
  await _zumSeitenanfang(tester);
  await _tippe(tester, find.byKey(const ValueKey('settings-back')));
  expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
}

/// Scrolls the language pill into range and takes one of its three options.
Future<void> _waehleSprache(WidgetTester tester, String optionKey) async {
  final option = find.byKey(ValueKey(optionKey));
  if (option.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      option,
      find.byKey(const ValueKey('screen-settings')),
      const Offset(0, -150),
    );
  }
  await _tippe(tester, option);
}

void main() {
  // LocaleController.setOverride persists through SharedPreferences; without
  // mock values the plugin channel is missing and the write is only swallowed.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgetsRobust(
      'Sprachwechsel: Kernscreens auf Deutsch, auf Englisch und zurueck',
      (WidgetTester tester) async {
    // `collectOverflows` (test/support/harness.dart) RECORDS layout errors
    // instead of swallowing them like testWidgetsRobust — a language switch is
    // exactly where a longer word breaks a fixed box. Deliberately the shared
    // helper and not a local `contains('overflowed')`: it also catches
    // `RenderBox was not laid out`, unbounded constraints and everything else
    // the rendering library reports, and those are the shapes a too-long
    // translation takes inside a Row.
    final ueberlaeufe = await collectOverflows(() async {
      // Device speaks English; the German start can only come from the
      // override.
      tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      final controller = LocaleController(initial: const Locale('de'));
      addTearDown(controller.dispose);

      await tester.pumpWidget(EatovaApp(localeController: controller));
      await tester.pumpAndSettle();

      // --- 1. Deutsch ------------------------------------------------------
      await _rundgang(tester, deL10n, enL10n);
      await _oeffneEinstellungen(tester);
      _erwarteSprache(
          _einstellungenTexte, deL10n, enL10n, 'Einstellungen (de)');

      // --- 2. Umschalten auf Englisch --------------------------------------
      await _waehleSprache(tester, 'settings-language-en');
      expect(controller.override, const Locale('en'));
      // Die offene Route zieht sofort nach, ohne Neustart.
      await _zumSeitenanfang(tester);
      _erwarteSprache(
          _einstellungenTexte, enL10n, deL10n, 'Einstellungen (en)');

      await _schliesseEinstellungen(tester);
      await _rundgang(tester, enL10n, deL10n);

      // --- 3. Zurueck auf Deutsch ------------------------------------------
      await _oeffneEinstellungen(tester);
      await _waehleSprache(tester, 'settings-language-de');
      expect(controller.override, const Locale('de'));
      await _zumSeitenanfang(tester);
      _erwarteSprache(
          _einstellungenTexte, deL10n, enL10n, 'Einstellungen (zurueck)');

      await _schliesseEinstellungen(tester);
      await _rundgang(tester, deL10n, enL10n);

      expect(tester.takeException(), isNull);
    });

    expect(ueberlaeufe, isEmpty,
        reason: 'ein Sprachwechsel darf kein Layout sprengen: '
            '${describeOverflows(ueberlaeufe)}');
  });
}
