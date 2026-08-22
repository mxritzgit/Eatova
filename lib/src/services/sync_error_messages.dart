import 'dart:async';
import 'dart:io';

// http comes in transitively via supabase_flutter; the resulting lint is
// demoted in analysis_options.yaml.
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, PostgrestException;

import '../l10n/l10n.dart';
import 'sync_outbox.dart'
    show SyncOpKind, kOutboxDeleteMaxAttempts, kOutboxMaxAttempts;

// UI error texts for failed sync/profile writes (pure, unit-testable).
// Never put `error.toString()` in the UI: Postgrest errors leak schema
// details. The raw exception goes to CrashReporter + dev.log instead.

/// True for connection/network errors — everything that heals once online.
///
/// [IOException] covers the whole dart:io family on purpose, since
/// `TlsException` implements it and package:http wraps only Socket/Http; a
/// [FileSystemException] then also counts as "network", which costs retries,
/// not data. Server error responses are excluded: the server was reachable.
bool isNetworkSyncError(Object error) =>
    error is IOException ||
    error is TimeoutException ||
    error is ClientException ||
    error is AuthRetryableFetchException;

/// What actually happened to a write, for callers showing their own success
/// message. Three cases, not a bool: queued-after-rejection must not claim
/// "as soon as you are online again" when the server did answer.
enum SyncDelivery {
  /// Reached the server live.
  delivered,

  /// Queued in the persisted outbox because the device had no network.
  queuedOffline,

  /// Queued although the server was reachable (rejection, or the entity
  /// already had a failed op pending).
  queuedRetry,
}

/// Turns a success statement into the message matching the real outcome.
/// One message says both things, because [showAppSnack] replaces the previous
/// snack and a success toast plus a queued hint would only flash past.
String deliveryHint(
  String erfolg,
  SyncDelivery delivery, [
  AppLocalizations? l10n,
]) {
  final t = l10n ?? deL10n;
  return switch (delivery) {
    SyncDelivery.delivered => t.commonDeliverySuccess(erfolg),
    SyncDelivery.queuedOffline => t.commonDeliveryQueuedOffline(erfolg),
    SyncDelivery.queuedRetry => t.commonDeliveryQueuedRetry(erfolg),
  };
}

/// Classifies a queue reason for [deliveryHint]. [error] is null when the op
/// was queued behind a pending one without a live attempt.
SyncDelivery queuedDelivery(Object? error) =>
    error != null && isNetworkSyncError(error)
        ? SyncDelivery.queuedOffline
        : SyncDelivery.queuedRetry;

/// Quiet hint for a write that landed in the outbox; it retries on its own.
/// Network errors get the offline text, everything else a neutral one.
String queuedSyncHint(Object? error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  return error != null && isNetworkSyncError(error)
      ? t.commonQueuedOfflineHint
      : t.commonQueuedRetryGenericHint;
}

// `profileSyncErrorMessage` was removed: the profile save goes through the
// outbox and auto-retries, so asking the user to retry later was wrong.

/// Generic message for operations without an outbox safety net (e.g. account
/// deletion): no auto-retry, the user has to trigger it again.
String directSyncErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  return isNetworkSyncError(error)
      ? t.commonSyncErrorOffline
      : t.commonGenericRetryError;
}

/// True for the server-side re-auth rejection of `delete_account()`, which
/// throws `EX_REAUTH_REQUIRED` with SQLSTATE 28000. Both are checked: the
/// message token is precise, the errcode survives a reworded message. A bare
/// HTTP 403 does NOT count — an expired token is something else.
bool isReauthRequiredError(Object error) =>
    error is PostgrestException &&
    (error.code == '28000' || error.message == 'EX_REAUTH_REQUIRED');

/// Error text for account deletion. The re-auth rejection gets its own
/// sentence: retrying later does not help, the user must restart the flow.
String deleteAccountErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  if (isReauthRequiredError(error)) {
    return t.settingsDeleteAccountReauthExpired;
  }
  return directSyncErrorMessage(error, t);
}

/// Hint that the outbox dropped ops for good (poison op, spent retry budget or
/// queue cap). Real data loss: the user is told, but without technical details.
String outboxLossHint([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).commonOutboxLossHint;

/// Hint for a finally failed DELETE. Own text because the consequence is
/// inverted: a dropped write loses something, a dropped delete brings
/// something BACK. The store re-shows the entry locally in the same step.
String outboxDeleteLossHint([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).commonOutboxDeleteLossHint;

/// What should happen to a failed outbox op.
enum OutboxVerdict {
  /// Drop for good — a retry cannot work, or the budget is spent.
  drop,

  /// Keep and count one delivery attempt.
  retryCounted,

  /// Keep WITHOUT counting an attempt.
  retryFree,
}

/// Classifies a failed outbox write.
///
/// Network errors are [OutboxVerdict.retryFree]: boot, lifecycle flush and the
/// backoff timer can all fire within seconds offline, so counting them would
/// let an offline weekend destroy valid data. Otherwise the error code decides,
/// told apart by SHAPE (5 chars = SQLSTATE, `PGRST` prefix, 3 digits = HTTP).
/// When in doubt, keep.
///
/// Pass [kind] when known: dropping a DELETE is the only drop a cold start
/// actively undoes, so deletes suspend both the write budget and the
/// code-based drop (an empty payload cannot violate a payload constraint) and
/// use [kOutboxDeleteMaxAttempts] instead — finite, because an immortal op
/// holds retry timer, queue cap and logout cleanup hostage.
OutboxVerdict classifyOutboxFailure(
  Object error,
  int attempts, {
  SyncOpKind? kind,
}) {
  if (isNetworkSyncError(error)) return OutboxVerdict.retryFree;
  if (kind != null && _isDeleteKind(kind)) {
    return attempts + 1 >= kOutboxDeleteMaxAttempts
        ? OutboxVerdict.drop
        : OutboxVerdict.retryCounted;
  }
  final verdict = _verdictForCode(error);
  if (verdict == OutboxVerdict.drop) return OutboxVerdict.drop;
  // Budget spent: even a retryable error ends here.
  return attempts + 1 >= kOutboxMaxAttempts ? OutboxVerdict.drop : verdict;
}

/// Enum-level copy of `SyncOp.isDelete`: [classifyOutboxFailure] only gets the
/// [SyncOpKind], not the op.
bool _isDeleteKind(SyncOpKind kind) =>
    kind == SyncOpKind.mealDelete ||
    kind == SyncOpKind.favoriteDelete ||
    kind == SyncOpKind.recipeDelete;

OutboxVerdict _verdictForCode(Object error) {
  // Anything that is not a PostgREST error is unclassified -> keep.
  if (error is! PostgrestException) return OutboxVerdict.retryCounted;
  final code = error.code;
  if (code == null || code.isEmpty) return OutboxVerdict.retryCounted;

  // --- PostgREST's own codes ----------------------------------------------
  if (code.startsWith('PGRST')) {
    // PGRST301 = expired JWT, healed by the next refresh. Every other PGRST*
    // code means a broken request; resending the same bytes never helps.
    return code == 'PGRST301'
        ? OutboxVerdict.retryCounted
        : OutboxVerdict.drop;
  }

  // --- Raw HTTP status (body without `code`, e.g. proxy/gateway) ----------
  final status = code.length == 3 ? int.tryParse(code) : null;
  if (status != null) {
    if (status == 429 || status >= 500) return OutboxVerdict.retryCounted;
    // 401/403 is almost always an expired token; the refresh heals it.
    if (status == 401 || status == 403) return OutboxVerdict.retryCounted;
    if (status >= 400) return OutboxVerdict.drop;
    return OutboxVerdict.retryCounted;
  }

  // --- SQLSTATE (always exactly 5 chars) -----------------------------------
  if (code.length == 5) {
    // 22 = data exception, payload-determined: never accepted on a retry.
    if (code.startsWith('22')) return OutboxVerdict.drop;
    if (code.startsWith('23')) {
      // Class 23 is not dropped wholesale: 23503 can be transient during a
      // migration window, 23505 is unreachable (upserts), and 23514 is
      // expected user input while the model-limit clamps are missing.
      // Only 23502 drops — a missing required column is a client bug.
      // TODO(clamps): back to OutboxVerdict.drop once the clamps sit at the
      // model limits (lib/src/models/model_limits.dart).
      return code == '23502' ? OutboxVerdict.drop : OutboxVerdict.retryCounted;
    }
    switch (code.substring(0, 2)) {
      // 08 connection, 40 rollback/deadlock, 53 resources, 57 shutdown,
      // 58 system_error — all states that pass.
      case '08':
      case '40':
      case '53':
      case '57':
      case '58':
        return OutboxVerdict.retryCounted;
      // 42, incl. 42501 (RLS denial): retryable on purpose, since a missing or
      // expired token makes RLS bite and that heals on the next refresh.
      case '42':
        return OutboxVerdict.retryCounted;
    }
  }
  return OutboxVerdict.retryCounted;
}
