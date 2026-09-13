import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/health_service.dart';

import '../support/harness.dart';
import 'flow_test_helpers.dart' show storeOf;

final _today = DateTime(2026, 9, 13, 18);

class _MeasuredSteps extends NoopHealthService {
  @override
  HealthAuthState get authState => HealthAuthState.granted;

  @override
  Future<HealthAuthState> requestAuthorization() async => authState;

  @override
  Future<HealthSnapshot> readSnapshot() async =>
      HealthSnapshot(stepsToday: 7000, fetchedAt: _today);
}

Future<void> _loadFonts() async {
  for (final family in ['Archivo', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final file in Directory('assets/fonts').listSync().whereType<File>()) {
      if (file.uri.pathSegments.last.startsWith('$family-')) {
        loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      }
    }
    await loader.load();
  }
}

Future<void> _pumpToday(
  WidgetTester tester, {
  required Size size,
  required EdgeInsets insets,
  required Locale locale,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = FakeViewPadding(top: insets.top, bottom: insets.bottom);
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    localizedApp(
      EatovaHomePage(healthService: _MeasuredSteps()),
      locale: locale,
      brightness: Brightness.light,
      textScale: textScale,
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
  // Include the activity and streak lines, which make the hero taller.
  final store = storeOf(tester);
  store.lifetimeStats = LifetimeStats(
    currentStreak: 7,
    lastTrackedDate: _today,
    sessionStart: _today,
  );
  await store.refreshHealthSteps();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  for (final locale in [const Locale('de'), const Locale('en')]) {
    for (final (name, size, insets) in [
      (
        'iPhone',
        const Size(390, 844),
        const EdgeInsets.only(top: 59, bottom: 34),
      ),
      (
        'Android',
        const Size(412, 892),
        const EdgeInsets.only(top: 24, bottom: 24),
      ),
    ]) {
      testWidgets(
        'complete steps card fits before the add action: $name $locale',
        (tester) async {
          await withClock(Clock.fixed(_today), () async {
            await _pumpToday(
              tester,
              size: size,
              insets: insets,
              locale: locale,
            );
            final scrollable = find.descendant(
              of: find.byKey(const ValueKey('screen-today')),
              matching: find.byType(Scrollable),
            );
            expect(
              tester.state<ScrollableState>(scrollable).position.pixels,
              0,
            );
            final steps = tester.getRect(
              find.byKey(const ValueKey('today-steps-card')),
            );
            final viewport = tester.getRect(
              find.byKey(const ValueKey('screen-today')),
            );
            final action = tester.getRect(
              find.byKey(const ValueKey('today-add-meal')),
            );
            expect(steps.top, greaterThanOrEqualTo(viewport.top));
            expect(
              steps.bottom,
              lessThanOrEqualTo(viewport.bottom),
              reason:
                  'The entire card, including bottom padding, must be visible before scrolling.',
            );
            expect(steps.bottom, lessThan(action.top));
            expect(action.height, greaterThanOrEqualTo(48));
            for (final key in ['today-date-prev', 'today-date-next']) {
              final target = tester.getSize(find.byKey(ValueKey(key)));
              expect(target.width, greaterThanOrEqualTo(44));
              expect(target.height, greaterThanOrEqualTo(44));
            }
            expect(tester.takeException(), isNull);
          });
        },
      );
    }
  }

  for (final locale in [const Locale('de'), const Locale('en')]) {
    testWidgets(
      'small phones with double text scroll to complete steps: $locale',
      (tester) async {
        await withClock(Clock.fixed(_today), () async {
          await _pumpToday(
            tester,
            size: const Size(320, 568),
            insets: const EdgeInsets.only(top: 20),
            locale: locale,
            textScale: 2,
          );
          final scrollable = find.descendant(
            of: find.byKey(const ValueKey('screen-today')),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('today-steps-card')),
            200,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          final steps = tester.getRect(
            find.byKey(const ValueKey('today-steps-card')),
          );
          final viewport = tester.getRect(
            find.byKey(const ValueKey('screen-today')),
          );
          expect(steps.top, greaterThanOrEqualTo(viewport.top));
          expect(steps.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(
            find.byKey(const ValueKey('today-add-meal')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      },
    );
  }
}
