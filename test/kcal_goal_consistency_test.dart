// The today hero names the RAW daily goal while computing the remainder
// against goal + burned.
//
// The displayed goal is the value from the settings; burned credit only feeds
// the REMAINING number and the progress, never the shown goal. The assertions
// compare the displayed number against the raw `profile.dailyKcalGoal`, never
// `+ burned`, across five situations (burned, archive day, overshoot, broken
// profile, display mode).
//
// Reads deliberately from the SCREEN (`TodayScreen`), not from the hero widget
// below it, so a wiring drift shows up too — e.g. if the shell ever passes an
// "effective" goal.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Sunday, 9 August 2026, 10:00 — far from any day boundary.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

/// The numbers the hero claims about the day.
class _Aussage {
  const _Aussage({
    required this.ziel,
    required this.rest,
    required this.einheit,
  });

  /// The goal figure, normalised to a `"<number> kcal"` form.
  final String ziel;

  /// The remaining kcal as a bare number.
  final String rest;

  /// The unit label — remaining or over.
  final String einheit;

  @override
  String toString() => 'Ziel $ziel · $rest $einheit';

  @override
  bool operator ==(Object other) =>
      other is _Aussage &&
      other.ziel == ziel &&
      other.rest == rest &&
      other.einheit == einheit;

  @override
  int get hashCode => Object.hash(ziel, rest, einheit);
}

/// The tab viewport: iPhone 16 Pro usable area.
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The same shell `EatovaHomePage` gives the tab (SafeArea + 20/12/20/12),
/// otherwise the test would measure a layout the app never draws.
/// TodayScreen reads `context.l10n`, so the localization is required.
Widget _schale(Widget child, Brightness brightness) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: child,
          ),
        ),
      ),
    );

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

/// Extracts the `"<number> kcal"` part from the goal label.
String _zielZahl(String roh) {
  final treffer = RegExp(r'([\d.]+)\s*kcal').firstMatch(roh);
  expect(treffer, isNotNull, reason: 'keine Zielzahl in „$roh"');
  return '${treffer!.group(1)} kcal';
}

/// Finds the unit label among the visible texts (today_hero.dart).
String _einheit(WidgetTester tester) {
  if (find.text('kcal übrig').evaluate().isNotEmpty) return 'kcal übrig';
  if (find.text('kcal drüber').evaluate().isNotEmpty) return 'kcal drüber';
  fail('weder „kcal übrig" noch „kcal drüber" gefunden');
}

Future<_Aussage> _heute(
  WidgetTester tester, {
  required UserProfile profile,
  required int consumedKcal,
  required int burnedKcal,
  required DateTime selectedDate,
  Brightness brightness = Brightness.light,
}) async {
  _pinViewport(tester);
  await withClock(Clock.fixed(_jetzt), () async {
    await tester.pumpWidget(
      _schale(
        TodayScreen(
          userName: 'Moritz',
          profile: profile,
          consumedKcal: consumedKcal,
          burnedKcal: burnedKcal,
          macroProgress: MacroProgress.empty,
          meals: const <LoggedMeal>[],
          selectedDate: selectedDate,
          streak: 3,
        ),
        brightness,
      ),
    );
    await tester.pumpAndSettle();
  });

  return _Aussage(
    ziel: _zielZahl(_textOf(tester, 'today-kcal-goal')),
    rest: _textOf(tester, 'today-kcal-remaining'),
    einheit: _einheit(tester),
  );
}

void main() {
  group('Der Heute-Hero: Ziel roh, Verbranntes im Rest', () {
    // One day, one profile — the situations in which the goal number used to
    // drift.
    final faelle =
        <String, (UserProfile, int, int, DateTime, _Aussage)>{
      // The original finding: burned present, day is today.
      // 2000 + 300 - 500 = 1800 remaining, displayed goal stays 2000.
      'mit verbrannten Kalorien': (
        const UserProfile(dailyKcalGoal: 2000),
        500,
        300,
        DateTime(2026, 8, 9),
        const _Aussage(
          ziel: '2.000 kcal',
          rest: '1.800',
          einheit: 'kcal übrig',
        ),
      ),
      // Archive day: `burnedKcal` is hard 0, so the remainder is computed
      // against the plain daily goal.
      'auf einem Archivtag ohne Schrittdaten': (
        const UserProfile(dailyKcalGoal: 2200),
        1200,
        0,
        DateTime(2026, 8, 4),
        const _Aussage(
          ziel: '2.200 kcal',
          rest: '1.000',
          einheit: 'kcal übrig',
        ),
      ),
      // Overshoot: magnitude WITHOUT a minus sign, the unit carries the sign.
      // 1800 + 120 - 2400 = -480.
      'nach dem Ueberziehen': (
        const UserProfile(dailyKcalGoal: 1800),
        2400,
        120,
        DateTime(2026, 8, 9),
        const _Aussage(
          ziel: '1.800 kcal',
          rest: '480',
          einheit: 'kcal drüber',
        ),
      ),
      // Broken profile from the network: `goal <= 0 -> 1` is the emergency
      // clamp against a division by 0 in `progress`.
      'bei einem Tagesziel von 0': (
        const UserProfile(dailyKcalGoal: 0),
        400,
        0,
        DateTime(2026, 8, 9),
        const _Aussage(ziel: '1 kcal', rest: '399', einheit: 'kcal drüber'),
      ),
    };

    faelle.forEach((name, fall) {
      final (profile, consumed, burned, datum, erwartet) = fall;

      testWidgets(name, (tester) async {
        final aussage = await _heute(
          tester,
          profile: profile,
          consumedKcal: consumed,
          burnedKcal: burned,
          selectedDate: datum,
        );

        expect(
          aussage,
          erwartet,
          reason: 'Der Hero sagt „$aussage", erwartet war „$erwartet"',
        );
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('das genannte Ziel ist das ROHE Tagesziel, nicht '
        'Ziel+Verbranntes', (tester) async {
      // The finding, character-exact: with a 2000 goal and 300 burned, 2300
      // must never appear as the GOAL — it is only the quantity behind the
      // remainder.
      const profile = UserProfile(dailyKcalGoal: 2000);

      final aussage = await _heute(
        tester,
        profile: profile,
        consumedKcal: 500,
        burnedKcal: 300,
        selectedDate: DateTime(2026, 8, 9),
      );

      expect(aussage.ziel, '2.000 kcal');
      expect(aussage.rest, '1.800');
      // Nowhere in the tree — not in a tile, not in a subtitle.
      expect(find.textContaining('2.300'), findsNothing);
      // The burned tile keeps the arithmetic traceable.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('today-stat-burned')),
          matching: find.text('300'),
        ),
        findsOneWidget,
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('die Zahlen haengen nicht am Anzeige-Modus ($brightness)',
          (tester) async {
        final aussage = await _heute(
          tester,
          profile: const UserProfile(dailyKcalGoal: 2000),
          consumedKcal: 500,
          burnedKcal: 300,
          selectedDate: startOfDay(_jetzt),
          brightness: brightness,
        );

        expect(
          aussage,
          const _Aussage(
            ziel: '2.000 kcal',
            rest: '1.800',
            einheit: 'kcal übrig',
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
