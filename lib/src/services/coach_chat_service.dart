import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/l10n.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/coach_recipe_proposal.dart';
import 'crash_reporter.dart';
import 'sync_error_messages.dart';

/// Coach-chat backend bridge.
///
/// Rate limit (5/day), safety filter and the model call all live in the
/// `coach-chat` edge function. This class only loads history from
/// public.chat_messages (RLS scopes it to the user), invokes the function,
/// reads the counter via get_chat_quota_today, and manages sessions by RPC.
class CoachChatService {
  CoachChatService(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  /// Locale pack for the user-visible fallback error texts. Set via setter
  /// rather than a `send()` parameter so test doubles overriding `send` stay
  /// unchanged; the screen refreshes `context.l10n` before each send (not in
  /// initState). Defaults to German so context-free callers still work.
  AppLocalizations _l10n = deL10n;

  set l10n(AppLocalizations value) => _l10n = value;

  /// Request locale for the edge function; same normalisation as
  /// [requestRecipe]. Anything but `en` falls back to `de` server-side anyway.
  String get _localeCode =>
      _l10n.localeName.toLowerCase().startsWith('en') ? 'en' : 'de';

  // -------------------------------------------------------------------------
  // Diagnostics
  // -------------------------------------------------------------------------
  /// Reports a failure path to the [CrashReporter], but only if it means
  /// something. Without this the coach would be the one area of the app whose
  /// outages are invisible in production.
  ///
  /// Network errors are filtered out, same classification as
  /// [CrashReporter.captureSyncFailure]: opening the coach fires three
  /// requests, so offline use would drain the Sentry quota.
  ///
  /// [operation] must always be a source literal — it becomes the Sentry
  /// `context` tag, and message texts, titles or ids must never reach a report
  /// (health data).
  static void _melde(String operation, Object error, StackTrace stack) {
    if (isNetworkSyncError(error)) return;
    unawaited(CrashReporter.capture(error, stack, context: operation));
  }

  /// Whether an edge-function error status describes an incident.
  ///
  /// 401/403 (session expired), 413 (image too large) and 429 (daily limit or
  /// burst brake) are intended responses shown in the banner, so reporting
  /// them would be user-proportional noise. Everything else, 5xx above all,
  /// is the outage nobody else sees.
  static bool _statusIstVorfall(int status) =>
      status != 401 && status != 403 && status != 413 && status != 429;

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------
  /// The user's sessions.
  ///
  /// Throws [CoachDataUnavailable] instead of returning an empty list on
  /// error: "offline" and "no conversations yet" are different statements,
  /// and the empty list made the sessions sheet clear itself.
  Future<List<ChatSession>> loadSessions() async {
    final dynamic res;
    try {
      res = await _client.rpc('list_chat_sessions');
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadSessions failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.loadSessions', e, stack);
      throw CoachDataUnavailable('Sessionliste nicht abrufbar', e);
    }
    if (res is! List) {
      dev.log(
        'CoachChatService.loadSessions: unerwartete Form ${res.runtimeType}',
        name: 'eatova.coach',
      );
      // Broken contract, never a network error: the RPC returns a table. The
      // runtime type stays in the local log; the report has the `context` tag.
      const fehler = CoachDataUnavailable('Sessionliste in unerwarteter Form');
      _melde('coach.loadSessions.form', fehler, StackTrace.current);
      throw fehler;
    }
    return res
        .map<ChatSession>((row) =>
            ChatSession.fromRow((row as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Returns the default session id, creating one if needed.
  Future<String?> ensureDefaultSession() async {
    try {
      final res = await _client.rpc('ensure_default_chat_session');
      if (res is String) return res;
      if (res is List && res.isNotEmpty) return res.first.toString();
      return null;
    } catch (e, stack) {
      dev.log(
        'CoachChatService.ensureDefaultSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      // A `null` return locks the composer for the rest of the app run (the
      // screen has no session), so this needs more than a local log.
      _melde('coach.ensureDefaultSession', e, stack);
      return null;
    }
  }

  /// [title] is the localized placeholder (`coachSessionDefaultTitle`); the
  /// server replaces it with an auto title after the first question.
  Future<String?> createSession({required String title}) async {
    try {
      final res = await _client.rpc(
        'create_chat_session',
        params: {'p_title': title},
      );
      if (res is String) return res;
      if (res is List && res.isNotEmpty) return res.first.toString();
      return null;
    } catch (e, stack) {
      dev.log(
        'CoachChatService.createSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.createSession', e, stack);
      return null;
    }
  }

  /// Throws [CoachDataUnavailable] on failure, like loadSessions and friends:
  /// a `Future<void>` that completes asserts "renamed/deleted" to the caller,
  /// so a swallowed error would let the screen continue as if it succeeded.
  Future<void> renameSession(String sessionId, String title) async {
    try {
      await _client.rpc('rename_chat_session', params: {
        'p_session_id': sessionId,
        'p_title': title,
      });
    } catch (e, stack) {
      dev.log(
        'CoachChatService.renameSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.renameSession', e, stack);
      throw CoachDataUnavailable('Umbenennen fehlgeschlagen', e);
    }
  }

  Future<void> deleteSession(String sessionId) async {
    try {
      await _client.rpc('delete_chat_session', params: {
        'p_session_id': sessionId,
      });
    } catch (e, stack) {
      dev.log(
        'CoachChatService.deleteSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.deleteSession', e, stack);
      throw CoachDataUnavailable('Loeschen fehlgeschlagen', e);
    }
  }

  // -------------------------------------------------------------------------
  // History / quota / send
  // -------------------------------------------------------------------------
  /// Last n messages of one session, in chronological order.
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    try {
      final rows = await _client
          .from('chat_messages')
          // `recipe`: the proposal JSON, so the card survives a reload.
          .select('id, role, content, refusal, created_at, recipe')
          .eq('user_id', _userId)
          .eq('session_id', sessionId)
          .inFilter('role', ['user', 'assistant'])
          .order('created_at', ascending: false)
          .limit(limit);
      final list = rows.map<ChatMessage>((row) {
        return ChatMessage.fromRow((row as Map).cast<String, dynamic>());
      }).toList();
      return list.reversed.toList();
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadHistory failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.loadHistory', e, stack);
      // Never return an empty list here: the screen would render the empty
      // state and the user would see their history as deleted.
      throw CoachDataUnavailable('Verlauf nicht abrufbar', e);
    }
  }

  /// The daily counter as the server reports it.
  ///
  /// `p_daily_limit` is display arithmetic only: the RPC is read-only and
  /// derives `remaining` from the passed value. The limit is enforced
  /// server-side via `claim_chat_quota` (service_role only), so a tampered
  /// client only lies to its own display.
  ///
  /// Throws [CoachDataUnavailable] if the RPC fails or returns no usable
  /// numbers — inventing a full quota there would lift an existing lock.
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    final dynamic res;
    try {
      res = await _client.rpc(
        'get_chat_quota_today',
        params: {'p_daily_limit': ChatQuotaSnapshot.standardTageslimit},
      );
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadQuotaToday failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.loadQuotaToday', e, stack);
      throw CoachDataUnavailable('Tageszaehler nicht abrufbar', e);
    }
    // A table-returning RPC arrives as a list.
    var row = const <String, dynamic>{};
    if (res is List && res.isNotEmpty && res.first is Map) {
      row = (res.first as Map).cast<String, dynamic>();
    } else if (res is Map) {
      row = res.cast<String, dynamic>();
    }
    final used = (row['used'] as num?)?.toInt();
    final remaining = (row['remaining'] as num?)?.toInt();
    final dailyLimit = (row['daily_limit'] as num?)?.toInt();
    if (used == null || remaining == null || dailyLimit == null) {
      dev.log(
        'CoachChatService.loadQuotaToday: Antwort ohne verwertbare Zahlen',
        name: 'eatova.coach',
      );
      // Broken contract again: the RPC answered without the columns its
      // signature promises. Typical after a migration, so report it.
      const fehler =
          CoachDataUnavailable('Tageszaehler ohne verwertbare Zahlen');
      _melde('coach.loadQuotaToday.form', fehler, StackTrace.current);
      throw fehler;
    }
    return ChatQuotaSnapshot(
      used: used,
      remaining: remaining,
      dailyLimit: dailyLimit,
    );
  }

  /// Sends the user message to the edge function.
  ///
  /// All error handling sits in the `on Functions*` arms: functions_client
  /// throws on non-2xx rather than exposing a status. Only a 429 carrying
  /// `error: quota_exceeded` becomes [CoachQuotaExceeded]; everything else,
  /// including a burst-limit 429, becomes a displayable [CoachChatException].
  /// A compressed image may be attached as base64; vision and safety logic
  /// stay server-side.
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'coach-chat',
        body: {
          'message': message,
          'session_id': sessionId,
          'locale': _localeCode,
          if (imageBase64 != null && imageBase64.isNotEmpty)
            'image_base64': imageBase64,
          if (imageMimeType != null && imageMimeType.isNotEmpty)
            'image_mime_type': imageMimeType,
          if (userContext != null && userContext.trim().isNotEmpty)
            'user_context': userContext.trim(),
        },
      );
      // Reaching this point means 2xx: functions_client throws on any other
      // status, so error handling lives only in the `on Functions*` arms.
      final data = res.data;
      final map = data is Map ? data : const <dynamic, dynamic>{};
      final reply = map['reply'] is String
          ? (map['reply'] as String).trim()
          : '';
      if (reply.isEmpty) {
        // 2xx without text: a broken contract, and the only failure here that
        // no status reveals.
        final leer = CoachChatException(_l10n.coachErrorEmptyReply);
        _melde('coach.send.leereAntwort', leer, StackTrace.current);
        throw leer;
      }
      return CoachChatReply(
        reply: reply,
        refusal: map['refusal'] == true,
        refusalReason: map['refusal_reason']?.toString(),
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        dailyLimit: map['daily_limit'] is num
            ? (map['daily_limit'] as num).toInt()
            : null,
        sessionId: map['session_id']?.toString() ?? sessionId,
      );
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } on FunctionsHttpException catch (e, stack) {
      // The edge function itself answered with a non-2xx status.
      _logSendFailure(e, stack);
      if (_statusIstVorfall(e.status)) _melde('coach.send.http', e, stack);
      throw _failureForStatus(e.status, e.details);
    } on FunctionsRelayException catch (e, stack) {
      // The Supabase relay in front of the function aborted, so the function
      // never ran and the body carries no domain meaning: always infra.
      _logSendFailure(e, stack);
      _melde('coach.send.relay', e, stack);
      throw CoachChatException(_unreachableMessage);
    } on FunctionsFetchException catch (e, stack) {
      // The request never left the device. Deliberately unreported: the pure
      // offline case, whose type [isNetworkSyncError] does not recognise.
      _logSendFailure(e, stack);
      throw CoachChatException(_l10n.coachErrorNoConnection);
    } catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.send.unbekannt', e, stack);
      throw CoachChatException(_unreachableMessage);
    }
  }

  /// /rezept: has the function generate a recipe plus image (`mode: "recipe"`).
  /// Costs one daily coach slot.
  ///
  /// The function only returns data; saving happens client-side after the user
  /// confirms in the sheet. Error mapping is identical to [send].
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
    String? userContext,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'coach-chat',
        body: {
          'message': wish,
          'mode': 'recipe',
          'locale': locale.toLowerCase().startsWith('en') ? 'en' : 'de',
          'session_id': sessionId,
          if (userContext != null && userContext.trim().isNotEmpty)
            'user_context': userContext.trim(),
        },
      );
      final data = res.data;
      final map = data is Map ? data : const <dynamic, dynamic>{};
      final reply =
          map['reply'] is String ? (map['reply'] as String).trim() : '';
      final refusal = map['refusal'] == true;

      // Broken base64 costs the image only, never the recipe.
      Uint8List? imageBytes;
      final rawImage = map['image_base64'];
      if (rawImage is String && rawImage.isNotEmpty) {
        try {
          imageBytes = base64Decode(rawImage);
        } catch (_) {
          imageBytes = null;
        }
      }

      CoachRecipeProposal? proposal;
      final rawRecipe = map['recipe'];
      if (!refusal && rawRecipe is Map) {
        proposal = CoachRecipeProposal.fromJson(
          rawRecipe,
          imageBytes: imageBytes,
        );
      }
      // A 200 with neither a usable recipe nor a refusal is not an answer.
      if (reply.isEmpty || (!refusal && proposal == null)) {
        final leer = CoachChatException(_l10n.coachErrorEmptyReply);
        _melde('coach.recipe.leereAntwort', leer, StackTrace.current);
        throw leer;
      }
      return CoachRecipeReply(
        reply: reply,
        refusal: refusal,
        proposal: proposal,
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        dailyLimit: map['daily_limit'] is num
            ? (map['daily_limit'] as num).toInt()
            : null,
        sessionId: map['session_id']?.toString() ?? sessionId,
        // Key for the local image store; absent on older function deployments
        // or if the insert failed.
        assistantMessageId: map['assistant_message_id'] is String
            ? map['assistant_message_id'] as String
            : null,
      );
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } on FunctionsHttpException catch (e, stack) {
      _logSendFailure(e, stack);
      if (_statusIstVorfall(e.status)) _melde('coach.recipe.http', e, stack);
      throw _failureForStatus(e.status, e.details);
    } on FunctionsRelayException catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.recipe.relay', e, stack);
      throw CoachChatException(_unreachableMessage);
    } on FunctionsFetchException catch (e, stack) {
      // As in [send], deliberately unreported: the request never left.
      _logSendFailure(e, stack);
      throw CoachChatException(_l10n.coachErrorNoConnection);
    } catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.recipe.unbekannt', e, stack);
      throw CoachChatException(_unreachableMessage);
    }
  }

  String get _unreachableMessage => _l10n.coachErrorUnreachable;

  void _logSendFailure(Object error, StackTrace stack) {
    dev.log(
      'CoachChatService.send failed',
      error: error,
      stackTrace: stack,
      name: 'eatova.coach',
    );
  }

  /// Maps an edge-function error status to the exception the coach screen
  /// understands. Raw server data never reaches the message: only a line
  /// cleared by [_serverReply], or a fixed text.
  Exception _failureForStatus(int status, dynamic details) {
    // `details` is dynamic — JSON from our function, but plain text or an HTML
    // page from the gateway. Anything but a Map becomes an empty Map so none
    // of the lookups below throw.
    final map = details is Map ? details : const <dynamic, dynamic>{};
    final serverReply = _serverReply(map);

    // 401/403: the session is gone — prompt a re-login instead of "unknown
    // error"; the function sends no displayable text here anyway.
    if (status == 401 || status == 403) {
      return CoachChatException(_l10n.coachErrorSessionExpired);
    }

    if (status == 429) {
      // Only quota_exceeded is the daily limit. `rate_limited` (burst brake)
      // carries no daily_limit and must not lock the composer for the day.
      if (map['error'] == 'quota_exceeded') {
        final limit = map['daily_limit'];
        return CoachQuotaExceeded(
          message: serverReply ?? _l10n.coachErrorQuotaFallback,
          // The function's 429 always carries daily_limit; if a gateway body
          // omits it, fall back to the shared display constant.
          dailyLimit:
              limit is num ? limit.toInt() : ChatQuotaSnapshot.standardTageslimit,
        );
      }
      return CoachChatException(
        serverReply ?? _l10n.coachErrorTooManyRequests,
      );
    }

    if (status == 413) {
      return CoachChatException(
        serverReply ?? _l10n.coachErrorImageTooLarge,
      );
    }

    if (status >= 500) {
      // 5xx bodies are internals ("rpc_unavailable", gateway HTML) — never
      // display them, even if a reply field is present.
      return CoachChatException(_unreachableMessage);
    }

    return CoachChatException(
      serverReply ?? _l10n.coachErrorRequestFailed,
    );
  }

  /// Clears the server-authored display text, or null if it does not look like
  /// a finished message. Deliberately strict: `details` may be an HTML error
  /// page, a stack trace or a JSON fragment, and a generic fallback beats a
  /// raw dump on screen.
  static String? _serverReply(Map<dynamic, dynamic> details) {
    final raw = details['reply'];
    if (raw is! String) return null;
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty || text.length > 240) return null;
    // Reject markup and dump fragments.
    if (RegExp(r'[<>{}]').hasMatch(text)) return null;
    return text;
  }
}

class CoachChatReply {
  const CoachChatReply({
    required this.reply,
    required this.refusal,
    required this.sessionId,
    this.refusalReason,
    this.remaining,
    this.dailyLimit,
  });

  final String reply;
  final bool refusal;
  final String sessionId;
  final String? refusalReason;
  final int? remaining;

  /// The daily limit as the server names it (COACH_DAILY_LIMIT); without it
  /// the screen would count against its assumed default and show an invented
  /// number. null only on older function deployments.
  final int? dailyLimit;
}

/// Recipe-mode response. On [refusal], [proposal] is null and [reply] holds
/// the refusal sentence; otherwise [proposal] carries the recipe (possibly
/// with an image) and [reply] the summary that also lands in the history.
class CoachRecipeReply {
  const CoachRecipeReply({
    required this.reply,
    required this.refusal,
    required this.sessionId,
    this.proposal,
    this.remaining,
    this.dailyLimit,
    this.assistantMessageId,
  });

  final String reply;
  final bool refusal;
  final String sessionId;
  final CoachRecipeProposal? proposal;
  final int? remaining;
  final int? dailyLimit;

  /// Id of the persisted assistant row, the key of the local image store so
  /// the card survives a reload. null on older function deployments, where the
  /// card is ephemeral.
  final String? assistantMessageId;
}

class CoachChatException implements Exception {
  const CoachChatException(this.message);
  final String message;
  @override
  String toString() => 'CoachChatException: $message';
}

/// "Unknown": the server delivered no reliable state (offline, expired token,
/// broken RPC, answer without numbers).
///
/// An exception rather than a sentinel value, because a placeholder object
/// looks like a real server answer to the caller — that is how the quota lock
/// broke. Whoever catches this keeps their last known state instead of
/// replacing it with a guess. Carries no display text: this is missing
/// information, not an error the user must read.
class CoachDataUnavailable implements Exception {
  const CoachDataUnavailable(this.reason, [this.cause]);

  final String reason;
  final Object? cause;

  @override
  String toString() => 'CoachDataUnavailable: $reason';
}

class CoachQuotaExceeded implements Exception {
  const CoachQuotaExceeded({required this.message, required this.dailyLimit});
  final String message;
  final int dailyLimit;
}
