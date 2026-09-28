import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/services/background_sync_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 9, 20, 12);
final _exp = _now.millisecondsSinceEpoch ~/ 1000 + 3600;

Map<String, Object?> _claims() => {
  'sub': 'A',
  'session_id': 'session-A',
  'role': 'authenticated',
  'exp': _exp,
};

String _token(Map<String, Object?> claims) {
  final payload = base64Url
      .encode(utf8.encode(jsonEncode(claims)))
      .replaceAll('=', '');
  return 'header.$payload.signature';
}

Map<String, Object?> _session({Map<String, Object?>? claims}) => {
  'user': {'id': 'A'},
  'access_token': _token(claims ?? _claims()),
};

BackgroundSyncSession? _decode(Object? persisted) => withClock(
  Clock.fixed(_now),
  () => BackgroundSyncSession.fromPersisted(jsonEncode(persisted)),
);

Map<String, Object?> _without(Map<String, Object?> map, String key) =>
    Map.of(map)..remove(key);

void main() {
  test('a complete session decodes to its user, session and expiry', () {
    final session = _decode(_session())!;
    expect(session.userId, 'A');
    expect(session.sessionId, 'session-A');
    expect(session.accessToken, _token(_claims()));
    expect(session.expiresAt, _now.add(const Duration(hours: 1)));
  });

  group('the envelope rejects', () {
    final cases = <String, Object?>{
      'a list': [_session()],
      'an omitted user': _without(_session(), 'user'),
      'a null user': {..._session(), 'user': null},
      'a non-map user': {..._session(), 'user': 'A'},
      'an omitted user id': {..._session(), 'user': <String, Object?>{}},
      'a null user id': {
        ..._session(),
        'user': {'id': null},
      },
      'a numeric user id': {
        ..._session(),
        'user': {'id': 7},
      },
      'an empty user id': {
        ..._session(),
        'user': {'id': ''},
      },
      'an omitted token': _without(_session(), 'access_token'),
      'a null token': {..._session(), 'access_token': null},
      'a numeric token': {..._session(), 'access_token': 42},
      'a two-part token': {..._session(), 'access_token': 'a.b'},
      'a token with invalid base64': {
        ..._session(),
        'access_token': 'a.%%%.c',
      },
      'a token with non-JSON claims': {
        ..._session(),
        'access_token':
            'a.${base64Url.encode(utf8.encode('nope')).replaceAll('=', '')}.c',
      },
      'a token with list claims': {
        ..._session(),
        'access_token':
            'a.${base64Url.encode(utf8.encode('[]')).replaceAll('=', '')}.c',
      },
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(_decode(entry.value), isNull));
    }
  });

  group('the claims reject', () {
    final cases = <String, Map<String, Object?>>{
      'an omitted subject': _without(_claims(), 'sub'),
      'a null subject': {..._claims(), 'sub': null},
      'another subject': {..._claims(), 'sub': 'B'},
      'an omitted role': _without(_claims(), 'role'),
      'a null role': {..._claims(), 'role': null},
      'the anon role': {..._claims(), 'role': 'anon'},
      'an omitted session id': _without(_claims(), 'session_id'),
      'a null session id': {..._claims(), 'session_id': null},
      'an empty session id': {..._claims(), 'session_id': ''},
      'a numeric session id': {..._claims(), 'session_id': 7},
      'an omitted expiry': _without(_claims(), 'exp'),
      'a null expiry': {..._claims(), 'exp': null},
      'a fractional expiry': {..._claims(), 'exp': _exp + 0.5},
      'a string expiry': {..._claims(), 'exp': '$_exp'},
      'an expiry inside the safety margin': {
        ..._claims(),
        'exp': _now.millisecondsSinceEpoch ~/ 1000 + 60,
      },
    };
    for (final entry in cases.entries) {
      test(
        entry.key,
        () => expect(_decode(_session(claims: entry.value)), isNull),
      );
    }
  });

  test('an empty user id is rejected even with a matching empty subject', () {
    expect(
      _decode({
        'user': {'id': ''},
        'access_token': _token({..._claims(), 'sub': ''}),
      }),
      isNull,
    );
  });

  test('extra envelope and claim keys are ignored', () {
    final session = _decode({
      ..._session(claims: {..._claims(), 'aal': 'aal1'}),
      'refresh_token': 'never-read',
      'expires_in': 3600,
    });
    expect(session?.userId, 'A');
  });

  test('oversized and absent encodings are rejected before decoding', () {
    expect(BackgroundSyncSession.fromPersisted(null), isNull);
    expect(BackgroundSyncSession.fromPersisted('x' * 65537), isNull);
    expect(BackgroundSyncSession.fromPersisted('{'), isNull);
  });
}
