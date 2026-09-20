import 'dart:io';

import 'package:eatova/src/services/sqlite_key_value_store.dart';

// A real child process, deliberately killed without Dart cleanup by its test.
Future<void> main(List<String> arguments) async {
  final store = await SqliteKeyValueStore.open(arguments[0]);
  final mode = arguments[1];
  Future<void> checkpoint() async {
    stdout.writeln('CRASH_CHECKPOINT');
    await stdout.flush();
    await stdin.first;
  }

  if (mode == 'before_commit') {
    await store.initializeExclusively(() async {
      await store.setString('entity', 'new');
      await checkpoint();
      await store.setString('outbox', 'new-op');
    });
  } else if (mode == 'after_commit') {
    await store.writeBatch({'entity': 'new', 'outbox': 'new-op'});
    await checkpoint();
  } else if (mode == 'sequential_control') {
    // Deliberately faulty control: the same crash detects a partial write.
    await store.setString('entity', 'new');
    await checkpoint();
    await store.setString('outbox', 'new-op');
  } else {
    throw ArgumentError('Unknown crash scenario');
  }
  await store.close();
}
