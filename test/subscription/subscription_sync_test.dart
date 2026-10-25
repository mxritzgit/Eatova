// The account's plan and purchase verification on the server (docs/PREMIUM.md
// 3.4, 4.2), through a real SupabaseClient over a MockClient: every request
// carries the account's own bearer, a foreign or missing session sends
// nothing, and each answer of subscription-verify maps to one outcome.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/services/billing/billing_client.dart';
import 'package:eatova/src/services/subscription_sync.dart';

import '../support/expired_session.dart' show syntheticJwt;
import '../support/subscription_fakes.dart' show planOf;

const PurchaseProof _proof = PurchaseProof.google(
  productId: 'eatova_premium',
  purchaseToken: 'play-token-1',
);

String _token(String user) => syntheticJwt(user, 4102444800);

typedef _Answer = http.Response Function(http.Request request);

http.Response _json(http.Request request, Object? body, int status) =>
    http.Response(
      jsonEncode(body),
      status,
      request: request,
      headers: const {'content-type': 'application/json'},
    );

/// A client signed in as [sessionUser] (none when null) whose requests land
/// in [seen] and are answered by [answer].
Future<SupabaseClient> _client(
  String? sessionUser,
  List<http.Request> seen,
  _Answer answer,
) async {
  final client = SupabaseClient(
    'https://ci.invalid',
    'ci-dummy-key',
    httpClient: MockClient((request) async {
      seen.add(request);
      return answer(request);
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  if (sessionUser != null) {
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token': _token(sessionUser),
        'refresh_token': 'refresh-$sessionUser',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': sessionUser,
          'aud': 'authenticated',
          'created_at': '2026-09-20T00:00:00Z',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
        },
      }),
    );
  }
  return client;
}

void main() {
  test('nur mit dem eigenen Bearer, eine fremde oder fehlende Sitzung '
      'schickt nichts', () async {
    for (final foreign in <String?>['user-b', null]) {
      final seen = <http.Request>[];
      final log = SupabaseSubscriptionLog(
        await _client(foreign, seen, (r) => _json(r, {}, 200)),
        'user-a',
      );

      expect(
        await log.verify(_proof),
        const VerifyResult(VerifyOutcome.unauthorized),
        reason: '$foreign',
      );
      expect(
        (await log.refresh()).outcome,
        VerifyOutcome.unauthorized,
        reason: '$foreign',
      );
      if (foreign != null) {
        await expectLater(log.fetchPlan(), throwsA(isA<AuthException>()));
        await expectLater(log.accountToken(), throwsA(isA<AuthException>()));
      }
      expect(seen, isEmpty, reason: 'session $foreign');
    }

    final seen = <http.Request>[];
    final log = SupabaseSubscriptionLog(
      await _client(
        'user-a',
        seen,
        (r) => _json(r, {
          'outcome': 'active',
          'plan': planOf(PlanTier.premium).toJson(),
        }, 200),
      ),
      'user-a',
    );
    final result = await log.verify(_proof);

    expect(result.outcome, VerifyOutcome.active);
    expect(result.plan, planOf(PlanTier.premium));
    final request = seen.single;
    expect(request.url.path, '/functions/v1/subscription-verify');
    expect(request.headers['Authorization'], 'Bearer ${_token('user-a')}');
    expect(jsonDecode(request.body), {
      'action': 'verify',
      'platform': 'google',
      'productId': 'eatova_premium',
      'purchaseToken': 'play-token-1',
    });
  });

  test('jede Antwort von subscription-verify hat genau ein Ergebnis', () async {
    final plan = planOf(PlanTier.premium);
    final planJson = plan.toJson();
    http.Response Function(http.Request) answer = (r) => _json(r, {}, 200);
    final log = SupabaseSubscriptionLog(
      await _client('user-a', <http.Request>[], (r) => answer(r)),
      'user-a',
    );

    final rows = <(String, http.Response Function(http.Request), VerifyResult)>[
      (
        'aktiv',
        (r) => _json(r, {'outcome': 'active', 'plan': planJson}, 200),
        VerifyResult(VerifyOutcome.active, plan: plan),
      ),
      (
        'inaktiv',
        (r) => _json(r, {'outcome': 'inactive', 'plan': planJson}, 200),
        VerifyResult(VerifyOutcome.inactive, plan: plan),
      ),
      (
        'aktiv, Plan kaputt',
        (r) => _json(r, {
          'outcome': 'active',
          'plan': {'tier': 'x'},
        }, 200),
        const VerifyResult(VerifyOutcome.active),
      ),
      (
        '200 ohne Ergebnis',
        (r) => _json(r, {'outcome': 'maybe'}, 200),
        const VerifyResult(VerifyOutcome.unavailable),
      ),
      (
        '200 als Text',
        (r) => http.Response('ok', 200, request: r),
        const VerifyResult(VerifyOutcome.unavailable),
      ),
      (
        'ausstehend',
        (r) => _json(r, {'error': 'purchase_pending', 'plan': planJson}, 202),
        VerifyResult(VerifyOutcome.pending, plan: plan),
      ),
      (
        '400',
        (r) => _json(r, {'error': 'invalid_request'}, 400),
        const VerifyResult(VerifyOutcome.invalid),
      ),
      (
        '401',
        (r) => _json(r, {'error': 'invalid_user_token'}, 401),
        const VerifyResult(VerifyOutcome.unauthorized),
      ),
      (
        '409',
        (r) => _json(r, {'error': 'purchase_owned_by_other_account'}, 409),
        const VerifyResult(VerifyOutcome.ownedByOther),
      ),
      (
        // `account` is the reason the controller shows as another account's.
        '422 mit Grund',
        (r) =>
            _json(r, {'error': 'purchase_invalid', 'reason': 'account'}, 422),
        const VerifyResult(VerifyOutcome.invalid, invalidReason: 'account'),
      ),
      (
        '422 mit fremdem Grund',
        (r) => _json(r, {'error': 'purchase_invalid', 'reason': 'x'}, 422),
        const VerifyResult(VerifyOutcome.invalid),
      ),
      (
        '429',
        (r) => _json(r, {'error': 'rate_limited'}, 429),
        const VerifyResult(VerifyOutcome.unavailable),
      ),
      (
        '503',
        (r) => _json(r, {'error': 'store_unavailable'}, 503),
        const VerifyResult(VerifyOutcome.unavailable),
      ),
      (
        'Verbindung weg',
        (r) => throw http.ClientException('offline'),
        const VerifyResult(VerifyOutcome.unavailable),
      ),
    ];
    for (final (name, response, expected) in rows) {
      answer = response;
      expect(await log.verify(_proof), expected, reason: name);
    }

    final requests = <http.Request>[];
    final apple = SupabaseSubscriptionLog(
      await _client(
        'user-a',
        requests,
        (r) => _json(r, {'outcome': 'inactive', 'plan': planJson}, 200),
      ),
      'user-a',
    );
    await apple.verify(
      const PurchaseProof.apple(
        productId: 'eatova_premium_yearly',
        signedTransaction: 'header.payload.signature',
      ),
    );
    await apple.refresh();
    expect(requests.map((r) => jsonDecode(r.body)), [
      {
        'action': 'verify',
        'platform': 'apple',
        'signedTransaction': 'header.payload.signature',
      },
      {'action': 'refresh'},
    ]);
  });

  test(
    'Plan und Konto-Token kommen aus den RPCs, schief heisst Fehler',
    () async {
      Object? plan = planOf(PlanTier.free).toJson();
      Object? token = '00000000-0000-4000-8000-0000000000AB';
      final seen = <http.Request>[];
      final log = SupabaseSubscriptionLog(
        await _client(
          'user-a',
          seen,
          (r) => switch (r.url.path) {
            '/rest/v1/rpc/get_my_plan' => _json(r, plan, 200),
            '/rest/v1/rpc/get_store_account_token' => _json(r, token, 200),
            _ => _json(r, {'message': 'unexpected'}, 404),
          },
        ),
        'user-a',
      );

      expect(await log.fetchPlan(), planOf(PlanTier.free));
      expect(await log.accountToken(), '00000000-0000-4000-8000-0000000000ab');
      expect(await log.accountToken(), '00000000-0000-4000-8000-0000000000ab');
      expect(
        seen.where((r) => r.url.path.endsWith('get_store_account_token')),
        hasLength(1),
        reason: 'the token never changes for an account',
      );
      expect(seen.first.headers['Authorization'], 'Bearer ${_token('user-a')}');

      plan = {'tier': 'premium'};
      await expectLater(log.fetchPlan(), throwsA(isA<FormatException>()));
      token = 'not-a-uuid';
      final fresh = SupabaseSubscriptionLog(
        await _client('user-a', <http.Request>[], (r) => _json(r, token, 200)),
        'user-a',
      );
      await expectLater(fresh.accountToken(), throwsA(isA<FormatException>()));
    },
  );
}
