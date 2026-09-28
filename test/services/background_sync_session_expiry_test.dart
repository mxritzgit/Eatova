import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/background_sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

String _persisted(Object? expiry) {
  final claims = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sub': 'A',
            'session_id': 'session-A',
            'role': 'authenticated',
            'exp': expiry,
          }),
        ),
      )
      .replaceAll('=', '');
  return jsonEncode({
    'user': {'id': 'A'},
    'access_token': 'header.$claims.signature',
  });
}

void main() {
  final now = DateTime.utc(2026, 9, 20, 12);

  test('an overflowing expiry claim is rejected instead of wrapping', () {
    withClock(Clock.fixed(now), () {
      // exp * 1000 wraps past 2^64 to a millisecond value in 2033.
      expect(
        BackgroundSyncSession.fromPersisted(_persisted(18446746073709552)),
        isNull,
      );
      expect(
        BackgroundSyncSession.fromPersisted(
          _persisted(-18446746073709552),
        ),
        isNull,
      );
    });
  });

  test('expiry claims outside the DateTime range are rejected', () {
    withClock(Clock.fixed(now), () {
      for (final expiry in [8640000000001, -8640000000001, 9007199254740991]) {
        expect(
          BackgroundSyncSession.fromPersisted(_persisted(expiry)),
          isNull,
          reason: '$expiry',
        );
      }
    });
  });

  test('the largest representable expiry is still accepted', () {
    withClock(Clock.fixed(now), () {
      final session = BackgroundSyncSession.fromPersisted(
        _persisted(8640000000000),
      );
      expect(session, isNotNull);
      expect(
        session!.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(8640000000000000, isUtc: true),
      );
      expect(
        BackgroundSyncSession.fromPersisted(
          _persisted(now.millisecondsSinceEpoch ~/ 1000 + 3600),
        )?.expiresAt,
        now.add(const Duration(hours: 1)),
      );
    });
  });
}
