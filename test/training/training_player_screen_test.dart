import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

final _captureKey = GlobalKey();

Future<void> _loadFonts() async {
  final material = FontLoader('MaterialIcons');
  material.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await material.load();
  for (final family in {
    'Archivo': [
      'Archivo-Regular.ttf',
      'Archivo-SemiBold.ttf',
      'Archivo-Bold.ttf',
    ],
    'BricolageGrotesque': [
      'BricolageGrotesque-Bold.ttf',
      'BricolageGrotesque-ExtraBold.ttf',
    ],
  }.entries) {
    final loader = FontLoader(family.key);
    for (final file in family.value) {
      loader.addFont(rootBundle.load('assets/fonts/$file'));
    }
    await loader.load();
  }
}

Future<void> _host(
  WidgetTester tester, {
  required Future<void> Function(TrainingSessionSnapshot?) persist,
  TimerTestClock? clock,
  TrainingSessionSnapshot? snapshot,
  String locale = 'en',
  Brightness brightness = Brightness.light,
  Size size = const Size(393, 852),
  double scale = 1,
  bool longText = false,
  int duration = 30,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: _captureKey, child: child),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TrainingPlayerScreen(
                  plan: snapshot == null
                      ? timerPlan(longText: longText, duration: duration)
                      : null,
                  initialSnapshot: snapshot,
                  monotonicNow: clock?.now,
                  onPersist: persist,
                ),
              ),
            ),
            child: const Text('Open fixture'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture'));
  await tester.pumpAndSettle();
}

Finder _key(String id) => find.byKey(ValueKey('training-timer-$id'));

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(_key(id));
  await tester.pump();
  await tester.tap(_key(id));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('TIMER_CAPTURE')) return;
  if (!name.endsWith('-controls') && !name.endsWith('-time')) {
    tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!
        .jumpTo(0);
  }
  await tester.pump(const Duration(milliseconds: 300));
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/training-timer').create(recursive: true);
    await File(
      'build/training-timer/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  testWidgets(
    'initial recovery is paused and does not claim saved before callback',
    (tester) async {
      final gate = Completer<void>();
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        persist: (s) async {
          writes.add(s);
          await gate.future;
        },
      );
      expect(writes.length, 1);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Recovery checkpoint saved'), findsNothing);
      expect(find.text('Saving your place…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Recovery checkpoint saved'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'start pause resume and +/-10 reset persist truthful paused checkpoints',
    (tester) async {
      final clock = TimerTestClock();
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        clock: clock,
        persist: (s) async {
          writes.add(s);
        },
      );
      await _tap(tester, 'primary');
      expect(find.text('Running'), findsOneWidget);
      clock.elapse(const Duration(seconds: 12));
      await tester.pump(const Duration(milliseconds: 100));
      await _tap(tester, 'primary');
      expect(writes.last!.remainingMilliseconds, 18000);
      await _tap(tester, 'rewind');
      expect(writes.last!.remainingMilliseconds, 28000);
      await _tap(tester, 'forward');
      expect(writes.last!.remainingMilliseconds, 18000);
      await _tap(tester, 'reset');
      expect(writes.last!.remainingMilliseconds, 30000);
      expect(find.text('Paused'), findsOneWidget);
      expect(writes.every((s) => s!.toJson()['status'] == 'paused'), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('zero waits for explicit set completion, rest waits too', (
    tester,
  ) async {
    final clock = TimerTestClock();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      clock: clock,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'primary');
    clock.elapse(const Duration(hours: 3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Time is up'), findsOneWidget);
    expect(writes.last!.completedSets, isEmpty);
    await _tap(tester, 'primary');
    expect(writes.last!.phase, TrainingSessionPhase.rest);
    expect(writes.last!.completedSets.length, 1);
    expect(find.text('Paused'), findsOneWidget);
    await _capture(tester, 'rest-light');
    await _tap(tester, 'primary');
    clock.elapse(const Duration(hours: 2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(writes.last!.phase, TrainingSessionPhase.rest);
    await _tap(tester, 'primary');
    expect(writes.last!.setIndex, 1);
    expect(writes.last!.phase, TrainingSessionPhase.exercise);
    expect(find.text('Paused'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reps require action, expose pause, and do not complete unattended',
    (tester) async {
      final clock = TimerTestClock();
      final writes = <TrainingSessionSnapshot?>[];
      final controller = TrainingSessionController(
        plan: timerPlan(),
        autoTick: false,
      )..nextExercise();
      final snapshot = controller.snapshot();
      controller.dispose();
      await _host(
        tester,
        clock: clock,
        snapshot: snapshot,
        persist: (s) async {
          writes.add(s);
        },
      );
      expect(find.text('12'), findsOneWidget);
      expect(_key('rewind'), findsNothing);
      await _tap(tester, 'primary');
      clock.elapse(const Duration(days: 1));
      await tester.pump(const Duration(seconds: 5));
      expect(writes.last!.completedSets, isEmpty);
      await _tap(tester, 'pause');
      expect(find.text('Paused'), findsOneWidget);
      await _tap(tester, 'primary');
      await _tap(tester, 'primary');
      expect(writes.last!.completedSets.length, 1);
      expect(writes.last!.setIndex, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('background pauses before a tick and resume never auto-starts', (
    tester,
  ) async {
    final clock = TimerTestClock();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      clock: clock,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'primary');
    clock.elapse(const Duration(milliseconds: 7123));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(writes.last!.remainingMilliseconds, 22877);
    expect(writes.last!.completedSets, isEmpty);
    clock.elapse(const Duration(days: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Paused'), findsOneWidget);
    expect(writes.last!.remainingMilliseconds, 22877);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rest snapshot opens paused and preserves completed ledger', (
    tester,
  ) async {
    final clock = TimerTestClock();
    final controller = TrainingSessionController(
      plan: timerPlan(),
      monotonicNow: clock.now,
      autoTick: false,
    );
    controller.start();
    clock.elapse(const Duration(seconds: 30));
    controller.completeCurrentSet();
    controller.forward10Seconds();
    final snapshot = controller.snapshot();
    controller.dispose();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      snapshot: snapshot,
      persist: (s) async {
        writes.add(s);
      },
    );
    expect(find.text('Rest between sets'), findsOneWidget);
    expect(find.text('00:05'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    await _tap(tester, 'skip-rest');
    expect(writes.last!.setIndex, 1);
    expect(writes.last!.completedSets.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('all navigation controls work and revoked progress can replay', (
    tester,
  ) async {
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'next-set');
    expect(writes.last!.setIndex, 1);
    await _tap(tester, 'next-exercise');
    expect(writes.last!.exerciseIndex, 1);
    await _tap(tester, 'previous-set');
    expect(writes.last!.exerciseIndex, 0);
    expect(writes.last!.setIndex, 1);
    await _tap(tester, 'next-exercise');
    await _tap(tester, 'previous-exercise');
    expect(writes.last!.setIndex, 0);
    expect(writes.last!.skippedSets, isEmpty);
    expect(find.text('0 of 4 sets completed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('save failure is sanitized, pauses and supports retry', (
    tester,
  ) async {
    var fail = false;
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      persist: (s) async {
        if (fail) throw StateError('private-account-path');
        writes.add(s);
      },
    );
    fail = true;
    await _tap(tester, 'primary');
    await tester.pump();
    expect(_key('save-error'), findsOneWidget);
    expect(find.textContaining('private-account-path'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Recovery checkpoint saved'), findsNothing);
    fail = false;
    await _tap(tester, 'retry');
    await tester.pump();
    expect(_key('save-error'), findsNothing);
    expect(find.text('Recovery checkpoint saved'), findsOneWidget);
    expect(writes.last, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('back offers stay paused or durable save and leave', (
    tester,
  ) async {
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'primary');
    await _tap(tester, 'back');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stay here'));
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    await _tap(tester, 'back');
    await tester.pumpAndSettle();
    await _tap(tester, 'confirm-exit');
    await tester.pumpAndSettle();
    expect(find.text('Open fixture'), findsOneWidget);
    expect(writes.last, isNotNull);
  });

  testWidgets('system back pauses and requires the same leave choice', (
    tester,
  ) async {
    await _host(tester, persist: (_) async {});
    await _tap(tester, 'primary');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Pause and leave?'), findsOneWidget);
    await tester.tap(find.text('Stay here'));
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another page covers the player and pauses its monotonic clock', (
    tester,
  ) async {
    final clock = TimerTestClock();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      clock: clock,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'primary');
    clock.elapse(const Duration(milliseconds: 4001));
    final context = tester.element(find.byType(TrainingPlayerScreen));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covered fixture')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(writes.last!.remainingMilliseconds, 25999);
    clock.elapse(const Duration(hours: 1));
    Navigator.of(tester.element(find.text('Covered fixture'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('00:26'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed save and leave keeps route, retry waits for durable callback',
    (tester) async {
      var fail = false;
      var block = false;
      final gate = Completer<void>();
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        persist: (s) async {
          writes.add(s);
          if (fail) throw StateError('save failed');
          if (block) await gate.future;
        },
      );
      await _tap(tester, 'back');
      await tester.pumpAndSettle();
      fail = true;
      await _tap(tester, 'confirm-exit');
      await tester.pumpAndSettle();
      expect(_key('save-error'), findsOneWidget);
      fail = false;
      block = true;
      await _tap(tester, 'retry');
      await tester.pumpAndSettle();
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(writes.every((s) => s != null), isTrue);
    },
  );

  testWidgets(
    'background cannot hide failed clear or replace its retry intent',
    (tester) async {
      var failClear = true;
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        persist: (s) async {
          writes.add(s);
          if (s == null && failClear) throw StateError('clear failed');
        },
      );
      await _tap(tester, 'discard');
      await tester.pumpAndSettle();
      await _tap(tester, 'confirm-exit');
      await tester.pumpAndSettle();
      final count = writes.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(writes.length, count);
      expect(_key('save-error'), findsOneWidget);
      failClear = false;
      await _tap(tester, 'retry');
      await tester.pumpAndSettle();
      expect(writes.last, isNull);
      expect(find.text('Open fixture'), findsOneWidget);
    },
  );

  testWidgets(
    'semantic phase announcement names exercise and set without ticking live time',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final clock = TimerTestClock();
      await _host(tester, clock: clock, persist: (_) async {});
      expect(
        find.bySemanticsLabel('Hold. Set 1 of 2. Paused.'),
        findsOneWidget,
      );
      await _tap(tester, 'primary');
      expect(
        find.bySemanticsLabel('Hold. Set 1 of 2. Running.'),
        findsOneWidget,
      );
      clock.elapse(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.bySemanticsLabel('Hold. Set 1 of 2. Running.'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('26 seconds remaining'), findsOneWidget);
      await _tap(tester, 'next-set');
      expect(
        find.bySemanticsLabel('Hold. Set 2 of 2. Paused.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  for (final terminal in ['discard', 'finish']) {
    testWidgets(
      '$terminal confirms and clears only after older checkpoints finish',
      (tester) async {
        final gate = Completer<void>();
        final writes = <TrainingSessionSnapshot?>[];
        var active = 0;
        var maxActive = 0;
        await _host(
          tester,
          persist: (s) async {
            active++;
            if (active > maxActive) maxActive = active;
            writes.add(s);
            if (writes.length == 1) await gate.future;
            active--;
          },
        );
        await _tap(tester, terminal);
        await tester.pumpAndSettle();
        expect(writes.where((s) => s == null), isEmpty);
        await _tap(tester, 'confirm-exit');
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(writes.length, 1);
        expect(find.byType(TrainingPlayerScreen), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(maxActive, 1);
        expect(writes.last, isNull);
        expect(writes.where((s) => s == null).length, 1);
        expect(find.text('Open fixture'), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(writes.last, isNull);
      },
    );
  }

  testWidgets(
    'failed clear keeps route and retry repeats null, not a checkpoint',
    (tester) async {
      var failClear = true;
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        persist: (s) async {
          writes.add(s);
          if (s == null && failClear) throw StateError('clear failed');
        },
      );
      await _tap(tester, 'discard');
      await tester.pumpAndSettle();
      await _tap(tester, 'confirm-exit');
      await tester.pumpAndSettle();
      expect(_key('save-error'), findsOneWidget);
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      failClear = false;
      await _tap(tester, 'retry');
      await tester.pumpAndSettle();
      expect(writes.last, isNull);
      expect(writes.where((s) => s == null).length, 2);
      expect(find.text('Open fixture'), findsOneWidget);
    },
  );

  testWidgets('older failed checkpoint cannot unlock a queued clear', (
    tester,
  ) async {
    final checkpoint = Completer<void>();
    final clear = Completer<void>();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      persist: (s) async {
        writes.add(s);
        if (writes.length == 1) await checkpoint.future;
        if (s == null) await clear.future;
      },
    );
    await _tap(tester, 'discard');
    await tester.pumpAndSettle();
    await _tap(tester, 'confirm-exit');
    await tester.pumpAndSettle();
    checkpoint.completeError(StateError('old checkpoint failed'));
    await tester.pumpAndSettle();
    expect(writes.last, isNull);
    await _tap(tester, 'primary');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    clear.complete();
    await tester.pumpAndSettle();
    expect(
      writes.last,
      isNull,
      reason: 'No checkpoint may be queued after a terminal clear',
    );
    expect(find.text('Open fixture'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets(
    'review is honest about skipped sets and finishing needs confirmation',
    (tester) async {
      final controller =
          TrainingSessionController(plan: timerPlan(), autoTick: false)
            ..nextExercise()
            ..nextExercise();
      final snapshot = controller.snapshot();
      controller.dispose();
      final writes = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        snapshot: snapshot,
        persist: (s) async {
          writes.add(s);
        },
      );
      expect(find.text('4 sets skipped'), findsOneWidget);
      expect(find.text('0 of 4 sets completed'), findsNWidgets(2));
      await _tap(tester, 'primary');
      await tester.pumpAndSettle();
      expect(find.text('Finish this workout?'), findsOneWidget);
      expect(writes.last, isNotNull);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('external route removal pauses and queues final recovery', (
    tester,
  ) async {
    final clock = TimerTestClock();
    final writes = <TrainingSessionSnapshot?>[];
    await _host(
      tester,
      clock: clock,
      persist: (s) async {
        writes.add(s);
      },
    );
    await _tap(tester, 'primary');
    clock.elapse(const Duration(seconds: 7));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(writes.last!.remainingMilliseconds, 23000);
    expect(writes.last!.toJson()['status'], 'paused');
  });

  for (final locale in ['de', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '320x568 2x $locale ${brightness.name}: readable controls and long prescription',
        (tester) async {
          await _host(
            tester,
            locale: locale,
            brightness: brightness,
            size: const Size(320, 568),
            scale: 2,
            longText: true,
            duration: 3600,
            persist: (_) async {},
          );
          expect(tester.takeException(), isNull);
          await _capture(tester, 'narrow-$locale-${brightness.name}-top');
          await tester.ensureVisible(_key('readout'));
          await tester.pump();
          final timerRect = tester.getRect(_key('readout'));
          expect(timerRect.width, lessThanOrEqualTo(280));
          expect(timerRect.height, lessThanOrEqualTo(568));
          expect(timerRect.top, greaterThanOrEqualTo(0));
          expect(timerRect.bottom, lessThanOrEqualTo(568));
          await _capture(tester, 'narrow-$locale-${brightness.name}-time');
          for (final id in [
            'primary',
            'rewind',
            'forward',
            'reset',
            'previous-set',
            'next-set',
            'previous-exercise',
            'next-exercise',
            'finish',
            'discard',
          ]) {
            await tester.ensureVisible(_key(id));
            await tester.pump();
            final rect = tester.getRect(_key(id));
            expect(rect.left, greaterThanOrEqualTo(0), reason: id);
            expect(rect.right, lessThanOrEqualTo(320), reason: id);
            expect(rect.height, greaterThanOrEqualTo(48), reason: id);
            expect(rect.top, greaterThanOrEqualTo(0), reason: id);
            expect(rect.bottom, lessThanOrEqualTo(568), reason: id);
            expect(_key(id).hitTestable(), findsOneWidget, reason: id);
            expect(tester.takeException(), isNull, reason: id);
            if (id == 'rewind') {
              await _capture(
                tester,
                'narrow-$locale-${brightness.name}-controls',
              );
            }
          }
          await _tap(tester, 'discard');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final rect = tester.getRect(_key('confirm-exit'));
          expect(rect.right, lessThanOrEqualTo(320));
          expect(rect.bottom, lessThanOrEqualTo(568));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'normal player captures paused and running with readable dominant action',
    (tester) async {
      final clock = TimerTestClock();
      await _host(tester, clock: clock, persist: (_) async {});
      expect(tester.getRect(_key('primary')).bottom, lessThan(852));
      await _capture(tester, 'paused-light');
      await _tap(tester, 'primary');
      clock.elapse(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 100));
      await _capture(tester, 'running-light');
      expect(find.text('00:23'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
