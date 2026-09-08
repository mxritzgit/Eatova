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
import 'package:eatova/src/widgets/design/steps_icon.dart';

import '../../support/harness.dart';

const _card = ValueKey('today-steps-card');
const _subtitle = ValueKey('today-steps-subtitle');
const _value = ValueKey('today-steps-value');

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

void main() {
  setUpAll(_loadFonts);

  for (final locale in [const Locale('de'), const Locale('en')]) {
    for (final width in [375.0, 430.0]) {
      testWidgets(
        'steps explanation stays beside the icon at $width / $locale',
        (tester) async {
          await pumpLocalized(
            tester,
            TodayScreen(
              userName: 'Moritz',
              profile: const UserProfile(),
              consumedKcal: 1420,
              burnedKcal: 261,
              macroProgress: MacroProgress.empty,
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

          final title = tester.getRect(
            find.descendant(
              of: find.byKey(_card),
              matching: find.text(
                locale.languageCode == 'de' ? 'Schritte' : 'Steps',
              ),
            ),
          );
          final subtitle = tester.getRect(find.byKey(_subtitle));
          final value = tester.getRect(find.byKey(_value));
          final icon = tester.getRect(find.byType(StepsIcon));
          expect(
            subtitle.left,
            closeTo(title.left, 0.5),
            reason: 'Calories belong under the title, not under the icon.',
          );
          expect(subtitle.top - title.bottom, closeTo(2, 0.5));
          expect(subtitle.left, greaterThan(icon.right));
          expect(value.left, greaterThan(subtitle.right));
          expect(
            subtitle.height,
            lessThan(19),
            reason: 'The normal phone layout has room for one subtitle line.',
          );
          expect(
            tester.getRect(find.byKey(_card)).top,
            greaterThan(
              tester
                  .getRect(find.byKey(const ValueKey('today-kcal-hero')))
                  .bottom,
            ),
          );
          expect(
            tester.getRect(find.byKey(_card)).bottom,
            lessThan(
              tester
                  .getRect(find.byKey(const ValueKey('today-macros-card')))
                  .top,
            ),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('steps remain readable at 320 px / 2x / $locale', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        const SingleChildScrollView(
          child: TodayStepsCard(
            steps: 1234567,
            goal: 9999999,
            burnedKcal: 4321,
          ),
        ),
        surfaceSize: const Size(320, 852),
        padding: const EdgeInsets.all(20),
        locale: locale,
        textScale: 2,
        settle: true,
      );
      final card = tester.getRect(find.byKey(_card));
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: find.byKey(_card), matching: find.byType(RichText)),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse);
        final topLeft = paragraph.localToGlobal(Offset.zero);
        expect(card.contains(topLeft), isTrue);
        expect(
          card.contains(
            topLeft + Offset(paragraph.size.width, paragraph.size.height),
          ),
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
