import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart';

// Fix run 2026-08-27, F4-02: an analysis error no longer pops the sheet with
// a snack and loses the photo. The error lives in the sheet with "try again"
// (fresh future from the same bytes) and "enter manually"; after 12 s a
// "taking longer" line with cancel appears; dispose cancels the request.
//
// Errors are delivered through Completers AFTER the sheet listens: a
// `Future.error` built before `pumpWidget` is an unhandled error in the zone.

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

final Uint8List _preview = Uint8List.fromList(
  img.encodePng(img.Image(width: 2, height: 2)),
);

const _ergebnis = MealAnalysisResult(
  mealName: 'Bowl',
  caloriesKcal: 520,
  estimatedGrams: 300,
  kcalPer100G: 173,
  protein: '25 g',
  carbs: '55 g',
  fat: '20 g',
  confidence: 'Mittel',
  portionNotes: '',
  sourceLabel: 'Foto-KI',
);

Widget _host(
  Future<MealAnalysisResult> resultFuture, {
  Future<MealAnalysisResult> Function()? retry,
  MealAnalysisCancellation? cancellation,
  Uint8List? previewImage,
}) {
  return MealAnalysisSheet(
    slot: MealSlot.lunch,
    resultFuture: resultFuture,
    previewImage: previewImage,
    onAdd: (_, __) => 'id',
    onUpdateMeal: (_, __) {},
    failureMessage: _de.foodAnalysisFailedMessage,
    retry: retry,
    cancellation: cancellation,
  );
}

/// [_host] in the localized harness — the sheet sits directly in the body.
Future<void> _pumpHost(WidgetTester tester, Widget host) =>
    pumpLocalized(tester, host, reducedMotion: false, safeArea: false);

/// Frames plus microtasks without `pumpAndSettle`, whose loading-card
/// animation never settles.
Future<void> _flush(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
      'Fehler -> Karte im Sheet, Foto bleibt, "Erneut versuchen" startet '
      'einen zweiten Aufruf aus denselben Bytes', (tester) async {
    var retries = 0;
    final first = Completer<MealAnalysisResult>();
    final second = Completer<MealAnalysisResult>();
    await _pumpHost(tester, _host(
      first.future,
      retry: () {
        retries++;
        return second.future;
      },
      previewImage: _preview,
    ));
    await _flush(tester);
    expect(find.byType(MealLoadingCard), findsOneWidget);

    first.completeError(const MealAnalysisServerError(
      statusCode: 502,
      code: 'provider_error',
      debugMessage: 'Analyse konnte nicht abgeschlossen werden.',
    ));
    await _flush(tester);

    expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
    expect(find.text(_de.foodAnalysisProviderErrorMessage), findsOneWidget);
    expect(find.text('Analyse konnte nicht abgeschlossen werden.'),
        findsNothing, reason: 'Server-message ist nur Debug');
    expect(find.byType(MealPreviewCard), findsOneWidget,
        reason: 'das Foto bleibt im Sheet');
    expect(find.byType(SnackBar), findsNothing);
    // The sheet is still there (no auto-pop).
    expect(find.byType(MealAnalysisSheet), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyse-retry')));
    await _flush(tester);

    expect(retries, 1);
    expect(find.byType(MealLoadingCard), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-error')), findsNothing);

    second.complete(_ergebnis);
    await _flush(tester);

    expect(find.byType(MealResultCard), findsOneWidget);
    expect(find.text('Bowl'), findsWidgets);
  });

  testWidgets('zweiter Fehlschlag zeigt wieder die Karte, Retry bleibt',
      (tester) async {
    var retries = 0;
    final first = Completer<MealAnalysisResult>();
    await _pumpHost(tester, _host(
      first.future,
      retry: () {
        retries++;
        // Listened to synchronously by the sheet, so an error future is fine.
        return Future<MealAnalysisResult>.error(
          const MealAnalysisReauthRequired(),
        );
      },
    ));
    await _flush(tester);
    first.completeError(const MealAnalysisRateLimited());
    await _flush(tester);
    expect(find.text(_de.foodAnalysisRateLimitError), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyse-retry')));
    await _flush(tester);

    expect(retries, 1);
    expect(find.text(_de.foodReauthRequiredError), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-retry')), findsOneWidget);
  });

  testWidgets('ohne retry (Barcode) gibt es keinen Retry-Button, aber '
      '"Manuell eintragen"', (tester) async {
    final first = Completer<MealAnalysisResult>();
    await _pumpHost(tester, _host(first.future));
    await _flush(tester);
    first.completeError(const FormatException('not found'));
    await _flush(tester);

    expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-retry')), findsNothing);
    expect(find.byKey(const ValueKey('analyse-manual-entry')), findsOneWidget);
  });

  testWidgets('"Manuell eintragen" schliesst das Sheet mit Outcome.manualEntry',
      (tester) async {
    MealAnalysisSheetOutcome? outcome;
    var closed = false;
    final first = Completer<MealAnalysisResult>();
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            outcome = await showMealAnalysisSheet(
              context,
              slot: MealSlot.dinner,
              resultFuture: first.future,
              previewImage: null,
              onAdd: (_, __) => 'id',
              onUpdateMeal: (_, __) {},
              failureMessage: _de.foodAnalysisFailedMessage,
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
      reducedMotion: false,
      safeArea: false,
    );

    await tester.tap(find.text('open'));
    await _flush(tester, 20);
    first.completeError(
      const MealAnalysisServerError(statusCode: 500, code: 'internal_error'),
    );
    await tester.pumpAndSettle();
    expect(find.text(_de.foodAnalysisServiceUnavailableMessage),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyse-manual-entry')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(outcome, MealAnalysisSheetOutcome.manualEntry);
    expect(find.byType(MealAnalysisSheet), findsNothing);
  });

  testWidgets('nach 12 s erscheint der Hinweis mit Abbrechen; Abbrechen '
      'cancelt den Request und schliesst — ohne Fehlerkarte', (tester) async {
    final never = Completer<MealAnalysisResult>();
    final cancellation = MealAnalysisCancellation();
    // Like the real analyzer: cancel fails the pending future at once. The
    // sheet is still mounted for the pop animation and must NOT flash the
    // error card for its own cancel (Fix-Runde 1, Finding 2).
    cancellation.register(
      () => never.completeError(const MealAnalysisCancelled()),
    );
    var closed = false;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await showMealAnalysisSheet(
              context,
              slot: MealSlot.lunch,
              resultFuture: never.future,
              previewImage: null,
              onAdd: (_, __) => 'id',
              onUpdateMeal: (_, __) {},
              failureMessage: _de.foodAnalysisFailedMessage,
              cancellation: cancellation,
            );
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
      reducedMotion: false,
      safeArea: false,
    );

    await tester.tap(find.text('open'));
    await _flush(tester, 20);

    expect(find.byType(MealLoadingCard), findsOneWidget);
    expect(find.byKey(const ValueKey('analyse-slow-hint')), findsNothing);

    await tester.pump(const Duration(seconds: 11));
    expect(find.byKey(const ValueKey('analyse-slow-hint')), findsNothing,
        reason: 'noch unter der Schwelle');
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);
    expect(find.byKey(const ValueKey('analyse-slow-hint')), findsOneWidget);
    expect(find.text(_de.foodAnalysisSlowHint), findsOneWidget);
    expect(find.byType(MealLoadingCard), findsOneWidget,
        reason: 'der Ladebalken bleibt');

    await tester.tap(find.byKey(const ValueKey('analyse-cancel')));
    // Frame by frame through the close animation: no error card at any point.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const ValueKey('analyse-error')), findsNothing,
          reason: 'Frame $i: der eigene Abbruch darf keine Fehlerkarte zeigen');
      expect(find.text(_de.foodAnalysisFailedMessage), findsNothing);
    }
    await tester.pumpAndSettle();

    expect(cancellation.isCancelled, isTrue);
    expect(closed, isTrue);
    expect(find.byType(MealAnalysisSheet), findsNothing);
    expect(find.byKey(const ValueKey('analyse-error')), findsNothing);
  });

  testWidgets('dispose-Cancel mit sofort scheiterndem Future zeigt keine '
      'Fehlerkarte', (tester) async {
    final never = Completer<MealAnalysisResult>();
    final cancellation = MealAnalysisCancellation();
    cancellation.register(
      () => never.completeError(const MealAnalysisCancelled()),
    );
    await _pumpHost(tester, _host(never.future, cancellation: cancellation));
    await _flush(tester);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await _flush(tester);

    expect(cancellation.isCancelled, isTrue);
    expect(find.byKey(const ValueKey('analyse-error')), findsNothing);
  });

  testWidgets('dispose bei laufendem Request cancelt', (tester) async {
    final never = Completer<MealAnalysisResult>();
    final cancellation = MealAnalysisCancellation();
    await _pumpHost(tester, _host(never.future, cancellation: cancellation));
    await _flush(tester);
    expect(cancellation.isCancelled, isFalse);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await _flush(tester);

    expect(cancellation.isCancelled, isTrue);
  });

  testWidgets('dispose nach fertigem Ergebnis cancelt NICHT', (tester) async {
    final cancellation = MealAnalysisCancellation();
    await _pumpHost(tester, _host(
      Future<MealAnalysisResult>.value(_ergebnis),
      cancellation: cancellation,
    ));
    await _flush(tester);
    expect(find.byType(MealResultCard), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await _flush(tester);

    expect(cancellation.isCancelled, isFalse,
        reason: 'nichts mehr in der Luft — ein Cancel waere ein Fehlsignal');
  });

  testWidgets('ein synchron werfendes retry landet in der Fehlerkarte',
      (tester) async {
    final first = Completer<MealAnalysisResult>();
    await _pumpHost(tester, _host(
      first.future,
      retry: () => throw const MealAnalysisReauthRequired(),
    ));
    await _flush(tester);
    first.completeError(const MealImageTooLarge());
    await _flush(tester);
    expect(find.text(_de.foodImageTooLargeError), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyse-retry')));
    await _flush(tester);

    expect(find.text(_de.foodReauthRequiredError), findsOneWidget);
  });
}
