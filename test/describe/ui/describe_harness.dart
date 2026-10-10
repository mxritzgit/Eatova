// Mounts the describe sheet from a button, with every dependency faked.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_describe_sheet.dart';

import '../../support/harness.dart';
import 'describe_fakes.dart';

Finder key(String value) => find.byKey(ValueKey(value));

Finder get describeInput => key('meal-describe-input');
Finder get describeSubmit => key('meal-describe-submit');
Finder get describeMic => key('meal-describe-mic');

class Logged {
  Logged(this.result, this.slot);
  final MealAnalysisResult result;
  final MealSlot slot;
}

/// Everything the sheet talks to, plus what it handed back.
class DescribeHost {
  final FakeSpeech speech = FakeSpeech();
  final FakeAwake awake = FakeAwake();
  final MemoryLanguageStore languages = MemoryLanguageStore();
  final FakeDescriber describer = FakeDescriber();
  final FakeMatcher matcher = FakeMatcher();
  final List<Logged> logged = <Logged>[];

  /// Holds `onAdd` open until completed.
  Completer<void>? addGate;

  /// Thrown by `onAdd` (a failed local save).
  Object? addError;

  MealDescribeOutcome? outcome;
  bool closed = false;

  Future<String> onAdd(MealAnalysisResult result, MealSlot slot) async {
    logged.add(Logged(result, slot));
    await addGate?.future;
    final error = addError;
    if (error != null) throw error;
    return 'meal-${logged.length}';
  }
}

/// Phone viewport (logical [width] x 852, home indicator and notch insets).
void phoneViewport(WidgetTester tester, {double width = 393}) {
  tester.view.physicalSize = Size(width, 852);
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
  tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
  addTearDown(tester.view.reset);
}

Future<DescribeHost> openDescribe(
  WidgetTester tester, {
  DescribeHost? host,
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.dark,
  double width = 393,
  double textScale = 1,
  MealSlot slot = MealSlot.lunch,
}) async {
  final h = host ?? DescribeHost();
  phoneViewport(tester, width: width);
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            h.outcome = await showMealDescribeSheet(
              context,
              initialSlot: slot,
              describer: h.describer,
              matcher: h.matcher,
              onAdd: h.onAdd,
              onUpdateMeal: (_, _) {},
              speechInput: h.speech,
              screenAwake: h.awake,
              dictationLanguageStore: h.languages,
            );
            h.closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
    locale: locale,
    brightness: brightness,
    textScale: textScale,
    safeArea: false,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return h;
}

AppLocalizations l10nOf(WidgetTester tester) =>
    tester.element(key('meal-describe-sheet')).l10n;

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(describeInput).controller!.text;

bool enabled(WidgetTester tester, Finder button) =>
    tester.widget<PrimaryActionButton>(button).onTap != null;

/// Types [text] and sends it; settles on the draft (or the error).
Future<void> describe(WidgetTester tester, String text) async {
  await tester.enterText(describeInput, text);
  await tester.pump();
  await tester.ensureVisible(describeSubmit);
  await tester.pumpAndSettle();
  await tester.tap(describeSubmit);
  await tester.pumpAndSettle();
}

/// Runs [body] on [platform]; reset in `finally`, as the binding checks
/// foundation variables before tear-downs run.
Future<void> onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}
