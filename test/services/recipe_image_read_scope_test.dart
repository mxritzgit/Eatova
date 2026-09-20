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

class _PendingDirectoryDelete implements Directory {
  _PendingDirectoryDelete(this.directory, this.started, this.release);
  final Directory directory;
  final Completer<void> started;
  final Completer<void> release;
  @override
  Future<bool> exists() => directory.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    started.complete();
    await release.future;
    return directory.delete(recursive: recursive);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('same-session refresh preserves photos but same-account new session purges', () async {
    final root = await Directory.systemTemp.createTemp('eatova_image_binding_');
    final store = RecipeImageStore(baseDirectory: () async => root);
    try {
      await store.setActiveUser('account-a', sessionId: 'session-1');
      await store.saveProposalImage(messageId: 'old', bytes: Uint8List.fromList([1]));
      final scope = store.scopeToken;
      await store.setActiveUser('account-a', sessionId: 'session-1');
      expect(store.scopeToken, same(scope));
      expect(await store.readProposalImage('old'), [1]);
      await store.setActiveUser('account-a', sessionId: 'session-2');
      expect(store.scopeToken, isNot(same(scope)));
      expect(await store.readProposalImage('old'), isNull);
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('new-session writes wait until an already-running purge finishes IO', () async {
    final root = await Directory.systemTemp.createTemp('eatova_image_purge_io_');
    final store = RecipeImageStore(baseDirectory: () async => root);
    final started = Completer<void>();
    final release = Completer<void>();
    try {
      await store.setActiveUser('account-a', sessionId: 'old');
      await store.saveProposalImage(messageId: 'old', bytes: Uint8List.fromList([1]));
      final directory = Directory('${root.path}/account-a');
      final purge = IOOverrides.runZoned(
        () => store.clear(expectedUserId: 'account-a', expectedSessionId: 'old'),
        createDirectory: (path) => path == directory.path
          ? _PendingDirectoryDelete(directory, started, release)
          : Zone.root.run(() => Directory(path)),
      );
      await started.future;
      final binding = store.setActiveUser('account-a', sessionId: 'new');
      final save = store.saveProposalImage(messageId: 'new', bytes: Uint8List.fromList([2]));
      release.complete();
      await purge;
      await binding;
      expect(await save, isTrue);
      expect(await store.readProposalImage('new'), [2]);
    } finally {
      if (!release.isCompleted) release.complete();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('delayed old-session cleanup preserves photos after same-account login', () async {
    final root = await Directory.systemTemp.createTemp('eatova_image_session_');
    final store = RecipeImageStore(baseDirectory: () async => root);
    try {
      await store.setActiveUser('account-a', sessionId: 'old-session');
      await store.saveProposalImage(messageId: 'old', bytes: Uint8List.fromList([1]));
      await store.setActiveUser(null);
      await store.setActiveUser('account-a', sessionId: 'new-session');
      await store.saveProposalImage(messageId: 'new', bytes: Uint8List.fromList([2]));
      final scope = store.scopeToken;
      await store.clear(expectedUserId: 'account-a', expectedSessionId: 'old-session');
      expect(await store.readProposalImage('new'), [2]);
      expect(store.scopeToken, same(scope));
      await store.clear(expectedUserId: 'account-a', expectedSessionId: 'new-session');
      expect(await store.readProposalImage('new'), isNull);
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

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
