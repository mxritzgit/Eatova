import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/services/sqlite_key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

String _dartExecutable() {
  // flutter_tester lives below Flutter's bin/cache. Plain dart test also works.
  var parent = File(Platform.resolvedExecutable).parent;
  final executable = Platform.isWindows ? 'dart.exe' : 'dart';
  while (true) {
    for (final candidate in [
      '${parent.path}/dart-sdk/bin/$executable',
      '${parent.path}/$executable',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    final next = parent.parent;
    if (next.path == parent.path) throw StateError('Dart SDK was not found');
    parent = next;
  }
}

void main() {
  for (final mode in ['before_commit', 'after_commit', 'sequential_control']) {
    test('real process death: $mode', () async {
      final directory = await Directory.systemTemp.createTemp('eatova_crash_');
      final path = '${directory.path}/cache.sqlite';
      Process? child;
      try {
        final initial = await SqliteKeyValueStore.open(path);
        await initial.writeBatch({'entity': 'old', 'outbox': 'old-op'});
        await initial.close();
        child = await Process.start(_dartExecutable(), [
          'run',
          'test/support/sqlite_crash_worker.dart',
          path,
          mode,
        ], workingDirectory: Directory.current.path);
        final stderr = child.stderr.transform(utf8.decoder).join();
        final checkpoint = Completer<int>();
        final output = child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final match = RegExp(
                r'^CRASH_CHECKPOINT (\d+)$',
              ).firstMatch(line);
              if (match != null && !checkpoint.isCompleted) {
                checkpoint.complete(int.parse(match[1]!));
              }
            });
        unawaited(
          child.exitCode.then((code) async {
            if (!checkpoint.isCompleted) {
              checkpoint.completeError(
                StateError('Child exited $code: ${await stderr}'),
              );
            }
          }),
        );
        final worker = await checkpoint.future.timeout(
          const Duration(seconds: 90),
        );
        // On Windows `dart run` hosts the script in a separate VM process and
        // the launcher is not the database holder. Killing only the launcher
        // let the reopen race the worker's teardown: its locks were gone but
        // its -shm view was still mapped, so SQLite's reset of the stale -shm
        // failed (SQLITE_IOERR_TRUNCATE), or the cleanup hit its open files.
        // Kill the process that holds the database; its launcher exits only
        // once that process has terminated. On Linux and macOS `dart run`
        // execs, so both are the same process.
        expect(Process.killPid(worker, ProcessSignal.sigkill), isTrue);
        await child.exitCode;
        await output.cancel();

        final reopened = await SqliteKeyValueStore.open(path);
        try {
          final state = (await reopened.readSnapshot([
            'entity',
            'outbox',
          ])).values;
          expect(state, switch (mode) {
            'before_commit' => {'entity': 'old', 'outbox': 'old-op'},
            'after_commit' => {'entity': 'new', 'outbox': 'new-op'},
            _ => {'entity': 'new', 'outbox': 'old-op'},
          });
          if (mode == 'sequential_control') {
            expect(
              state['entity'] == 'new' && state['outbox'] == 'new-op',
              isFalse,
              reason:
                  'The crash oracle must detect the old split-write design.',
            );
          }
        } finally {
          await reopened.close();
        }
      } finally {
        child?.kill(ProcessSignal.sigkill);
        await child?.exitCode;
        await directory.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
