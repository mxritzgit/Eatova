import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'background_sync.dart';
import 'crash_reporter.dart';

const backgroundSyncTask = 'com.eatova.app.sync';

abstract interface class BackgroundSyncScheduler {
  Future<void> request();
  Future<void> cancel();
}

abstract interface class BackgroundSyncDriver {
  Future<void> schedule({
    required Duration delay,
    required int attempt,
    required bool followUp,
  });
  Future<void> cancel();
}

class _WorkmanagerSyncDriver implements BackgroundSyncDriver {
  @override
  Future<void> schedule({
    required Duration delay,
    required int attempt,
    required bool followUp,
  }) {
    final constraints = Constraints(networkType: NetworkType.connected);
    // No user ID, token or payload is copied into OS job metadata.
    final data = <String, dynamic>{'attempt': attempt};
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return Workmanager().registerProcessingTask(
        backgroundSyncTask,
        backgroundSyncTask,
        initialDelay: delay,
        inputData: data,
        constraints: constraints,
      );
    }
    return Workmanager().registerOneOffTask(
      backgroundSyncTask,
      backgroundSyncTask,
      initialDelay: delay,
      inputData: data,
      constraints: constraints,
      existingWorkPolicy: followUp
          ? ExistingWorkPolicy.append
          : ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );
  }

  @override
  Future<void> cancel() => Workmanager().cancelByUniqueName(backgroundSyncTask);
}

class PlatformBackgroundSyncScheduler implements BackgroundSyncScheduler {
  PlatformBackgroundSyncScheduler({BackgroundSyncDriver? driver})
    : _driver = driver ?? _WorkmanagerSyncDriver();
  final BackgroundSyncDriver _driver;
  static const maxFollowUps = 3;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> initialize() async {
    if (!isSupported) return;
    try {
      await Workmanager().initialize(backgroundSyncDispatcher);
    } catch (error, stack) {
      await CrashReporter.capture(
        error,
        stack,
        context: 'background-sync-init',
      );
    }
  }

  @override
  Future<void> request() => _schedule(attempt: 0, followUp: false);

  Future<void> retry(int previousAttempt) async {
    if (previousAttempt < 0 || previousAttempt >= maxFollowUps) return;
    await _schedule(attempt: previousAttempt + 1, followUp: true);
  }

  Future<void> _schedule({required int attempt, required bool followUp}) async {
    try {
      await _driver.schedule(
        delay: followUp
            ? Duration(minutes: 15 * (1 << (attempt - 1)))
            : const Duration(seconds: 30),
        attempt: attempt,
        followUp: followUp,
      );
    } catch (error, stack) {
      await CrashReporter.capture(
        error,
        stack,
        context: 'background-sync-schedule',
      );
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _driver.cancel();
    } catch (error, stack) {
      await CrashReporter.capture(
        error,
        stack,
        context: 'background-sync-cancel',
      );
    }
  }
}

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  BackgroundSyncRunner? running;
  Workmanager().executeTask(
    (task, input) async {
      if (task != backgroundSyncTask) return true;
      final attempt = input?['attempt'];
      if (attempt is! int ||
          attempt < 0 ||
          attempt > PlatformBackgroundSyncScheduler.maxFollowUps) {
        return true;
      }
      final runner = BackgroundSyncRunner();
      running = runner;
      try {
        final outcome = await runner.run();
        if (outcome == BackgroundSyncOutcome.retry) {
          await PlatformBackgroundSyncScheduler().retry(attempt);
        }
        return true;
      } finally {
        if (identical(running, runner)) running = null;
      }
    },
    onTaskStopped: (_, __) async {
      running?.cancel();
    },
  );
}
