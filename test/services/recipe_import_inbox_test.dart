import 'dart:async';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/services/recipe_import_inbox.dart';
import 'package:eatova/src/services/recipe_share_receiver.dart';
import 'package:flutter_test/flutter_test.dart';

class _Receiver extends RecipeShareReceiver {
  final events = StreamController<SharedRecipeSource>.broadcast(sync: true);
  Completer<void>? clear;
  int clears = 0;
  int starts = 0;
  int refreshes = 0;
  final owners = <String?>[];
  @override
  Stream<SharedRecipeSource> get shares => events.stream;
  @override
  Future<void> start() async {
    expect(owners, isNotEmpty);
    starts++;
  }

  @override
  void bindOwner(String? ownerKey) {
    super.bindOwner(ownerKey);
    owners.add(ownerKey);
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<void> clearPending() async {
    clears++;
    await clear?.future;
  }

  @override
  Future<void> dispose() => events.close();
  void share(String id) =>
      events.add(SharedRecipeSource(id: id, text: 'recipe $id'));
}

void main() {
  const alice = EatovaUser(id: 'a', sessionId: 'a-session');
  const bob = EatovaUser(id: 'b', sessionId: 'b-session');

  test(
    'cold signed-out share waits for explicit login and is consumed once',
    () async {
      final receiver = _Receiver();
      final inbox = RecipeImportInbox(receiver);
      addTearDown(inbox.dispose);
      await inbox.start();
      expect(receiver.starts, 0);
      inbox.bindUser(null);
      expect(receiver.starts, 1);
      receiver.share('first');
      expect(inbox.take(), isNull);
      inbox.bindUser(alice);
      expect(inbox.take()?.id, 'first');
      expect(inbox.take(), isNull);
      expect(receiver.clears, 0);
    },
  );

  test('restored identity is bound before the first native drain', () async {
    final receiver = _Receiver();
    final inbox = RecipeImportInbox(receiver);
    addTearDown(inbox.dispose);
    await inbox.start();
    receiver.share('before-auth-is-known');
    inbox.bindUser(alice);
    expect(receiver.starts, 1);
    expect(receiver.owners.single, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(receiver.owners.single, isNot(contains('a-session')));
    expect(inbox.take(), isNull);
    final firstOwner = receiver.owners.single;
    inbox.bindUser(alice);
    expect(receiver.owners, [firstOwner]);
    inbox.bindUser(bob);
    await Future<void>.delayed(Duration.zero);
    expect(receiver.owners.last, isNot(firstOwner));
    expect(receiver.refreshes, 1);
  });

  test(
    'logout-login while clear is pending neither leaks nor wedges inbox',
    () async {
      final receiver = _Receiver()..clear = Completer<void>();
      final inbox = RecipeImportInbox(receiver);
      addTearDown(inbox.dispose);
      await inbox.start();
      inbox.bindUser(alice);
      receiver.share('alice-private');
      final generation = inbox.generation;
      inbox.bindUser(null);
      inbox.bindUser(bob);
      expect(inbox.generation, greaterThan(generation));
      receiver.share('late-old-share');
      expect(inbox.take(), isNull);
      receiver.clear!.complete();
      await Future<void>.delayed(Duration.zero);
      receiver.share('bob-new-share');
      expect(inbox.take()?.id, 'bob-new-share');
      expect(inbox.take(), isNull);
    },
  );

  test(
    'same-user new session retires pending sources but token refresh does not',
    () async {
      final receiver = _Receiver();
      final inbox = RecipeImportInbox(receiver);
      addTearDown(inbox.dispose);
      await inbox.start();
      inbox.bindUser(alice);
      receiver.share('keep');
      final generation = inbox.generation;
      inbox.bindUser(const EatovaUser(id: 'a', sessionId: 'a-session'));
      expect(inbox.generation, generation);
      expect(inbox.take()?.id, 'keep');
      receiver.share('retire');
      inbox.bindUser(const EatovaUser(id: 'a', sessionId: 'new-session'));
      await Future<void>.delayed(Duration.zero);
      expect(inbox.take(), isNull);
      expect(receiver.clears, 1);
    },
  );

  test(
    'failed native clear blocks subsequent sources for that owner',
    () async {
      final receiver = _Receiver()..clear = Completer<void>();
      final inbox = RecipeImportInbox(receiver);
      addTearDown(inbox.dispose);
      await inbox.start();
      inbox.bindUser(alice);
      inbox.bindUser(bob);
      receiver.clear!.completeError(StateError('protected store unavailable'));
      await Future<void>.delayed(Duration.zero);
      receiver.share('untrusted-retained-source');
      expect(inbox.take(), isNull);
    },
  );
}
