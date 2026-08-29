import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

import '../support/harness.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));
final AppLocalizations _en = lookupAppLocalizations(const Locale('en'));

// meal_analyzer.dart puts explicit .timeout(...) on request completion and
// body read, so a hanging LLM provider reaches the analysis sheet as a
// TimeoutException. The user must then see an honest "takes too long"
// message, not the generic one implying a broken connection. Since the
// 2026-08-27 fix run the analyzer also throws typed MealAnalysisExceptions,
// which the sheet resolves to ARB texts at display time (F4-01/F9-03).

const String _fallback =
    'Die Analyse hat nicht geklappt. Prüfe deine Internetverbindung und '
    'versuch es nochmal.';
const String _timeoutText =
    'Das dauert gerade zu lange. Bitte versuch es gleich nochmal.';

const String _barcodeFallback =
    'Barcode 4001724012345 nicht gefunden oder OpenFoodFacts nicht erreichbar.';

Widget _sheetHost(
  Future<MealAnalysisResult> resultFuture, {
  String failureMessage = _fallback,
  String Function(MealAnalysisResult, MealSlot)? onAdd,
}) {
  return localizedApp(
    MealAnalysisSheet(
      slot: MealSlot.lunch,
      resultFuture: resultFuture,
      previewImage: null,
      onAdd: onAdd ?? (_, __) => '',
      onUpdateMeal: (_, __) {},
      failureMessage: failureMessage,
    ),
    // Motion as before the migration.
    reducedMotion: false,
    safeArea: false,
  );
}

/// A photo-AI result without calories. Search and barcode no longer deliver
/// this (their service throws), but the photo path bypasses that filter.
const _ohneKalorien = MealAnalysisResult(
  mealName: 'Unklarer Teller',
  caloriesKcal: 0,
  estimatedGrams: 250,
  kcalPer100G: 0,
  protein: '-',
  carbs: '-',
  fat: '-',
  confidence: 'Niedrig',
  portionNotes: 'Das Modell konnte nichts Belastbares schaetzen.',
  sourceLabel: 'Foto-KI',
);

/// The same result with calories — the counter-check for the guard.
const _mitKalorien = MealAnalysisResult(
  mealName: 'Klarer Teller',
  caloriesKcal: 420,
  estimatedGrams: 250,
  kcalPer100G: 168,
  protein: '20 g',
  carbs: '40 g',
  fat: '15 g',
  confidence: 'Mittel',
  portionNotes: 'Normale Schaetzung.',
  sourceLabel: 'Foto-KI',
);

void main() {
  group('mealAnalysisErrorMessage', () {
    test('TimeoutException -> freundliche Timeout-Meldung', () {
      final error =
          TimeoutException('Future not completed', const Duration(seconds: 60));
      expect(mealAnalysisErrorMessage(error, _fallback, _de), _timeoutText);
    });

    test('untypisierte Fehler -> generische Meldung des jeweiligen Flows', () {
      expect(
        mealAnalysisErrorMessage(const HttpException('boom'), _fallback, _de),
        _fallback,
      );
      expect(
        mealAnalysisErrorMessage(
            const FormatException('bad'), _fallback, _de),
        _fallback,
      );
    });

    test('SocketException -> Verbindungsmeldung', () {
      expect(
        mealAnalysisErrorMessage(
            const SocketException('no route'), _fallback, _de),
        _de.foodAnalysisOfflineMessage,
      );
    });

    // F4-01: the typed errors reach the user with THEIR message, not the
    // generic one — and in the display language, not the server's German.
    test('typisierte Fehler -> spezifische ARB-Texte in beiden Sprachen', () {
      expect(
        mealAnalysisErrorMessage(
            const MealAnalysisReauthRequired(), _fallback, _de),
        _de.foodReauthRequiredError,
      );
      expect(
        mealAnalysisErrorMessage(
            const MealAnalysisReauthRequired(), _fallback, _en),
        _en.foodReauthRequiredError,
      );
      expect(
        mealAnalysisErrorMessage(const MealImageTooLarge(), _fallback, _de),
        _de.foodImageTooLargeError,
      );
      expect(
        mealAnalysisErrorMessage(
            const MealAnalysisRateLimited(), _fallback, _de),
        _de.foodAnalysisRateLimitError,
      );
      expect(
        mealAnalysisErrorMessage(
            const MealAnalysisRateLimited(), _fallback, _en),
        _en.foodAnalysisRateLimitError,
      );
    });

    test('429 mit resetAt in der Zukunft nennt die Uhrzeit (lokal)', () {
      final now = DateTime(2026, 8, 27, 14, 5);
      withClock(Clock.fixed(now), () {
        final resetAt = now.add(const Duration(minutes: 37));
        final text = mealAnalysisErrorMessage(
          MealAnalysisRateLimited(resetAt: resetAt),
          _fallback,
          _de,
        );
        expect(text, _de.foodAnalysisRateLimitUntilMessage('14:42'));
        expect(text, contains('14:42'));
      });
    });

    test('429 mit resetAt in der Vergangenheit -> Standardtext', () {
      final now = DateTime(2026, 8, 27, 14, 5);
      withClock(Clock.fixed(now), () {
        final text = mealAnalysisErrorMessage(
          MealAnalysisRateLimited(
              resetAt: now.subtract(const Duration(minutes: 1))),
          _fallback,
          _de,
        );
        expect(text, _de.foodAnalysisRateLimitError);
      });
    });

    // F9-03: the server's `error` codes are mapped client-side; `message`
    // (German) is never shown.
    test('Server-Codes -> ARB-Keys, message bleibt Debug', () {
      String map(String code, [AppLocalizations? l10n]) =>
          mealAnalysisErrorMessage(
            MealAnalysisServerError(
              statusCode: 502,
              code: code,
              debugMessage: 'Analyse konnte nicht abgeschlossen werden.',
            ),
            _fallback,
            l10n ?? _de,
          );

      // P6-01c: `request_timeout` (408) is the server's answer to a body that
      // trickles in — the same situation as `provider_timeout` from the
      // user's side, so it gets the same text, not the generic fallback.
      for (final code in const ['provider_timeout', 'request_timeout']) {
        expect(map(code), _de.foodAnalysisTimeoutMessage, reason: code);
        expect(map(code, _en), _en.foodAnalysisTimeoutMessage, reason: code);
        expect(map(code), isNot(_fallback), reason: code);
      }
      for (final code in const [
        'provider_error',
        'provider_invalid_response',
        'provider_invalid_json',
        'provider_empty_response',
        // P6-06: the server rejects an answer that carries no usable value at
        // all instead of delivering it as a 200 full of nulls.
        'provider_unusable_result',
        'invalid_result',
      ]) {
        expect(map(code), _de.foodAnalysisProviderErrorMessage,
            reason: code);
        expect(map(code, _en), _en.foodAnalysisProviderErrorMessage,
            reason: code);
      }
      for (final code in const [
        'rate_limit_unavailable',
        'internal_error',
        'server_misconfigured',
        'provider_not_configured',
      ]) {
        expect(map(code), _de.foodAnalysisServiceUnavailableMessage,
            reason: code);
      }
      for (final code in const [
        'missing_image',
        'invalid_image_base64',
        'image_too_small',
      ]) {
        expect(map(code), _de.foodAnalysisImageUnusableMessage, reason: code);
      }
      // Unknown code: the flow's fallback, never the raw server message.
      expect(map('something_new'), _fallback);
      expect(map('something_new'), isNot(contains('Analyse konnte')));
    });

    test('kein Text nennt Infrastruktur beim Namen', () {
      for (final l10n in [_de, _en]) {
        for (final text in [
          l10n.foodAnalysisFailedMessage,
          l10n.foodAnalysisProviderErrorMessage,
          l10n.foodAnalysisServiceUnavailableMessage,
          l10n.foodAnalysisOfflineMessage,
        ]) {
          expect(text, isNot(contains('Supabase')));
          expect(text, isNot(contains('OpenRouter')));
        }
      }
    });

    // B7: the service knows the product exists but carries no loggable
    // nutrition, so "not found" would be a lie — the user is holding it.
    test('ProductWithoutNutritionException -> die Meldung des Fehlers selbst',
        () {
      const ohneAngabe = ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Die Ofenfrische Salami',
        kcalPer100G: 0,
      );
      expect(
        mealAnalysisErrorMessage(ohneAngabe, _barcodeFallback, _de),
        'Die Ofenfrische Salami gefunden, aber ohne Nährwertangaben. '
        'Bitte manuell eintragen.',
      );
      expect(
        mealAnalysisErrorMessage(ohneAngabe, _barcodeFallback, _de),
        isNot(_barcodeFallback),
      );
    });

    test('unplausible Angabe nennt den gemessenen Wert', () {
      const unplausibel = ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Nussmus',
        kcalPer100G: 2180,
      );
      expect(unplausibel.isImplausible, isTrue);
      expect(
        mealAnalysisErrorMessage(unplausibel, _barcodeFallback, _de),
        'Nussmus gefunden, aber die Nährwertangabe ist unplausibel '
        '(2180 kcal / 100 g). Bitte manuell eintragen.',
      );
    });
  });

  testWidgets(
      'Analyse-Sheet zeigt bei fehlenden Naehrwerten die Produkt-Meldung',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(
      _sheetHost(completer.future, failureMessage: _barcodeFallback),
    );

    completer.completeError(
      const ProductWithoutNutritionException(
        barcode: '4001724012345',
        productName: 'Die Ofenfrische Salami',
        kcalPer100G: 0,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Die Ofenfrische Salami gefunden, aber ohne Nährwertangaben. '
        'Bitte manuell eintragen.',
      ),
      findsOneWidget,
    );
    expect(find.text(_barcodeFallback), findsNothing);
  });

  // W2-08's last brake: `_addToDaily` called `onAdd` unconditionally. Search
  // and barcode deliver nothing unloggable any more, but the photo-AI path
  // bypasses that filter.
  group('Guard vor onAdd', () {
    testWidgets('0 kcal wird nicht geloggt — und der Nutzer erfaehrt warum',
        (tester) async {
      var aufrufe = 0;
      await tester.pumpWidget(
        _sheetHost(
          Future<MealAnalysisResult>.value(_ohneKalorien),
          onAdd: (_, __) {
            aufrufe++;
            return 'id';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
      await tester.pump();
      await tester.pump();

      expect(aufrufe, 0, reason: 'nichts Unloggbares darf ins Tagebuch');
      // No silent abort: the reason and the next step are on screen.
      expect(
        find.textContaining('Ohne Kalorienangabe'),
        findsOneWidget,
      );
      expect(find.textContaining('Anpassen'), findsWidgets);
      // The button stays usable — it must work once the values are added.
      expect(find.text('Zu heute hinzugefügt'), findsNothing);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('mit Kalorien laeuft der Weg unveraendert durch',
        (tester) async {
      var aufrufe = 0;
      await tester.pumpWidget(
        _sheetHost(
          Future<MealAnalysisResult>.value(_mitKalorien),
          onAdd: (_, __) {
            aufrufe++;
            return 'id';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('analyse-add-daily-button')));
      await tester.pump();
      await tester.pump();

      expect(aufrufe, 1);
      expect(find.text('Zu heute hinzugefügt'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  // F4-02: errors live IN the sheet now (error card, no snack, no auto-pop).
  testWidgets('Analyse-Sheet zeigt bei Timeout die Timeout-Meldung im Sheet',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(_sheetHost(completer.future));

    completer.completeError(
      TimeoutException('Future not completed', const Duration(seconds: 60)),
    );
    await tester.pump(); // process the error
    await tester.pump(); // render the card

    expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
    expect(find.text(_timeoutText), findsOneWidget);
    expect(find.text(_fallback), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('Analyse-Sheet zeigt bei untypisierten Fehlern die Flow-Meldung',
      (tester) async {
    final completer = Completer<MealAnalysisResult>();
    await tester.pumpWidget(_sheetHost(completer.future));

    completer.completeError(const HttpException('provider down'));
    await tester.pump();
    await tester.pump();

    expect(find.text(_fallback), findsOneWidget);
    expect(find.text(_timeoutText), findsNothing);
  });

  testWidgets('Analyse-Sheet zeigt 401/429/413 mit ihrem eigenen Text',
      (tester) async {
    for (final (error, expected) in <(Object, String)>[
      (const MealAnalysisReauthRequired(), _de.foodReauthRequiredError),
      (const MealAnalysisRateLimited(), _de.foodAnalysisRateLimitError),
      (const MealImageTooLarge(), _de.foodImageTooLargeError),
    ]) {
      // Fresh tree per case: the same widget type in the same slot would
      // keep its State and never listen to the new future. No MaterialApp
      // in between — its theme would lerp from a token-less default.
      await tester.pumpWidget(const SizedBox.shrink());
      final completer = Completer<MealAnalysisResult>();
      await tester.pumpWidget(_sheetHost(completer.future));
      completer.completeError(error);
      await tester.pump();
      await tester.pump();

      expect(find.text(expected), findsOneWidget, reason: '$error');
      expect(find.text(_fallback), findsNothing, reason: '$error');
    }
  });
}
