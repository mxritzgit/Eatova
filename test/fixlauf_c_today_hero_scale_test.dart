// Fix run for review 2026-08-27, F8-09 (Today part): the hero's metric tiles
// wrapped value and label in FittedBox.scaleDown, which silently undid the
// system text scale (a 10.5 px label stayed 10.5 px at 1.3x). Now the tiles
// keep their real size: side by side up to 1.3x, stacked above that. Only
// the 66 px hero number keeps its FittedBox.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/today/today_hero.dart';
import 'package:eatova/src/theme/app_theme.dart';

const List<String> _tiles = <String>[
  'today-stat-eaten',
  'today-stat-burned',
  'today-stat-streak',
];

Future<List<String>> _pumpHero(
  WidgetTester tester, {
  required double scale,
  int consumed = 1234,
  int burned = 321,
  int streak = 12,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Padding(
              // The shell's 20 px side margin.
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TodayCalorieHero(
                consumedKcal: consumed,
                burnedKcal: burned,
                kcalGoal: 2000,
                streak: streak,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return overflows;
}

/// Font size the text actually renders with (style x scaler).
double _renderedFontSize(WidgetTester tester, Finder text) {
  final element = tester.element(text);
  final style = tester.widget<Text>(text).style!;
  return MediaQuery.textScalerOf(element).scale(style.fontSize!);
}

void main() {
  testWidgets('Kacheln tragen keine FittedBox mehr, die Hero-Zahl schon',
      (tester) async {
    await _pumpHero(tester, scale: 1.0);
    for (final tile in _tiles) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>(tile)),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
        reason: '$tile schrumpft Text statt ihn zu skalieren',
      );
    }
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('today-kcal-remaining')),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bei 1.3 stehen die Kacheln nebeneinander, Labels skalieren mit',
      (tester) async {
    final overflows = await _pumpHero(tester, scale: 1.3);
    expect(overflows, isEmpty, reason: overflows.join('\n'));

    final tops = _tiles
        .map((k) => tester.getTopLeft(find.byKey(ValueKey<String>(k))).dy)
        .toList();
    expect(tops[1], moreOrLessEquals(tops[0], epsilon: 0.5));
    expect(tops[2], moreOrLessEquals(tops[0], epsilon: 0.5));

    final label = find.descendant(
      of: find.byKey(const ValueKey('today-stat-streak')),
      matching: find.text('TAGE-STREAK'),
    );
    expect(label, findsOneWidget);
    expect(_renderedFontSize(tester, label), moreOrLessEquals(10.5 * 1.3));
  });

  testWidgets('bei 2.0 stapeln sich die Kacheln statt zu schrumpfen',
      (tester) async {
    final overflows = await _pumpHero(
      tester,
      scale: 2.0,
      consumed: 12345,
      burned: 1234,
      streak: 365,
    );
    expect(overflows, isEmpty, reason: overflows.join('\n'));

    final tops = _tiles
        .map((k) => tester.getTopLeft(find.byKey(ValueKey<String>(k))).dy)
        .toList();
    expect(tops[1], greaterThan(tops[0]));
    expect(tops[2], greaterThan(tops[1]));

    // No mid-word wrap: each text stays on one line at its real size.
    for (final fall in const <List<String>>[
      <String>['today-stat-eaten', '12.345', 'GEGESSEN'],
      <String>['today-stat-burned', '1.234', 'VERBRANNT'],
      <String>['today-stat-streak', '365', 'TAGE-STREAK'],
    ]) {
      for (final text in <String>[fall[1], fall[2]]) {
        final zeile = find.descendant(
          of: find.byKey(ValueKey<String>(fall[0])),
          matching: find.text(text),
        );
        expect(zeile, findsOneWidget);
        expect(
          tester.getSize(zeile).height,
          lessThan(_renderedFontSize(tester, zeile) * 1.6),
          reason: '„$text" ist in ${fall[0]} umgebrochen',
        );
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('die Restzahl schrumpft in $brightness weiterhin per FittedBox',
        (tester) async {
      final overflows = await _pumpHero(
        tester,
        scale: 2.0,
        consumed: 12345,
        burned: 1234,
        brightness: brightness,
      );
      expect(overflows, isEmpty, reason: overflows.join('\n'));
      final hero = find.byKey(const ValueKey('today-kcal-hero'));
      final kasten = find
          .ancestor(
            of: find.byKey(const ValueKey('today-kcal-remaining')),
            matching: find.byType(FittedBox),
          )
          .first;
      expect(tester.widget<FittedBox>(kasten).fit, BoxFit.scaleDown);
      expect(
        tester.getSize(kasten).width,
        lessThanOrEqualTo(tester.getSize(hero).width),
      );
    });
  }
}
