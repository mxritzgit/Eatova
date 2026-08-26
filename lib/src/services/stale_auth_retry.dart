import 'dart:async';
import 'dart:developer' as dev;

import 'sync_error_messages.dart' show isStaleAuthError;

/// Seam for the wait between attempts; tests pass a recorder.
typedef StaleAuthDelay = Future<void> Function(Duration duration);

/// Retries a read the server rejected for its access token
/// ([isStaleAuthError]) — the boot pattern behind Sentry FLUTTER-9/-A/-B.
///
/// Evidence (Supabase edge logs, three cold starts on 2026-08-26): one
/// `POST /auth/v1/token` (200), ~1.1 s later the six boot GETs within 70 ms,
/// all carrying that fresh token — and exactly ONE of them answered 401, a
/// different table each time (PGRST303 from PostgREST twice, once a bare 401
/// from the gateway). The token was neither expired nor stale on the client;
/// the rejection is a server-side flake on brand-new tokens.
///
/// Hence two retries with different remedies:
/// 1. wait only — a refresh would just mint the next brand-new token;
/// 2. refresh, then wait — for a token the client-side expiry check missed
///    (device clock skew beyond gotrue's 30 s margin) or a token revoked
///    meanwhile.
/// A third rejection reaches the caller: looping against the server would
/// hold the boot budget hostage.
///
/// Concurrent callers share ONE refresh: gotrue de-duplicates in-flight
/// refreshes by refresh token, but a caller arriving after the first refresh
/// completed would otherwise start a second one with the NEW token.
///
/// A failed refresh (offline, revoked token) surfaces as its own error rather
/// than the rejected read: it is the more precise diagnosis, and the network
/// classification (`isNetworkSyncError`) keeps an outage out of Sentry.
class StaleAuthRetry {
  StaleAuthRetry(this._refresh, {StaleAuthDelay? delay})
      : _delay = delay ?? _realDelay;

  /// Long enough for whatever the server side needs to accept a token it
  /// minted a second ago; short enough to stay inside `kBootNetworkBudget`.
  static const Duration firstRetryDelay = Duration(seconds: 1);
  static const Duration secondRetryDelay = Duration(seconds: 2);

  static Future<void> _realDelay(Duration duration) =>
      Future<void>.delayed(duration);

  final Future<void> Function() _refresh;
  final StaleAuthDelay _delay;
  Future<void>? _inFlight;

  Future<void> _refreshShared() {
    final running = _inFlight;
    if (running != null) return running;
    final started = _refresh().whenComplete(() => _inFlight = null);
    _inFlight = started;
    return started;
  }

  Future<T> run<T>(Future<T> Function() load) async {
    try {
      return await load();
    } catch (error) {
      if (!isStaleAuthError(error)) rethrow;
    }
    dev.log(
        'Server lehnt den Token ab — 1. Wiederholung nach Wartezeit '
        '(frischer Token, kein Refresh)',
        name: 'eatova_sync');
    await _delay(firstRetryDelay);
    try {
      return await load();
    } catch (error) {
      if (!isStaleAuthError(error)) rethrow;
    }
    dev.log(
        'Server lehnt den Token erneut ab — Session-Refresh, dann '
        '2. Wiederholung',
        name: 'eatova_sync');
    await _refreshShared();
    await _delay(secondRetryDelay);
    // Third strike is a real error and must reach the caller.
    return await load();
  }
}
