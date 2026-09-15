import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixlauf_a_helpers.dart';

class _PausedClear extends InMemoryKeyValueStore {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> remove(String key) async {
    if (key == 'eatova.v1.profile.$kFixlaufUser') {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    await super.remove(key);
  }
}

class _PausedNotifications extends NoopNotificationService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> cancelAll() async {
    started.complete();
    await release.future;
  }
}

Map<String, dynamic> _session(String id) => {
  'access_token': 'synthetic-token-$id',
  'refresh_token': 'synthetic-refresh-$id',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'created_at': '2026-09-15T00:00:00Z',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final deletion in [false, true]) {
    test('${deletion ? 'delete account' : 'logout'} before boot clears A cache '
        'even when the shared client has switched to B', () async {
      final a = (await LocalCache.create(kFixlaufUser))!;
      final b = (await LocalCache.create('account-b'))!;
      addTearDown(a.close);
      addTearDown(b.close);
      await a.writeProfile(const UserProfile(weightKg: 70));
      await b.writeProfile(const UserProfile(weightKg: 80));
      final prefs = await SharedPreferences.getInstance();
      final beforeB = prefs.getString('eatova.v1.profile.account-b');
      expect(beforeB, isNotNull);
      final notifications = _PausedNotifications();
      final setup = fixlaufSetup(ohneCache: true, notifications: notifications);
      final client = setup.store.sync!.client;
      await client.auth.setInitialSession(jsonEncode(_session(kFixlaufUser)));
      RecipeImageStore.instance = StummerFotoStore();
      addTearDown(RecipeImageStore.resetInstance);
      Future<void> cleanup() async {
        if (deletion) {
          expect(await setup.store.deleteAccount(), isTrue);
        } else {
          await setup.store.signOutCleanup();
        }
      }
      final pending = cleanup();
      await notifications.started.future;
      await client.auth.setInitialSession(jsonEncode(_session('account-b')));
      notifications.release.complete();
      await pending;

      expect(prefs.getString('eatova.v1.profile.account-b') == beforeB, isTrue,
          reason: 'The fallback must not erase the new account cache.');
      expect(prefs.getString('eatova.v1.profile.$kFixlaufUser'), isNull,
          reason: 'The initiating account cache still needs deletion.');
    });

    for (final switchAccount in [false, true]) {
      test('${deletion ? 'delete account' : 'logout'} cleans only the owner '
          '${switchAccount ? 'after switching A to B' : 'without a switch'}',
          () async {
        final root = await Directory.systemTemp.createTemp('eatova_cleanup_owner_');
        final images = RecipeImageStore(baseDirectory: () async => root);
        RecipeImageStore.instance = images;
        final storage = _PausedClear();
        final setup = fixlaufSetup(cache: LocalCache(storage, kFixlaufUser));
        Future<void> cleanup() async {
          if (deletion) {
            expect(await setup.store.deleteAccount(), isTrue);
          } else {
            await setup.store.signOutCleanup();
          }
        }

        try {
          await images.setActiveUser(kFixlaufUser);
          await images.saveProposalImage(messageId: 'a', bytes: Uint8List.fromList([1]));
          final pending = cleanup();
          await storage.started.future;
          if (switchAccount) {
            await images.setActiveUser('account-b');
            await images.saveProposalImage(messageId: 'b', bytes: Uint8List.fromList([2]));
          }
          final scope = images.scopeToken;
          storage.release.complete();
          await pending;

          if (switchAccount) {
            expect(await images.readProposalImage('b'), [2],
                reason: 'A cleanup must not remove B personal images.');
            expect(images.scopeToken, same(scope));
          } else {
            expect(await images.readProposalImage('a'), isNull,
                reason: 'The legitimate owner cleanup still removes photos.');
          }
        } finally {
          if (!storage.release.isCompleted) storage.release.complete();
          RecipeImageStore.resetInstance();
          if (await root.exists()) await root.delete(recursive: true);
        }
      });
    }
  }
}
