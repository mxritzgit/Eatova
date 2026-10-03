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

// The real player across pause, background and restart (spec A4,
// 2026-10-03). Supersedes "background pauses; resume never auto-starts":
// only the explicit Pause (menu) or Save & leave freezes time.

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

Future<void> _menu(WidgetTester tester, String item) async {
  await _tap(tester, 'training-timer-menu');
  await tester.tap(find.byKey(ValueKey(item)));
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
  testWidgets('real player: menu pause freezes, background keeps the deadline '
      'running', (tester) async {
    var time = Duration.zero;
    final checkpoints = <TrainingSessionSnapshot?>[];
    await _mount(
      tester,
      () => TrainingPlayerScreen(
        plan: _plan(),
        monotonicNow: () => time,
        onPersist: (snapshot) async {
          checkpoints.add(snapshot);
          return true;
        },
      ),
    );
    expect(_readout(tester), '00:40');
    await _tap(tester, 'training-set-check-0-0');
    time += const Duration(seconds: 16);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_readout(tester), '00:27', reason: '3 s lead, then 13 s');
    await _menu(tester, 'training-timer-pause');
    expect(checkpoints.last!.remainingMilliseconds, 27000);
    expect(checkpoints.last!.phaseEndsAt, isNull);
    time += const Duration(minutes: 5);
    await tester.pump(const Duration(seconds: 1));
    expect(_readout(tester), '00:27');
    await _menu(tester, 'training-timer-resume');
    time += const Duration(seconds: 7);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _frames(tester);
    expect(checkpoints.last!.phaseEndsAt, isNotNull);
    expect(checkpoints.last!.remainingMilliseconds, 20000);
    time += const Duration(seconds: 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _frames(tester);
    expect(_readout(tester), '00:10');
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
  });

  testWidgets('system back: Save & leave pauses durably; a restart resumes '
      'only with ▶', (tester) async {
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
          return true;
        },
      ),
    );
    await _tap(tester, 'training-set-check-0-0');
    time += const Duration(milliseconds: 15500);
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
      jsonDecode(jsonEncode(last!.toJson())) as Map<dynamic, dynamic>,
    );
    expect(reboot.remainingMilliseconds, 27500);
    expect(reboot.phaseEndsAt, isNull);
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
          return true;
        },
      ),
    );
    expect(_readout(tester), '00:28');
    time += const Duration(minutes: 5);
    await tester.pump(const Duration(seconds: 1));
    expect(_readout(tester), '00:28');
    await _tap(tester, 'training-set-check-0-0');
    time += const Duration(milliseconds: 1500);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_readout(tester), '00:26', reason: 'no lead-in when resuming');
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
  });

  testWidgets('failed discard keeps the player open; retry clears recovery '
      'before exit', (tester) async {
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
          return true;
        },
      ),
    );
    await _menu(tester, 'training-timer-discard');
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
  });
}
