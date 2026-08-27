// The steps card on the Today tab.
//
// It sits under the calorie hero and shows the math behind the burned tile:
// day total, progress towards the profile's step goal, estimated kcal. Without
// a step source (`steps == null`) there is no card — "0 / 8.000" would be a
// claim about data that does not exist.
//
// Harness as in today_screen_test.dart: Eatova theme, phone viewport, shell
// padding.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/today/today_sections.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/theme/app_theme.dart';

const ValueKey<String> _karte = ValueKey<String>('today-steps-card');
const ValueKey<String> _wert = ValueKey<String>('today-steps-value');
const ValueKey<String> _untertitel = ValueKey<String>('today-steps-subtitle');
const ValueKey<String> _balken = ValueKey<String>('today-steps-bar');

Widget _harness(
  Widget child, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  Locale locale = const Locale('de'),
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEatovaTheme(brightness),
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  int? steps,
  int burnedKcal = 0,
  int goal = 8000,
  bool dayLoading = false,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  Locale locale = const Locale('de'),
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _harness(
      TodayScreen(
        userName: 'Moritz',
        profile: const UserProfile().copyWith(dailyStepsGoal: goal),
        consumedKcal: 0,
        burnedKcal: burnedKcal,
        macroProgress: MacroProgress.empty,
        meals: const <LoggedMeal>[],
        selectedDate: startOfDay(clock.now()),
        streak: 0,
        steps: steps,
        dayLoading: dayLoading,
      ),
      brightness: brightness,
      textScaler: textScaler,
      locale: locale,
    ),
  );
  if (dayLoading) {
    // The loading card spins forever; pumpAndSettle would never settle.
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  } else {
    await tester.pumpAndSettle();
  }
}

String _text(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;

double _balkenWert(WidgetTester tester) =>
    tester.widget<LinearProgressIndicator>(find.byKey(_balken)).value!;

void main() {
  group('TodayStepsCard', () {
    testWidgets('ohne Schrittquelle gibt es keine Karte', (tester) async {
      await _pump(tester, steps: null, burnedKcal: 261);

      expect(find.byKey(_karte), findsNothing);
      expect(find.byType(TodayStepsCard), findsNothing);
      // The rest of the day is unchanged.
      expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('today-macros-card')), findsOneWidget);
    });

    testWidgets('Stand, Einheit, kcal und Ziel — mit Tausenderpunkt', (
      tester,
    ) async {
      await _pump(tester, steps: 7000, burnedKcal: 261);

      expect(find.byKey(_karte), findsOneWidget);
      expect(find.text('Schritte'), findsOneWidget);
      expect(_text(tester, _wert), '7.000');
      expect(find.text('SCHRITTE'), findsOneWidget);
      expect(_text(tester, _untertitel), '≈ 261 kcal verbrannt · Ziel 8.000');
      // 7000 / 8000 after the animation settles.
      expect(_balkenWert(tester), closeTo(0.875, 0.001));
    });

    testWidgets('die Karte steht zwischen Hero und Makros', (tester) async {
      await _pump(tester, steps: 7000, burnedKcal: 261);

      final hero = tester.getRect(
        find.byKey(const ValueKey('today-kcal-hero')),
      );
      final karte = tester.getRect(find.byKey(_karte));
      final makros = tester.getRect(
        find.byKey(const ValueKey('today-macros-card')),
      );
      expect(karte.top, greaterThanOrEqualTo(hero.bottom));
      expect(makros.top, greaterThanOrEqualTo(karte.bottom));
      // Same column as its neighbours - no second side margin.
      expect(karte.left, hero.left);
      expect(karte.right, hero.right);
    });

    testWidgets('ohne Verbranntes steht nur das Ziel', (tester) async {
      await _pump(tester, steps: 7000, burnedKcal: 0);

      expect(_text(tester, _untertitel), 'Ziel 8.000');
    });

    testWidgets('Ziel erreicht: der Untertitel sagt es, der Balken ist voll', (
      tester,
    ) async {
      await _pump(tester, steps: 9000, burnedKcal: 300);

      expect(_text(tester, _wert), '9.000');
      expect(
        _text(tester, _untertitel),
        '≈ 300 kcal verbrannt · Ziel erreicht',
      );
      expect(_balkenWert(tester), 1.0);
    });

    testWidgets('eine echte 0 (Quelle da, noch kein Schritt) bleibt sichtbar', (
      tester,
    ) async {
      await _pump(tester, steps: 0, burnedKcal: 0);

      expect(find.byKey(_karte), findsOneWidget);
      expect(_text(tester, _wert), '0');
      expect(_text(tester, _untertitel), 'Ziel 8.000');
      expect(_balkenWert(tester), 0.0);
    });

    testWidgets('auf Englisch: Komma-Tausender, STEPS, Goal', (tester) async {
      await _pump(
        tester,
        steps: 7000,
        burnedKcal: 261,
        locale: const Locale('en'),
      );

      expect(find.text('Steps'), findsOneWidget);
      expect(_text(tester, _wert), '7,000');
      expect(find.text('STEPS'), findsOneWidget);
      expect(_text(tester, _untertitel), '≈ 261 kcal burned · Goal 8,000');
    });

    testWidgets('waehrend der Tag laedt, fehlt auch die Schritte-Karte', (
      tester,
    ) async {
      await _pump(tester, steps: 7000, burnedKcal: 261, dayLoading: true);

      expect(find.byKey(_karte), findsNothing);
      expect(find.byKey(const ValueKey('today-day-loading')), findsOneWidget);
    });

    testWidgets('der Screenreader hoert Stand und Ziel', (tester) async {
      // Disposed explicitly, not via addTearDown: the framework checks for
      // open handles BEFORE the teardowns run.
      final handle = tester.ensureSemantics();
      await _pump(tester, steps: 7000, burnedKcal: 261);

      // RegExp + contains: the card merges the bar node with the texts above
      // it, so label and value do not stand alone in the node.
      final balken = find.bySemanticsLabel(RegExp('Schrittziel'));
      expect(balken, findsOneWidget);
      expect(
        tester.getSemantics(balken).value,
        contains('7.000 von 8.000 Schritten'),
      );
      handle.dispose();
    });

    for (final helligkeit in Brightness.values) {
      testWidgets(
        'rendert in $helligkeit auch bei Systemschrift 2.0 ohne Ueberlauf',
        (tester) async {
          await _pump(
            tester,
            steps: 12345,
            burnedKcal: 4321,
            brightness: helligkeit,
            textScaler: const TextScaler.linear(2.0),
          );

          expect(tester.takeException(), isNull);
          // At 2.0 the hero's metric tiles stack (F8-09) and push the card
          // below the lazy ListView's viewport; scroll it into existence.
          await tester.scrollUntilVisible(
            find.byKey(_karte),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(_karte), findsOneWidget);
          expect(_text(tester, _wert), '12.345');
        },
      );
    }
  });
}
