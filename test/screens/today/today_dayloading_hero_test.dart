// Komplettreview 2026-08-19: der Lade-Zustand des Tabs „Heute" hing nur an der
// Mahlzeiten-Karte.
//
// Kalorien-Hero und Makro-Karte bekamen keinen `dayLoading`-Guard. Beim
// Blaettern in einen Archivtag ausserhalb des Boot-Fensters stand deshalb fuer
// die Dauer des Nachladens die volle Tagesbilanz eines LEEREN Tages da:
// „2.000 kcal uebrig", 0 g Protein — obwohl der Tag noch gar nicht geladen
// war. Eine Sekunde spaeter sprangen beide Flaechen auf die echten Werte um.
//
// Der Harness stellt die Schale nach wie test/screens/today/today_screen_test
// .dart (Eatova-Theme, Telefon-Viewport, das Padding aus
// eatova_home_page.dart:420-424).

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

/// Sonntag, 9. August 2026, 10:00 — weit weg von jeder Tagesgrenze.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

/// Ein Tag weit ausserhalb des 35-Tage-Boot-Fensters: nur dort setzt
/// `HomeStore.isLoadingFoodDay` ueberhaupt jemals `dayLoading`
/// (home_store_meals.dart:28-32).
final DateTime _archivtag = DateTime(2026, 6, 12);

const UserProfile _profil = UserProfile(
  dailyKcalGoal: 2000,
  proteinGoalG: 130,
  carbsGoalG: 240,
  fatGoalG: 70,
);

Future<void> _pumpToday(
  WidgetTester tester, {
  required bool dayLoading,
  int consumedKcal = 0,
  MacroProgress macroProgress = MacroProgress.empty,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEatovaTheme(Brightness.light),
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
            child: TodayScreen(
              userName: 'Moritz',
              profile: _profil,
              consumedKcal: consumedKcal,
              burnedKcal: 0,
              macroProgress: macroProgress,
              meals: const [],
              selectedDate: _archivtag,
              streak: 4,
              dayLoading: dayLoading,
            ),
          ),
        ),
      ),
    ),
  );

  // KEIN pumpAndSettle: die Ladekarte dreht einen CircularProgressIndicator
  // endlos, dort settlet nichts.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _key(String key) =>
    find.byKey(ValueKey<String>(key), skipOffstage: false);

void main() {
  group('dayLoading deckt den ganzen Tagesblock', () {
    testWidgets('waehrend des Ladens behauptet der Hero keine Tagesbilanz',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-kcal-hero'), findsNothing);
      // Die eigentliche Luege: „2.000" + „kcal uebrig" fuer einen Tag, an dem
      // vielleicht 2.400 kcal stehen — die Zahlen sind nur noch nicht da.
      expect(_key('today-kcal-remaining'), findsNothing);
      expect(find.text('kcal übrig', skipOffstage: false), findsNothing);
      expect(_key('today-kcal-goal'), findsNothing);
    });

    testWidgets('waehrend des Ladens behaupten die Makro-Balken keine Nullen',
        (tester) async {
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-macros-card'), findsNothing);
      expect(find.byType(MacroBar, skipOffstage: false), findsNothing);
    });

    testWidgets('die Ladekarte bleibt die EINZIGE Lade-Aussage',
        (tester) async {
      // Der Zustand gehoert einmal auf den Schirm, nicht dreimal: Hero und
      // Makros weichen, die Karte unter der Ueberschrift traegt ihn.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(tester, dayLoading: true);
      });

      expect(_key('today-day-loading'), findsOneWidget);
      expect(find.text('Tag wird geladen…', skipOffstage: false),
          findsOneWidget);
      // Die Ueberschrift bleibt stehen — auf einem Archivtag ohne „Heutige".
      expect(find.text('Mahlzeiten', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ohne dayLoading stehen Hero und Makros unveraendert da',
        (tester) async {
      // Gegenprobe: der Guard darf die geladene Ansicht nicht anfassen.
      await withClock(Clock.fixed(_jetzt), () async {
        await _pumpToday(
          tester,
          dayLoading: false,
          consumedKcal: 700,
          macroProgress: const MacroProgress(
            proteinG: 42,
            carbsG: 80,
            fatG: 20,
            kcal: 700,
          ),
        );
      });

      expect(_key('today-kcal-hero'), findsOneWidget);
      // 2.000 Ziel + 0 verbrannt − 700 gegessen.
      expect(tester.widget<Text>(_key('today-kcal-remaining')).data, '1.300');
      expect(_key('today-day-loading'), findsNothing);

      // Herangescrollt statt geraten: die ListView baut ihre unteren Kinder
      // erst beim Heranscrollen, und wo die Makro-Karte auf dem Testgeraet
      // endet, haengt an der Systemschrift.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('today-macros-card')),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(_key('today-macros-card'), findsOneWidget);
      expect(find.byType(MacroBar, skipOffstage: false), findsNWidgets(3));
    });
  });
}
