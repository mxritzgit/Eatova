import 'dart:async';
import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/plan_status.dart';
import 'billing/billing_client.dart' show PurchaseProof;
import 'user_rpc.dart';

/// What the server made of a store proof (`subscription-verify`, 3.4).
enum VerifyOutcome {
  /// Verified and entitled: Premium.
  active,

  /// Verified, but not entitling (expired, on hold, revoked).
  inactive,

  /// Google reports the payment as pending; nothing is granted yet.
  pending,

  /// The purchase belongs to another Eatova account (409).
  ownedByOther,

  /// The proof failed a check (400, 422); retrying the same proof cannot help.
  invalid,

  /// No answer worth acting on (offline, timeout, 429, 503, off-contract
  /// body): try again later and keep the store transaction open.
  unavailable,

  /// No session of this account (401, or the session changed before the
  /// call): nothing was sent with another account's bearer.
  unauthorized,
}

class VerifyResult {
  const VerifyResult(this.outcome, {this.plan, this.invalidReason});

  final VerifyOutcome outcome;

  /// The account's plan after the call, when the body carried a valid one.
  final PlanStatus? plan;

  /// For [VerifyOutcome.invalid] after a 422: `signature`, `bundle`,
  /// `product`, `environment`, `ownership` or `account`.
  final String? invalidReason;

  @override
  bool operator ==(Object other) =>
      other is VerifyResult &&
      other.outcome == outcome &&
      other.plan == plan &&
      other.invalidReason == invalidReason;

  @override
  int get hashCode => Object.hash(outcome, plan, invalidReason);

  @override
  String toString() => 'VerifyResult(${outcome.name})';
}

/// The account's plan and purchase verification on the server, for ONE
/// account. Every request carries that account's bearer, pinned before the
/// call, so nothing started for one account can land on the next.
abstract interface class SubscriptionLog {
  /// The plan snapshot (`get_my_plan`). Throws when it cannot be read or is
  /// off the contract; the caller keeps what it knew.
  Future<PlanStatus> fetchPlan();

  /// The account's store token (`get_store_account_token`), a lowercase
  /// canonical UUID for `applicationUserName`. Throws on failure.
  Future<String> accountToken();

  /// Verifies a store proof and returns the plan after it. Never throws.
  Future<VerifyResult> verify(PurchaseProof proof);

  /// Has the server re-check the account's stored Google purchases that
  /// expire within 48 h or have expired (`action: refresh`). Never throws.
  Future<VerifyResult> refresh();
}

/// How long one `subscription-verify` call may take: the function calls
/// Google (token, purchase, acknowledge) before it answers.
const Duration kSubscriptionVerifyDeadline = Duration(seconds: 30);

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

const Set<String> _invalidReasons = {
  'signature',
  'bundle',
  'product',
  'environment',
  'ownership',
  'account',
};

/// [SubscriptionLog] over Supabase: the RPCs through `userRpc`, the verify
/// function with a bearer captured before the await like the Coach's
/// `_capturedAuthorization`. Supabase only, so it is safe to build in the
/// background isolate (which never calls it). Logs never carry tokens,
/// proofs, user ids or response bodies.
class SupabaseSubscriptionLog implements SubscriptionLog {
  SupabaseSubscriptionLog(
    this._client,
    this._userId, {
    this.verifyDeadline = kSubscriptionVerifyDeadline,
  });

  static const String functionName = 'subscription-verify';

  final SupabaseClient _client;
  final String _userId;
  final Duration verifyDeadline;

  /// The token never changes for an account; asked once per session.
  String? _token;

  @override
  Future<PlanStatus> fetchPlan() async {
    final Object? raw = await userRpc(_client, _userId, 'get_my_plan');
    final plan = PlanStatus.fromJson(raw);
    if (plan == null) {
      throw const FormatException('get_my_plan off the contract');
    }
    return plan;
  }

  @override
  Future<String> accountToken() async {
    final known = _token;
    if (known != null) return known;
    final Object? raw = await userRpc(
      _client,
      _userId,
      'get_store_account_token',
    );
    final token = raw is String ? raw.toLowerCase() : null;
    if (token == null || !_uuidPattern.hasMatch(token)) {
      throw const FormatException('get_store_account_token off the contract');
    }
    return _token = token;
  }

  @override
  Future<VerifyResult> verify(PurchaseProof proof) =>
      _invoke(proof.toVerifyBody());

  @override
  Future<VerifyResult> refresh() =>
      _invoke(const <String, Object>{'action': 'refresh'});

  /// This account's bearer, or [AuthException] when the session belongs to
  /// someone else or there is none: a verify without the account's own
  /// bearer is never sent.
  Future<String> _authorization() async {
    var session = _client.auth.currentSession;
    if (session == null || session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    if (session.isExpired) {
      await _client.auth.refreshSession();
      session = _client.auth.currentSession;
    }
    if (session == null || session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    return 'Bearer ${session.accessToken}';
  }

  Future<VerifyResult> _invoke(Map<String, Object> body) async {
    final String authorization;
    try {
      authorization = await _authorization();
    } on AuthRetryableFetchException {
      // The refresh failed for lack of a connection, not a lost session.
      return const VerifyResult(VerifyOutcome.unavailable);
    } on AuthException {
      return const VerifyResult(VerifyOutcome.unauthorized);
    } catch (e) {
      _logFailure(e);
      return const VerifyResult(VerifyOutcome.unavailable);
    }
    final abort = Completer<void>();
    final alarm = Timer(verifyDeadline, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final response = await _client.functions
          .invoke(
            functionName,
            headers: <String, String>{'Authorization': authorization},
            body: body,
            abortSignal: abort.future,
          )
          .timeout(verifyDeadline + const Duration(seconds: 2));
      return _verifyResultFor(response.status, response.data);
    } on FunctionsHttpException catch (e) {
      return _verifyResultFor(e.status, e.details);
    } catch (e) {
      // Relay errors, lost connections, the deadline.
      _logFailure(e);
      return const VerifyResult(VerifyOutcome.unavailable);
    } finally {
      alarm.cancel();
    }
  }

  void _logFailure(Object error) => dev.log(
    'subscription-verify failed (${error.runtimeType})',
    name: 'subscription_sync',
  );
}

/// The status table of 3.4.
VerifyResult _verifyResultFor(int status, Object? body) {
  final map = body is Map ? body : const <String, Object?>{};
  final plan = PlanStatus.fromJson(map['plan']);
  switch (status) {
    case 200:
      return switch (map['outcome']) {
        'active' => VerifyResult(VerifyOutcome.active, plan: plan),
        'inactive' => VerifyResult(VerifyOutcome.inactive, plan: plan),
        _ => const VerifyResult(VerifyOutcome.unavailable),
      };
    case 202:
      return VerifyResult(VerifyOutcome.pending, plan: plan);
    case 400:
      return const VerifyResult(VerifyOutcome.invalid);
    case 401 || 403:
      return const VerifyResult(VerifyOutcome.unauthorized);
    case 409:
      return const VerifyResult(VerifyOutcome.ownedByOther);
    case 422:
      final reason = map['reason'];
      return VerifyResult(
        VerifyOutcome.invalid,
        invalidReason: reason is String && _invalidReasons.contains(reason)
            ? reason
            : null,
      );
    default:
      return const VerifyResult(VerifyOutcome.unavailable);
  }
}
