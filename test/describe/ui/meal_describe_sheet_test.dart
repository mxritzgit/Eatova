// Describe sheet: text input, the working step with its errors, the draft
// (origins, candidates, removal), Add and Edit, the discard guard, and the
// 320 px / 2x text layout.

import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_describe_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';

import '../../support/meal_slot_picker.dart';
import 'describe_fakes.dart';
import 'describe_harness.dart';

String _plain(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).textSpan!.toPlainText();

Finder _inLine(int index, Finder matching) =>
    find.descendant(of: key('meal-describe-line-$index'), matching: matching);

Future<void> _openLine(WidgetTester tester, int index) async {
  await tester.ensureVisible(key('meal-describe-line-$index'));
  await tester.pumpAndSettle();
  await tester.tap(key('meal-describe-line-$index'));
  await tester.pumpAndSettle();
  expect(key('describe-line-editor'), findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

void main() {
  group('input', () {
    for (final locale in const [Locale('de'), Locale('en')]) {
      testWidgets('submit sends the text once, in the app language: $locale', (
        tester,
      ) async {
        final h = await openDescribe(tester, locale: locale);
        expect(enabled(tester, describeSubmit), isFalse);
        await tester.enterText(describeInput, 'N');
        await tester.pump();
        expect(enabled(tester, describeSubmit), isFalse, reason: 'min 2');
        await tester.enterText(describeInput, '  Nutella auf Toast  ');
        await tester.pump();
        expect(enabled(tester, describeSubmit), isTrue);

        await tester.tap(describeSubmit);
        await tester.pumpAndSettle();

        expect(h.describer.calls, hasLength(1));
        expect(h.describer.calls.single.text, 'Nutella auf Toast');
        expect(h.describer.calls.single.language, locale.languageCode);
        expect(h.matcher.calls, hasLength(1));
        expect(key('meal-describe-line-0'), findsOneWidget);
        expect(h.logged, isEmpty, reason: 'nothing logs before Add');
      });
    }

    testWidgets('the field refuses typing past 500 characters', (tester) async {
      await openDescribe(tester);
      await tester.enterText(describeInput, 'a' * 500);
      await tester.pump();
      expect(fieldText(tester), hasLength(500));
      expect(key('meal-describe-length'), findsOneWidget);
      await tester.enterText(describeInput, 'a' * 501);
      await tester.pump();
      expect(fieldText(tester), hasLength(500));
      expect(enabled(tester, describeSubmit), isTrue);
    });

    testWidgets('no_food_in_text keeps the text and says why', (tester) async {
      final h = await openDescribe(tester);
      h.describer.error = const MealAnalysisServerError(
        statusCode: 422,
        code: 'no_food_in_text',
      );
      await describe(tester, 'Heute war ein schöner Tag');

      expect(describeInput, findsOneWidget);
      expect(fieldText(tester), 'Heute war ein schöner Tag');
      expect(find.text(l10nOf(tester).foodDescribeNoFood), findsOneWidget);
      expect(enabled(tester, describeSubmit), isTrue);
      // Editing answers the hint.
      await tester.enterText(describeInput, 'Zwei Eier');
      await tester.pump();
      expect(key('meal-describe-notice'), findsNothing);
    });

    testWidgets('a typed description asks before it is discarded', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      await tester.enterText(describeInput, 'Porridge');
      await tester.pump();
      await tester.tap(key('meal-describe-close'));
      await tester.pumpAndSettle();
      expect(key('describe-discard-dialog'), findsOneWidget);
      await tester.tap(key('describe-discard-cancel'));
      await tester.pumpAndSettle();
      expect(key('meal-describe-sheet'), findsOneWidget);
      expect(fieldText(tester), 'Porridge');

      await tester.tap(key('meal-describe-close'));
      await tester.pumpAndSettle();
      await tester.tap(key('describe-discard-confirm'));
      await tester.pumpAndSettle();
      expect(key('meal-describe-sheet'), findsNothing);
      expect(h.closed, isTrue);
      expect(h.outcome, isNull);
    });

    testWidgets('an empty sheet closes without asking', (tester) async {
      final h = await openDescribe(tester);
      await tester.tap(key('meal-describe-close'));
      await tester.pumpAndSettle();
      expect(key('describe-discard-dialog'), findsNothing);
      expect(h.closed, isTrue);
    });
  });

  group('working', () {
    testWidgets('cancel while loading cancels the request and keeps the text', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      h.describer.pending = Completer();
      await tester.enterText(describeInput, 'Döner mit allem');
      await tester.pump();
      await tester.tap(describeSubmit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(key('meal-describe-working'), findsOneWidget);
      expect(key('meal-describe-slow-hint'), findsNothing);
      await tester.pump(const Duration(seconds: 13));
      expect(key('meal-describe-slow-hint'), findsOneWidget);

      await tester.tap(key('meal-describe-cancel'));
      await tester.pumpAndSettle();
      expect(h.describer.calls.single.cancellation!.isCancelled, isTrue);
      expect(key('meal-describe-working'), findsNothing);
      expect(fieldText(tester), 'Döner mit allem');
      expect(h.matcher.calls, isEmpty);
    });

    testWidgets('rate limit and re-auth speak of a meal, never retried', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      final l10n = l10nOf(tester);
      h.describer.error = const MealAnalysisRateLimited();
      await describe(tester, 'Müsli mit Milch');
      expect(find.text(l10n.foodDescribeRateLimit), findsOneWidget);
      expect(key('meal-describe-retry'), findsNothing);

      await tester.tap(key('meal-describe-edit-text'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Müsli mit Milch');

      h.describer.error = const MealAnalysisReauthRequired();
      await tester.tap(describeSubmit);
      await tester.pumpAndSettle();
      expect(find.text(l10n.foodDescribeReauthRequired), findsOneWidget);
      expect(key('meal-describe-retry'), findsNothing);
    });

    // The photo scan's texts speak of a photo; none of them may reach the
    // description, in either language.
    for (final (lang, l10n, photoWords) in [
      ('de', deL10n, RegExp('Foto|Bild', caseSensitive: false)),
      ('en', enL10n, RegExp('photo|image|picture', caseSensitive: false)),
    ]) {
      test('$lang: every describe error is about a meal, not a photo', () {
        withClock(Clock.fixed(DateTime(2026, 10, 10, 12)), () {
          final errors = <Object, String>{
            const MealAnalysisReauthRequired(): l10n.foodDescribeReauthRequired,
            const MealAnalysisRateLimited(): l10n.foodDescribeRateLimit,
            MealAnalysisRateLimited(resetAt: DateTime(2026, 10, 10, 13, 30)):
                l10n.foodDescribeRateLimitUntil('13:30'),
            const MealImageTooLarge(): l10n.foodAnalysisFailedMessage,
            for (final code in [
              'invalid_body',
              'missing_image',
              'invalid_image_base64',
              'image_too_small',
            ])
              MealAnalysisServerError(statusCode: 400, code: code):
                  l10n.foodAnalysisServiceUnavailableMessage,
            const MealAnalysisServerError(
              statusCode: 400,
              code: 'invalid_hint',
            ): l10n.foodAnalysisFailedMessage,
            const MealAnalysisServerError(
              statusCode: 502,
              code: 'provider_unusable_result',
            ): l10n.foodAnalysisProviderErrorMessage,
            const MealAnalysisServerError(
              statusCode: 504,
              code: 'provider_timeout',
            ): l10n.foodAnalysisTimeoutMessage,
            const SocketException('offline'): l10n.foodAnalysisOfflineMessage,
          };
          for (final MapEntry(key: error, value: expected) in errors.entries) {
            final message = mealDescribeErrorMessage(error, l10n);
            expect(message, expected, reason: '$error');
            expect(message, isNot(contains(photoWords)), reason: '$error');
          }
        });
      });
    }

    testWidgets('offline offers a retry that describes again', (tester) async {
      final h = await openDescribe(tester);
      h.describer.error = const SocketException('offline');
      await describe(tester, 'Pizza Margherita');
      expect(
        find.text(l10nOf(tester).foodAnalysisOfflineMessage),
        findsOneWidget,
      );
      h.describer.error = null;
      await _tapVisible(tester, key('meal-describe-retry'));
      await tester.pumpAndSettle();
      expect(h.describer.calls, hasLength(2));
      expect(key('meal-describe-line-0'), findsOneWidget);
    });

    testWidgets('a server error offers a retry', (tester) async {
      final h = await openDescribe(tester);
      h.describer.error = const MealAnalysisServerError(
        statusCode: 502,
        code: 'provider_error',
      );
      await describe(tester, 'Pizza Margherita');
      expect(
        find.text(l10nOf(tester).foodAnalysisProviderErrorMessage),
        findsOneWidget,
      );
      expect(key('meal-describe-retry'), findsOneWidget);
    });
  });

  group('draft', () {
    testWidgets('lines show their origin, grams and kcal; totals sum them', (
      tester,
    ) async {
      await openDescribe(tester);
      await describe(tester, 'Nutella auf einer Scheibe Toast von Lidl');
      final l10n = l10nOf(tester);

      expect(_inLine(0, find.text('Nutella')), findsOneWidget);
      expect(
        _inLine(0, find.text(l10n.foodDescribeOriginProduct)),
        findsOneWidget,
      );
      expect(_inLine(0, find.text('Ferrero · 15 g')), findsOneWidget);
      expect(
        _inLine(0, find.text('81 kcal', findRichText: true)),
        findsOneWidget,
      );
      expect(
        _inLine(1, find.text(l10n.foodDescribeOriginEstimate)),
        findsOneWidget,
      );
      expect(_inLine(1, find.text('25 g')), findsOneWidget);
      expect(_plain(tester, key('meal-describe-total-kcal')), '146 kcal');
    });

    testWidgets('the slot hint preselects the slot', (tester) async {
      final host = DescribeHost();
      host.matcher.draft = nutellaToastDraft(slotHint: MealSlot.breakfast);
      await openDescribe(tester, host: host, slot: MealSlot.dinner);
      await describe(tester, 'Zum Frühstück Nutella-Toast');
      expect(
        tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
        MealSlot.breakfast,
      );
    });

    testWidgets('switching a candidate updates grams and kcal', (tester) async {
      await openDescribe(tester);
      await describe(tester, 'Nutella auf einer Scheibe Toast von Lidl');
      await _openLine(tester, 1);
      await tester.tap(key('describe-candidate-0'));
      await tester.pump();
      // "1 Scheibe" follows the product's 26 g slice: 279 * 0.26 = 73.
      expect(_plain(tester, key('describe-line-kcal')), '73 kcal');
      expect(
        tester.widget<TextField>(key('describe-grams-input')).controller!.text,
        '26',
      );
      await _tapVisible(tester, key('describe-line-apply'));
      await tester.pumpAndSettle();

      expect(_inLine(1, find.text('Butter Toast')), findsOneWidget);
      expect(
        _inLine(1, find.text('73 kcal', findRichText: true)),
        findsOneWidget,
      );
      expect(_plain(tester, key('meal-describe-total-kcal')), '154 kcal');
    });

    testWidgets('the gram stepper re-portions; closing keeps the line', (
      tester,
    ) async {
      await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await _openLine(tester, 0);
      await tester.tap(key('describe-grams-plus'));
      await tester.pump();
      // 20 g of 539 kcal / 100 g.
      expect(_plain(tester, key('describe-line-kcal')), '108 kcal');
      await tester.enterText(key('describe-grams-input'), '0');
      await tester.pump();
      expect(key('describe-grams-hint'), findsOneWidget);
      expect(enabled(tester, key('describe-line-apply')), isFalse);
      // Closing without Apply leaves the draft alone.
      Navigator.of(tester.element(key('describe-line-editor'))).pop();
      await tester.pumpAndSettle();
      expect(_plain(tester, key('meal-describe-total-kcal')), '146 kcal');

      await _openLine(tester, 0);
      await tester.tap(key('describe-grams-plus'));
      await tester.pump();
      await _tapVisible(tester, key('describe-line-apply'));
      await tester.pumpAndSettle();
      expect(_inLine(0, find.text('Ferrero · 20 g')), findsOneWidget);
      expect(_plain(tester, key('meal-describe-total-kcal')), '173 kcal');
    });

    testWidgets('removing every line disables Add and Edit; undo restores', (
      tester,
    ) async {
      await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await _openLine(tester, 0);
      await _tapVisible(tester, key('describe-line-remove'));
      await tester.pumpAndSettle();
      expect(key('meal-describe-line-1'), findsNothing);
      expect(enabled(tester, key('meal-describe-add')), isTrue);
      // The line's name, not the product title "Nutella · Ferrero".
      expect(
        find.text(l10nOf(tester).foodDescribeLineRemoved('Nutella')),
        findsOneWidget,
      );

      await tester.tap(find.text(l10nOf(tester).commonUndo));
      await tester.pumpAndSettle();
      expect(key('meal-describe-line-1'), findsOneWidget);

      for (var i = 0; i < 2; i++) {
        await _openLine(tester, 0);
        await _tapVisible(tester, key('describe-line-remove'));
        await tester.pumpAndSettle();
      }
      expect(key('meal-describe-line-0'), findsNothing);
      expect(key('meal-describe-empty'), findsOneWidget);
      expect(enabled(tester, key('meal-describe-add')), isFalse);
      expect(
        tester.widget<SoftPillButton>(key('meal-describe-edit')).onTap,
        isNull,
      );
    });

    testWidgets('Add logs once with the chosen slot, also on a double tap', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await chooseMealSlot(tester, 'describe-slot-dinner');
      h.addGate = Completer<void>();

      await _tapVisible(tester, key('meal-describe-add'));
      await tester.pump();
      await tester.tap(key('meal-describe-add'), warnIfMissed: false);
      await tester.pump();
      expect(h.logged, hasLength(1));
      expect(h.logged.single.slot, MealSlot.dinner);
      expect(h.logged.single.result.caloriesKcal, 146);
      expect(h.logged.single.result.items, hasLength(2));

      h.addGate!.complete();
      await tester.pumpAndSettle();
      expect(h.logged, hasLength(1));
      expect(h.closed, isTrue);
      expect(h.outcome!.slot, MealSlot.dinner);
      expect(h.outcome!.result!.caloriesKcal, 146);
    });

    testWidgets('a failed save keeps the draft and allows another Add', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      h.addError = StateError('disk full');
      await _tapVisible(tester, key('meal-describe-add'));
      await tester.pumpAndSettle();
      expect(h.closed, isFalse);
      expect(h.logged, hasLength(1));
      expect(enabled(tester, key('meal-describe-add')), isTrue);
      h.addError = null;
      await _tapVisible(tester, key('meal-describe-add'));
      await tester.pumpAndSettle();
      expect(h.logged, hasLength(2));
      expect(h.closed, isTrue);
    });

    testWidgets('Edit opens the analysis sheet; adding there closes both', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await _tapVisible(tester, key('meal-describe-edit'));
      await tester.pumpAndSettle();
      expect(key('analyse-sheet'), findsOneWidget);
      expect(find.text('Nutella-Toast'), findsOneWidget);

      await _tapVisible(tester, key('analyse-add-daily-button'));
      await tester.pumpAndSettle();
      expect(h.logged, hasLength(1));
      expect(h.logged.single.slot, MealSlot.lunch);

      await tester.tap(key('analyse-sheet-close'));
      await tester.pumpAndSettle();
      expect(key('meal-describe-sheet'), findsNothing);
      expect(h.outcome!.result, isNull, reason: 'confirmed by the review');
      expect(h.outcome!.slot, MealSlot.lunch);
      expect(h.logged, hasLength(1));
    });

    testWidgets('Edit closed without adding keeps the draft', (tester) async {
      final h = await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await _tapVisible(tester, key('meal-describe-edit'));
      await tester.pumpAndSettle();
      await tester.tap(key('analyse-sheet-close'));
      await tester.pumpAndSettle();
      expect(key('meal-describe-line-0'), findsOneWidget);
      expect(h.logged, isEmpty);
    });

    testWidgets('editing the text goes back with the text kept', (
      tester,
    ) async {
      await openDescribe(tester);
      await describe(tester, 'Nutella auf Toast');
      await tester.tap(key('meal-describe-edit-description'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Nutella auf Toast');
      expect(key('meal-describe-line-0'), findsNothing);
    });
  });

  group('layout', () {
    for (final locale in const [Locale('de'), Locale('en')]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '320 px, 2x text, $locale, ${brightness.name}: no overflow',
          (tester) async {
            await openDescribe(
              tester,
              locale: locale,
              brightness: brightness,
              width: 320,
              textScale: 2,
            );
            expect(tester.takeException(), isNull);
            for (final id in [
              'meal-describe-close',
              'meal-describe-mic',
              'meal-describe-language',
              'meal-describe-submit',
            ]) {
              await tester.ensureVisible(key(id));
              await tester.pumpAndSettle();
              final size = tester.getSize(key(id));
              expect(size.height, greaterThanOrEqualTo(48), reason: id);
              expect(size.width, greaterThanOrEqualTo(48), reason: id);
            }

            await describe(tester, 'Nutella auf einer Scheibe Toast von Lidl');
            expect(tester.takeException(), isNull);
            for (final id in [
              'meal-describe-line-0',
              'meal-describe-line-1',
              'meal-describe-edit',
              'meal-describe-add',
            ]) {
              await tester.ensureVisible(key(id));
              await tester.pumpAndSettle();
              expect(
                tester.getSize(key(id)).height,
                greaterThanOrEqualTo(48),
                reason: id,
              );
            }
            await _openLine(tester, 1);
            await tester.ensureVisible(key('describe-line-remove'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
