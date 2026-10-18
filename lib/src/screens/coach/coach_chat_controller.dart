/// Coach tab state without widgets: sessions, history, sending, the wait for
/// a stored answer, the quota and the banner.
///
/// Lives exactly as long as the screen's State, which creates and disposes
/// it, so it sits next to the screen rather than with the app-wide stores in
/// `lib/src/app/`. It talks to the backend only through [CoachChatService]
/// and never touches a BuildContext: scrolling, haptics, announcements, the
/// composer field and every other UI reaction go through [CoachChatViewHooks].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../models/coach_training_context.dart';
import '../../models/fitness_recipe.dart';
import '../../services/coach_chat_service.dart';
import '../../services/recipe_image_store.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';

/// What the screen does around a controller transition. Every call is
/// synchronous, made only while the controller is alive and in the same turn
/// as the [ChangeNotifier] notification of that transition, so the next frame
/// sees both.
class CoachChatViewHooks {
  const CoachChatViewHooks();

  /// A conversation was loaded or reloaded: the screen shows its end.
  void conversationShown() {}

  /// The conversation on screen is replaced or reloaded; transient UI that
  /// belongs to it (the answer cue) goes.
  void conversationReplaced() {}

  /// A question became a bubble and goes out: the composer empties and the
  /// chat glides to its end.
  void questionSent() {}

  /// The first streamed text replaced the thinking dots.
  void previewStarted() {}

  /// An answer landed in the conversation on screen.
  void answerArrived() {}

  /// A request ended in the conversation that sent it (answer or error).
  void sendFinished() {}

  /// A request the server cannot take gives its text back to the composer.
  void draftReturned(String text) {}
}

/// Inputs from the screen's widget for the next request, read when it
/// starts. A new per-request field (say, preferences for /recipe) goes here
/// and into the matching service call in [CoachChatController].
@immutable
class CoachRequestInputs {
  const CoachRequestInputs({this.userContext});

  /// Compact snapshot of profile + daily balance for chat mode only. /recipe
  /// deliberately gets none (P5-02): the function's recipe branch never reads
  /// it, so it would be health data sent for nothing.
  final String? userContext;
}

/// A send attempt that never reached the server — marker and retry job.
///
/// Holds everything the second attempt needs instead of reconstructing it from
/// the input field: [text] is the displayed text, [imageBytes] the already
/// scrubbed image. Keeps the retry bit-identical and free of a second
/// compression/EXIF scrub.
@immutable
class CoachFailedSend {
  const CoachFailedSend({
    required this.messageId,
    required this.text,
    this.imageBytes,
    this.imageMimeType,
    this.trainingContext,
  });

  /// Id of the bubble in the history; the retry removes exactly this one, so
  /// no duplicate appears.
  final String messageId;

  final String text;
  final Uint8List? imageBytes;
  final String? imageMimeType;
  final CoachTrainingContext? trainingContext;
}

/// A stored /recipe proposal: the recipe as written, how the write was
/// delivered, and whether its photo could not be kept.
typedef CoachRecipeAdoption = ({
  FitnessRecipe recipe,
  SyncDelivery delivery,
  bool photoFailed,
});

/// What a proposal request hands [CoachChatController._sendProposalRequest]:
/// the finished answer bubble plus the session and quota the server named.
typedef _ProposalAnswer = ({
  ChatMessage answer,
  String sessionId,
  int? remaining,
  int? dailyLimit,
});

/// State and operations of the Coach tab.
///
/// [inBackground] tells the answer wait whether the app is in the
/// background right now (the screen reads the binding's lifecycle state);
/// there no timer runs.
class CoachChatController extends ChangeNotifier {
  CoachChatController({
    CoachChatService? service,
    CoachChatViewHooks hooks = const CoachChatViewHooks(),
    CoachRequestInputs Function()? requestInputs,
    bool Function()? inBackground,
  }) : _service = service,
       _hooks = hooks,
       _requestInputs = requestInputs ?? _noInputs {
    _antwortWarten = _AntwortWarten(this, inBackground ?? _never);
    _antwortWarten.binden(service);
  }

  static CoachRequestInputs _noInputs() => const CoachRequestInputs();
  static bool _never() => false;

  final CoachChatViewHooks _hooks;
  final CoachRequestInputs Function() _requestInputs;
  bool _disposed = false;

  /// Keeps a request whose connection died in its thinking state while the
  /// server may still store the answer (COACH-4).
  late final _AntwortWarten _antwortWarten;

  // --- Inputs from the screen ------------------------------------------------

  CoachChatService? _service;

  /// The signed-in account's backend; null means not logged in.
  CoachChatService? get service => _service;

  /// Bumped on every account switch; review sheets and /plan and /log
  /// answers check it on top of the service identity.
  int _accountRevision = 0;
  int get accountRevision => _accountRevision;

  /// Account switch from the shell. Results of the old service are fenced
  /// out by identity and [accountRevision]; the old account's answer wait
  /// ends here.
  void updateService(CoachChatService? service) {
    if (identical(service, _service)) return;
    _antwortWarten.loesen(_service);
    _service = service;
    _accountRevision++;
    _antwortWarten.binden(service);
  }

  AppLocalizations _l10n = deL10n;

  /// Locale pack for the texts the controller writes into the banner and the
  /// locale of its requests, set by the screen from `context.l10n` (the same
  /// setter pattern as [CoachChatService.l10n]). German until the screen
  /// sets it.
  set l10n(AppLocalizations value) => _l10n = value;

  // --- State -----------------------------------------------------------------

  List<ChatMessage> _messages = const <ChatMessage>[];
  List<ChatSession> _sessions = const <ChatSession>[];

  /// The conversation on screen.
  List<ChatMessage> get messages => _messages;

  /// The sessions sheet's list; the last known one while the server is away.
  List<ChatSession> get sessions => _sessions;

  /// The last undelivered question — marker and retry job in one; null means
  /// everything in the history went out.
  ///
  /// The message stays in the history (it is user content). Only ONE job is
  /// held, the newest; an older one loses its marker but keeps its bubble.
  CoachFailedSend? _failedSend;
  CoachFailedSend? get failedSend => _failedSend;

  /// `null` means "unknown" — neither full nor empty. A snapshot exists only
  /// once the server actually named numbers; a failed RPC must not refill an
  /// exhausted quota and lift the block (Review D2).
  ChatQuotaSnapshot? _quota;
  ChatQuotaSnapshot? get quota => _quota;
  int _quotaRevision = 0;

  /// Only a *known* empty quota blocks. An unknown state (cold start without
  /// network) deliberately does not: the server decides and answers 429.
  ///
  /// An ASSUMED limit counts as unknown too (P5-06): `get_chat_quota_today`
  /// derives `remaining` from the limit the client hands it, so with
  /// `COACH_DAILY_LIMIT=10` it reports 0 free after five slots and would lock
  /// a composer the server still accepts. The limit only becomes real once a
  /// function answer or a quota 429 names it.
  bool get quotaExhausted {
    final quota = _quota;
    return quota != null && !quota.limitAssumed && quota.remaining <= 0;
  }

  /// Remaining count for display only. Widgets need a number, so an unknown
  /// state falls back to the default limit and claims neither "limit reached"
  /// nor a concrete count. Blocking decisions use [quotaExhausted].
  int get remainingForDisplay =>
      _quota?.remaining ?? ChatQuotaSnapshot.standardTageslimit;

  int get limitForDisplay =>
      _quota?.dailyLimit ?? ChatQuotaSnapshot.standardTageslimit;

  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;

  /// Visit counter of the conversation on screen. It fences slow loads and
  /// answers, including an A→B→A return to the same session id.
  int _conversationRevision = 0;
  int get conversationRevision => _conversationRevision;
  int _sessionListRevision = 0;

  bool _loading = true;

  /// Bootstrap or a conversation load is running.
  bool get loading => _loading;

  /// The banner text; null shows none.
  String? _error;
  String? get error => _error;

  /// The active session's history failed to load — the hero empty state must
  /// then not present it as "empty".
  bool _historyUnavailable = false;
  bool get historyUnavailable => _historyUnavailable;

  /// The coach answer as it streams in, empty while nothing has arrived.
  ///
  /// A notifier of its own, not part of this controller's notifications: the
  /// deltas arrive dozens of times a second and only the one preview bubble
  /// may rebuild for them. It is a PREVIEW — `send` returns the
  /// authoritative text and the finished bubble replaces this one, so
  /// nothing here is ever the record.
  final ValueNotifier<String> _preview = ValueNotifier<String>('');
  ValueListenable<String> get preview => _preview;

  /// A streamed preview was on screen for the answer in flight: the finished
  /// answer takes its place without a second entrance.
  bool _vorschauGezeigt = false;
  bool get previewShown => _vorschauGezeigt;

  /// How many send jobs (chat or recipe) are in flight.
  ///
  /// Counts per USER, not per session, because the quota does too: a plain
  /// `bool` reset on session switch let two requests run in parallel and burn
  /// two daily slots from one interaction. Only [_sendevorgangBeendet]
  /// decrements, from a `finally` — a discarded answer must free the counter
  /// too, or the composer stays locked forever.
  int _laufendeSendungen = 0;

  bool get sending => _laufendeSendungen > 0;

  /// Session the in-flight request belongs to. [sending] is per user, so
  /// without this the thinking dots showed in whichever session was open.
  String? _sendendeSessionId;

  bool get sendingInActiveSession =>
      sending && _sendendeSessionId == _activeSessionId;

  /// Typing stays allowed while an answer is in flight — a disabled TextField
  /// would close the keyboard mid-flow. Only actions wait on [canInteract].
  bool get canType =>
      _service != null &&
      !_loading &&
      !quotaExhausted &&
      _activeSessionId != null;

  bool get canInteract => canType && !sending;

  /// An add is running (confirm sheet, store image, createUserRecipe) — locks
  /// all recipe card buttons until it finishes.
  bool _addingRecipe = false;
  bool get addingRecipe => _addingRecipe;

  /// Why nothing can be sent at all, or null. Loading and a running request
  /// are waits, not locks.
  String? get lockReason {
    if (_service == null) return _l10n.coachErrorNotLoggedIn;
    if (quotaExhausted) {
      return _l10n.coachErrorDailyLimitReached(limitForDisplay);
    }
    if (_activeSessionId == null) {
      // A failed history load leaves no active session either; its banner
      // names the real cause.
      return _historyUnavailable
          ? _l10n.coachErrorHistoryUnavailable
          : _l10n.coachErrorNoSession;
    }
    return null;
  }

  // --- Lifecycle ---------------------------------------------------------------

  /// Every state change notifies here, so this one place also ends a pending
  /// answer wait once its conversation is left.
  void _notify() {
    if (_disposed) return;
    _antwortWarten.sitzungPruefen(_activeSessionId);
    notifyListeners();
  }

  /// Ends the answer wait without a timer left behind; late results of
  /// running requests change nothing afterwards.
  @override
  void dispose() {
    _disposed = true;
    _antwortWarten.loesen(_service);
    _preview.dispose();
    super.dispose();
  }

  /// No service = not logged in: nothing loads, the banner says why.
  void reportSignedOut() {
    _loading = false;
    _error = _l10n.coachErrorNotLoggedIn;
    _notify();
  }

  /// Feedback the screen produces itself (dictation, photo, a locked brief)
  /// in the same banner; null clears it.
  void showError(String? message) {
    if (_disposed || _error == message) return;
    _error = message;
    _notify();
  }

  /// The app went to the background: the answer wait keeps no timer.
  void appPaused() => _antwortWarten.hintergrund();

  /// Back in front: a waiting answer check runs at once, the answer may have
  /// landed meanwhile.
  void appResumed() => _antwortWarten.vordergrund();

  /// Everything a tab switch used to do by unmounting the screen. It stays
  /// mounted, so whatever is missing here never happens again until cold
  /// start. Called when the tab becomes visible and on resume of a visible
  /// tab, for the account [svc] seen at that moment.
  Future<void> returnToChat(CoachChatService svc) async {
    if (_disposed) return;
    // Healing path: a bootstrap that ended without a session (offline on the
    // first visit) would otherwise leave the composer dead for the whole app
    // run, since only the quota was refreshed here, never the session.
    if (_activeSessionId == null) {
      await bootstrap();
      return;
    }
    // The error banner is feedback on an action, not a permanent state. A
    // failed history load is the exception: nothing here reloads it, and
    // without its banner the conversation is just blank.
    if (identical(_service, svc) && _error != null && !_historyUnavailable) {
      _error = null;
      _notify();
    }
    await _refreshQuota(svc);
  }

  // --- Sessions and history ---------------------------------------------------

  /// Never runs twice concurrently — the return path's healing can restart
  /// the bootstrap, so this is a real case.
  bool _bootstrapLaeuft = false;

  /// Loads the session list, picks (or creates) the active session and loads
  /// its history and the quota.
  Future<void> bootstrap() async {
    if (_bootstrapLaeuft) return;
    _bootstrapLaeuft = true;
    try {
      await _bootstrapIntern();
    } finally {
      _bootstrapLaeuft = false;
    }
  }

  Future<void> _bootstrapIntern() async {
    final svc = _service;
    final sessionBeforeLoad = _activeSessionId;
    if (svc == null || _disposed) return;
    // Only on a repeat run: show spinner, clear old banner.
    if (!_loading) {
      _loading = true;
      _error = null;
      _notify();
    }

    List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Offline: "no list" is not "no sessions". The next step asks for a
      // default session anyway.
      sessions = const <ChatSession>[];
    }
    if (_disposed || _activeSessionId != sessionBeforeLoad) return;
    final activeId = sessions.isNotEmpty
        ? sessions.first.id
        : await svc.ensureDefaultSession();
    if (activeId == null) {
      if (_disposed || _activeSessionId != sessionBeforeLoad) return;
      _loading = false;
      // No session means no history to have failed (a retry after one).
      _historyUnavailable = false;
      _error = _l10n.coachErrorNoSession;
      _notify();
      return;
    }
    // These reads are independent once the active session is known. Start
    // quota alongside history so a slow quota RPC does not add a round-trip
    // to the first coach render.
    final knownQuota = _quota;
    final quotaFuture = () async {
      try {
        return await svc.loadQuotaToday();
      } on CoachDataUnavailable {
        return knownQuota;
      }
    }();

    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(activeId);
    } on CoachDataUnavailable {
      // Consume the parallel task on this early exit to avoid an unhandled
      // failure while retaining the existing history error state.
      await quotaFuture;
      // "Not loadable" is not "empty": an empty list would show the hero
      // state and present the history as deleted.
      if (_disposed || _activeSessionId != sessionBeforeLoad) return;
      // The list did load: the sheet shows it, and picking a conversation
      // there retries the history load and unlocks the composer.
      if (sessions.isNotEmpty) _sessions = sessions;
      _loading = false;
      _historyUnavailable = true;
      _error = _l10n.coachErrorHistoryUnavailable;
      _notify();
      return;
    }
    if (_disposed || _activeSessionId != sessionBeforeLoad) return;
    _historyUnavailable = false;
    history = await _hydrateProposalImages(history);
    // Unknown stays unknown: the last known state survives instead of being
    // replaced by a guess.
    // The quota RPC has been running alongside history; preserve the previous
    // snapshot when it is unavailable rather than inventing a value.
    final quota = await quotaFuture;
    var refreshedSessions = sessions;
    if (sessions.isEmpty) {
      try {
        refreshedSessions = await svc.loadSessions();
      } on CoachDataUnavailable {
        refreshedSessions = _sessions;
      }
    }
    // A newly created or selected conversation takes precedence over bootstrap.
    if (_disposed || _activeSessionId != sessionBeforeLoad) return;
    _sessions = refreshedSessions;
    _activeSessionId = activeId;
    _messages = history;
    _quota = quota;
    _loading = false;
    // Fresh history from the server: a retry job pointing at a local bubble
    // that no longer exists would target nothing.
    _failedSend = null;
    _notify();
    _hooks.conversationShown();
  }

  /// Reloads the daily counter into the display.
  ///
  /// Rule: a network outage must neither consume nor refill the quota —
  /// [CoachChatService.loadQuotaToday] throws instead of inventing a snapshot.
  Future<void> _refreshQuota(CoachChatService svc) async {
    final revision = ++_quotaRevision;
    final ChatQuotaSnapshot frisch;
    try {
      frisch = await svc.loadQuotaToday();
    } on CoachDataUnavailable {
      return;
    }
    if (!_disposed &&
        identical(_service, svc) &&
        revision == _quotaRevision) {
      _quota = frisch;
      _notify();
    }
  }

  /// Reloads the sessions sheet's list; an outage keeps the last known one.
  Future<void> _refreshSessions() async {
    final svc = _service;
    if (svc == null) return;
    final revision = ++_sessionListRevision;
    final List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Keep the last known state: an outage must not empty the sessions
      // sheet and claim there are no conversations.
      return;
    }
    if (_disposed ||
        !identical(_service, svc) ||
        revision != _sessionListRevision) {
      return;
    }
    _sessions = sessions;
    _notify();
  }

  bool _matchesConversation(
    CoachChatService svc,
    String? sessionId,
    int revision,
  ) =>
      !_disposed &&
      identical(_service, svc) &&
      _activeSessionId == sessionId &&
      _conversationRevision == revision;

  /// Switches the displayed conversation.
  ///
  /// A visit revision fences slow loads, including an A→B→A return to the same
  /// session id. Picking the open conversation again retries a history that
  /// failed to load; otherwise it does nothing.
  ///
  /// [keepNotice] keeps the banner that explains the switch itself.
  Future<void> switchToSession(
    String sessionId, {
    bool keepNotice = false,
  }) async {
    final svc = _service;
    if (svc == null || _disposed) return;
    final retry = _activeSessionId == sessionId;
    if (retry && !_historyUnavailable) return;
    final revision = ++_conversationRevision;
    _preview.value = '';
    _loading = true;
    _activeSessionId = sessionId;
    // A retry keeps what is on screen until the reload answers.
    if (!retry) {
      _messages = const <ChatMessage>[];
      // The undelivered question and the banner belong to the session
      // being left; the retry job would otherwise land in the new one.
      _failedSend = null;
      if (!keepNotice) _error = null;
    }
    // So does a cue still waiting behind the sessions sheet.
    _hooks.conversationReplaced();
    _notify();
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      // The error belongs to the session that caused it, or C would carry A's
      // banner and history state.
      if (!_matchesConversation(svc, sessionId, revision)) {
        return;
      }
      _loading = false;
      _historyUnavailable = true;
      _error = _l10n.coachErrorHistoryUnavailable;
      _notify();
      return;
    }
    history = await _hydrateProposalImages(history);
    if (!_matchesConversation(svc, sessionId, revision)) {
      return;
    }
    _messages = history;
    // A successful retry answers the history banner.
    if (retry) _error = null;
    _historyUnavailable = false;
    _loading = false;
    _notify();
    _hooks.conversationShown();
  }

  /// Creates and opens a new conversation. False when the server created
  /// none; the screen says so.
  Future<bool> startNewSession() async {
    final svc = _service;
    if (svc == null || _disposed) return true;
    // Same check as [switchToSession], against the state before creating: if
    // the user switched meanwhile, the view is theirs — the new session is in
    // the list, one tap away.
    final vorher = _activeSessionId;
    final revision = _conversationRevision;
    final id = await svc.createSession(title: _l10n.coachSessionDefaultTitle);
    if (id == null) return false;
    await _refreshSessions();
    if (!_matchesConversation(svc, vorher, revision)) return true;
    _conversationRevision++;
    _activeSessionId = id;
    _messages = const <ChatMessage>[];
    _loading = false;
    _historyUnavailable = false;
    _error = null;
    _failedSend = null;
    _hooks.conversationReplaced();
    _notify();
    return true;
  }

  /// Deletes a conversation. False when the server did not delete it (S8:
  /// not deleted is not deleted — it stays in the list, the screen says so).
  Future<bool> deleteSession(String sessionId) async {
    final svc = _service;
    if (svc == null || _disposed) return true;
    try {
      await svc.deleteSession(sessionId);
    } on CoachDataUnavailable {
      return false;
    }
    if (_disposed || !identical(_service, svc)) return true;
    _sessions = _sessions.where((s) => s.id != sessionId).toList();
    _notify();
    await _refreshSessions();
    if (_disposed || !identical(_service, svc)) return true;
    // Ignore a list response that still contains the confirmed deletion.
    if (_sessions.any((s) => s.id == sessionId)) {
      _sessions = _sessions.where((s) => s.id != sessionId).toList();
      _notify();
    }
    if (_activeSessionId == sessionId) {
      if (_sessions.isNotEmpty) {
        await switchToSession(_sessions.first.id);
      } else {
        // Last session deleted: recreate the default AND reload, so list and
        // sheet show the new session instead of being empty.
        final fallback = await svc.ensureDefaultSession();
        if (_disposed ||
            !identical(_service, svc) ||
            _activeSessionId != sessionId) {
          return true;
        }
        if (fallback == null) {
          _conversationRevision++;
          _preview.value = '';
          _activeSessionId = null;
          _messages = const <ChatMessage>[];
          _loading = false;
          _error = _l10n.coachErrorNoSession;
          _hooks.conversationReplaced();
          _notify();
          return true;
        }
        await _refreshSessions();
        if (_disposed ||
            !identical(_service, svc) ||
            _activeSessionId != sessionId) {
          return true;
        }
        await switchToSession(fallback);
      }
    }
    return true;
  }

  /// Proposals loaded from history carry no bytes; this reloads the locally
  /// stored proposal images (RecipeImageStore, keyed by message id). Missing
  /// files (second device, cap prune, logout) stay placeholders.
  Future<List<ChatMessage>> _hydrateProposalImages(
    List<ChatMessage> history,
  ) async {
    final result = List<ChatMessage>.of(history);
    // Proposal images are independent local reads. Loading them one by one
    // made opening a long conversation wait for every file in sequence,
    // even though the history itself was already available. Start all reads
    // together and apply the results by index so message order stays stable.
    final imageStore = RecipeImageStore.instance;
    final reads = <Future<(int, ChatMessage, Uint8List?)>>[];
    for (var i = 0; i < result.length; i++) {
      final message = result[i];
      final proposal = message.recipeProposal;
      if (proposal == null || proposal.imageBytes != null) continue;
      reads.add(() async {
        final bytes = await imageStore.readProposalImage(message.id);
        return (i, message, bytes);
      }());
    }
    for (final (index, message, bytes) in await Future.wait(reads)) {
      final proposal = message.recipeProposal;
      if (proposal == null || bytes == null) continue;
      result[index] = message.withRecipeProposal(proposal.withImageBytes(bytes));
    }
    return result;
  }

  // --- Commands ------------------------------------------------------------------

  /// Detects the /recipe command at line start — English is the only spelling
  /// in both app languages; the command menu handles discoverability. Returns
  /// the wish text ('' if none) or null for no/unknown command.
  static String? recipeWishFrom(String text) {
    final match = RegExp(
      r'^/recipe(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    if (match == null) return null;
    return (match.group(1) ?? '').trim();
  }

  static String? planWishFrom(String text) {
    final match = RegExp(
      r'^/plan(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    return match == null ? null : (match.group(1) ?? '').trim();
  }

  /// `/log` and the finished workout after it ('' if none); null for any
  /// other text. English in both app languages, like /recipe and /plan.
  static String? workoutLogWishFrom(String text) {
    final match = RegExp(
      r'^/log(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    return match == null ? null : (match.group(1) ?? '').trim();
  }

  // --- Sending -------------------------------------------------------------------

  /// Sends [typedText] (and an optional, already scrubbed photo) to the
  /// active conversation: a chat question, or /recipe, /plan or /log.
  ///
  /// The question becomes a bubble at once; the answer, an error and the
  /// quota land only where they belong — the answer and error in the
  /// conversation that asked (re-checked after every await), the quota for
  /// the account that spent it.
  Future<void> send(
    String typedText, {
    Uint8List? imageBytes,
    String? imageMimeType,
    CoachTrainingContext? trainingContext,
  }) async {
    final l10n = _l10n;
    final svc = _service;
    final sessionId = _activeSessionId;
    final conversationRevision = _conversationRevision;
    final knownMessageIds = _messages.map((message) => message.id).toSet();
    final text = typedText.trim();
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;
    if (_disposed ||
        svc == null ||
        sessionId == null ||
        sending ||
        (text.isEmpty && !hasImage)) {
      return;
    }
    // The service deliberately holds no BuildContext; `l10n` is handed in
    // fresh here, only for the fallback error texts.
    svc.l10n = l10n;
    // Only a known-empty quota blocks. If unknown, the attempt goes to the
    // server, which answers 429 if needed (-> CoachQuotaExceeded below).
    if (quotaExhausted) {
      _error = l10n.coachErrorDailyLimitReached(limitForDisplay);
      _notify();
      return;
    }

    if (hasImage && planWishFrom(text) != null) {
      _error = l10n.coachPlanPhotoUnsupported;
      _notify();
      return;
    }
    // A log is read from text alone; the photo would turn it into a paid chat
    // question with a /log caption.
    if (hasImage && workoutLogWishFrom(text) != null) {
      _error = l10n.coachWorkoutLogPhotoUnsupported;
      _notify();
      return;
    }

    // Slash commands, text-only: an attached photo is a normal
    // coach question, not a command. An unknown /-command never reaches the
    // model — that would burn a daily slot on a typo.
    if (!hasImage && text.startsWith('/')) {
      final planWish = planWishFrom(text);
      if (planWish != null) {
        if (planWish.isEmpty) {
          _error = l10n.coachPlanEmptyHint;
          _notify();
          return;
        }
        await _sendPlanRequest(
          svc: svc,
          sessionId: sessionId,
          wish: planWish,
          displayText: text,
          l10n: l10n,
          trainingContext: trainingContext,
        );
        return;
      }
      final logWish = workoutLogWishFrom(text);
      if (logWish != null) {
        if (logWish.isEmpty) {
          _error = l10n.coachWorkoutLogEmptyHint;
          _notify();
          return;
        }
        await _sendWorkoutLogRequest(
          svc: svc,
          sessionId: sessionId,
          wish: logWish,
          displayText: text,
          l10n: l10n,
        );
        return;
      }
      final recipeWish = recipeWishFrom(text);
      if (recipeWish == null) {
        _error = l10n.coachPlanUnknownCommandHint;
        _notify();
        return;
      }
      if (recipeWish.isEmpty) {
        // Nothing to generate without a wish: local hint, no request, no slot.
        _error = l10n.coachRecipeEmptyHint;
        _notify();
        return;
      }
      await _sendRecipeRequest(
        svc: svc,
        sessionId: sessionId,
        wish: recipeWish,
        displayText: text,
        l10n: l10n,
      );
      return;
    }

    final displayText = text.isEmpty ? l10n.coachImageDefaultCaption : text;
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
      imageBytes: imageBytes,
    );
    // Retry job built before the request: same bubble, text and image. The
    // retry removes the message from the history and resends exactly this,
    // instead of creating a second bubble with the same content.
    final auftrag = CoachFailedSend(
      messageId: userMsg.id,
      text: displayText,
      imageBytes: imageBytes,
      imageMimeType: imageMimeType,
    );
    _frageZeigen(userMsg, sessionId: sessionId);

    try {
      final res = await svc.send(
        displayText,
        sessionId: sessionId,
        imageBase64: hasImage ? base64Encode(imageBytes) : null,
        imageMimeType: hasImage ? (imageMimeType ?? 'image/jpeg') : null,
        userContext: _requestInputs().userContext,
        // Live preview only. Bound to the session the question came from —
        // switching stays possible while sending, and the answer to another
        // conversation must not type itself into this one.
        onPartialReply: (text) {
          if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
          // When the dots turn into text the bubble takes the row's place; a
          // reader at the end keeps it in view. A reader scrolled up is never
          // moved.
          final erstesZeichen = _preview.value.isEmpty;
          _preview.value = text;
          if (text.isNotEmpty) _vorschauGezeigt = true;
          if (erstesZeichen) _hooks.previewStarted();
        },
      );
      // The daily slot is spent even if the answer is discarded — hence
      // before the session comparison.
      if (_disposed || !identical(_service, svc)) return;
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      if (res.remaining == null) _quotaNachfragen(svc);
      final answer = ChatMessage(
        id: 'local-r-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.assistant,
        content: res.reply,
        createdAt: DateTime.now(),
        refusal: res.refusal,
      );
      // Answer and error belong to the session the question came from;
      // switching stays possible while sending.
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        if (res.sessionId == sessionId) {
          await _reconcileReenteredSession(
            svc,
            sessionId,
            fallback: answer,
            knownMessageIds: knownMessageIds,
          );
        }
        return;
      }
      if (res.sessionId != sessionId) {
        await _serverSessionUebernehmen(
          svc: svc,
          angefragt: sessionId,
          benutzt: res.sessionId,
          l10n: l10n,
          revision: conversationRevision,
        );
        return;
      }
      _antwortZeigen(answer);
    } on CoachQuotaExceeded catch (e) {
      if (_disposed || !identical(_service, svc)) return;
      // The server named the limit explicitly, so this replaces any prior
      // state regardless of the open session: the limit is per user.
      _quotaRevision++;
      _quota = ChatQuotaSnapshot(
        used: e.dailyLimit,
        remaining: 0,
        dailyLimit: e.dailyLimit,
      );
      _notify();
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        _fehlschlagNachRueckkehr(
          svc: svc,
          sessionId: sessionId,
          message: e.message,
          auftrag: auftrag,
          frage: userMsg,
          stored: displayText,
        );
        return;
      }
      // Marked here too: the slot was gone, the question did not go out. The
      // retry button hangs on [canInteract] and stays off, but the marker
      // remains — otherwise the bubble would look sent.
      _fehlschlagZeigen(e.message, auftrag);
    } on CoachChatException catch (e) {
      _quotaNachfragen(svc);
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        _fehlschlagNachRueckkehr(
          svc: svc,
          sessionId: sessionId,
          message: e.message,
          auftrag: auftrag,
          frage: userMsg,
          stored: displayText,
        );
        return;
      }
      _fehlschlagZeigen(e.message, auftrag);
    } finally {
      // On EVERY exit, including the `return`s that discard the answer after
      // a session switch — otherwise the composer locks until cold start.
      _sendevorgangBeendet();
    }
    if (!_disposed) _hooks.sendFinished();
  }

  /// Takes the unsent question back for its retry: its bubble, marker and
  /// banner go. The caller sends the returned job again unchanged, so the
  /// attempt replaces the same bubble instead of creating a duplicate; the
  /// image rides along (history stores no image data).
  CoachFailedSend? withdrawFailedSend() {
    final auftrag = _failedSend;
    if (auftrag == null || _disposed) return null;
    _messages = _messages
        .where((m) => m.id != auftrag.messageId)
        .toList(growable: false);
    _failedSend = null;
    _error = null;
    _notify();
    return auftrag;
  }

  /// The optimistic bubble of a request about to go out.
  void _frageZeigen(ChatMessage frage, {required String sessionId}) {
    _messages = [..._ohneAltenFehlschlag(frage.content), frage];
    if (_wiederholtFehlschlag(frage.content)) _failedSend = null;
    _sendendeSessionId = sessionId;
    _laufendeSendungen++;
    _vorschauGezeigt = false;
    _error = null;
    _hooks.questionSent();
    _notify();
  }

  /// An answer for the conversation on screen.
  void _antwortZeigen(ChatMessage answer) {
    _messages = [..._messages, answer];
    _notify();
    _hooks.answerArrived();
    // Refresh sessions in the background so auto title / last_message_at are
    // current in the sheet without blocking the send flow.
    unawaited(_refreshSessions());
  }

  /// A request of the conversation on screen failed: banner and marker.
  void _fehlschlagZeigen(String message, CoachFailedSend auftrag) {
    _error = message;
    _failedSend = auftrag;
    _notify();
  }

  /// Whether a new attempt with [text] is the failed question typed again.
  /// Only then does the old bubble (and its marker) give way; a DIFFERENT
  /// text leaves the old bubble standing WITH its marker — it was never
  /// delivered and must not look so.
  bool _wiederholtFehlschlag(String text) {
    final alt = _failedSend;
    return alt != null && alt.text.trim() == text.trim();
  }

  /// A request failed after its session was left and opened again. The visit
  /// that sent it is gone, but the conversation is on screen: dropping the
  /// outcome made the thinking row vanish without a word, and a question the
  /// server never stored was lost with the cleared composer. [stored] is the
  /// text the server keeps for it (the wish, without the command).
  void _fehlschlagNachRueckkehr({
    required CoachChatService svc,
    required String sessionId,
    required String message,
    required CoachFailedSend auftrag,
    required ChatMessage frage,
    required String stored,
  }) {
    if (_disposed ||
        !identical(_service, svc) ||
        _activeSessionId != sessionId) {
      return;
    }
    final letzte = _messages.isEmpty ? null : _messages.last;
    final gespeichert = letzte != null &&
        letzte.role == ChatRole.user &&
        letzte.content.trim() == stored.trim();
    _error = message;
    if (gespeichert) {
      // The reload shows the stored question: the marker belongs to it.
      _failedSend = CoachFailedSend(
        messageId: letzte.id,
        text: auftrag.text,
        imageBytes: auftrag.imageBytes,
        imageMimeType: auftrag.imageMimeType,
        trainingContext: auftrag.trainingContext,
      );
    } else {
      _failedSend = auftrag;
      // A reload still in flight replaces the list anyway.
      if (!_loading && !_messages.any((m) => m.id == frage.id)) {
        _messages = [..._messages, frage];
      }
    }
    _notify();
  }

  /// History without the previous failure's bubble when the new attempt
  /// carries the same text. The marker (retry job) is the only place a failed
  /// question lives on; the field is NOT refilled, so typing it again and
  /// pressing send must replace the bubble, not duplicate it.
  List<ChatMessage> _ohneAltenFehlschlag(String text) {
    if (!_wiederholtFehlschlag(text)) return _messages;
    final alt = _failedSend!;
    return _messages
        .where((m) => m.id != alt.messageId)
        .toList(growable: false);
  }

  /// The server persisted the exchange in a DIFFERENT session than the one
  /// asked for (P5-01).
  ///
  /// It falls back to the default session once it has proven the requested one
  /// is not the user's — typically because a second device deleted it — and
  /// reports that in `session_id`. Appending the answer to the local
  /// conversation would show it in a thread the server no longer has, and a
  /// reload would move the exchange elsewhere without a word. So: say it, then
  /// follow the server and load the session it actually used.
  Future<void> _serverSessionUebernehmen({
    required CoachChatService svc,
    required String angefragt,
    required String benutzt,
    required AppLocalizations l10n,
    required int revision,
  }) async {
    if (!_matchesConversation(svc, angefragt, revision)) return;
    _error = l10n.coachSessionSwitchedNotice;
    // The question WAS delivered — it just landed elsewhere. An unsent
    // marker would invite a retry and burn a second daily slot.
    _failedSend = null;
    _notify();
    // The deleted session is gone from the sheet and the used one may be new.
    await _refreshSessions();
    if (!_matchesConversation(svc, angefragt, revision)) return;
    // [switchToSession] does the full load; the history it fetches already
    // contains both the question and the answer.
    await switchToSession(benutzt, keepNotice: true);
  }

  /// Asks the server for the counter after a request that named none: one
  /// recovered from the transcript, or one that failed after it may have
  /// spent its slot (deadline, lost connection, input the provider billed).
  /// Keeping the old number would promise a question the server refuses.
  void _quotaNachfragen(CoachChatService svc) {
    if (!_disposed && identical(_service, svc)) {
      unawaited(_refreshQuota(svc));
    }
  }

  /// Takes over a quota state the server just named.
  ///
  /// Called before the session comparison on purpose: the quota is per user,
  /// so a discarded answer still spent the slot. Older function deployments
  /// send no limit and fall back to the current display value.
  void _quotaUebernehmen({required int? remaining, required int? dailyLimit}) {
    if (remaining == null || _disposed) return;
    _quotaRevision++;
    final limit = dailyLimit ?? limitForDisplay;
    final frei = remaining.clamp(0, limit);
    _quota = ChatQuotaSnapshot(
      used: limit - frei,
      remaining: frei,
      dailyLimit: limit,
      // Only a limit the server itself named makes the lock trustworthy
      // (P5-06); an older deployment that sends none leaves it assumed.
      limitAssumed: dailyLimit == null && (_quota?.limitAssumed ?? true),
    );
    _notify();
  }

  /// Counterpart to `_laufendeSendungen++`; belongs in a `finally` so every
  /// exit counts. After dispose only the bookkeeping runs.
  void _sendevorgangBeendet() {
    final rest = math.max(0, _laufendeSendungen - 1);
    // Nothing in flight: no session is "the sending one" any more.
    final sendende = rest == 0 ? null : _sendendeSessionId;
    // The preview belongs to the request, not to the screen: the finished
    // bubble (or the error banner) has taken over by now, and a leftover would
    // reappear under the NEXT question before its first token. Not after
    // dispose: a write to the disposed notifier would throw.
    if (!_disposed && rest == 0) _preview.value = '';
    _laufendeSendungen = rest;
    _sendendeSessionId = sendende;
    _notify();
  }

  bool _sameCompletedAnswer(ChatMessage row, ChatMessage answer) {
    if (row.role != ChatRole.assistant ||
        row.content != answer.content ||
        row.refusal != answer.refusal) {
      return false;
    }
    final recipe = answer.recipeProposal;
    if (recipe != null) {
      final other = row.recipeProposal;
      return other != null &&
          other.title == recipe.title &&
          other.description == recipe.description &&
          other.portion == recipe.portion &&
          other.caloriesKcal == recipe.caloriesKcal &&
          other.proteinG == recipe.proteinG &&
          other.carbsG == recipe.carbsG &&
          other.fatG == recipe.fatG &&
          other.estimatedGrams == recipe.estimatedGrams &&
          other.ingredients == recipe.ingredients &&
          other.preparation == recipe.preparation;
    }
    final plan = answer.trainingPlanProposal;
    if (plan != null) {
      final other = row.trainingPlanProposal;
      return other != null &&
          jsonEncode(other.toJson()) == jsonEncode(plan.toJson());
    }
    final log = answer.workoutLogProposal;
    if (log != null) {
      final other = row.workoutLogProposal;
      return other != null &&
          jsonEncode(other.toJson()) == jsonEncode(log.toJson());
    }
    return row.recipeProposal == null &&
        row.trainingPlanProposal == null &&
        row.workoutLogProposal == null;
  }

  /// A completed send may reach the server after a user has left and returned
  /// to its session. Reload that visit instead of appending an old local answer
  /// to history that may already contain the persisted row.
  Future<void> _reconcileReenteredSession(
    CoachChatService svc,
    String sessionId, {
    ChatMessage? fallback,
    required Set<String> knownMessageIds,
  }) async {
    if (_disposed ||
        !identical(_service, svc) ||
        _activeSessionId != sessionId) {
      return;
    }
    // Supersede any earlier history load for this same visit.
    final revision = ++_conversationRevision;
    _loading = true;
    _notify();
    List<ChatMessage>? history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      // A paid plan or recipe can have an answer even when its history write
      // failed. Keep that response visible without claiming history is sound.
    }
    if (!_matchesConversation(svc, sessionId, revision)) return;
    if (history != null) history = await _hydrateProposalImages(history);
    if (!_matchesConversation(svc, sessionId, revision)) return;
    final loaded = history;
    final messages = loaded ?? _messages;
    _messages = [
      ...messages,
      if (fallback != null &&
          !messages.any((message) =>
              message.id == fallback.id ||
              (fallback.id.startsWith('local-') &&
                  !knownMessageIds.contains(message.id) &&
                  _sameCompletedAnswer(message, fallback))))
        fallback,
    ];
    _historyUnavailable = loaded == null;
    _loading = false;
    _error = loaded == null ? _l10n.coachErrorHistoryUnavailable : null;
    _notify();
    _hooks.conversationShown();
  }

  /// Mirror of [send] for the recipe path: optimistic user bubble with the
  /// original input, then requestRecipe. The answer becomes an assistant
  /// message with [ChatMessage.recipeProposal]; the history keeps only reply.
  Future<void> _sendRecipeRequest({
    required CoachChatService svc,
    required String sessionId,
    required String wish,
    required String displayText,
    required AppLocalizations l10n,
  }) async {
    final imageStore = RecipeImageStore.instance;
    final imageScope = imageStore.scopeToken;
    final conversationRevision = _conversationRevision;
    final knownMessageIds = _messages.map((message) => message.id).toSet();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    // As in [send]: [displayText] carries the command, so a retry lands in
    // this branch again by itself.
    final auftrag = CoachFailedSend(
      messageId: userMsg.id,
      text: displayText,
    );
    _frageZeigen(userMsg, sessionId: sessionId);

    try {
      // No `userContext` (P5-02): the function's recipe mode never reads it,
      // so sending profile and daily balance would be data without a purpose.
      final res = await svc.requestRecipe(
        wish,
        sessionId: sessionId,
        locale: l10n.localeName,
      );
      // As in [send]: the slot is spent even if the card is discarded.
      if (_disposed || !identical(_service, svc)) return;
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      if (res.remaining == null) _quotaNachfragen(svc);
      // Store the image under the SERVER message id, so history reconstruction
      // and the live card use the same key.
      final serverId = res.assistantMessageId;
      final imageBytes = res.proposal?.imageBytes;
      // Fire and forget, except on the drift path below, which has to wait for
      // the file. `catchError` keeps that await from throwing into a branch
      // that only knows coach errors.
      final bildGespeichert =
          serverId != null &&
              imageBytes != null &&
              imageStore.scopeToken == imageScope
          ? imageStore
                .saveProposalImage(messageId: serverId, bytes: imageBytes)
                .catchError((Object _) => false)
          : null;
      if (bildGespeichert != null) unawaited(bildGespeichert);
      final answer = ChatMessage(
        id: serverId ?? 'local-r-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.assistant,
        content: res.reply,
        createdAt: DateTime.now(),
        refusal: res.refusal,
        recipeProposal: res.proposal,
      );
      // Images exist only in this response: keep them in the original user's
      // local store even when another conversation is now visible.
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        if (res.sessionId == sessionId) {
          if (bildGespeichert != null) await bildGespeichert;
          await _reconcileReenteredSession(
            svc,
            sessionId,
            fallback: answer,
            knownMessageIds: knownMessageIds,
          );
        }
        return;
      }
      if (res.sessionId != sessionId) {
        // Mirror of [send]. The reload rebuilds the card from
        // `chat_messages.recipe` and rehydrates its image from disk, so the
        // write has to be finished first.
        if (bildGespeichert != null) await bildGespeichert;
        if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
        await _serverSessionUebernehmen(
          svc: svc,
          angefragt: sessionId,
          benutzt: res.sessionId,
          l10n: l10n,
          revision: conversationRevision,
        );
        return;
      }
      _antwortZeigen(answer);
    } on CoachQuotaExceeded catch (e) {
      if (_disposed || !identical(_service, svc)) return;
      // As in [send]: the limit is per user, not per session.
      _quotaRevision++;
      _quota = ChatQuotaSnapshot(
        used: e.dailyLimit,
        remaining: 0,
        dailyLimit: e.dailyLimit,
      );
      _notify();
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        _fehlschlagNachRueckkehr(
          svc: svc,
          sessionId: sessionId,
          message: e.message,
          auftrag: auftrag,
          frage: userMsg,
          stored: wish,
        );
        return;
      }
      _fehlschlagZeigen(e.message, auftrag);
    } on CoachChatException catch (e) {
      _quotaNachfragen(svc);
      if (!_matchesConversation(svc, sessionId, conversationRevision)) {
        _fehlschlagNachRueckkehr(
          svc: svc,
          sessionId: sessionId,
          message: e.message,
          auftrag: auftrag,
          frage: userMsg,
          stored: wish,
        );
        return;
      }
      _fehlschlagZeigen(e.message, auftrag);
    } finally {
      _sendevorgangBeendet();
    }
    if (!_disposed) _hooks.sendFinished();
  }

  Future<void> _sendPlanRequest({
    required CoachChatService svc,
    required String sessionId,
    required String wish,
    required String displayText,
    required AppLocalizations l10n,
    CoachTrainingContext? trainingContext,
  }) => _sendProposalRequest(
    svc: svc,
    sessionId: sessionId,
    displayText: displayText,
    stored: wish,
    l10n: l10n,
    trainingContext: trainingContext,
    request: () async {
      final reply = trainingContext == null
          ? await svc.requestPlan(wish, sessionId: sessionId, locale: l10n.localeName)
          : await svc.requestPlanWithContext(wish, sessionId: sessionId,
              locale: l10n.localeName, trainingContext: trainingContext);
      return (
        answer: ChatMessage(
          id:
              reply.assistantMessageId ??
              'local-p-${DateTime.now().microsecondsSinceEpoch}',
          role: ChatRole.assistant,
          content: reply.reply,
          createdAt: DateTime.now(),
          refusal: reply.refusal,
          trainingPlanProposal: reply.refusal ? null : reply.proposal,
        ),
        sessionId: reply.sessionId,
        remaining: reply.remaining,
        dailyLimit: reply.dailyLimit,
      );
    },
  );

  /// /log: the same fenced send as /plan. The answer becomes a draft card;
  /// nothing is written until its review sheet's Add.
  Future<void> _sendWorkoutLogRequest({
    required CoachChatService svc,
    required String sessionId,
    required String wish,
    required String displayText,
    required AppLocalizations l10n,
  }) => _sendProposalRequest(
    svc: svc,
    sessionId: sessionId,
    displayText: displayText,
    stored: wish,
    l10n: l10n,
    request: () async {
      final reply = await svc.requestWorkoutLog(
        wish,
        sessionId: sessionId,
        locale: l10n.localeName,
      );
      final proposal = reply.refusal ? null : reply.proposal;
      final id =
          reply.assistantMessageId ??
          'local-w-${DateTime.now().microsecondsSinceEpoch}';
      return (
        answer: ChatMessage(
          id: id,
          role: ChatRole.assistant,
          content: reply.reply,
          createdAt: DateTime.now(),
          refusal: reply.refusal,
          workoutLogProposal: proposal,
          // No stored row to derive the history id from: allocate it once,
          // so a retry or a second review targets the same row.
          workoutLogLocalId:
              proposal != null && deriveCoachWorkoutLogId(id) == null
              ? uuidV4()
              : null,
        ),
        sessionId: reply.sessionId,
        remaining: reply.remaining,
        dailyLimit: reply.dailyLimit,
      );
    },
  );

  /// One account- and conversation-fenced proposal request (/plan, /log):
  /// the optimistic bubble, quota from every answer of this account, and the
  /// answer only in the conversation that asked for it.
  Future<void> _sendProposalRequest({
    required CoachChatService svc,
    required String sessionId,
    required String displayText,
    required String stored,
    required AppLocalizations l10n,
    required Future<_ProposalAnswer> Function() request,
    CoachTrainingContext? trainingContext,
  }) async {
    final accountRevision = _accountRevision;
    final conversationRevision = _conversationRevision;
    final knownMessageIds = _messages.map((message) => message.id).toSet();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    final retry = CoachFailedSend(
      messageId: userMsg.id,
      text: displayText,
      trainingContext: trainingContext,
    );
    _frageZeigen(userMsg, sessionId: sessionId);
    final submittedMessages = _messages;
    bool isCurrentAccount() =>
        !_disposed &&
        identical(_service, svc) &&
        _accountRevision == accountRevision;
    bool isCurrentConversation() =>
        isCurrentAccount() &&
        _activeSessionId == sessionId &&
        identical(_messages, submittedMessages);
    try {
      final reply = await request();
      if (!isCurrentAccount()) return;
      // Quota is account-wide, including responses to another conversation.
      _quotaUebernehmen(
        remaining: reply.remaining,
        dailyLimit: reply.dailyLimit,
      );
      if (reply.remaining == null) _quotaNachfragen(svc);
      final answer = reply.answer;
      if (!isCurrentConversation()) {
        if (_activeSessionId == sessionId &&
            _conversationRevision != conversationRevision &&
            reply.sessionId == sessionId) {
          await _reconcileReenteredSession(
            svc,
            sessionId,
            fallback: answer,
            knownMessageIds: knownMessageIds,
          );
        }
        return;
      }
      if (reply.sessionId != sessionId) {
        await _receiveRemappedAnswer(
          svc: svc,
          sessionId: reply.sessionId,
          answer: answer,
          isCurrentAccount: isCurrentAccount,
          isCurrentSource: isCurrentConversation,
          l10n: l10n,
        );
        return;
      }
      _antwortZeigen(answer);
    } on CoachQuotaExceeded catch (error) {
      if (!isCurrentAccount()) return;
      _quotaUebernehmen(remaining: 0, dailyLimit: error.dailyLimit);
      if (!isCurrentConversation()) {
        _fehlschlagNachRueckkehr(
          svc: svc,
          sessionId: sessionId,
          message: error.message,
          auftrag: retry,
          frage: userMsg,
          stored: stored,
        );
        return;
      }
      _fehlschlagZeigen(error.message, retry);
    } on CoachRequestUnsupported catch (error) {
      if (!isCurrentConversation()) return;
      // Certain and free (an older server): no Retry to loop on. The text
      // goes back to the composer instead of a bubble that looks sent.
      _error = error.message;
      _messages = _messages
          .where((message) => message.id != userMsg.id)
          .toList(growable: false);
      _notify();
      _hooks.draftReturned(displayText);
    } on CoachChatException catch (error) {
      if (isCurrentAccount()) _quotaNachfragen(svc);
      if (!isCurrentConversation()) {
        if (isCurrentAccount()) {
          _fehlschlagNachRueckkehr(
            svc: svc,
            sessionId: sessionId,
            message: error.message,
            auftrag: retry,
            frage: userMsg,
            stored: stored,
          );
        }
        return;
      }
      _fehlschlagZeigen(error.message, retry);
    } finally {
      _sendevorgangBeendet();
    }
    if (!_disposed) _hooks.sendFinished();
  }

  /// A paid plan or log can be valid even when its assistant history write
  /// failed. Keep that buffered answer after remapping, without duplicating
  /// persisted IDs.
  Future<void> _receiveRemappedAnswer({
    required CoachChatService svc,
    required String sessionId,
    required ChatMessage answer,
    required bool Function() isCurrentAccount,
    required bool Function() isCurrentSource,
    required AppLocalizations l10n,
  }) async {
    final listRevision = ++_sessionListRevision;
    List<ChatSession>? sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Keep the last known list; the response still names its actual session.
    }
    if (!isCurrentSource()) return;
    // A fresh list also identifies this load across navigation away and back.
    final loadingMessages = <ChatMessage>[];
    if (sessions != null && listRevision == _sessionListRevision) {
      _sessions = sessions;
    }
    _conversationRevision++;
    _activeSessionId = sessionId;
    _messages = loadingMessages;
    _loading = true;
    _failedSend = null;
    _error = l10n.coachSessionSwitchedNotice;
    _hooks.conversationReplaced();
    _notify();
    bool isCurrentTarget() =>
        isCurrentAccount() &&
        _activeSessionId == sessionId &&
        identical(_messages, loadingMessages);
    var history = <ChatMessage>[];
    var historyUnavailable = false;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      historyUnavailable = true;
    }
    if (!isCurrentTarget()) return;
    history = await _hydrateProposalImages(history);
    if (!isCurrentTarget()) return;
    _messages = [
      ...history,
      if (!history.any((message) => message.id == answer.id)) answer,
    ];
    _historyUnavailable = historyUnavailable;
    _loading = false;
    if (historyUnavailable) _error = l10n.coachErrorHistoryUnavailable;
    _notify();
    _hooks.answerArrived();
    _hooks.conversationShown();
  }

  // --- Recipe adoption ---------------------------------------------------------

  /// Adopting a /recipe proposal — the ONLY way anything from a coach answer
  /// is ever stored, and only after the user confirmed it in [confirm]
  /// (the screen's sheet); [create] is the store hook. Null when nothing was
  /// stored (declined, another add running, controller gone); a failed write
  /// throws. Whether the card counts as added stays derived from the live
  /// recipe slugs, so deleting or undoing it in the recipes tab re-enables it.
  Future<CoachRecipeAdoption?> adoptRecipe(
    ChatMessage message, {
    required Future<bool?> Function() confirm,
    required Future<SyncDelivery> Function(FitnessRecipe recipe) create,
  }) async {
    final proposal = message.recipeProposal;
    if (proposal == null || _addingRecipe || _disposed) return null;
    // Taken before the sheet: the navigator absorbs a second tap once the
    // route is pushed, but not a second accessibility action in that frame.
    _addingRecipe = true;
    _notify();
    try {
      final confirmed = await confirm();
      if (confirmed != true || _disposed) return null;
      var imageAsset = '';
      var photoFailed = false;
      final bytes = proposal.imageBytes;
      if (bytes != null) {
        final referenz = await RecipeImageStore.instance.save(bytes: bytes);
        if (_disposed) return null;
        // A failed photo save does not discard the confirmed recipe; the
        // outcome message says so.
        if (referenz == null) {
          photoFailed = true;
        } else {
          imageAsset = referenz;
        }
      }
      final recipe = proposal.toFitnessRecipe(
        imageAsset: imageAsset,
        slug: FitnessRecipe.coachProposalSlug(message.id),
      );
      final delivery = await create(recipe);
      if (_disposed) return null;
      return (recipe: recipe, delivery: delivery, photoFailed: photoFailed);
    } finally {
      _addingRecipe = false;
      _notify();
    }
  }
}

/// [CoachChatService.answerWaiter] of the controller (COACH-4): after a lost
/// connection the service re-checks the transcript while the question is
/// stored without an answer, and the request keeps its thinking state. No
/// timer runs while the app is in the background (the resume checks at once),
/// and the wait ends when the controller leaves the request's session or
/// account or goes away; the error then stands, fenced as for any late
/// failure.
class _AntwortWarten implements CoachAnswerWaiter {
  _AntwortWarten(this._coach, this._imHintergrund);

  final CoachChatController _coach;
  final bool Function() _imHintergrund;
  Timer? _wecker;
  Completer<bool>? _pause;
  String? _sitzung;

  void binden(CoachChatService? svc) {
    if (svc != null) svc.answerWaiter = this;
  }

  void loesen(CoachChatService? svc) {
    if (svc != null && identical(svc.answerWaiter, this)) {
      svc.answerWaiter = null;
    }
    _wecken(false);
  }

  bool _gilt(String sessionId) =>
      !_coach._disposed && _coach._activeSessionId == sessionId;

  @override
  Future<bool> pause(String sessionId, Duration interval) async {
    if (!_gilt(sessionId)) return false;
    _wecken(false);
    final pause = _pause = Completer<bool>();
    _sitzung = sessionId;
    if (!_imHintergrund()) _wecker = Timer(interval, () => _wecken(true));
    final weiter = await pause.future;
    return weiter && _gilt(sessionId);
  }

  /// Background: no timer; the pending pause waits for [vordergrund].
  void hintergrund() {
    _wecker?.cancel();
    _wecker = null;
  }

  /// Back in front: check at once, the answer may have landed meanwhile.
  void vordergrund() => _wecken(true);

  void sitzungPruefen(String? aktiv) {
    if (_pause != null && aktiv != _sitzung) _wecken(false);
  }

  void _wecken(bool weiter) {
    _wecker?.cancel();
    _wecker = null;
    final pause = _pause;
    _pause = null;
    _sitzung = null;
    if (pause != null && !pause.isCompleted) pause.complete(weiter);
  }
}
