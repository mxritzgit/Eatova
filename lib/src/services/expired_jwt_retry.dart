import 'dart:async';
import 'dart:developer' as dev;

import 'sync_error_messages.dart' show isExpiredJwtError;

/// Retries a read ONCE after refreshing the session when the server rejects
/// the access token as expired ([isExpiredJwtError]).
///
/// Background (Sentry FLUTTER-9, 2026-08-26): the boot loads fire in parallel
/// right after cold start with whatever token the persisted session carries.
/// gotrue refreshes proactively only when fewer than ~30 s remain on the
/// DEVICE clock, while PostgREST checks `exp` on its own clock — so a token can
/// pass the client check and still come back as `PGRST303`. Until now that
/// load failed for good and the store kept stale cached data for the whole
/// session; the auto-refresh a few seconds later healed nothing in the past.
///
/// Concurrent callers share ONE refresh: gotrue de-duplicates in-flight
/// refreshes by refresh token, but a caller arriving after the first refresh
/// completed would otherwise start a second one with the NEW token.
///
/// A failed refresh (offline, revoked token) surfaces as its own error rather
/// than the rejected read: it is the more precise diagnosis, and the network
/// classification (`isNetworkSyncError`) keeps an outage out of Sentry.
class ExpiredJwtRetry {
  ExpiredJwtRetry(this._refresh);

  final Future<void> Function() _refresh;
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
      if (!isExpiredJwtError(error)) rethrow;
      dev.log(
          'Server lehnt den Token als abgelaufen ab — Session-Refresh, dann '
          'ein Wiederholungsversuch',
          name: 'eatova_sync');
      await _refreshShared();
      // Exactly one retry: a second rejection is a real error and must reach
      // the caller instead of looping against the server.
      return await load();
    }
  }
}
