import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/background_sync_scheduler.dart';

class _Driver implements BackgroundSyncDriver {
  final scheduled = <({Duration delay, int attempt, bool followUp})>[];
  int cancelled = 0;
  bool fail = false;

  @override
  Future<void> schedule({
    required Duration delay,
    required int attempt,
    required bool followUp,
  }) async {
    if (fail) throw StateError('OS declined');
    scheduled.add((delay: delay, attempt: attempt, followUp: followUp));
  }

  @override
  Future<void> cancel() async {
    cancelled++;
  }
}

void main() {
  test('OS-Retries sind begrenzt und mit wachsendem Abstand geplant', () async {
    final driver = _Driver();
    final scheduler = PlatformBackgroundSyncScheduler(driver: driver);
    await scheduler.request();
    for (var attempt = -1; attempt < 6; attempt++) {
      await scheduler.retry(attempt);
    }
    expect(driver.scheduled, [
      (delay: const Duration(seconds: 30), attempt: 0, followUp: false),
      (delay: const Duration(minutes: 15), attempt: 1, followUp: true),
      (delay: const Duration(minutes: 30), attempt: 2, followUp: true),
      (delay: const Duration(minutes: 60), attempt: 3, followUp: true),
    ]);
    await scheduler.cancel();
    expect(driver.cancelled, 1);
  });

  test('OS-Ablehnung bricht weder Save noch Foreground-Sync ab', () async {
    final driver = _Driver()..fail = true;
    final scheduler = PlatformBackgroundSyncScheduler(driver: driver);
    await scheduler.request();
    driver.fail = false;
    await scheduler.request();
    expect(driver.scheduled, hasLength(1));
  });
}
