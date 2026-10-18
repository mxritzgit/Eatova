/// Coach tab state without widgets: sessions, history and the banner.
///
/// Lives exactly as long as the screen's State, which creates and disposes
/// it, so it sits next to the screen rather than with the app-wide stores in
/// `lib/src/app/`. It talks to the backend only through [CoachChatService]
/// and never touches a BuildContext: scrolling, the answer cue and every
/// other UI reaction go through [CoachChatViewHooks].
library;

// The setters of the bridge section below are plain until sending moves in.
// ignore_for_file: unnecessary_getters_setters

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../models/coach_training_context.dart';
import '../../services/coach_chat_service.dart';
import '../../services/recipe_image_store.dart';

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

/// State and operations of the Coach tab.
class CoachChatController extends ChangeNotifier {
  CoachChatController({
    CoachChatService? service,
    CoachChatViewHooks hooks = const CoachChatViewHooks(),
  }) : _service = service,
       _hooks = hooks;

  final CoachChatViewHooks _hooks;
  bool _disposed = false;

  // --- Inputs from the screen ------------------------------------------------

  CoachChatService? _service;

  /// The signed-in account's backend; null means not logged in.
  CoachChatService? get service => _service;

  /// Account switch from the shell. Results of the old service are fenced
  /// out by identity.
  void updateService(CoachChatService? service) {
    _service = service;
  }

  AppLocalizations _l10n = deL10n;

  /// Locale pack for the texts the controller writes into the banner, set by
  /// the screen from `context.l10n` (the same setter pattern as
  /// [CoachChatService.l10n]). German until the screen sets it.
  AppLocalizations get l10n => _l10n;
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
  ValueNotifier<String> get preview => _preview;

  // --- Bridge for the send paths that still live in the screen --------------

  set messages(List<ChatMessage> value) => _messages = value;
  set sessions(List<ChatSession> value) => _sessions = value;
  set failedSend(CoachFailedSend? value) => _failedSend = value;
  set quota(ChatQuotaSnapshot? value) => _quota = value;
  int get quotaRevision => _quotaRevision;
  set quotaRevision(int value) => _quotaRevision = value;
  set activeSessionId(String? value) => _activeSessionId = value;
  set conversationRevision(int value) => _conversationRevision = value;
  int get sessionListRevision => _sessionListRevision;
  set sessionListRevision(int value) => _sessionListRevision = value;
  set loading(bool value) => _loading = value;
  set error(String? value) => _error = value;
  set historyUnavailable(bool value) => _historyUnavailable = value;

  // --- Lifecycle ---------------------------------------------------------------

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _preview.dispose();
    super.dispose();
  }

  /// No service = not logged in: nothing loads, the banner says why.
  void reportSignedOut() {
    _loading = false;
    _error = _l10n.coachErrorNotLoggedIn;
    _notify();
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
    history = await hydrateProposalImages(history);
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
  Future<void> refreshQuota(CoachChatService svc) async {
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
  Future<void> refreshSessions() async {
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
    history = await hydrateProposalImages(history);
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
    await refreshSessions();
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
    await refreshSessions();
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
        await refreshSessions();
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
  Future<List<ChatMessage>> hydrateProposalImages(
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
}
