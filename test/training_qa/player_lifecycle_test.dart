import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'fixtures.dart';

TrainingPlan _plan() {
  final raw = trainingDraft();
  firstWorkout(raw)['exercises'] = (firstWorkout(raw)['exercises'] as List)
      .reversed
      .toList();
  return CoachTrainingProposal.fromJson(raw)!.toTrainingPlan(id: 'player-plan');
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _frames(tester);
}

Future<void> _mount(WidgetTester tester, Widget Function() player) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('open-player'),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => player())),
        child: const Text('Open'),
      ),
    ),
    locale: const Locale('en'),
    surfaceSize: const Size(430, 1000),
  );
  await _tap(tester, 'open-player');
}

String _readout(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('training-timer-readout')),
            matching: find.byType(Text),
          )
          .first,
    )
    .data!;

void main() {
  testWidgets(
    'real player pause, rewind, reset and background persist exact time',
    (tester) async {
      var time = Duration.zero;
      final checkpoints = <TrainingSessionSnapshot?>[];
      await _mount(
        tester,
        () => TrainingPlayerScreen(
          plan: _plan(),
          monotonicNow: () => time,
          onPersist: (snapshot) async {
            checkpoints.add(snapshot);
          },
        ),
      );
      expect(_readout(tester), '00:40');
      await _tap(tester, 'training-timer-primary');
      time += const Duration(seconds: 13);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_readout(tester), '00:27');
      await _tap(tester, 'training-timer-primary');
      expect(checkpoints.last!.remainingMilliseconds, 27000);
      time += const Duration(minutes: 5);
      await tester.pump(const Duration(seconds: 1));
      expect(_readout(tester), '00:27');
      await _tap(tester, 'training-timer-rewind');
      expect(_readout(tester), '00:37');
      await _tap(tester, 'training-timer-reset');
      expect(_readout(tester), '00:40');
      await _tap(tester, 'training-timer-primary');
      time += const Duration(seconds: 7);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _frames(tester);
      expect(checkpoints.last!.remainingMilliseconds, 33000);
      time += const Duration(hours: 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(_readout(tester), '00:33');
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    },
  );

  testWidgets(
    'system back waits for durable pause and restart requires deliberate resume',
    (tester) async {
      var time = Duration.zero;
      TrainingSessionSnapshot? last;
      Completer<void>? hold;
      await _mount(
        tester,
        () => TrainingPlayerScreen(
          plan: _plan(),
          monotonicNow: () => time,
          onPersist: (snapshot) async {
            await hold?.future;
            last = snapshot;
          },
        ),
      );
      await _tap(tester, 'training-timer-primary');
      time += const Duration(milliseconds: 12500);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('training-timer-confirm-exit')),
        findsOneWidget,
      );
      hold = Completer<void>();
      await _tap(tester, 'training-timer-confirm-exit');
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      final reboot = TrainingSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(last!.toJson())),
      );
      expect(reboot.remainingMilliseconds, 27500);
      expect(reboot.toJson()['status'], 'paused');
      time += const Duration(days: 1);
      hold = null;
      await _mount(
        tester,
        () => TrainingPlayerScreen(
          initialSnapshot: reboot,
          monotonicNow: () => time,
          onPersist: (snapshot) async {
            last = snapshot;
          },
        ),
      );
      expect(_readout(tester), '00:28');
      time += const Duration(minutes: 5);
      await tester.pump(const Duration(seconds: 1));
      expect(_readout(tester), '00:28');
      await _tap(tester, 'training-timer-primary');
      time += const Duration(milliseconds: 1500);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_readout(tester), '00:26');
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
    },
  );

  testWidgets(
    'failed discard keeps player open; retry clears recovery before exit',
    (tester) async {
      var failClear = true;
      final stored = <TrainingSessionSnapshot?>[];
      await _mount(
        tester,
        () => TrainingPlayerScreen(
          plan: _plan(),
          onPersist: (snapshot) async {
            if (snapshot == null && failClear) {
              throw StateError('CI disk failure');
            }
            stored.add(snapshot);
          },
        ),
      );
      await _tap(tester, 'training-timer-discard');
      await _tap(tester, 'training-timer-confirm-exit');
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('training-timer-save-error')),
        findsOneWidget,
      );
      expect(stored.last, isNotNull);
      failClear = false;
      await _tap(tester, 'training-timer-retry');
      await tester.pumpAndSettle();
      expect(find.byType(TrainingPlayerScreen), findsNothing);
      expect(stored.last, isNull);
      await tester.pump(const Duration(seconds: 6));
      expect(stored.last, isNull);
    },
  );
}
