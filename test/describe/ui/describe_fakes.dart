// Fakes and fixtures for the describe sheet's widget tests: the speech
// bridge, the describer, the matcher and a two-line draft (Nutella on toast).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:eatova/src/models/described_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/dictation_language.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_describer.dart';
import 'package:eatova/src/services/meal_description_matcher.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/speech_input.dart';

/// One [SpeechInput.listen] call as the sheet made it.
class ListenCall {
  ListenCall(this.localeId, this.token, this.vocabulary, this.maxChars);
  final String localeId;
  final int token;
  final SpeechVocabulary vocabulary;
  final int maxChars;
}

/// The `eatova/speech` bridge without a channel. A listen stays open until
/// [finish]; [stop] finishes with [finalText] (or the last partial), like the
/// plugin's graceful stop; [cancel] finishes at once with what was shown.
class FakeSpeech extends SpeechInput {
  FakeSpeech();

  final List<ListenCall> listens = <ListenCall>[];
  int stops = 0;
  int cancels = 0;

  /// Thrown by the next [listen].
  Object? failWith;

  /// What a graceful [stop] completes with; null = the last partial.
  String? finalText;

  /// False: [stop] does not answer (a hung recognizer).
  bool stopAnswers = true;

  /// Android's system dialog (SpeechBridge): [stop] and [cancel] leave it
  /// running, only [finish] answers, and a second listen meanwhile is busy.
  bool systemDialog = false;

  Completer<String?>? _pending;
  ValueChanged<String>? _onPartial;
  ValueChanged<SpeechEnd>? _onEnd;
  String? _lastPartial;

  bool get isListening => _pending != null;

  @override
  Future<String?> listen({
    required String localeId,
    required int token,
    SpeechVocabulary vocabulary = SpeechVocabulary.gym,
    int maxChars = 1000,
    ValueChanged<String>? onPartial,
    ValueChanged<SpeechEnd>? onEnd,
  }) {
    listens.add(ListenCall(localeId, token, vocabulary, maxChars));
    final failure = failWith;
    if (failure != null) {
      failWith = null;
      return Future<String?>.error(failure);
    }
    if (systemDialog && _pending != null) {
      return Future<String?>.error(
        const SpeechInputException(SpeechFailure.busy),
      );
    }
    _onPartial = onPartial;
    _onEnd = onEnd;
    _lastPartial = null;
    final pending = _pending = Completer<String?>();
    return pending.future;
  }

  /// The recognizer's transcript so far (iOS only).
  void partial(String text) {
    _lastPartial = text;
    _onPartial?.call(text);
  }

  /// The recording ends with [text] for [end].
  void finish(String? text, {SpeechEnd end = SpeechEnd.stopped}) {
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    _onEnd?.call(end);
    pending.complete(text);
  }

  @override
  Future<void> stop() async {
    stops++;
    if (systemDialog) return;
    if (stopAnswers) finish(finalText ?? _lastPartial);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (systemDialog) return;
    finish(_lastPartial);
  }
}

class FakeAwake implements ScreenAwake {
  final List<bool> calls = <bool>[];
  bool get held => calls.isNotEmpty && calls.last;

  @override
  Future<void> setKeepAwake(bool on, {String owner = 'default'}) async {
    calls.add(on);
  }
}

class MemoryLanguageStore implements DictationLanguageStore {
  MemoryLanguageStore([this.value]);
  DictationLanguage? value;

  @override
  Future<DictationLanguage?> load() async => value;

  @override
  Future<void> save(DictationLanguage language) async => value = language;
}

class DescribeCall {
  DescribeCall(this.text, this.language, this.cancellation);
  final String text;
  final String language;
  final MealAnalysisCancellation? cancellation;
}

/// Answers with [meal], or [error], or waits for [pending].
class FakeDescriber implements MealDescriber {
  FakeDescriber({DescribedMeal? meal}) : meal = meal ?? describedNutellaToast;

  final List<DescribeCall> calls = <DescribeCall>[];
  DescribedMeal meal;
  Object? error;
  Completer<DescribedMeal>? pending;

  @override
  Future<DescribedMeal> describe(
    String text, {
    required String language,
    MealAnalysisCancellation? cancellation,
  }) {
    calls.add(DescribeCall(text, language, cancellation));
    final failure = error;
    if (failure != null) return Future<DescribedMeal>.error(failure);
    final wait = pending;
    if (wait != null) {
      cancellation?.register(() {
        if (!wait.isCompleted) {
          wait.completeError(const MealAnalysisCancelled());
        }
      });
      return wait.future;
    }
    return Future<DescribedMeal>.value(meal);
  }
}

class FakeMatcher implements MealDescriptionMatcher {
  FakeMatcher({MealDescriptionDraft? draft})
    : draft = draft ?? nutellaToastDraft();

  MealDescriptionDraft draft;
  final List<DescribedMeal> calls = <DescribedMeal>[];

  @override
  Future<MealDescriptionDraft> match(DescribedMeal meal) async {
    calls.add(meal);
    return draft;
  }
}

// --- Fixtures -----------------------------------------------------------------

const nutellaDescribed = DescribedFoodItem(
  name: 'Nutella',
  searchQuery: 'Nutella',
  brand: 'Ferrero',
  grams: 15,
  gramsSource: DescribedGramsSource.estimated,
  caloriesKcal: 81,
  kcalPer100G: 539,
  proteinG: 0.9,
  carbsG: 8.6,
  fatG: 4.6,
);

const toastDescribed = DescribedFoodItem(
  name: 'Toastbrot',
  searchQuery: 'Toastbrot',
  brand: 'Lidl',
  amountText: '1 Scheibe',
  grams: 25,
  gramsSource: DescribedGramsSource.stated,
  caloriesKcal: 65,
  kcalPer100G: 260,
  proteinG: 2,
  carbsG: 12.3,
  fatG: 1,
);

const nutellaProduct = DraftCandidate(
  origin: DraftItemOrigin.product,
  title: 'Nutella · Ferrero',
  brand: 'Ferrero',
  kcalPer100G: 539,
  proteinPer100G: 6.3,
  carbsPer100G: 57.5,
  fatPer100G: 30.9,
  servingGrams: 15,
  barcode: '3017620422003',
);

const nutellaEstimate = DraftCandidate(
  origin: DraftItemOrigin.estimate,
  title: 'Nutella',
  kcalPer100G: 539,
  proteinPer100G: 6,
  carbsPer100G: 57,
  fatPer100G: 31,
);

const toastEstimate = DraftCandidate(
  origin: DraftItemOrigin.estimate,
  title: 'Toastbrot',
  kcalPer100G: 260,
  proteinPer100G: 8,
  carbsPer100G: 49,
  fatPer100G: 4,
);

/// 279 kcal per 100 g in 26 g slices: "1 Scheibe" becomes 26 g, 73 kcal.
const toastProduct = DraftCandidate(
  origin: DraftItemOrigin.product,
  title: 'Butter Toast · Grafschafter',
  brand: 'Grafschafter',
  kcalPer100G: 279,
  proteinPer100G: 8.2,
  carbsPer100G: 49,
  fatPer100G: 4.8,
  servingGrams: 26,
  barcode: '20345678',
);

const toastFavorite = DraftCandidate(
  origin: DraftItemOrigin.favorite,
  title: 'Vollkorntoast',
  kcalPer100G: 247,
  proteinPer100G: 9,
  carbsPer100G: 42,
  fatPer100G: 3.5,
);

const nutellaToastBase = MealAnalysisResult(
  mealName: 'Nutella-Toast',
  caloriesKcal: 146,
  estimatedGrams: 40,
  kcalPer100G: 365,
  protein: '3 g',
  carbs: '21 g',
  fat: '6 g',
  confidence: 'medium',
  portionNotes: '',
);

const describedNutellaToast = DescribedMeal(
  base: nutellaToastBase,
  items: [nutellaDescribed, toastDescribed],
);

/// Nutella from the database (15 g, 81 kcal) and toast on the estimate
/// (25 g, 65 kcal): 146 kcal.
MealDescriptionDraft nutellaToastDraft({MealSlot? slotHint}) =>
    MealDescriptionDraft(
      meal: DescribedMeal(
        base: nutellaToastBase,
        items: const [nutellaDescribed, toastDescribed],
        slotHint: slotHint,
      ),
      items: const [
        DraftFoodItem(
          described: nutellaDescribed,
          selected: nutellaProduct,
          candidates: [nutellaProduct, nutellaEstimate],
          grams: 15,
        ),
        DraftFoodItem(
          described: toastDescribed,
          selected: toastEstimate,
          candidates: [toastProduct, toastFavorite, toastEstimate],
          grams: 25,
        ),
      ],
    );
