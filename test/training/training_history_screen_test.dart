import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_history_screen.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'training_timer_fixtures.dart';

final _capture = GlobalKey();

Future<void> _host(
  WidgetTester tester,
  Widget child, {
  String locale = 'en',
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(scale == 1 ? 393 : 320, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.light),
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: _capture, child: child),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('Open fixture'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

TrainingHistoryEntry _entry() =>
    withClock(Clock.fixed(DateTime.utc(2026, 9, 10, 12)), () {
      final controller = TrainingSessionController(
        plan: timerPlan(),
        autoTick: false,
      );
      controller.nextExercise();
      controller.start();
      controller.setCurrentActual(reps: 8, weightKg: 20);
      controller.completeCurrentSet();
      final result = controller.completion(note: 'Comfortable pace');
      controller.dispose();
      return result;
    });

Future<void> _saveImage(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('build/training-history-qa')
      ..createSync(recursive: true);
    File(
      '${directory.path}/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    for (final family in {
      'Archivo': ['Archivo-Regular.ttf', 'Archivo-SemiBold.ttf'],
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
    final symbols = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await symbols.load();
  });

  testWidgets(
    'actual input, last time, failed completion and retry preserve one immutable candidate',
    (tester) async {
      final previousController = TrainingSessionController(
        plan: timerPlan(),
        workoutIndex: 1,
        autoTick: false,
      );
      previousController.start();
      previousController.setCurrentActual(reps: 6, weightKg: 15);
      previousController.completeCurrentSet();
      final previous = previousController.completion();
      previousController.dispose();
      final attempts = <TrainingHistoryEntry>[];
      final checkpoints = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        TrainingPlayerScreen(
          plan: timerPlan(),
          workoutIndex: 1,
          history: [previous],
          onPersist: (value) async => checkpoints.add(value),
          onComplete: (value) async {
            attempts.add(value);
            if (attempts.length == 1) throw StateError('fixture disk failure');
          },
        ),
      );
      expect(find.text('Last time'), findsOneWidget);
      final reps = find.byKey(const ValueKey('training-actual-reps'));
      await tester.ensureVisible(reps);
      await tester.enterText(reps, '5');
      final weight = find.byKey(const ValueKey('training-actual-weight'));
      await tester.ensureVisible(weight);
      await tester.enterText(weight, '17,5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await _tap(tester, 'training-timer-primary');
      await _tap(tester, 'training-timer-primary');
      await _saveImage(tester, 'completion-review');
      await _tap(tester, 'training-timer-primary');
      await _tap(tester, 'training-timer-confirm-exit');
      expect(attempts.single.snapshot.actualSets.single.reps, 5);
      expect(attempts.single.snapshot.actualSets.single.weightKg, 17.5);
      expect(checkpoints.where((s) => s == null), isEmpty);
      expect(find.byType(TrainingPlayerScreen), findsOneWidget);
      await _tap(tester, 'training-timer-retry');
      expect(attempts, hasLength(2));
      expect(attempts.last.toRow(), attempts.first.toRow());
      expect(find.text('Open fixture'), findsOneWidget);
    },
  );

  testWidgets('ordinary review note remains in a saved recovery checkpoint', (
    tester,
  ) async {
    TrainingSessionSnapshot? checkpoint;
    final entry = _entry();
    await _host(
      tester,
      TrainingPlayerScreen(
        initialSnapshot: entry.snapshot,
        onPersist: (value) async => checkpoint = value,
        onComplete: (_) async {},
      ),
    );
    final note = find.byKey(const ValueKey('training-history-note'));
    await tester.ensureVisible(note);
    await tester.enterText(note, 'Keep this note');
    await tester.pumpAndSettle();
    expect(checkpoint!.recoveryNote, 'Keep this note');
    final restored = TrainingSessionSnapshot.fromJson(checkpoint!.toJson());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _host(
      tester,
      TrainingPlayerScreen(
        initialSnapshot: restored,
        onPersist: (_) async {},
        onComplete: (_) async {},
      ),
    );
    expect(find.text('Keep this note'), findsOneWidget);
  });

  testWidgets(
    'restored pending completion retries identical note and timestamp without edits',
    (tester) async {
      final entry = _entry();
      TrainingHistoryEntry? saved;
      await _host(
        tester,
        TrainingPlayerScreen(
          initialSnapshot: entry.recoverySnapshot(),
          onPersist: (_) async {},
          onComplete: (value) async => saved = value,
        ),
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('training-timer-discard')),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, 'training-timer-retry');
      expect(saved!.toRow(), entry.toRow());
      expect(find.text('Open fixture'), findsOneWidget);
    },
  );

  testWidgets(
    'retired source exits without completion or recovery-clear claim',
    (tester) async {
      final values = <TrainingSessionSnapshot?>[];
      await _host(
        tester,
        TrainingPlayerScreen(
          plan: timerPlan(),
          onPersist: (value) async => values.add(value),
          onComplete: (_) async =>
              throw const TrainingCompletionSourceRetired(),
        ),
      );
      await _tap(tester, 'training-timer-finish');
      await _tap(tester, 'training-timer-confirm-exit');
      expect(find.text('Open fixture'), findsOneWidget);
      expect(values.where((s) => s == null), isEmpty);
      expect(
        find.text('Your plan changed. This workout was not saved.'),
        findsOneWidget,
      );
    },
  );

  for (final locale in ['de', 'en']) {
    testWidgets('history and detail reflow at 320 px and 2x text in $locale', (
      tester,
    ) async {
      final entry = _entry();
      await _host(
        tester,
        TrainingHistoryScreen(
          entries: [entry],
          onDelete: (_) async => SyncDelivery.delivered,
        ),
        locale: locale,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      await _saveImage(tester, 'history-$locale-320');
      await _tap(tester, 'training-history-${entry.id}');
      expect(tester.takeException(), isNull);
      await _saveImage(tester, 'history-detail-$locale-320');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('training-history-delete')),
        250,
      );
      await tester.pump();
      final rect = tester.getRect(
        find.byKey(const ValueKey('training-history-delete')),
      );
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'history deletion failure remains retryable; dismissal changes nothing',
    (tester) async {
      var deletes = 0;
      await _host(
        tester,
        TrainingHistoryDetail(
          entry: _entry(),
          onDelete: (_) async {
            deletes++;
            if (deletes == 1) throw StateError('fixture failure');
            return SyncDelivery.delivered;
          },
        ),
      );
      await _tap(tester, 'training-history-delete');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await _tap(tester, 'training-history-delete');
      await tester.tap(find.text('Delete workout').last);
      await tester.pumpAndSettle();
      expect(
        find.text('The workout could not be deleted. Try again.'),
        findsOneWidget,
      );
      await _tap(tester, 'training-history-delete');
      await tester.tap(find.text('Delete workout').last);
      await tester.pumpAndSettle();
      expect(deletes, 2);
      expect(find.text('Open fixture'), findsOneWidget);
    },
  );
}
