// Heute-Hero und Food-Zusammenfassung nennen dieselbe Zielzahl.
//
// WARUM ES DIESE DATEI GIBT (Verifikation 2026-08-09):
// Der Heute-Hero zeigte `Ziel ${kcalGoal + burnedKcal} kcal`, die
// ZIEL-Kachel der Food-Zusammenfassung dagegen das rohe `profile.dailyKcalGoal`.
// Bei Tagesziel 2000 und 300 verbrannten kcal stand auf der einen Flaeche
// „Ziel 2.300 kcal" und einen Tab-Tap weiter „2.000 kcal" — zwei Zahlen fuer
// dasselbe Wort, am selben Tag, im selben Profil.
//
// Aufgeloest wurde das zugunsten des ROHEN Ziels: „Ziel" ist der Wert aus den
// Einstellungen. Das verbrannte Guthaben fliesst in die VERBLEIBENDE Zahl und
// in den Fortschritt, nie in die angezeigte Zielzahl — genau so hielt es auch
// die abgeloeste `calories_overview_card.dart` (Zeilen 34-39).
//
// Dieser Test ist die Klammer, die beide Flaechen zusammenhaelt. Er liest die
// Zahlen aus BEIDEN Screens (nicht aus den Widgets darunter), damit auch eine
// Drift in der VERDRAHTUNG auffaellt — etwa wenn ein Screen kuenftig ein
// „effektives" Ziel durchreicht und der andere das rohe.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Sonntag, 9. August 2026, 10:00 — weit weg von jeder Tagesgrenze.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

/// Die Zahlen, die eine Flaeche ueber den Tag behauptet.
class _Aussage {
  const _Aussage({
    required this.ziel,
    required this.rest,
    required this.einheit,
  });

  /// Die ZIEL-Angabe, normalisiert auf „2.000 kcal".
  final String ziel;

  /// Die verbleibenden kcal als reine Zahl („1.800").
  final String rest;

  /// „kcal übrig" bzw. „kcal drüber".
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

/// Der gemeinsame Viewport beider Tabs: iPhone 16 Pro, nutzbare Flaeche.
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Dieselbe Huelle, die `EatovaHomePage` beiden Tabs gibt (SafeArea +
/// 20/12/20/12) — sonst maesse der Test ein Layout, das die App nie zeichnet.
Widget _schale(Widget child, Brightness brightness) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEatovaTheme(brightness),
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

/// Zieht „2.000 kcal" aus „Ziel 2.000 kcal" bzw. aus „2.000 kcal".
String _zielZahl(String roh) {
  final treffer = RegExp(r'([\d.]+)\s*kcal').firstMatch(roh);
  expect(treffer, isNotNull, reason: 'keine Zielzahl in „$roh"');
  return '${treffer!.group(1)} kcal';
}

/// Findet die Einheit unter den sichtbaren Texten — beide Flaechen setzen sie
/// wortgleich („kcal übrig" / „kcal drüber", today_hero.dart:118).
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

Future<_Aussage> _food(
  WidgetTester tester, {
  required UserProfile profile,
  required int consumedKcal,
  required int burnedKcal,
  required DateTime selectedDate,
  Brightness brightness = Brightness.light,
}) async {
  _pinViewport(tester);
  await tester.pumpWidget(
    _schale(
      MealAnalysisScreen(
        dailyConsumedKcal: consumedKcal,
        burnedKcal: burnedKcal,
        profile: profile,
        selectedDate: selectedDate,
      ),
      brightness,
    ),
  );
  await tester.pumpAndSettle();

  return _Aussage(
    ziel: _zielZahl(_textOf(tester, 'analyse-daily-kcal-goal')),
    rest: _textOf(tester, 'analyse-daily-kcal-remaining'),
    einheit: _einheit(tester),
  );
}

void main() {
  // Ein Tag, ein Profil — vier Lagen, in denen die beiden Flaechen frueher
  // auseinanderlaufen konnten.
  final faelle = <String, (UserProfile, int, int, DateTime)>{
    // Der konkrete Fund: Verbranntes vorhanden, Tag ist heute.
    'mit verbrannten Kalorien': (
      const UserProfile(dailyKcalGoal: 2000),
      500,
      300,
      DateTime(2026, 8, 9),
    ),
    // Archivtag: `burnedKcal` ist hart 0 (DESIGN_REFACTOR §5).
    'auf einem Archivtag ohne Schrittdaten': (
      const UserProfile(dailyKcalGoal: 2200),
      1200,
      0,
      DateTime(2026, 8, 4),
    ),
    // Ueberzogen: beide muessen denselben Betrag UND dieselbe Einheit setzen.
    'nach dem Ueberziehen': (
      const UserProfile(dailyKcalGoal: 1800),
      2400,
      120,
      DateTime(2026, 8, 9),
    ),
    // Kaputtes Profil aus dem Netz: `goal <= 0 -> 1` muss auf beiden
    // Flaechen dieselbe Notklemme sein.
    'bei einem Tagesziel von 0': (
      const UserProfile(dailyKcalGoal: 0),
      400,
      0,
      DateTime(2026, 8, 9),
    ),
  };

  faelle.forEach((name, fall) {
    final (profile, consumed, burned, datum) = fall;

    testWidgets('Heute und Food nennen dieselben Zahlen — $name',
        (tester) async {
      final ausHeute = await _heute(
        tester,
        profile: profile,
        consumedKcal: consumed,
        burnedKcal: burned,
        selectedDate: datum,
      );
      final ausFood = await _food(
        tester,
        profile: profile,
        consumedKcal: consumed,
        burnedKcal: burned,
        selectedDate: datum,
      );

      expect(
        ausFood,
        ausHeute,
        reason: 'Heute sagt „$ausHeute", Food sagt „$ausFood" — beide '
            'beschreiben denselben Tag mit demselben Profil',
      );
    });
  });

  testWidgets('das genannte Ziel ist das ROHE Tagesziel, nicht Ziel+Verbranntes',
      (tester) async {
    // Der eigentliche Fund, noch einmal zeichengenau: bei 2000 kcal Ziel und
    // 300 verbrannten kcal darf nirgends „2.300" als ZIEL stehen. Die 2.300
    // sind die Rechengroesse hinter dem Rest — und der steht als 1.800 da.
    const profile = UserProfile(dailyKcalGoal: 2000);
    final datum = DateTime(2026, 8, 9);

    final ausHeute = await _heute(tester,
        profile: profile,
        consumedKcal: 500,
        burnedKcal: 300,
        selectedDate: datum);
    expect(ausHeute.ziel, '2.000 kcal');
    expect(ausHeute.rest, '1.800');
    expect(find.textContaining('2.300'), findsNothing);

    final ausFood = await _food(tester,
        profile: profile,
        consumedKcal: 500,
        burnedKcal: 300,
        selectedDate: datum);
    expect(ausFood.ziel, '2.000 kcal');
    expect(ausFood.rest, '1.800');
    expect(find.textContaining('2.300'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('die Uebereinstimmung haengt nicht am Anzeige-Modus '
        '($brightness)', (tester) async {
      const profile = UserProfile(dailyKcalGoal: 2000);
      final datum = startOfDay(_jetzt);

      final ausHeute = await _heute(
        tester,
        profile: profile,
        consumedKcal: 500,
        burnedKcal: 300,
        selectedDate: datum,
        brightness: brightness,
      );
      final ausFood = await _food(
        tester,
        profile: profile,
        consumedKcal: 500,
        burnedKcal: 300,
        selectedDate: datum,
        brightness: brightness,
      );

      expect(ausFood, ausHeute);
      expect(tester.takeException(), isNull);
    });
  }
}
