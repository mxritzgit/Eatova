import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// P2-02, store side: the gate cancels on the session ends it sees
// (test/auth_gate_device_schedules_test.dart). Pinned here:
//  * a cold start whose user has reminders OFF still cancels what an earlier
//    account scheduled (it used to return before touching the OS);
//  * a store whose session already ended cannot schedule from a late
//    continuation, which would land after the gate's cancel;
//  * a throwing notification layer does not fail the sign-out.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

class _Spy implements NotificationService, NotificationPermissionProbe {
  _Spy({this.permission, this.cancelThrows = false});

  /// When set, the permission dialog stays open until it completes.
  final Completer<bool>? permission;
  final bool cancelThrows;
  int cancelAllCalls = 0;
  int hasPermissionCalls = 0;
  final List<List<NotificationSpec>> scheduled = [];

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => permission?.future ?? true;

  @override
  Future<bool> hasPermission() async {
    hasPermissionCalls++;
    return true;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    if (cancelThrows) throw StateError('plugin kaputt');
  }
}

HomeStore _store(
  LocalCache cache,
  NotificationService notifications, {
  EatovaSync? sync,
}) =>
    HomeStore(
      sync: sync,
      health: const NoopHealthService(),
      notificationService: notifications,
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

String _session(String userId, String sid) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return jsonEncode({
    'access_token': '${encode({'alg': 'HS256'})}.'
        '${encode({'session_id': sid, 'exp': 4102444800})}.signatur',
    'refresh_token': 'refresh-$sid',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': userId,
      'aud': 'authenticated',
      'created_at': '2026-09-20T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Kaltstart mit Erinnerungen aus', () {
    for (final (label, flag) in [('ausgeschaltet', false), ('nie gesetzt', null)]) {
      test('Opt-in $label: Erinnerungen eines frueheren Kontos werden '
          'verworfen, ohne das OS zu fragen', () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-b');
        if (flag != null) await cache.writeNotificationsEnabled(flag);
        final spy = _Spy();

        await _store(cache, spy).initNotificationsFromCache();

        expect(spy.cancelAllCalls, 1,
            reason: 'Sonst feuert A\'s Streak-Erinnerung weiter bei B, der '
                'Erinnerungen gar nicht eingeschaltet hat.');
        expect(spy.hasPermissionCalls, 0);
        expect(spy.scheduled, isEmpty);
      });
    }

    test('ein werfender Cancel bricht den Kaltstart nicht ab', () async {
      final reports = <String?>[];
      CrashReporter.debugSentrySink = (error, stack, context) =>
          reports.add(context);
      addTearDown(() => CrashReporter.debugSentrySink = null);
      final cache = LocalCache(InMemoryKeyValueStore(), 'user-b');

      await expectLater(
        _store(cache, _Spy(cancelThrows: true)).initNotificationsFromCache(),
        completes,
      );
      expect(reports, ['notifications-cold-start-cancel']);
    });
  });

  group('Session endet waehrend der Systemdialog offen ist', () {
    late SupabaseClient client;

    setUp(() async {
      client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: MockClient((request) async =>
            http.Response('{}', 200, request: request)),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.setInitialSession(_session('user-a', 'sitzung-a'));
    });

    tearDown(() => client.dispose());

    Future<_Spy> optInWhile(Future<void> Function() sessionChange) async {
      final dialog = Completer<bool>();
      final spy = _Spy(permission: dialog);
      final store = _store(
        LocalCache(InMemoryKeyValueStore(), 'user-a'),
        spy,
        sync: EatovaSync.forUser(client, 'user-a'),
      );
      addTearDown(store.dispose);

      final optIn = store.setNotificationsEnabled(true);
      await pumpEventQueue();
      await sessionChange();
      dialog.complete(true);
      await optIn;
      return spy;
    }

    test('Kontrolle: ohne Wechsel plant der Store', () async {
      final spy = await optInWhile(() async {});
      expect(spy.scheduled, hasLength(1));
    });

    test('direkter Wechsel zu B: A plant nichts mehr nach', () async {
      final spy = await optInWhile(() =>
          client.auth.setInitialSession(_session('user-b', 'sitzung-b')));
      expect(spy.scheduled, isEmpty,
          reason: 'Das Gate hat schon verworfen; A\'s spaete Planung wuerde '
              'danach bei B weiterfeuern.');
    });

    test('Session-Verlust: A plant nichts mehr nach', () async {
      final spy = await optInWhile(
          () => client.auth.signOut(scope: SignOutScope.local));
      expect(spy.scheduled, isEmpty);
    });
  });

  test('ein werfender Cancel haelt den Sign-Out nicht auf und wird gemeldet',
      () async {
    final reports = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) =>
        reports.add(context);
    addTearDown(() => CrashReporter.debugSentrySink = null);
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
    await cache.writeNotificationsEnabled(true);

    await expectLater(
      _store(cache, _Spy(cancelThrows: true)).signOutCleanup(),
      completes,
    );

    expect(reports, contains('sign-out-notification-cancel'));
    expect(await cache.readNotificationsEnabled(), isNull,
        reason: 'der restliche Cleanup lief trotzdem');
  });
}
