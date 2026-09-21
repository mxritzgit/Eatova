import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/durable_cache_store.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'outbox/outbox_test_helpers.dart' as h;
import 'support/harness.dart';

Future<void> pumpUntilComplete(
  WidgetTester tester,
  bool Function() completed,
  String reason,
) async {
  for (var i = 0; i < 500 && !completed(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(completed(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const outbox = 'eatova.v1.outbox.user-outbox';
  late Directory directory;
  late h.FakeServer server;
  late SupabaseClient client;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('eatova_rollback_ui_');
    LocalCache.debugDatabasePath = '${directory.path}/cache.sqlite';
    CacheKeyProvider.debugReset();
    SharedPreferences.setMockInitialValues({outbox: '{"items":[]}'});
    FlutterSecureStorage.setMockInitialValues({
      CacheKeyProvider.dekStorageKey: base64Encode(List.filled(32, 12)),
    });
    server = h.FakeServer();
    client = SupabaseClient(
      'https://ci.invalid',
      'ci-dummy-key',
      httpClient: server.client(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final cache = (await LocalCache.create('user-outbox'))!;
    await cache.releaseStorage();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(outbox, 'preserved-obsolete-offline-write');
    CacheKeyProvider.debugReset();
  });

  tearDown(() {
    CacheKeyProvider.debugReset();
    LocalCache.debugDatabasePath = null;
  });

  for (final language in ['de', 'en']) {
    testWidgets('obsolete writer recovery screen is actionable in $language', (
      tester,
    ) async {
      HomeStore? store;
      try {
        final home = EatovaHomePage(
          sync: EatovaSync.forUser(client, 'user-outbox'),
          showWelcome: false,
        );
        await pumpLocalized(
          tester,
          home,
          locale: Locale(language),
          scaffold: false,
          safeArea: false,
        );
        store =
            (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
                .debugStore;
        final localizations = language == 'de' ? deL10n : enL10n;
        final title = find.text(localizations.commonLegacyStorageConflictTitle);
        await pumpUntilComplete(
          tester,
          () => title.evaluate().isNotEmpty && !store!.bootLoadInFlight,
          'Initial storage conflict recovery must finish before retry.',
        );
        expect(title, findsOneWidget);
        expect(
          find.text(localizations.commonLegacyStorageConflictBody),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
        expect(server.requests, isEmpty);
        await tester.tap(find.byKey(const ValueKey('boot-unanswered-retry')));
        expect(store.bootLoadInFlight, isTrue);
        await pumpUntilComplete(
          tester,
          () => !store!.bootLoadInFlight,
          'Retry must finish; the existing conflict title also stays visible while busy.',
        );
        expect(title, findsOneWidget);
        expect(server.requests, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(outbox), 'preserved-obsolete-offline-write');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        if (store != null) {
          var released = false;
          // The release continuation belongs to the fake zone; keep pumping it.
          store.storageReleased.then((_) => released = true);
          await pumpUntilComplete(
            tester,
            () => released,
            'Storage must release after disposal.',
          );
        }
        await tester.runAsync(() async {
          await DurableCacheStore.closeAll();
          await client.dispose();
          await directory.delete(recursive: true);
        });
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
