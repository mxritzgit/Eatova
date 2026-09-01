import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
// Only for the `ClientException` arm below: a connection that dies MID-STREAM
// is past everything functions_client wraps, so the type arrives raw.
import 'package:http/http.dart' as http;
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
  /// [chatFrist], [rezeptFrist] and [fristPuffer] exist for the test suite
  /// alone and default to the constants below. The real deadlines are minutes
  /// long, so no test can sit one out; the timing cases run the same ledger at
  /// a fraction of its scale, with their numbers still DERIVED from
  /// [chatDeadline] / [recipeDeadline] so a changed constant changes the case.
  CoachChatService(
    this._client,
    this._userId, {
    Duration? chatFrist,
    Duration? rezeptFrist,
    Duration? fristPuffer,
  })  : _chatFrist = chatFrist ?? chatDeadline,
        _rezeptFrist = rezeptFrist ?? recipeDeadline,
        _fristPuffer = fristPuffer ?? _deadlineGrace;

  final SupabaseClient _client;
  final String _userId;
  final Duration _chatFrist;
  final Duration _rezeptFrist;
  final Duration _fristPuffer;

  // -------------------------------------------------------------------------
  // Deadlines
  // -------------------------------------------------------------------------
  /// Deadline for a plain coach question.
  ///
  /// Calibrated against what the SERVER can really spend, not against its
  /// provider caps alone. `coach-chat` has no request budget of its own —
  /// unlike analyze-meal, whose `ANALYZE_MEAL_REQUEST_BUDGET_MS` (55 s) is
  /// exactly what `HttpTimeoutPolicy.mealAnalysis` is derived from. Only the
  /// two provider round trips are capped (`PROVIDER_TIMEOUTS_MS` in handler.ts:
  /// 15 s classify + 45 s answer); the ten Supabase hops around them —
  /// /auth/v1/user, both request gates, the auth-fail gate, loadHistory,
  /// claim_chat_quota, the two stores, maybeAutoTitle, touchSession — carry a
  /// per-call deadline at best and no sum at all, so they come on top. The
  /// ledger:
  ///
  ///     15 s  connect plus body upload (an image may ride along; the same
  ///           allowance `mealAnalysis` budgets for its upload)
  ///   + 15 s  those ten round trips (one client-side PostgREST timeout)
  ///   + 60 s  the two provider caps
  ///   +  5 s  the small JSON answer coming back
  ///   = 95 s
  ///
  /// The old 75 s claimed "15 s of headroom over the server" but covered the
  /// two caps only, so 14 s of upload plus a provider using its full budget cut
  /// the connection while the server was still writing an answer it had already
  /// charged a daily slot for. Move this together with `PROVIDER_TIMEOUTS_MS` —
  /// and keep [_nachzuegler] either way: while the server has no total budget,
  /// no client-side number can be the right one.
  ///
  /// Without any deadline at all a network switch left the future hanging until
  /// the OS tore the connection down, and the composer stayed dead meanwhile.
  static const Duration chatDeadline = Duration(seconds: 95);

  /// Deadline for /recipe: the same ledger as [chatDeadline] with three provider
  /// round trips (15 s classification + 45 s draft + 30 s image = 90 s) and a
  /// base64 image travelling back, which gets 15 s instead of 5 s —
  /// 15 + 15 + 90 + 15 = 135 s. The old 120 s left 30 s for everything that is
  /// not a provider call, which the upload and the DB hops eat by themselves.
  static const Duration recipeDeadline = Duration(seconds: 135);

  /// Grace the outer `timeout` gets on top of the abort signal. The signal is
  /// the clean exit (it tears the socket down); the timeout is the guarantee,
  /// for HTTP clients that ignore `abortTrigger`.
  static const Duration _deadlineGrace = Duration(seconds: 5);

  /// The daily limit as the SERVER named it, learned from the last function
  /// answer or quota 429.
  ///
  /// The only reliable source there is: `get_chat_quota_today` merely echoes
  /// the limit it is handed, so the client cannot ask for it. null until the
  /// server has spoken once.
  int? _serverTageslimit;

  int? get serverDailyLimit => _serverTageslimit;

  /// Test seam for the state the app reaches after the first server answer.
  @visibleForTesting
  set serverDailyLimit(int? value) => _serverTageslimit = value;

  void _tageslimitMerken(int? limit) {
    if (limit != null && limit > 0) _serverTageslimit = limit;
  }

  /// Runs [aufruf] under [frist].
  ///
  /// Two layers on purpose: `abortSignal` (functions_client 2.7.1) actually
  /// cancels the request, and the outer `timeout` guarantees the future
  /// completes even where the trigger is ignored. The timer is cancelled on
  /// every exit, so no pending timer leaks into a widget test.
  Future<T> _mitFrist<T>(
    Duration frist,
    Future<T> Function(Future<void> abbruch) aufruf,
  ) {
    final abbruch = Completer<void>();
    final wecker = Timer(frist, () {
      if (!abbruch.isCompleted) abbruch.complete();
    });
    return aufruf(abbruch.future)
        .timeout(frist + _fristPuffer)
        .whenComplete(wecker.cancel);
  }

  // -------------------------------------------------------------------------
  // After the deadline: did the request land anyway?
  // -------------------------------------------------------------------------
  /// Clock-skew allowance for [_nachzuegler].
  ///
  /// `created_at` is server time, the send started on the device clock. Wide
  /// enough that a few minutes of skew never hide a real straggler, narrow
  /// enough that the same question asked earlier today is never replayed as the
  /// answer to this one.
  static const Duration _uhrenversatz = Duration(minutes: 5);

  /// The answer to [gesendet] when the server finished after the client gave
  /// up — null if it did not, or if that cannot be established.
  ///
  /// A deadline hit says nothing about whether the request died. The function
  /// claims the non-refundable daily slot BEFORE the first provider call and
  /// has no total budget, so a cut-off connection typically leaves a spent
  /// slot, a fully persisted exchange, and nothing missing but the response.
  /// Reporting "not sent" then invites a retry that claims a SECOND of the five
  /// daily slots and writes the same question into the transcript twice.
  ///
  /// So the transcript gets asked before the timeout is reported. Accepted only
  /// when the last two rows of the session are exactly this question and an
  /// answer to it, and that answer is young enough to belong to this attempt.
  /// Anything else — a failing lookup included — returns null and the timeout
  /// stands: missing proof is not proof of the opposite.
  Future<ChatMessage?> _nachzuegler({
    required String sessionId,
    required String gesendet,
    required DateTime begonnen,
  }) async {
    final List<ChatMessage> verlauf;
    try {
      verlauf = await loadHistory(sessionId, limit: 2);
    } catch (_) {
      // Already logged and reported by loadHistory; here it only means the
      // straggler cannot be proven.
      return null;
    }
    if (verlauf.length < 2) return null;
    final antwort = verlauf[verlauf.length - 1];
    final frage = verlauf[verlauf.length - 2];
    if (antwort.role != ChatRole.assistant || frage.role != ChatRole.user) {
      return null;
    }
    if (frage.content.trim() != gesendet.trim()) return null;
    if (antwort.content.trim().isEmpty) return null;
    if (antwort.createdAt.isBefore(begonnen.subtract(_uhrenversatz))) {
      return null;
    }
    return antwort;
  }

  /// The deadline's verdict for [send]: the straggler if the server finished
  /// anyway, otherwise the timeout the caller has always seen.
  ///
  /// `remaining` and `dailyLimit` stay null on purpose. Both are unknown here,
  /// and the screen reads a null `remaining` as "keep the counter you have" —
  /// exactly what it did on the old error path, so nothing regresses. Fetching
  /// the counter would add a second round trip to an already slow request and,
  /// as long as the server has not named COACH_DAILY_LIMIT itself, would only
  /// echo the client's own assumption back at the user.
  Future<CoachChatReply> _antwortNachFrist(
    String sessionId,
    String gesendet,
    DateTime begonnen,
  ) async {
    final antwort = await _nachzuegler(
      sessionId: sessionId,
      gesendet: gesendet,
      begonnen: begonnen,
    );
    if (antwort == null) throw CoachChatException(_l10n.coachErrorTimeout);
    return CoachChatReply(
      reply: antwort.content,
      refusal: antwort.refusal,
      sessionId: sessionId,
    );
  }

  /// [requestRecipe]'s counterpart to [_antwortNachFrist].
  ///
  /// The persisted row carries the recipe JSON but never the image
  /// (`handleRecipeMode` stores none, same rule as for user photos), so the
  /// card comes back without its picture — the placeholder state a second
  /// device shows anyway. A row that is neither a refusal nor a recipe is no
  /// answer to a wish, so the timeout stands.
  Future<CoachRecipeReply> _rezeptNachFrist(
    String sessionId,
    String wunsch,
    DateTime begonnen,
  ) async {
    final antwort = await _nachzuegler(
      sessionId: sessionId,
      gesendet: wunsch,
      begonnen: begonnen,
    );
    final vorschlag = antwort?.recipeProposal;
    if (antwort == null || (vorschlag == null && !antwort.refusal)) {
      throw CoachChatException(_l10n.coachErrorTimeout);
    }
    return CoachRecipeReply(
      reply: antwort.content,
      refusal: antwort.refusal,
      proposal: vorschlag,
      sessionId: sessionId,
      // Key of the local image store. The bytes are gone with the response, so
      // the card renders its placeholder until /recipe runs again.
      assistantMessageId: antwort.id.isEmpty ? null : antwort.id,
    );
  }

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
  /// derives `remaining` from the passed value and echoes it back. The limit
  /// is enforced server-side via `claim_chat_quota` (service_role only)
  /// against `COACH_DAILY_LIMIT`, which this RPC never sees — so the only
  /// reliable limit is the one a function answer named, kept in
  /// [serverDailyLimit]. Until then the request goes out with the client's
  /// assumption and the snapshot says so via [ChatQuotaSnapshot.limitAssumed].
  ///
  /// Throws [CoachDataUnavailable] if the RPC fails or returns no usable
  /// numbers — inventing a full quota there would lift an existing lock.
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    final bekannt = _serverTageslimit;
    final dynamic res;
    try {
      res = await _client.rpc(
        'get_chat_quota_today',
        params: {
          'p_daily_limit': bekannt ?? ChatQuotaSnapshot.standardTageslimit,
        },
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
      // `daily_limit` is the echo of what we just sent, so it is only a server
      // statement once the server itself named a limit.
      limitAssumed: bekannt == null,
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
  ///
  /// [onPartialReply] receives the answer WHILE it is being written, each call
  /// carrying everything assembled so far. It is a live preview and nothing
  /// else: the returned [CoachChatReply.reply] is the server's `done` payload
  /// and supersedes it — the ellipsis for a cut-off answer, the prompt-leak
  /// replacement and every refusal exist only there. A stream with ZERO
  /// previews is normal, not broken: that is what every refusal looks like.
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    // Reference point for [_nachzuegler]: everything it may accept as this
    // request's answer has to be younger than the request itself.
    final begonnen = DateTime.now();
    try {
      return await _mitFrist(_chatFrist, (abbruch) async {
        final res = await _client.functions.invoke(
          'coach-chat',
          // B7 — the streaming opt-in. Deliberately still `invoke()`:
          // functions_client 2.7.1 hands the LIVE body through for a 2xx
          // `text/event-stream` (functions_client.dart: `data =
          // response.stream`), so the JWT plus apikey headers, the abort
          // signal and the whole `on Functions*` mapping keep working exactly
          // as before and only the body reading changes.
          headers: const {'Accept': 'text/event-stream'},
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
          abortSignal: abbruch,
        );
        // Reaching this point means 2xx: functions_client throws on any other
        // status, so error handling lives only in the `on Functions*` arms.
        final data = res.data;
        // The fallback, and it is not optional: everything the server decides
        // BEFORE the answer call keeps its buffered JSON even though we asked
        // for a stream — refusals, recipe mode, and every function deployment
        // that predates streaming. This is also the rollback path, so it stays
        // the one that parses the payload for both.
        if (data is! Stream<List<int>>) {
          return _antwortAusNutzlast(
            data is Map ? data : const <dynamic, dynamic>{},
            sessionId,
          );
        }
        // The read happens INSIDE `_mitFrist`: with a stream the future is
        // done once the headers land, so a deadline around `invoke()` alone
        // would cover nothing at all.
        return _stromAuswerten(
          await _sseLesen(data, onPartialReply),
          sessionId,
        );
      });
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } on TimeoutException catch (e, stack) {
      // Deadline hit. Deliberately unreported, like the offline case: a slow
      // network or a slow provider is not an outage only we can see. Whether
      // this is an error at all is decided by the transcript, not by the clock.
      _logSendFailure(e, stack);
      return _antwortNachFrist(sessionId, message, begonnen);
    } on RequestAbortedException catch (e, stack) {
      // Same deadline, taken by the abort signal instead of the timeout.
      _logSendFailure(e, stack);
      return _antwortNachFrist(sessionId, message, begonnen);
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
    } on http.ClientException catch (e, stack) {
      // Only reachable on the streamed body: functions_client wraps a transport
      // error into [FunctionsFetchException] while it opens the request, but
      // the socket now stays open long past that, and a connection dropped
      // mid-answer arrives raw. Mapped to the same offline text, and equally
      // unreported — it is the same event, just later. Must stay BELOW the
      // [RequestAbortedException] arm: that one is a ClientException subclass
      // and the deadline must keep its straggler recovery.
      _logSendFailure(e, stack);
      throw CoachChatException(_l10n.coachErrorNoConnection);
    } catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.send.unbekannt', e, stack);
      throw CoachChatException(_unreachableMessage);
    }
  }

  /// Turns one buffered `coach-chat` body into the reply.
  ///
  /// Shared by the buffered path and the stream's `done` event on purpose: the
  /// server sends the IDENTICAL object in both (handler_stream_test.ts pins
  /// that byte for byte), so a single parser is what keeps the two wire shapes
  /// from drifting apart.
  CoachChatReply _antwortAusNutzlast(
    Map<dynamic, dynamic> map,
    String sessionId,
  ) {
    final reply = map['reply'] is String ? (map['reply'] as String).trim() : '';
    if (reply.isEmpty) {
      // 2xx without text: a broken contract, and the only failure here that
      // no status reveals.
      final leer = CoachChatException(_l10n.coachErrorEmptyReply);
      _melde('coach.send.leereAntwort', leer, StackTrace.current);
      throw leer;
    }
    final dailyLimit =
        map['daily_limit'] is num ? (map['daily_limit'] as num).toInt() : null;
    _tageslimitMerken(dailyLimit);
    return CoachChatReply(
      reply: reply,
      refusal: map['refusal'] == true,
      refusalReason: map['refusal_reason']?.toString(),
      // An omitted `remaining` stays null, and the screen reads null as "keep
      // the counter you have". Never 0 — that would lock the composer.
      remaining:
          map['remaining'] is num ? (map['remaining'] as num).toInt() : null,
      dailyLimit: dailyLimit,
      sessionId: map['session_id']?.toString() ?? sessionId,
    );
  }

  /// The verdict on a finished SSE response.
  CoachChatReply _stromAuswerten(_SseAntwort strom, String sessionId) {
    // `done` is AUTHORITATIVE and supersedes the concatenated deltas: the
    // ellipsis for a length-capped answer, the prompt-leak replacement and
    // every refusal exist only in it. Its payload is the buffered body, so the
    // same parser finishes the job.
    final done = strom.done;
    if (done != null) return _antwortAusNutzlast(done, sessionId);

    final geliefert = strom.text.trim();
    final fehler = strom.fehler;
    if (geliefert.isEmpty) {
      if (fehler == null) {
        // A 2xx that carried no usable frame at all. Same broken contract as a
        // buffered 200 without text, and the only failure here no status
        // reveals — so it keeps that name and that report.
        final leer = CoachChatException(_l10n.coachErrorEmptyReply);
        _melde('coach.send.leereAntwort', leer, StackTrace.current);
        throw leer;
      }
      // The server named the failure and delivered nothing, so it gave the
      // daily slot back on exactly this path — the caller's retry button is
      // right. Same text a buffered 502/504 produces.
      _melde(
        'coach.send.stream',
        StateError('coach stream ended empty: $fehler'),
        StackTrace.current,
      );
      throw CoachChatException(_unreachableMessage);
    }
    // Content went out and the stream then broke. The slot stays spent and the
    // server persisted exactly this partial text, so throwing here would show
    // an error next to an answer the transcript already holds — and the retry
    // would buy a second of the five daily slots for a question already asked.
    _melde(
      'coach.send.stream',
      StateError('coach stream cut after content: $fehler'),
      StackTrace.current,
    );
    final meta = strom.meta;
    final dailyLimit =
        meta['daily_limit'] is num ? (meta['daily_limit'] as num).toInt() : null;
    _tageslimitMerken(dailyLimit);
    return CoachChatReply(
      reply: geliefert,
      refusal: false,
      // Same rule as the buffered body: `meta` OMITS an unknown remaining
      // rather than sending null, and null means "keep the counter you have".
      remaining:
          meta['remaining'] is num ? (meta['remaining'] as num).toInt() : null,
      dailyLimit: dailyLimit,
      sessionId: meta['session_id']?.toString() ?? sessionId,
    );
  }

  /// /rezept: has the function generate a recipe plus image (`mode: "recipe"`).
  /// Costs one daily coach slot.
  ///
  /// The function only returns data; saving happens client-side after the user
  /// confirms in the sheet. Error mapping is identical to [send].
  ///
  /// Deliberately no `user_context`: `handleRecipeMode` takes eight parameters
  /// and none of them is the context, so weight, target weight, daily balance
  /// and the names of today's logged foods travelled to the server without
  /// ever being read. Data minimisation beats sending on spec — making the
  /// recipe respect the remaining balance is a server change and a product
  /// decision, not a client one.
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    // As in [send]: reference point for [_nachzuegler].
    final begonnen = DateTime.now();
    try {
      final res = await _mitFrist(
        _rezeptFrist,
        (abbruch) => _client.functions.invoke(
          'coach-chat',
          body: {
            'message': wish,
            'mode': 'recipe',
            'locale': locale.toLowerCase().startsWith('en') ? 'en' : 'de',
            'session_id': sessionId,
          },
          abortSignal: abbruch,
        ),
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
      final dailyLimit =
          map['daily_limit'] is num ? (map['daily_limit'] as num).toInt() : null;
      _tageslimitMerken(dailyLimit);
      return CoachRecipeReply(
        reply: reply,
        refusal: refusal,
        proposal: proposal,
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        dailyLimit: dailyLimit,
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
    } on TimeoutException catch (e, stack) {
      // As in [send]: the deadline, deliberately unreported, and the transcript
      // decides whether the slot was spent for nothing.
      _logSendFailure(e, stack);
      return _rezeptNachFrist(sessionId, wish, begonnen);
    } on RequestAbortedException catch (e, stack) {
      _logSendFailure(e, stack);
      return _rezeptNachFrist(sessionId, wish, begonnen);
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
        // The 429 is the second place the server names its own limit.
        if (limit is num) _tageslimitMerken(limit.toInt());
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

// ---------------------------------------------------------------------------
// B7 — reading the coach-chat SSE stream
//
// Wire shape (supabase/functions/coach-chat/handler.ts, `sseFrame`):
//   event: meta   data: {"session_id":…,"remaining":<omitted if unknown>,…}
//   event: delta  data: {"t":"<chunk>"}
//   event: done   data: <the exact object the buffered path returns>
//   event: error  data: {"error":"provider_error"|"provider_timeout"}
// `done` and `error` are mutually exclusive and always last.
// ---------------------------------------------------------------------------

/// What one finished `coach-chat` SSE response amounted to.
class _SseAntwort {
  const _SseAntwort({
    required this.text,
    required this.meta,
    this.done,
    this.fehler,
  });

  /// The `delta` texts concatenated — a live PREVIEW, never the final answer.
  /// Legitimately empty: a refusal and a prompt-leak hit send `meta` then
  /// `done` and not a single delta.
  final String text;

  /// The `meta` payload, empty until the event arrived.
  final Map<dynamic, dynamic> meta;

  /// The `done` payload — identical to the buffered body, and authoritative.
  final Map<dynamic, dynamic>? done;

  /// The `error` code, if the stream ended on one instead of on `done`.
  final String? fehler;
}

/// Parses the SSE frames of [bytes], handing every intermediate state to
/// [onPartialReply].
///
/// Deliberately forgiving in both directions. A frame whose payload is not
/// JSON, an unknown event name, a keep-alive comment and a body cut mid-frame
/// are all skipped rather than thrown: this runs after a 200 with an answer
/// already on the way, and killing it would cost the whole reply plus the
/// daily slot that paid for it. What it does NOT do is invent — a stream that
/// carried no usable frame comes back empty and the caller decides.
Future<_SseAntwort> _sseLesen(
  Stream<List<int>> bytes,
  void Function(String text)? onPartialReply,
) async {
  final text = StringBuffer();
  final daten = StringBuffer();
  var ereignis = '';
  var rest = '';
  Map<dynamic, dynamic> meta = const <dynamic, dynamic>{};
  Map<dynamic, dynamic>? done;
  String? fehler;

  void rahmenAbschliessen() {
    final roh = daten.toString();
    final name = ereignis;
    daten.clear();
    ereignis = '';
    if (roh.isEmpty) return;
    final Object? nutzlast;
    try {
      nutzlast = jsonDecode(roh);
    } on FormatException {
      // A frame that is not JSON is a hiccup on the way, not a reason to drop
      // an answer that is still arriving: it costs at most one preview chunk.
      return;
    }
    if (nutzlast is! Map) return;
    switch (name) {
      case 'meta':
        meta = nutzlast;
      case 'delta':
        final stueck = nutzlast['t'];
        if (stueck is! String || stueck.isEmpty) return;
        text.write(stueck);
        onPartialReply?.call(text.toString());
      case 'done':
        done = nutzlast;
      case 'error':
        final code = nutzlast['error'];
        fehler = code is String ? code : 'provider_error';
    }
  }

  void zeile(String roh) {
    final line = roh.endsWith('\r') ? roh.substring(0, roh.length - 1) : roh;
    // Blank = end of frame, ":" = keep-alive comment, no colon at all = a
    // field without a value, which carries nothing either way.
    if (line.isEmpty) return rahmenAbschliessen();
    if (line.startsWith(':')) return;
    final trenner = line.indexOf(':');
    if (trenner < 0) return;
    final feld = line.substring(0, trenner);
    var wert = line.substring(trenner + 1);
    if (wert.startsWith(' ')) wert = wert.substring(1);
    if (feld == 'event') ereignis = wert;
    if (feld == 'data') {
      if (daten.isNotEmpty) daten.write('\n');
      daten.write(wert);
    }
  }

  // `allowMalformed`: a connection cut inside a multi-byte character must not
  // become a FormatException that loses the answer around it.
  await for (final stueck
      in bytes.transform(const Utf8Decoder(allowMalformed: true))) {
    rest += stueck;
    for (;;) {
      final schnitt = rest.indexOf('\n');
      if (schnitt < 0) break;
      zeile(rest.substring(0, schnitt));
      rest = rest.substring(schnitt + 1);
    }
  }
  // A body that ended without its closing blank line still gets its last frame
  // decided: half a payload cannot parse and falls away, a whole one is the
  // `done` the whole answer hangs on.
  if (rest.isNotEmpty) zeile(rest);
  rahmenAbschliessen();

  return _SseAntwort(
    text: text.toString(),
    meta: meta,
    done: done,
    fehler: fehler,
  );
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
