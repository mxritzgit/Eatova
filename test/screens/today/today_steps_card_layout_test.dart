import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/today/today_sections.dart';

import '../../support/harness.dart';
import '../../support/today_summary.dart';

const _row = ValueKey('today-steps-card');
const _value = ValueKey('today-steps-value');
const _goal = ValueKey('today-steps-goal');
const _kcal = ValueKey('today-steps-kcal');

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

void main() {
  setUpAll(_loadFonts);

  for (final locale in [const Locale('de'), const Locale('en')]) {
    for (final width in [375.0, 430.0]) {
      testWidgets('steps, goal and credit share one line at $width / $locale', (
        tester,
      ) async {
        await pumpLocalized(
          tester,
          TodayScreen(
            userName: 'Moritz',
            profile: const UserProfile(),
            summary: todaySummary(
              profile: const UserProfile(),
              consumedKcal: 1420,
              burnedKcal: 261,
              macroProgress: MacroProgress.empty,
            ),
            meals: const [],
            selectedDate: DateTime(2026, 9, 8),
            streak: 3,
            steps: 7000,
          ),
          surfaceSize: Size(width, 852),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          locale: locale,
          settle: true,
        );

        final tile = tester.getRect(
          find
              .descendant(
                of: find.byKey(_row),
                matching: find.byType(Container),
              )
              .first,
        );
        final value = tester.getRect(find.byKey(_value));
        final goal = tester.getRect(find.byKey(_goal));
        final kcal = tester.getRect(find.byKey(_kcal));
        expect(value.left, greaterThan(tile.right));
        expect(goal.left, greaterThan(value.right));
        expect(kcal.left, greaterThan(goal.left));
        // One line: the credit sits on the value's line, right-aligned.
        expect(kcal.bottom, closeTo(value.bottom, 6));
        expect(
          kcal.right,
          closeTo(tester.getRect(find.byKey(_row)).right, 0.5),
        );
        expect(
          tester.getRect(find.byKey(_row)).top,
          greaterThan(
            tester
                .getRect(find.byKey(const ValueKey('today-meals-card')))
                .bottom,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('steps remain readable at 320 px / 2x / $locale', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        const SingleChildScrollView(
          child: TodayStepsRow(steps: 1234567, goal: 9999999, burnedKcal: 4321),
        ),
        surfaceSize: const Size(320, 852),
        padding: const EdgeInsets.all(20),
        locale: locale,
        textScale: 2,
        settle: true,
      );
      final row = tester.getRect(find.byKey(_row));
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: find.byKey(_row), matching: find.byType(RichText)),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse);
        final topLeft = paragraph.localToGlobal(Offset.zero);
        expect(row.contains(topLeft), isTrue);
        expect(
          row.contains(
            topLeft +
                Offset(
                  paragraph.size.width - 0.01,
                  paragraph.size.height - 0.01,
                ),
          ),
          isTrue,
        );
      }
      // Too narrow for one line: the credit moves under the steps.
      expect(
        tester.getRect(find.byKey(_kcal)).top,
        greaterThanOrEqualTo(tester.getRect(find.byKey(_value)).bottom),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
