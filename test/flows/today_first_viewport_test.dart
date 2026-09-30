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
  for (final family in ['Figtree', 'BricolageGrotesque']) {
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

/// The design (2026-09-28) supersedes the 2026-09-13 promise "complete steps
/// card in the first viewport": activity now sits below the meals. The new
/// first-viewport contract is the design's top: header, the 7-day strip and
/// the complete calorie card, visible at scroll offset 0 above the glass bar.
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
        'header, day strip and calorie card fit the first view: $name $locale',
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
            final viewport = tester.getRect(
              find.byKey(const ValueKey('screen-today')),
            );
            // The glass bar covers the bottom of the page; "visible" means
            // above it.
            final glassTop = tester
                .getRect(find.byKey(const ValueKey('nav-glass')))
                .top;
            final header = tester.getRect(
              find.byKey(const ValueKey('today-date-selected-label')),
            );
            final avatar = tester.getRect(
              find.byKey(const ValueKey('today-profile')),
            );
            final strip = tester.getRect(
              find.byKey(const ValueKey('today-date-strip')),
            );
            final card = tester.getRect(
              find.byKey(const ValueKey('today-kcal-hero')),
            );
            expect(header.top, greaterThanOrEqualTo(viewport.top));
            expect(avatar.top, greaterThanOrEqualTo(viewport.top));
            expect(strip.top, greaterThan(header.bottom));
            expect(card.top, greaterThan(strip.bottom));
            expect(
              card.bottom,
              lessThanOrEqualTo(glassTop),
              reason: 'The entire calorie card, stats included, must be '
                  'visible before scrolling.',
            );
            // All seven days are on screen and full touch targets.
            for (var back = 0; back < 7; back++) {
              final day = DateTime(2026, 9, 13 - back);
              final key = ValueKey(
                'today-day-2026-09-${day.day.toString().padLeft(2, '0')}',
              );
              final cell = find.byKey(key);
              expect(cell.hitTestable(), findsOneWidget, reason: '$key');
              final target = tester.getSize(cell);
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
      'small phones with double text scroll to the complete card: $locale',
      (tester) async {
        await withClock(Clock.fixed(_today), () async {
          await _pumpToday(
            tester,
            size: const Size(320, 568),
            insets: const EdgeInsets.only(top: 20),
            locale: locale,
            textScale: 2,
          );
          // Brought into view from its top, the whole card fits the scroll
          // viewport, stats included.
          await tester.ensureVisible(
            find.byKey(const ValueKey('today-kcal-hero')),
          );
          await tester.pumpAndSettle();
          final card = tester.getRect(
            find.byKey(const ValueKey('today-kcal-hero')),
          );
          final viewport = tester.getRect(
            find.byKey(const ValueKey('screen-today')),
          );
          expect(card.top, greaterThanOrEqualTo(viewport.top));
          expect(card.bottom, lessThanOrEqualTo(viewport.bottom));
          // At 2x on 568 px the card is taller than the space above the
          // glass bar; a short scroll brings its last stat above the bar.
          final stat = find.byKey(const ValueKey('today-stat-burned'));
          final scrollable = find.descendant(
            of: find.byKey(const ValueKey('screen-today')),
            matching: find.byType(Scrollable),
          );
          for (var i = 0; i < 10 && stat.hitTestable().evaluate().isEmpty; i++) {
            await tester.drag(scrollable, const Offset(0, -60));
            await tester.pumpAndSettle();
          }
          expect(stat.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      },
    );
  }
}
