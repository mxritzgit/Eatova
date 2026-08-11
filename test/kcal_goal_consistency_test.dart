// Der Heute-Hero nennt das ROHE Tagesziel — und rechnet den Rest trotzdem
// gegen Ziel + Verbranntes.
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
// UMGESCHRIEBEN 2026-08-10: Die Datei war die KLAMMER um zwei Flaechen und las
// dieselben Zahlen aus Heute-Hero UND Food-Zusammenfassung, um eine Drift in
// der Verdrahtung aufzudecken. Die Food-Zusammenfassung ist auf Nutzer-Entscheid
// entfallen („das haben wir ja im Heute-Tab schon") — mit nur noch EINER
// Flaeche ist der Vergleich gegenstandslos. Verglichen wird jetzt nicht mehr
// Flaeche gegen Flaeche, sondern die angezeigte Zahl gegen die ROHE Zahl aus
// dem Profil: „Ziel" muss `profile.dailyKcalGoal` sein, nie `+ burned`. Die
// fuenf Lagen des alten Tabellen-Tests (Verbranntes, Archivtag, Ueberziehung,
// kaputtes Profil, Anzeige-Modus) bleiben vollstaendig erhalten, jetzt mit
// zeichengenauen Erwartungswerten statt eines Flaechen-Vergleichs.
//
// Grenze dieser Datei: sie liest bewusst aus dem SCREEN (`TodayScreen`), nicht
// aus dem Hero-Widget darunter — so faellt auch eine Drift in der Verdrahtung
// auf, etwa wenn die Schale kuenftig ein „effektives" Ziel durchreicht.

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

/// Sonntag, 9. August 2026, 10:00 — weit weg von jeder Tagesgrenze.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

/// Die Zahlen, die der Hero ueber den Tag behauptet.
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

/// Der Viewport des Tabs: iPhone 16 Pro, nutzbare Flaeche.
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Dieselbe Huelle, die `EatovaHomePage` dem Tab gibt (SafeArea + 20/12/20/12)
/// — sonst maesse der Test ein Layout, das die App nie zeichnet.
///
/// TodayScreen liest seit dem i18n-Paket 1 `context.l10n` (Muster von
/// test/home_page_tabs_test.dart) — ohne die Lokalisierung wirft
/// AppLocalizations.of() beim ersten Build.
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

/// Zieht „2.000 kcal" aus „Ziel 2.000 kcal".
String _zielZahl(String roh) {
  final treffer = RegExp(r'([\d.]+)\s*kcal').firstMatch(roh);
  expect(treffer, isNotNull, reason: 'keine Zielzahl in „$roh"');
  return '${treffer!.group(1)} kcal';
}

/// Findet die Einheit unter den sichtbaren Texten (today_hero.dart:127).
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
    // Ein Tag, ein Profil — fuenf Lagen, in denen die Zielzahl frueher
    // wegdriften konnte. Uebernommen aus dem Flaechen-Vergleich, den diese
    // Datei bis 2026-08-10 fuehrte; die erwarteten Werte sind die, die dort
    // BEIDE Flaechen liefern mussten.
    final faelle =
        <String, (UserProfile, int, int, DateTime, _Aussage)>{
      // Der konkrete Fund: Verbranntes vorhanden, Tag ist heute.
      // 2000 + 300 - 500 = 1800 Rest, angezeigtes Ziel bleibt 2.000.
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
      // Archivtag: `burnedKcal` ist hart 0 (DESIGN_REFACTOR §5). Der Rest
      // rechnet dann gegen das reine Tagesziel.
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
      // Ueberzogen: Betrag OHNE Minuszeichen, das Vorzeichen traegt die
      // Einheit. 1800 + 120 - 2400 = -480.
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
      // Kaputtes Profil aus dem Netz: `goal <= 0 -> 1` ist die Notklemme
      // gegen die Division durch 0 in `progress`.
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
      // Der eigentliche Fund, noch einmal zeichengenau: bei 2000 kcal Ziel und
      // 300 verbrannten kcal darf nirgends „2.300" als ZIEL stehen. Die 2.300
      // sind die Rechengroesse hinter dem Rest — und der steht als 1.800 da.
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
      // Nirgends im Baum — auch nicht in einer Kachel oder einem Untertitel.
      expect(find.textContaining('2.300'), findsNothing);
      // Nachvollziehbar bleibt die Rechnung ueber die VERBRANNT-Kachel.
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
