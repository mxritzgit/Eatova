import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Holds only one file read after the bytes have reached the IO boundary. No
// scheduling sleeps: the test switches identity at that exact asynchronous gap.
class _PendingRead implements File {
  _PendingRead(this.file, this.started, this.release);
  final File file;
  final Completer<void> started;
  final Completer<Uint8List> release;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<Uint8List> readAsBytes() {
    started.complete();
    return release.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'delayed account A cleanup preserves account B photos and scope',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'eatova_image_cleanup_',
      );
      final store = RecipeImageStore(baseDirectory: () async => root);
      try {
        await store.setActiveUser('account-a');
        await store.saveProposalImage(
          messageId: 'a',
          bytes: Uint8List.fromList([1]),
        );
        await store.setActiveUser('account-b');
        await store.saveProposalImage(
          messageId: 'b',
          bytes: Uint8List.fromList([2]),
        );
        final scope = store.scopeToken;
        await store.clear(expectedUserId: 'account-a');
        expect(store.scopeToken, same(scope));
        expect(await store.readProposalImage('b'), [2]);
        await store.clear(expectedUserId: 'account-b');
        expect(await store.readProposalImage('b'), isNull);
        expect(store.scopeToken, isNot(same(scope)));
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

  test(
    'in-flight proposal read cannot return account A bytes after switch to B',
    () async {
      final root = await Directory.systemTemp.createTemp('eatova_image_scope_');
      final store = RecipeImageStore(baseDirectory: () async => root);
      final started = Completer<void>();
      final release = Completer<Uint8List>();
      try {
        await store.setActiveUser('account-a');
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        await store.saveProposalImage(messageId: 'proposal-a', bytes: bytes);
        final file = (await store.resolve(
          RecipeImageStore.proposalReference('proposal-a'),
        ))!;
        final pending = IOOverrides.runZoned(
          () => store.readProposalImage('proposal-a'),
          createFile: (path) => path == file.path
              ? _PendingRead(file, started, release)
              : Zone.root.run(() => File(path)),
        );
        await started.future;
        await store.setActiveUser('account-b');
        release.complete(bytes);
        expect(await pending, isNull);
      } finally {
        if (!release.isCompleted) release.complete(Uint8List(0));
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
