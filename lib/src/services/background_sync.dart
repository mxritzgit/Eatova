import 'dart:async';

import 'package:supabase/supabase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/supabase_config.dart';
import 'background_sync_client.dart';
import 'eatova_sync.dart';
import 'local_cache.dart';
import 'secure_cache_store.dart';
import 'session_revocations.dart';
import 'sync_dispatcher.dart';
import 'sync_error_messages.dart';
import 'sync_execution_guard.dart';
import 'sync_outbox.dart';

enum BackgroundSyncOutcome { complete, retry, unavailable }

/// Keeps local permission failures distinct even inside an HTTP auth callback.
class _BackgroundPrerequisiteUnavailable implements Exception {
  const _BackgroundPrerequisiteUnavailable();
}

typedef BackgroundCacheOpener = Future<LocalCache?> Function(String userId);
typedef BackgroundSyncDispatch =
    Future<LocalSyncResult> Function(EatovaSync sync, SyncOp op);

/// Best effort, bounded delivery. It never initializes or refreshes SDK Auth.
class BackgroundSyncRunner {
  BackgroundSyncRunner({
    Future<String?> Function()? readSession,
    BackgroundCacheOpener? openCache,
    BackgroundSyncDispatch? dispatch,
    BackgroundSyncClient Function(
      BackgroundSyncSession,
      Future<bool> Function(),
    )?
    clientBuilder,
    this.budget = const Duration(seconds: 20),
    this.maxOperations = 20,
  }) : _readSession = readSession ?? _readSecureSession,
       _openCache = openCache ?? _openBackgroundCache,
       _dispatch = dispatch ?? dispatchSyncOp,
       _clientBuilder = clientBuilder ?? _buildClient;

  final Future<String?> Function() _readSession;
  final BackgroundCacheOpener _openCache;
  final BackgroundSyncDispatch _dispatch;
  final BackgroundSyncClient Function(
    BackgroundSyncSession,
    Future<bool> Function(),
  )
  _clientBuilder;
  final Duration budget;
  final int maxOperations;
  bool _cancelled = false;
  bool _awaitingTransport = false;
  BackgroundSyncClient? _client;
  Future<void>? _clientDisposal;

  static Future<String?> _readSecureSession() async {
    final key = EatovaSupabaseConfig.sessionPersistKey;
    final value = await const PluginSecureKeyStore().read(key);
    if (value == null) return null;
    final journal = SessionRevocations(
      '$key.logout-v1',
      () async => _ReadOnlySessionJournal(),
    );
    return await journal.permits(value) ? value : null;
  }

  static Future<LocalCache?> _openBackgroundCache(String userId) =>
      LocalCache.create(userId, background: true);

  static BackgroundSyncClient _buildClient(
    BackgroundSyncSession session,
    Future<bool> Function() permitted,
  ) => BackgroundSyncClient(
    url: EatovaSupabaseConfig.url,
    anonKey: EatovaSupabaseConfig.anonKey,
    session: session,
    permitted: permitted,
  );

  void cancel() {
    _cancelled = true;
    unawaited(_disposeClient());
  }

  Future<void> _disposeClient() {
    final client = _client;
    if (client == null) return Future<void>.value();
    return _clientDisposal ??= client.dispose();
  }

  Future<BackgroundSyncOutcome> run() async {
    final elapsed = Stopwatch()..start();
    try {
      return await _run(elapsed).timeout(
        budget,
        onTimeout: () {
          final outcome = _awaitingTransport
              ? BackgroundSyncOutcome.retry
              : BackgroundSyncOutcome.unavailable;
          cancel();
          // Closing the owned transport interrupts pending client-side requests.
          return outcome;
        },
      );
    } on KeyValueConflict {
      // Another engine won a local CAS; a later bounded pass can progress.
      return BackgroundSyncOutcome.retry;
    } catch (_) {
      // Local/session prerequisites need foreground recovery, not an OS chain.
      return BackgroundSyncOutcome.unavailable;
    } finally {
      elapsed.stop();
    }
  }

  Future<BackgroundSyncOutcome> _run(Stopwatch elapsed) async {
    bool inBudget() => !_cancelled && elapsed.elapsed < budget;
    final session = BackgroundSyncSession.fromPersisted(await _readSession());
    if (session == null || !inBudget()) {
      return BackgroundSyncOutcome.unavailable;
    }
    final cache = await _openCache(session.userId);
    if (cache == null) return BackgroundSyncOutcome.unavailable;
    SyncExecutionClaim? claim;
    BackgroundSyncClient? client;
    try {
      if (!inBudget()) return BackgroundSyncOutcome.unavailable;
      final storage = cache.atomicStore;
      if (storage == null) return BackgroundSyncOutcome.unavailable;
      final guard = SyncExecutionGuard(storage);
      claim = await guard.tryClaim(
        session.userId,
        expectedSessionId: session.sessionId,
      );
      if (claim == null) {
        return await guard.hasActiveSession(session.userId, session.sessionId)
            ? BackgroundSyncOutcome.retry
            : BackgroundSyncOutcome.unavailable;
      }
      final ownedClaim = claim;
      Future<bool> permitted() async {
        final wasAwaitingTransport = _awaitingTransport;
        _awaitingTransport = false;
        try {
          if (!inBudget() ||
              !session.isUsable ||
              !await ownedClaim.isCurrent()) {
            return false;
          }
          final current = BackgroundSyncSession.fromPersisted(
            await _readSession(),
          );
          return inBudget() &&
              current?.userId == session.userId &&
              current?.sessionId == session.sessionId &&
              await ownedClaim.isCurrent();
        } catch (_) {
          throw const _BackgroundPrerequisiteUnavailable();
        } finally {
          _awaitingTransport = wasAwaitingTransport;
        }
      }

      if (!await permitted()) return BackgroundSyncOutcome.unavailable;
      client = _clientBuilder(session, permitted);
      _client = client;
      final sync = EatovaSync.forUser(client, session.userId);
      final attempted = <String>{};
      final blockedEntities = <String>{};
      while (inBudget() && attempted.length < maxOperations) {
        if (!await claim.renew() || !await permitted()) {
          return BackgroundSyncOutcome.unavailable;
        }
        final queue = await cache.readSyncOperations(guards: claim.guards);
        if (queue.isEmpty) return BackgroundSyncOutcome.complete;
        final entityHeads = <String, SyncOp>{};
        for (final op in queue) {
          entityHeads.putIfAbsent(op.entityKey, () => op);
        }
        if (entityHeads.values.every((op) => op.blockedReason != null)) {
          return BackgroundSyncOutcome.unavailable;
        }
        final candidate = entityHeads.values
            .where(
              (op) =>
                  !attempted.contains(op.operationId) &&
                  op.blockedReason == null &&
                  !blockedEntities.contains(op.entityKey),
            )
            .firstOrNull;
        if (candidate == null) return BackgroundSyncOutcome.retry;
        attempted.add(candidate.operationId);
        final op = await cache.startSyncOperation(
          candidate.operationId,
          guards: claim.guards,
        );
        if (op == null) continue;
        if (!await permitted()) return BackgroundSyncOutcome.unavailable;
        final LocalSyncResult result;
        try {
          _awaitingTransport = true;
          result = await _dispatch(sync, op);
        } on _BackgroundPrerequisiteUnavailable {
          return BackgroundSyncOutcome.unavailable;
        } catch (error) {
          _awaitingTransport = false;
          if ((error is AuthException && !isNetworkSyncError(error)) ||
              isStaleAuthError(error)) {
            return BackgroundSyncOutcome.unavailable;
          }
          if (!await permitted()) return BackgroundSyncOutcome.unavailable;
          await cache.recordSyncFailure(
            op.operationId,
            countAttempt: !isNetworkSyncError(error),
            blockedReason: blockedReasonForSyncError(
              error,
              attempts: op.attempts,
              kind: op.kind,
            ),
            guards: claim.guards,
          );
          blockedEntities.add(op.entityKey);
          continue;
        } finally {
          _awaitingTransport = false;
        }
        if (!await permitted()) return BackgroundSyncOutcome.unavailable;
        // A local ACK failure must not count or block a successful delivery.
        await cache.acknowledgeSyncOperation(
          op.operationId,
          result,
          guards: claim.guards,
        );
      }
      return BackgroundSyncOutcome.retry;
    } finally {
      try {
        await claim?.release();
      } finally {
        await _disposeClient();
        if (identical(_client, client)) _client = null;
        await cache.releaseStorage();
      }
    }
  }
}

/// Native, uncached reads also observe logout from another Flutter engine.
/// SessionRevocations.permits only reads; mutation is forbidden in headless work.
class _ReadOnlySessionJournal extends KeyValueStore {
  @override
  Future<String?> getString(String key) async {
    // The logout journal uses the legacy preferences namespace, including its
    // native key prefix. Reload avoids a stale cache in another engine.
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return preferences.getString(key);
  }

  @override
  Future<void> setString(String key, String value) =>
      throw UnsupportedError('Background session journal is read only');
  @override
  Future<void> remove(String key) =>
      throw UnsupportedError('Background session journal is read only');
}
