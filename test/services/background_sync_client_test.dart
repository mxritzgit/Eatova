import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';
import 'package:eatova/src/services/background_sync_client.dart';
import 'package:eatova/src/services/user_rpc.dart';

String encodedSession({String user = 'A', String subject = 'A', int? expiry}) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': subject,
            'session_id': 'session-A',
            'role': 'authenticated',
            'exp':
                expiry ??
                DateTime.utc(2026, 9, 20, 14).millisecondsSinceEpoch ~/ 1000,
          }),
        ),
      )
      .replaceAll('=', '');
  return jsonEncode({
    'user': {'id': user},
    'access_token': 'header.$payload.signature',
    'refresh_token': 'must-never-be-used',
  });
}

void main() {
  test(
    'headless RPC nutzt festen Token ohne Auth-Recovery oder Refresh',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
        final session = BackgroundSyncSession.fromPersisted(encodedSession())!;
        final requests = <http.Request>[];
        final client = BackgroundSyncClient(
          url: 'https://example.invalid',
          anonKey: 'dummy',
          session: session,
          permitted: () async => true,
          transport: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200, request: request);
          }),
        );
        addTearDown(client.dispose);
        await userRpc(client, 'A', 'apply_sync_operation');
        expect(requests.single.url.path, '/rest/v1/rpc/apply_sync_operation');
        expect(
          requests.single.headers['authorization'],
          'Bearer ${session.accessToken}',
        );
        expect(() => client.auth, throwsA(isA<AuthException>()));
        expect(
          requests.where((request) => request.url.path.contains('/auth/')),
          isEmpty,
        );
      });
    },
  );

  test(
    'falscher Owner und widerrufener Guard schicken keinen Request',
    () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () async {
        var allowed = true;
        var requests = 0;
        final client = BackgroundSyncClient(
          url: 'https://example.invalid',
          anonKey: 'dummy',
          session: BackgroundSyncSession.fromPersisted(encodedSession())!,
          permitted: () async => allowed,
          transport: MockClient((request) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        await expectLater(
          userRpc(client, 'B', 'apply_sync_operation'),
          throwsA(isA<AuthException>()),
        );
        allowed = false;
        await expectLater(
          userRpc(client, 'A', 'apply_sync_operation'),
          throwsA(isA<AuthException>()),
        );
        expect(requests, 0);
      });
    },
  );

  test(
    'Tokenablauf waehrend Run sperrt weitere Requests ohne Refresh',
    () async {
      var now = DateTime.utc(2026, 9, 20, 12);
      await withClock(Clock(() => now), () async {
        var requests = 0;
        final client = BackgroundSyncClient(
          url: 'https://example.invalid',
          anonKey: 'dummy',
          session: BackgroundSyncSession.fromPersisted(encodedSession())!,
          permitted: () async => true,
          transport: MockClient((request) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        now = DateTime.utc(2026, 9, 20, 13, 58);
        await expectLater(
          userRpc(client, 'A', 'apply_sync_operation'),
          throwsA(isA<AuthException>()),
        );
        expect(requests, 0);
      });
    },
  );

  test('Sessiondecoder lehnt Ablauf, Ownerabweichung und defekte Daten ab', () {
    withClock(Clock.fixed(DateTime.utc(2026, 9, 20, 12)), () {
      expect(BackgroundSyncSession.fromPersisted(null), isNull);
      expect(BackgroundSyncSession.fromPersisted('not-json'), isNull);
      expect(
        BackgroundSyncSession.fromPersisted(encodedSession(subject: 'B')),
        isNull,
      );
      expect(
        BackgroundSyncSession.fromPersisted(encodedSession(expiry: 1)),
        isNull,
      );
      expect(BackgroundSyncSession.fromPersisted(encodedSession()), isNotNull);
    });
  });
}
