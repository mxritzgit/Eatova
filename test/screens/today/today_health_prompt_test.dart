// Today's health cards (reviews 2026-10-19 and 2026-10-22): the Apple Health
// and Health Connect intro and the scale import's question say what they
// are for and answer through their two actions; one answer at a time.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/today/today_health_prompt.dart';

import '../../support/harness.dart';

void main() {
  testWidgets('the card answers through its actions', (tester) async {
    var connects = 0, dismissals = 0;
    await pumpLocalized(
      tester,
      TodayHealthPromptCard(
        onConnect: () async => connects++,
        onDismiss: () async => dismissals++,
      ),
      padding: const EdgeInsets.all(20),
      scrollable: true,
      settle: true,
    );

    expect(find.text('Schritte aus Apple Health'), findsOneWidget);
    expect(find.textContaining('zählen als Verbrauch'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-health-prompt-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('today-health-prompt-dismiss')));
    await tester.pumpAndSettle();

    expect((connects, dismissals), (1, 1));
  });

  testWidgets('Health Connect\'s card and the scale question answer through '
      'their actions', (tester) async {
    final answers = <String>[];
    for (final (card, prefix, primary) in <(Widget, String, String)>[
      (
        TodayHealthPromptCard(
          healthConnect: true,
          onConnect: () async => answers.add('connect'),
          onDismiss: () async => answers.add('not now'),
        ),
        'today-health-prompt',
        'connect',
      ),
      (
        TodayWeightImportCard(
          onAccept: () async => answers.add('import'),
          onDismiss: () async => answers.add('not now'),
        ),
        'today-weight-import',
        'accept',
      ),
    ]) {
      await pumpLocalized(
        tester,
        card,
        padding: const EdgeInsets.all(20),
        scrollable: true,
        settle: true,
      );
      await tester.tap(find.byKey(ValueKey('$prefix-$primary')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('$prefix-dismiss')));
      await tester.pumpAndSettle();
    }

    expect(answers, ['connect', 'not now', 'import', 'not now']);
  });

  testWidgets('a connect in flight takes no second answer', (tester) async {
    final pending = Completer<void>();
    var connects = 0, dismissals = 0;
    await pumpLocalized(
      tester,
      TodayHealthPromptCard(
        onConnect: () {
          connects++;
          return pending.future;
        },
        onDismiss: () async => dismissals++,
      ),
      padding: const EdgeInsets.all(20),
      scrollable: true,
      settle: true,
    );

    await tester.tap(find.byKey(const ValueKey('today-health-prompt-connect')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('today-health-prompt-connect')));
    await tester.tap(find.byKey(const ValueKey('today-health-prompt-dismiss')));
    await tester.pump();
    expect((connects, dismissals), (1, 0));

    pending.complete();
    await tester.pumpAndSettle();
  });
}
