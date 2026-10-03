/// Coach tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility
/// and [CoachChatScreen] stays the entry point. The iOS MethodChannel
/// `eatova/speech` lives in coach_speech.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/semantics.dart'
    show AccessibilityFocusBlockType, SemanticsService;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../models/coach_day_brief.dart';
import '../../models/coach_recipe_proposal.dart';
import '../../models/coach_training_proposal.dart';
import '../../models/coach_training_context.dart';
import '../../models/coach_workout_log.dart';
import '../../models/fitness_recipe.dart';
import '../../models/training_history.dart';
import '../../models/training_plan.dart';
import '../../services/coach_chat_service.dart';
import '../../services/dictation_language.dart';
import '../../services/kcal_format.dart';
import '../../services/local_day.dart';
import '../../services/meal_photo_compressor.dart';
import '../../services/meal_photo_temp_file.dart';
import '../../services/recipe_image_store.dart';
import '../../services/screen_awake.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../today/today_texts.dart' show greetingForHour;
import '../training/training_log_editor.dart';
import '../training/training_plan_editor.dart';
import 'coach_training_brief.dart';

part 'coach_speech.dart';
part 'coach_top_bar.dart';
part 'coach_hero.dart';
part 'coach_orb.dart';
part 'coach_message_list.dart';
part 'coach_composer.dart';
part 'coach_recipe.dart';
part 'coach_plan.dart';
part 'coach_workout_log.dart';
part 'coach_sessions.dart';

/// Coach chat: the AI fitness/nutrition coach.
///
/// Header with the context status, past chats and (i); the start state is the
/// animated [CoachOrb] with greeting, today's numbers with prepared questions,
/// the command chips and the AI disclaimer; otherwise message bubbles above
/// the floating composer capsule.
class CoachChatScreen extends StatefulWidget {
  const CoachChatScreen({
    super.key,
    required this.service,
    this.userName = 'Moritz',
    this.dayBrief,
    this.userContext,
    this.imagePicker,
    this.speechInput = const CoachSpeechInput(),
    this.screenAwake = const MethodChannelScreenAwake(),
    this.dictationLanguageStore = const PrefsDictationLanguageStore(),
    this.onCreateRecipe,
    this.userRecipeSlugs = const <String>{},
    this.onCreateTrainingPlan,
    this.hasTrainingAdoptionConflict,
    this.userTrainingPlanIds = const <String>{},
    this.userTrainingPlanSourceIds = const <String>{},
    this.onOpenTraining,
    this.planDraftRequest = 0,
    this.selectedPlanForCoach,
    this.onLogWorkout,
    this.trainingHistoryIds = const <String>{},
    this.trainingHistoryDeletedIds = const <String>{},
    this.trainingHistoryAuthoritative = false,
    this.trainingHistory = const <TrainingHistoryEntry>[],
    this.logDraftRequest = 0,
  });

  /// How long the answer live region stays once it can speak (where the
  /// platform has no announcements, see `_announceAnswer`): long enough for
  /// TalkBack, which reads the node asynchronously after the change event.
  @visibleForTesting
  static const Duration answerCueLifetime = Duration(seconds: 3);

  final CoachChatService? service;
  final String userName;

  /// Persistence hook for /recipe proposals (`HomeStore.createUserRecipe`).
  /// The coach itself has no write rights: this runs only after the user
  /// confirms in the sheet. null (preview/test): card shows, button disabled.
  final Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreateRecipe;

  /// Slugs of the currently existing user recipes (live view from the shell).
  /// Drives the "added" state of the cards, so deleting a recipe in the
  /// recipes tab re-enables the button on its own.
  final Set<String> userRecipeSlugs;

  /// Runs only after the user confirms a reviewed or edited plan.
  final Future<SyncDelivery> Function(TrainingPlan plan)? onCreateTrainingPlan;
  final bool Function(String planId)? hasTrainingAdoptionConflict;
  final Set<String> userTrainingPlanIds;
  final Set<String> userTrainingPlanSourceIds;
  final VoidCallback? onOpenTraining;

  /// Increment to open a training brief without sending a request.
  final int planDraftRequest;
  final TrainingPlan? selectedPlanForCoach;

  /// Writes a reviewed /log workout (`HomeStore.logCompletedWorkout` via the
  /// shell). Runs only from the review sheet's Add. null: the card shows no
  /// Add at all.
  final Future<TrainingLogSaveOutcome> Function(TrainingHistoryEntry entry)?
  onLogWorkout;

  /// Live history ids and deletion receipts: a /log card's state is derived
  /// from them, never stored ("Added", "Removed from history").
  final Set<String> trainingHistoryIds;
  final Set<String> trainingHistoryDeletedIds;

  /// Whether the history is known (loaded, not failed, receipts readable).
  /// Until then a /log card cannot be added: its id might already be there.
  final bool trainingHistoryAuthoritative;

  /// For the review sheet's exercise names and "Last time".
  final List<TrainingHistoryEntry> trainingHistory;

  /// Increment to prepare `/log ` in the composer without sending anything.
  final int logDraftRequest;

  /// Today's numbers for the start state's "From today's log" card, built
  /// by the shell from `HomeStore.nutritionSummaryForFoodDate`. null hides
  /// the card (previews, tests without a store).
  final CoachDayBrief? dayBrief;

  /// Compact snapshot of profile + daily balance handed to the coach as
  /// context so it can advise concretely instead of generically.
  ///
  /// Chat mode only. /recipe deliberately gets none (P5-02): the function's
  /// recipe branch never reads it, so it would be health data sent for nothing.
  final String? userContext;

  final ImagePicker? imagePicker;
  final CoachSpeechInput speechInput;

  /// On while dictating (spec A6/D6).
  final ScreenAwake screenAwake;

  /// Per-device DE/EN choice for dictation.
  final DictationLanguageStore dictationLanguageStore;

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  /// Whether the chat is pinned to its end: then new messages, streamed text
  /// and a shrinking viewport keep the newest line in view. Only the reader's
  /// own scrolling unpins it; sending pins it again.
  bool _chatAmEnde = true;

  /// A finger (or wheel) is moving the chat, from its first movement until the
  /// scroll ends, fling included. The pin never touches the list meanwhile:
  /// a programmatic jump or animation would cancel the reader's drag.
  bool _nutzerScrollt = false;

  /// Whether following the end glides (after a send) or jumps (opening a
  /// conversation, where the list still refines its estimated extent).
  bool _sanftFolgen = false;

  /// Content and viewport extent of the last metrics seen; a notification
  /// that only reports a new scroll offset is not a content change.
  double? _letzteMaxAusdehnung;
  double? _letztesFenster;
  double _letzteTastatur = 0;

  /// Distance from the end that still counts as "at the end".
  static const double _endeToleranz = 48;

  /// Messages that arrived while the chat was open and fade in once; history
  /// loads and a streamed answer replacing its preview do not.
  final Set<String> _einblenden = <String>{};
  List<String> _gerenderteIds = const <String>[];
  bool _warAmLaden = true;

  /// A streamed preview was on screen for the answer in flight: the finished
  /// answer takes its place without a second entrance.
  bool _vorschauGezeigt = false;

  List<ChatMessage> _messages = const <ChatMessage>[];
  List<ChatSession> _sessions = const <ChatSession>[];

  /// The last undelivered question — marker and retry job in one; null means
  /// everything in the history went out.
  ///
  /// The message stays in the history (it is user content). Only ONE job is
  /// held, the newest; an older one loses its marker but keeps its bubble.
  _FehlgeschlageneSendung? _fehlgeschlagen;

  /// `null` means "unknown" — neither full nor empty. A snapshot exists only
  /// once the server actually named numbers; a failed RPC must not refill an
  /// exhausted quota and lift the block (Review D2).
  ChatQuotaSnapshot? _quota;
  int _quotaRevision = 0;
  String? _activeSessionId;
  int _conversationRevision = 0;
  int _sessionListRevision = 0;
  bool _loading = true;
  bool _listening = false;

  /// Current recording; also its native token. Drawn from [_speechSeq].
  int _speechGeneration = 0;
  String? _error;

  /// Draft text as a [ValueNotifier], deliberately NOT screen state: its only
  /// consumers are the composer and the command menu, and a per-keystroke
  /// `setState` rebuilt the whole screen including every visible bubble (perf
  /// finding 3, 2026-08-31). The send paths read `_input.text` directly.
  final ValueNotifier<String> _draft = ValueNotifier<String>('');

  /// The coach answer as it streams in, empty while nothing has arrived.
  ///
  /// A notifier for the same reason as [_draft]: the deltas arrive dozens of
  /// times a second and only the one preview bubble may rebuild for them. It
  /// is a PREVIEW — `send` returns the authoritative text and the finished
  /// bubble replaces this one, so nothing here is ever the record.
  final ValueNotifier<String> _streamVorschau = ValueNotifier<String>('');

  /// The active session's history failed to load — the hero empty state must
  /// then not present it as "empty".
  bool _historyUnavailable = false;

  /// An add is running (confirm sheet, store image, createUserRecipe) — locks
  /// all card buttons until it finishes.
  bool _addingRecipe = false;
  bool _reviewingTrainingPlan = false;
  bool _reviewingWorkoutLog = false;
  bool _briefingTrainingPlan = false;
  ValueNotifier<bool>? _briefIsActive;
  int _trainingAccountRevision = 0;

  /// A brief asked for while a request ran or the chat loaded: never dropped
  /// (spec §9), [build] opens it once both are done.
  ({TrainingPlan? selectedPlan, bool sessionRetried})? _queuedBrief;
  bool _queuedBriefScheduled = false;

  /// The answer to speak through the live region in [build], where the
  /// platform has no announcements (see [_announceAnswer]); null = no cue.
  /// Its value keys the node, so each answer inserts a fresh one.
  int? _answerCue;

  /// Source of [_answerCue], never reset: a drop and a new answer in one
  /// frame must not reuse the dropped node.
  int _answerCueSerial = 0;

  /// Clears the cue once its lifetime ends. Runs only while the cue can speak
  /// ([_cueCanSpeak]); null otherwise.
  Timer? _answerCueTimer;

  /// No route (sheet, dialog, page) above this screen's route.
  bool _routeOnTop = true;

  /// Whether the cue is in the semantics tree: a hidden tab and any route
  /// above both drop the Coach semantics until they return.
  bool get _cueCanSpeak => _sichtbar && _routeOnTop;

  /// How many send jobs (chat or recipe) are in flight.
  ///
  /// Counts per USER, not per session, because the quota does too: a plain
  /// `bool` reset on session switch let two requests run in parallel and burn
  /// two daily slots from one interaction. Only [_sendevorgangBeendet]
  /// decrements, from a `finally` — a discarded answer must free the counter
  /// too, or the composer stays locked forever.
  int _laufendeSendungen = 0;

  bool get _sending => _laufendeSendungen > 0;

  /// Session the in-flight request belongs to. [_sending] is per user, so
  /// without this the thinking dots showed in whichever session was open.
  String? _sendendeSessionId;

  bool get _sendingInActiveSession =>
      _sending && _sendendeSessionId == _activeSessionId;

  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  /// Only a *known* empty quota blocks. An unknown state (cold start without
  /// network) deliberately does not: the server decides and answers 429.
  ///
  /// An ASSUMED limit counts as unknown too (P5-06): `get_chat_quota_today`
  /// derives `remaining` from the limit the client hands it, so with
  /// `COACH_DAILY_LIMIT=10` it reports 0 free after five slots and would lock
  /// a composer the server still accepts. The limit only becomes real once a
  /// function answer or a quota 429 names it.
  bool get _kontingentErschoepft {
    final quota = _quota;
    return quota != null && !quota.limitAssumed && quota.remaining <= 0;
  }

  /// Remaining count for display only. Widgets need a number, so an unknown
  /// state falls back to the default limit and claims neither "limit reached"
  /// nor a concrete count. Blocking decisions use [_kontingentErschoepft].
  int get _restFuerAnzeige =>
      _quota?.remaining ?? ChatQuotaSnapshot.standardTageslimit;

  int get _limitFuerAnzeige =>
      _quota?.dailyLimit ?? ChatQuotaSnapshot.standardTageslimit;

  /// Typing stays allowed while an answer is in flight — a disabled TextField
  /// would close the keyboard mid-flow. Only actions wait on [_canInteract].
  bool get _canType =>
      widget.service != null &&
      !_loading &&
      !_kontingentErschoepft &&
      _activeSessionId != null;
  bool get _canInteract => _canType && !_sending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ValueNotifier dedupes identical assignments, so no equality check here.
    _input.addListener(() => _draft.value = _input.text);
    _loadDictationLanguage();
    // No service = not logged in; that branch needs a localized error text and
    // `context.l10n` is not allowed in initState — didChangeDependencies does
    // it once before the first frame.
    if (widget.service != null) {
      _bootstrap();
    }
    if (widget.planDraftRequest > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openTrainingBrief(selectedPlan: widget.selectedPlanForCoach);
      });
    }
    if (widget.logDraftRequest > 0) _prepareLogDraft();
  }

  @override
  void didUpdateWidget(covariant CoachChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.service, oldWidget.service)) {
      _trainingAccountRevision++;
      _briefIsActive?.value = false;
      _queuedBrief = null;
      _dropAnswerCue();
      _cancelSpeechInput(discard: true);
    }
    if (widget.planDraftRequest != oldWidget.planDraftRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openTrainingBrief(selectedPlan: widget.selectedPlanForCoach);
      });
    }
    if (widget.logDraftRequest != oldWidget.logDraftRequest) {
      _prepareLogDraft();
    }
  }

  /// After the frame: the request arrives during a build.
  void _prepareLogDraft() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyCommand(_CoachCommand.log.token);
    });
  }

  /// Whether the tab is visible, tracked via `TickerMode`: this screen lives
  /// in an `IndexedStack` and stays mounted, so `_bootstrap()` runs once per
  /// app run and a stale quota, error banner or failed session would persist
  /// until cold start. A flip to `true` triggers [_beiRueckkehr].
  ///
  /// Depends on `TickerMode(enabled: i == tab, …)` in `eatova_home_page.dart`;
  /// remove it there and this branch silently dies. The edge only covers tab
  /// SWITCHES, so [didChangeAppLifecycleState] runs the same path on resume.
  bool _sichtbar = true;

  /// Sets the localized "not logged in" text exactly once — not in
  /// [initState] (no Localizations yet) and not on every
  /// [didChangeDependencies].
  bool _notEingeloggtGemeldet = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.service == null && !_notEingeloggtGemeldet) {
      _notEingeloggtGemeldet = true;
      _loading = false;
      _error = context.l10n.coachErrorNotLoggedIn;
    }
    final sichtbar = TickerMode.valuesOf(context).enabled;
    final wurdeSichtbar = sichtbar && !_sichtbar;
    if (!sichtbar && _sichtbar) {
      _cancelSpeechInput();
      // Leaving the tab withdraws a waiting brief; it must not pop up later.
      _queuedBrief = null;
      // And a cue still waiting behind a sheet: the user went elsewhere.
      _dropAnswerCue();
    }
    final cueCouldSpeak = _cueCanSpeak;
    _sichtbar = sichtbar;
    _routeOnTop = ModalRoute.isCurrentOf(context) ?? true;
    if (cueCouldSpeak && !_cueCanSpeak) {
      // The return of the tab or route re-creates the semantics; a kept cue
      // would announce an old answer as new.
      _dropAnswerCue();
    } else if (!cueCouldSpeak && _cueCanSpeak && _answerCue != null) {
      // Arrived while covered: it speaks now.
      _startAnswerCueLifetime();
    }
    final svc = widget.service;
    // Only on becoming visible and only once bootstrap is done, or two calls
    // race.
    if (!wurdeSichtbar || svc == null || _loading) return;
    // After the frame: [_beiRueckkehr] calls setState, and this runs mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_beiRueckkehr(svc));
    });
  }

  /// Everything a tab switch used to do by unmounting the screen. It stays
  /// mounted now, so whatever is missing here never happens again until cold
  /// start. Two callers: [didChangeDependencies] (tab switch) and
  /// [didChangeAppLifecycleState] (resume on an already-open coach tab).
  Future<void> _beiRueckkehr(CoachChatService svc) async {
    // Healing path: a bootstrap that ended without a session (offline on the
    // first visit) would otherwise leave the composer dead for the whole app
    // run, since only the quota was refreshed here, never the session.
    if (_activeSessionId == null) {
      await _bootstrap();
      return;
    }
    // The error banner is feedback on an action, not a permanent state.
    if (mounted && identical(widget.service, svc) && _error != null) {
      setState(() => _error = null);
    }
    await _refreshQuota(svc);
  }

  /// Second trigger for the refresh path: [didChangeDependencies] only fires
  /// on a `TickerMode` edge, i.e. on a tab switch. Backgrounding the app while
  /// the coach tab is already on top produces no edge, so an exhausted quota
  /// would keep the composer locked past midnight. Same guards as the tab
  /// path, so a resume on another tab issues no request.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_listening) setState(_cancelSpeechInput);
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final svc = widget.service;
    if (!_sichtbar || svc == null || _loading) return;
    unawaited(_beiRueckkehr(svc));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _briefIsActive?.value = false;
    _answerCueTimer?.cancel();
    _cancelSpeechInput();
    _input.dispose();
    _draft.dispose();
    _streamVorschau.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Never runs twice concurrently — [_beiRueckkehr]'s healing path can
  /// restart the bootstrap, so this is a real case.
  bool _bootstrapLaeuft = false;

  Future<void> _bootstrap() async {
    if (_bootstrapLaeuft) return;
    _bootstrapLaeuft = true;
    try {
      await _bootstrapIntern();
    } finally {
      _bootstrapLaeuft = false;
    }
  }

  Future<void> _bootstrapIntern() async {
    final svc = widget.service;
    final sessionBeforeLoad = _activeSessionId;
    // Safety net only: both callers already guarantee a non-null service, so
    // this branch needs no `context.l10n` before the first `await`.
    if (svc == null) return;
    // Only on a repeat run: show spinner, clear old banner. The first run from
    // initState already has `_loading == true` and must not call setState.
    if (!_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Offline: "no list" is not "no sessions". The next step asks for a
      // default session anyway.
      sessions = const <ChatSession>[];
    }
    if (!mounted || _activeSessionId != sessionBeforeLoad) return;
    final activeId = sessions.isNotEmpty
        ? sessions.first.id
        : await svc.ensureDefaultSession();
    if (activeId == null) {
      if (!mounted || _activeSessionId != sessionBeforeLoad) return;
      // After at least one `await`: Localizations is guaranteed to be there.
      setState(() {
        _loading = false;
        // No session means no history to have failed (a retry after one).
        _historyUnavailable = false;
        _error = context.l10n.coachErrorNoSession;
      });
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
      // "Not loadable" is not "empty": an empty _messages would show the hero
      // state and present the history as deleted.
      if (!mounted || _activeSessionId != sessionBeforeLoad) return;
      setState(() {
        // The list did load: the sheet shows it, and picking a conversation
        // there retries the history load and unlocks the composer.
        if (sessions.isNotEmpty) _sessions = sessions;
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    if (!mounted || _activeSessionId != sessionBeforeLoad) return;
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
    if (!mounted || _activeSessionId != sessionBeforeLoad) return;
    setState(() {
      _sessions = refreshedSessions;
      _activeSessionId = activeId;
      _messages = history;
      _quota = quota;
      _loading = false;
      // Fresh history from the server: a retry job pointing at a local bubble
      // that no longer exists would target nothing.
      _fehlgeschlagen = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
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
    if (mounted &&
        identical(widget.service, svc) &&
        revision == _quotaRevision) {
      setState(() => _quota = frisch);
    }
  }

  Future<void> _refreshSessions() async {
    final svc = widget.service;
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
    if (!mounted ||
        !identical(widget.service, svc) ||
        revision != _sessionListRevision) {
      return;
    }
    setState(() => _sessions = sessions);
  }

  bool _matchesConversation(
    CoachChatService svc,
    String? sessionId,
    int revision,
  ) =>
      mounted &&
      identical(widget.service, svc) &&
      _activeSessionId == sessionId &&
      _conversationRevision == revision;

  /// Switches the displayed conversation.
  ///
  /// A visit revision fences slow loads, including an A→B→A return to the same
  /// session id. The screen stays mounted across switches.
  Future<void> _switchToSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    if (_activeSessionId == sessionId) return;
    final revision = ++_conversationRevision;
    _streamVorschau.value = '';
    setState(() {
      _loading = true;
      _activeSessionId = sessionId;
      _messages = const <ChatMessage>[];
      // The undelivered question belongs to the session being left; its retry
      // job would otherwise land in the new one.
      _fehlgeschlagen = null;
      // So does a cue still waiting behind the sessions sheet.
      _dropAnswerCue();
    });
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      // The error belongs to the session that caused it, or C would carry A's
      // banner and `_historyUnavailable` state.
      if (!_matchesConversation(svc, sessionId, revision)) {
        return;
      }
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    history = await _hydrateProposalImages(history);
    if (!_matchesConversation(svc, sessionId, revision)) {
      return;
    }
    setState(() {
      _messages = history;
      _historyUnavailable = false;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
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
    if (!mounted ||
        !identical(widget.service, svc) ||
        _activeSessionId != sessionId) {
      return;
    }
    // Supersede any earlier history load for this same visit.
    final revision = ++_conversationRevision;
    setState(() => _loading = true);
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
    setState(() {
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
      _error = loaded == null ? context.l10n.coachErrorHistoryUnavailable : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  Future<void> _startNewSession() async {
    final svc = widget.service;
    if (svc == null) return;
    HapticFeedback.selectionClick();
    // Same check as [_switchToSession], against the state before creating: if
    // the user switched meanwhile, the view is theirs — the new session is in
    // the list, one tap away.
    final vorher = _activeSessionId;
    final revision = _conversationRevision;
    final l10n = context.l10n;
    final id = await svc.createSession(
      title: l10n.coachSessionDefaultTitle,
    );
    if (id == null) {
      // The sheet has closed; without this the tap simply did nothing.
      if (mounted && identical(widget.service, svc)) {
        showAppSnack(
          context,
          l10n.coachErrorNewSessionFailed,
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
          duration: kSnackError,
        );
      }
      return;
    }
    await _refreshSessions();
    if (!_matchesConversation(svc, vorher, revision)) return;
    setState(() {
      _conversationRevision++;
      _activeSessionId = id;
      _messages = const <ChatMessage>[];
      _loading = false;
      _historyUnavailable = false;
      _error = null;
      _fehlgeschlagen = null;
      _dropAnswerCue();
    });
  }

  Future<void> _deleteSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    try {
      await svc.deleteSession(sessionId);
    } on CoachDataUnavailable {
      // S8: not deleted is not deleted — the session stays in the list and the
      // user is told (snack sits above the still-open sessions sheet).
      if (!mounted) return;
      showAppSnack(
        context,
        context.l10n.coachErrorDeleteFailed,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }
    if (!mounted || !identical(widget.service, svc)) return;
    setState(() {
      _sessions = _sessions.where((s) => s.id != sessionId).toList();
    });
    await _refreshSessions();
    if (!mounted || !identical(widget.service, svc)) return;
    // Ignore a list response that still contains the confirmed deletion.
    if (_sessions.any((s) => s.id == sessionId)) {
      setState(() {
        _sessions = _sessions.where((s) => s.id != sessionId).toList();
      });
    }
    if (_activeSessionId == sessionId) {
      if (_sessions.isNotEmpty) {
        await _switchToSession(_sessions.first.id);
      } else {
        // Last session deleted: recreate the default AND reload, so list and
        // sheet show the new session instead of being empty.
        final fallback = await svc.ensureDefaultSession();
        if (!mounted ||
            !identical(widget.service, svc) ||
            _activeSessionId != sessionId) {
          return;
        }
        if (fallback == null) {
          _conversationRevision++;
          _streamVorschau.value = '';
          setState(() {
            _activeSessionId = null;
            _messages = const <ChatMessage>[];
            _loading = false;
            _error = context.l10n.coachErrorNoSession;
            _dropAnswerCue();
          });
          return;
        }
        await _refreshSessions();
        if (!mounted ||
            !identical(widget.service, svc) ||
            _activeSessionId != sessionId) {
          return;
        }
        await _switchToSession(fallback);
      }
    }
  }

  /// Pins the chat to its end and moves there: gliding after a send
  /// ([sanft]), jumping when a conversation opens.
  ///
  /// The move never aims at a precomputed target: a lazy list only estimates
  /// its extent until the last rows are laid out. Instead the pin re-aims at
  /// each content change in [_onChatMetrics] until the extent is exact.
  void _scrollToEnd({bool sanft = false}) {
    _chatAmEnde = true;
    // Sending or opening is an explicit "show me the end"; a drag whose end
    // was never reported (the list swapped mid-gesture) must not block it.
    _nutzerScrollt = false;
    _sanftFolgen = sanft;
    _geheAnsEnde(sanft: sanft);
  }

  /// Incoming content (a first token, a finished answer, an error) follows
  /// only a reader who is still at the end; one reading further up stays put.
  void _folgeDemEnde() {
    if (_chatAmEnde) _geheAnsEnde(sanft: _sanftFolgen);
  }

  void _geheAnsEnde({required bool sanft}) {
    if (!mounted || _nutzerScrollt) return;
    // Deliberately not `_scroll.position`: the AnimatedSwitcher in [build]
    // gives both the outgoing and incoming `_Conversation` the same
    // controller, so two ListViews are attached briefly and
    // `_positions.single` throws (`hasClients` does not catch that). Only the
    // last attached one should scroll; the outgoing one is gone next frame.
    final positionen = _scroll.positions;
    if (positionen.isEmpty) return;
    final liste = positionen.last;
    // `maxScrollExtent` asserts `hasContentDimensions`; a just-attached list
    // has none yet, and calls from the send path have no guaranteed ordering.
    if (!liste.hasContentDimensions) return;
    final ziel = liste.maxScrollExtent;
    if ((liste.pixels - ziel).abs() <= 0.5) return;
    // A few new lines (a streamed answer) are followed quickly so the newest
    // line stays in view; a long way (sending after reading further up)
    // glides visibly.
    final weit = (ziel - liste.pixels).abs() > liste.viewportDimension / 2;
    final dauer = sanft
        ? motionDuration(context, Duration(milliseconds: weit ? 320 : 140))
        : Duration.zero;
    // Past the end (the content just shrank) a glide would first bounce on
    // iOS; clamp instead.
    if (dauer == Duration.zero || liste.pixels > ziel) {
      liste.jumpTo(ziel);
      return;
    }
    // A later content change re-aims from wherever the glide is, so a
    // streamed answer is followed in one continuous motion.
    unawaited(
      liste.animateTo(ziel, duration: dauer, curve: Curves.easeOutCubic),
    );
  }

  /// New message, streamed text, keyboard or a refined extent estimate:
  /// dispatched after layout, so moving here is safe.
  ///
  /// Every scroll offset change is reported here too. Following those would
  /// answer the reader's first pixel of drag with a move back to the end,
  /// and a programmatic move cancels the drag: the chat could not be
  /// scrolled at all. Only a changed content or viewport extent counts.
  bool _onChatMetrics(ScrollMetricsNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    bool geaendert(double? alt, double neu) =>
        alt == null || (alt - neu).abs() > 0.5;
    final inhalt = geaendert(_letzteMaxAusdehnung, metrics.maxScrollExtent);
    final fenster = geaendert(_letztesFenster, metrics.viewportDimension);
    _letzteMaxAusdehnung = metrics.maxScrollExtent;
    _letztesFenster = metrics.viewportDimension;
    final tastatur = MediaQuery.viewInsetsOf(context).bottom;
    final tastaturBewegt = tastatur != _letzteTastatur;
    _letzteTastatur = tastatur;
    if (!_chatAmEnde || _nutzerScrollt || !(inhalt || fenster)) return false;
    // The keyboard resizes the viewport frame by frame; gliding would trail
    // behind it, so the last line stays glued to the composer instead.
    _geheAnsEnde(sanft: _sanftFolgen && !tastaturBewegt);
    return false;
  }

  /// Only the reader's own movement decides the pin, never a content change
  /// or the pin's own glide: growth below a pinned reader must not unpin
  /// them before [_onChatMetrics] follows it.
  ///
  /// A drag unpins at once and for its whole duration; when the reader lets
  /// go (a fling included) near the end, the chat is pinned again.
  bool _onChatScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final vomNutzer = switch (notification) {
      UserScrollNotification(:final direction) =>
        direction != ScrollDirection.idle,
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      // A drag that takes over a running glide starts no new scroll.
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (vomNutzer) {
      _nutzerScrollt = true;
      _chatAmEnde = false;
    } else if (notification is ScrollEndNotification && _nutzerScrollt) {
      _nutzerScrollt = false;
      _chatAmEnde = notification.metrics.extentAfter <= _endeToleranz;
    }
    return false;
  }

  Future<void> _send({
    String? textOverride,
    Uint8List? imageBytes,
    String? imageMimeType,
    CoachTrainingContext? trainingContext,
  }) async {
    if (_dictationHoldsSend(
      fromComposer: textOverride == null && imageBytes == null,
    )) {
      return;
    }
    // Grabbed before the first `await`: safe context access.
    final l10n = context.l10n;
    final svc = widget.service;
    final sessionId = _activeSessionId;
    final conversationRevision = _conversationRevision;
    final knownMessageIds = _messages.map((message) => message.id).toSet();
    final typedText = textOverride ?? _input.text;
    final text = typedText.trim();
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;
    if (svc == null ||
        sessionId == null ||
        _sending ||
        (text.isEmpty && !hasImage)) {
      return;
    }
    // The service deliberately holds no BuildContext; `l10n` is handed in
    // fresh here, only for the fallback error texts.
    svc.l10n = l10n;
    // Only a known-empty quota blocks. If unknown, the attempt goes to the
    // server, which answers 429 if needed (-> CoachQuotaExceeded below).
    if (_kontingentErschoepft) {
      setState(
        () => _error = l10n.coachErrorDailyLimitReached(_limitFuerAnzeige),
      );
      return;
    }

    if (hasImage && _planWishFrom(text) != null) {
      setState(() => _error = l10n.coachPlanPhotoUnsupported);
      return;
    }
    // A log is read from text alone; the photo would turn it into a paid chat
    // question with a /log caption.
    if (hasImage && _workoutLogWishFrom(text) != null) {
      setState(() => _error = l10n.coachWorkoutLogPhotoUnsupported);
      return;
    }

    // Slash commands, text-only: an attached photo is a normal
    // coach question, not a command. An unknown /-command never reaches the
    // model — that would burn a daily slot on a typo.
    if (!hasImage && text.startsWith('/')) {
      final planWish = _planWishFrom(text);
      if (planWish != null) {
        if (planWish.isEmpty) {
          setState(() => _error = l10n.coachPlanEmptyHint);
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
      final logWish = _workoutLogWishFrom(text);
      if (logWish != null) {
        if (logWish.isEmpty) {
          setState(() => _error = l10n.coachWorkoutLogEmptyHint);
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
      final recipeWish = _recipeWishFrom(text);
      if (recipeWish == null) {
        setState(() => _error = l10n.coachPlanUnknownCommandHint);
        return;
      }
      if (recipeWish.isEmpty) {
        // Nothing to generate without a wish: local hint, no request, no slot.
        setState(() => _error = l10n.coachRecipeEmptyHint);
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

    HapticFeedback.selectionClick();
    final displayText = text.isEmpty ? l10n.coachImageDefaultCaption : text;
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
      imageBytes: imageBytes,
    );
    // Retry job built before the request: same bubble, text and image.
    // [_wiederholen] removes the message from the history and resends exactly
    // this, instead of creating a second bubble with the same content.
    final auftrag = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
      imageBytes: imageBytes,
      imageMimeType: imageMimeType,
    );

    setState(() {
      _messages = [..._ohneAltenFehlschlag(displayText), userMsg];
      if (_wiederholtFehlschlag(displayText)) _fehlgeschlagen = null;
      _sendendeSessionId = sessionId;
      _input.clear();
      _draft.value = '';
      _laufendeSendungen++;
      _vorschauGezeigt = false;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToEnd(sanft: true),
    );

    try {
      final res = await svc.send(
        displayText,
        sessionId: sessionId,
        imageBase64: hasImage ? base64Encode(imageBytes) : null,
        imageMimeType: hasImage ? (imageMimeType ?? 'image/jpeg') : null,
        userContext: widget.userContext,
        // Live preview only. Bound to the session the question came from —
        // switching stays possible while sending, and the answer to another
        // conversation must not type itself into this one.
        onPartialReply: (text) {
          if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
          // When the dots turn into text the bubble takes the row's place; a
          // reader at the end keeps it in view, and later deltas follow via
          // [_onChatMetrics]. A reader scrolled up is never moved.
          final erstesZeichen = _streamVorschau.value.isEmpty;
          _streamVorschau.value = text;
          if (text.isNotEmpty) _vorschauGezeigt = true;
          if (erstesZeichen) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _folgeDemEnde());
          }
        },
      );
      // The daily slot is spent even if the answer is discarded — hence
      // before the session comparison.
      if (!mounted || !identical(widget.service, svc)) return;
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      final answer = ChatMessage(
        id: 'local-r-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.assistant,
        content: res.reply,
        createdAt: DateTime.now(),
        refusal: res.refusal,
      );
      // Answer and error belong to the session the question came from;
      // switching stays possible while sending, and `mounted` alone does not
      // cover it because the screen stays mounted.
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
      setState(() {
        _messages = [..._messages, answer];
      });
      HapticFeedback.lightImpact();
      _announceAnswer();
      // Refresh sessions in the background so auto title / last_message_at are
      // current in the sheet without blocking the send flow.
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted || !identical(widget.service, svc)) return;
      // The server named the limit explicitly, so this replaces any prior
      // state regardless of the open session: the limit is per user.
      setState(() {
        _quotaRevision++;
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
      // Marked here too: the slot was gone, the question did not go out. The
      // retry button hangs on [_canInteract] and stays off, but the marker
      // remains — otherwise the bubble would look sent.
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      // On EVERY exit, including the `return`s that discard the answer after
      // a session switch — otherwise the composer locks until cold start.
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _folgeDemEnde());
  }

  /// Whether a new attempt with [text] is the failed question typed again.
  /// Only then does the old bubble (and its marker) give way; a DIFFERENT
  /// text leaves the old bubble standing WITH its marker — it was never
  /// delivered and must not look so.
  bool _wiederholtFehlschlag(String text) {
    final alt = _fehlgeschlagen;
    return alt != null && alt.text.trim() == text.trim();
  }

  /// History without the previous failure's bubble when the new attempt
  /// carries the same text. The marker (retry job) is the only place a failed
  /// question lives on; the field is NOT refilled, so typing it again and
  /// pressing send must replace the bubble, not duplicate it.
  List<ChatMessage> _ohneAltenFehlschlag(String text) {
    if (!_wiederholtFehlschlag(text)) return _messages;
    final alt = _fehlgeschlagen!;
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
    setState(() {
      _error = l10n.coachSessionSwitchedNotice;
      // The question WAS delivered — it just landed elsewhere. An unsent
      // marker would invite a retry and burn a second daily slot.
      _fehlgeschlagen = null;
    });
    // The deleted session is gone from the sheet and the used one may be new.
    await _refreshSessions();
    if (!_matchesConversation(svc, angefragt, revision)) return;
    // [_switchToSession] does the full load; the history it fetches already
    // contains both the question and the answer.
    await _switchToSession(benutzt);
  }

  /// Takes over a quota state the server just named.
  ///
  /// Called before the session comparison on purpose: the quota is per user,
  /// so a discarded answer still spent the slot. Older function deployments
  /// send no limit and fall back to the current display value.
  void _quotaUebernehmen({required int? remaining, required int? dailyLimit}) {
    if (remaining == null || !mounted) return;
    _quotaRevision++;
    final limit = dailyLimit ?? _limitFuerAnzeige;
    final frei = remaining.clamp(0, limit);
    setState(() {
      _quota = ChatQuotaSnapshot(
        used: limit - frei,
        remaining: frei,
        dailyLimit: limit,
        // Only a limit the server itself named makes the lock trustworthy
        // (P5-06); an older deployment that sends none leaves it assumed.
        limitAssumed: dailyLimit == null && (_quota?.limitAssumed ?? true),
      );
    });
  }

  /// An answer lands without moving the screen-reader focus, so it is
  /// announced (spec §9). Android discourages announcements and reports
  /// `supportsAnnounce: false`; there a new polite live region speaks the
  /// same text. Only a node that is new (or relabelled) speaks, hence one per
  /// answer. The same rule speaks a re-created node again, so the cue is
  /// transient: it lives [CoachChatScreen.answerCueLifetime] once it can
  /// speak and goes as soon as a tab switch or a route hides it. An answer
  /// that lands while the tab is hidden is not announced at all: the user is
  /// elsewhere and finds it in the list on return.
  void _announceAnswer() {
    if (!mounted || !_sichtbar) return;
    if (!MediaQuery.supportsAnnounceOf(context)) {
      setState(() => _answerCue = ++_answerCueSerial);
      // Covered, it waits for [didChangeDependencies].
      if (_cueCanSpeak) _startAnswerCueLifetime();
      return;
    }
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        context.l10n.coachAnswerAnnouncement,
        Directionality.of(context),
      ),
    );
  }

  void _startAnswerCueLifetime() {
    _answerCueTimer?.cancel();
    _answerCueTimer = Timer(CoachChatScreen.answerCueLifetime, () {
      _answerCueTimer = null;
      if (mounted && _answerCue != null) setState(() => _answerCue = null);
    });
  }

  /// Without setState: callers are inside one, or before a build.
  void _dropAnswerCue() {
    _answerCueTimer?.cancel();
    _answerCueTimer = null;
    _answerCue = null;
  }

  /// Counterpart to `_laufendeSendungen++`; belongs in a `finally` so every
  /// exit counts. After unmount only the bookkeeping runs, no setState.
  void _sendevorgangBeendet() {
    final rest = math.max(0, _laufendeSendungen - 1);
    // Nothing in flight: no session is "the sending one" any more.
    final sendende = rest == 0 ? null : _sendendeSessionId;
    // The preview belongs to the request, not to the screen: the finished
    // bubble (or the error banner) has taken over by now, and a leftover would
    // reappear under the NEXT question before its first token.
    // `mounted` FIRST: dispose() disposes this notifier, and a write after that
    // trips ValueNotifier's debugAssertNotDisposed — it throws into the zone (and
    // so into Sentry) in debug and in every widget test. Reachable by signing out
    // or tearing the shell down while a stream has produced at least one delta.
    if (mounted && rest == 0) _streamVorschau.value = '';
    if (!mounted) {
      _laufendeSendungen = rest;
      _sendendeSessionId = sendende;
      return;
    }
    setState(() {
      _laufendeSendungen = rest;
      _sendendeSessionId = sendende;
    });
  }

  /// Retries the last undelivered question.
  ///
  /// The message is removed from the history first and then resent unchanged,
  /// so the attempt replaces the same bubble instead of creating a duplicate.
  /// The image rides along: it lives only in the local bubble (history stores
  /// no image data) and would otherwise be lost.
  Future<void> _wiederholen() async {
    final auftrag = _fehlgeschlagen;
    if (auftrag == null || !_canInteract) return;
    // A newly typed text must survive: [_send] always clears the field, even
    // with `textOverride`. The failed question itself typed again is consumed
    // by the retry, not restored.
    final fremderEntwurf = _input.text.trim() == auftrag.text.trim()
        ? ''
        : _input.text;
    setState(() {
      _messages = _messages
          .where((m) => m.id != auftrag.messageId)
          .toList(growable: false);
      _fehlgeschlagen = null;
      _error = null;
    });
    final versand = _send(
      textOverride: auftrag.text,
      imageBytes: auftrag.imageBytes,
      imageMimeType: auftrag.imageMimeType,
      trainingContext: auftrag.trainingContext,
    );
    // `_send` clears the field synchronously before its first await, so the
    // draft goes back right away instead of vanishing while the retry runs.
    if (mounted) _entwurfZurueck(fremderEntwurf);
    await versand;
  }

  /// Restores a draft the retry had to clear. Only that: a failed question is
  /// NOT put back here — the unsent marker is its single home, or the send
  /// button would create a duplicate next to the retry.
  void _entwurfZurueck(String entwurf) {
    if (entwurf.isEmpty || _input.text.isNotEmpty) return;
    _input.text = entwurf;
    _input.selection = TextSelection.collapsed(offset: entwurf.length);
  }

  /// Detects the /recipe command at line start — English is the only spelling
  /// in both app languages; the command menu handles discoverability. Returns
  /// the wish text ('' if none) or null for no/unknown command.
  static String? _recipeWishFrom(String text) {
    final match = RegExp(
      r'^/recipe(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    if (match == null) return null;
    return (match.group(1) ?? '').trim();
  }

  static String? _planWishFrom(String text) {
    final match = RegExp(
      r'^/plan(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    return match == null ? null : (match.group(1) ?? '').trim();
  }

  /// `/log` and the finished workout after it ('' if none); null for any
  /// other text. English in both app languages, like /recipe and /plan.
  static String? _workoutLogWishFrom(String text) {
    final match = RegExp(
      r'^/log(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    return match == null ? null : (match.group(1) ?? '').trim();
  }

  /// The command menu shows while the draft looks like a started command:
  /// starts with "/", no whitespace yet, and is a known command prefix.
  bool _commandMenuVisibleFor(String draftText) {
    final draft = draftText.trimLeft();
    if (!draft.startsWith('/')) return false;
    if (RegExp(r'\s').hasMatch(draft)) return false;
    return _CoachCommand.values.any((command) => command.offeredFor(draft));
  }

  /// A prepared question from the start card, sent through [_send] like a
  /// typed one: same bubble, quota, retry and session rules. A draft the user
  /// had typed survives — [_send] clears the field on its way out.
  Future<void> _sendPrepared(String prompt) async {
    if (!_canInteract) return;
    final entwurf = _input.text;
    final versand = _send(textOverride: prompt);
    if (mounted) _entwurfZurueck(entwurf);
    await versand;
  }

  /// Plan discovery opens a brief; recipe and log discovery prepare the
  /// composer.
  void _applyCommand(String command) {
    if (command == _CoachCommand.plan.token) {
      unawaited(_openTrainingBrief());
      return;
    }
    HapticFeedback.selectionClick();
    final prepared = '$command ';
    if (_listening) {
      // The command becomes the running dictation's draft base, so the next
      // partial appends to it instead of writing the old base back (R17
      // D2-M2). The words already dictated stay after it.
      _speechDraft = prepared;
      _setDraft(_withDictation(prepared, _speechShown));
    } else {
      _input.text = prepared;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
    _inputFocus.requestFocus();
  }

  Future<void> _openTrainingBrief({
    TrainingPlan? selectedPlan,
    bool sessionRetried = false,
  }) async {
    if (_briefingTrainingPlan) return;
    // A running request or a loading chat is a wait, not a refusal.
    if (_sending || _loading) {
      _queuedBrief = (
        selectedPlan: selectedPlan,
        sessionRetried: sessionRetried,
      );
      return;
    }
    // No session yet (an offline first visit): load it once more, as a tab
    // return would, before giving up on the brief.
    if (widget.service != null && _activeSessionId == null && !sessionRetried) {
      _queuedBrief = (selectedPlan: selectedPlan, sessionRetried: true);
      unawaited(_bootstrap());
      return;
    }
    // Nothing could be sent from the brief: say why up front instead of
    // after the whole form is filled in.
    final locked = _composerLockReason(context.l10n);
    if (locked != null) {
      setState(() => _error = locked);
      return;
    }
    final service = widget.service;
    final revision = _trainingAccountRevision;
    final session = _activeSessionId;
    bool sourceIsCurrent() => mounted &&
        identical(widget.service, service) &&
        _trainingAccountRevision == revision &&
        (session == null || _activeSessionId == session) &&
        (selectedPlan == null || widget.userTrainingPlanIds.contains(selectedPlan.id));
    _briefingTrainingPlan = true;
    final active = ValueNotifier(true);
    _briefIsActive = active;
    _endDictationForSheet();
    _inputFocus.unfocus();
    final CoachTrainingBriefSubmission? submitted;
    try {
      submitted = await showCoachTrainingBrief(
        context,
        selectedPlan: selectedPlan,
        initialWish: _planWishFrom(_input.text) ?? '',
        canSubmit: () => sourceIsCurrent() && _canInteract,
        isActive: active,
      );
    } finally {
      // Released with the sheet, not the request: a brief asked for while
      // the plan generates is queued instead of dropped.
      _briefingTrainingPlan = false;
      if (identical(_briefIsActive, active)) _briefIsActive = null;
      active.dispose();
    }
    if (submitted == null || !sourceIsCurrent() || !_canInteract) return;
    // Only this explicit submission can consume a request. Keep the snapshot
    // on its retry job, never implicitly attach it to later ordinary chat.
    // A typed `/plan` draft went into the brief; any other draft survives
    // the send, as with a prepared question.
    final draft = _input.text;
    final versand = _send(
      textOverride: '/plan ${submitted.wish}',
      trainingContext: submitted.context,
    );
    if (mounted && _planWishFrom(draft) == null) _entwurfZurueck(draft);
    await versand;
  }

  /// Why nothing can be sent at all, or null. Loading and a running request
  /// are waits, not locks.
  String? _composerLockReason(AppLocalizations l10n) {
    if (widget.service == null) return l10n.coachErrorNotLoggedIn;
    if (_kontingentErschoepft) {
      return l10n.coachErrorDailyLimitReached(_limitFuerAnzeige);
    }
    if (_activeSessionId == null) {
      // A failed history load leaves no active session either; its banner
      // names the real cause.
      return _historyUnavailable
          ? l10n.coachErrorHistoryUnavailable
          : l10n.coachErrorNoSession;
    }
    return null;
  }

  /// Opens a brief that waited for a request or a load ([_queuedBrief]).
  /// Never on top of another sheet or page: it stays queued, and the
  /// rebuild when that route closes opens it.
  void _openQueuedBriefWhenFree() {
    if (_queuedBrief == null ||
        _queuedBriefScheduled ||
        _sending ||
        _loading ||
        !_routeOnTop) {
      return;
    }
    _queuedBriefScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queuedBriefScheduled = false;
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      final queued = _queuedBrief;
      _queuedBrief = null;
      if (queued == null) return;
      unawaited(
        _openTrainingBrief(
          selectedPlan: queued.selectedPlan,
          sessionRetried: queued.sessionRetried,
        ),
      );
    });
  }

  /// "Added" is derived, never stored: the card slug comes deterministically
  /// from the message id and the live slugs from the shell. So the state
  /// survives restarts and second devices, and deleting re-enables the button.
  bool _isRecipeAdded(ChatMessage message) {
    if (message.recipeProposal == null) return false;
    return widget.userRecipeSlugs.contains(
      FitnessRecipe.coachProposalSlug(message.id),
    );
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

  /// Mirror of [_send] for the recipe path: optimistic user bubble with the
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
    HapticFeedback.selectionClick();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    // As in [_send]: [displayText] carries the command, so a retry lands in
    // this branch again by itself.
    final auftrag = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
    );
    setState(() {
      _messages = [..._ohneAltenFehlschlag(displayText), userMsg];
      if (_wiederholtFehlschlag(displayText)) _fehlgeschlagen = null;
      _sendendeSessionId = sessionId;
      _input.clear();
      _draft.value = '';
      _laufendeSendungen++;
      _vorschauGezeigt = false;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToEnd(sanft: true),
    );

    try {
      // No `userContext` (P5-02): the function's recipe mode never reads it,
      // so sending profile and daily balance would be data without a purpose.
      final res = await svc.requestRecipe(
        wish,
        sessionId: sessionId,
        locale: l10n.localeName,
      );
      // As in [_send]: the slot is spent even if the card is discarded.
      if (!mounted || !identical(widget.service, svc)) return;
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
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
        // Mirror of [_send]. The reload rebuilds the card from
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
      setState(() {
        _messages = [..._messages, answer];
      });
      HapticFeedback.lightImpact();
      _announceAnswer();
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted || !identical(widget.service, svc)) return;
      // As in [_send]: the limit is per user, not per session.
      setState(() {
        _quotaRevision++;
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!_matchesConversation(svc, sessionId, conversationRevision)) return;
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _folgeDemEnde());
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
    required AppLocalizations l10n,
    required Future<_ProposalAnswer> Function() request,
    CoachTrainingContext? trainingContext,
  }) async {
    final accountRevision = _trainingAccountRevision;
    final conversationRevision = _conversationRevision;
    final knownMessageIds = _messages.map((message) => message.id).toSet();
    HapticFeedback.selectionClick();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    final retry = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
      trainingContext: trainingContext,
    );
    setState(() {
      _messages = [..._ohneAltenFehlschlag(displayText), userMsg];
      if (_wiederholtFehlschlag(displayText)) _fehlgeschlagen = null;
      _sendendeSessionId = sessionId;
      _input.clear();
      _laufendeSendungen++;
      _vorschauGezeigt = false;
      _error = null;
    });
    final submittedMessages = _messages;
    bool isCurrentAccount() =>
        mounted &&
        identical(widget.service, svc) &&
        _trainingAccountRevision == accountRevision;
    bool isCurrentConversation() =>
        isCurrentAccount() &&
        _activeSessionId == sessionId &&
        identical(_messages, submittedMessages);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToEnd(sanft: true),
    );
    try {
      final reply = await request();
      if (!isCurrentAccount()) return;
      // Quota is account-wide, including responses to another conversation.
      _quotaUebernehmen(
        remaining: reply.remaining,
        dailyLimit: reply.dailyLimit,
      );
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
      setState(() {
        _messages = [..._messages, answer];
      });
      HapticFeedback.lightImpact();
      _announceAnswer();
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (error) {
      if (!isCurrentAccount()) return;
      _quotaUebernehmen(remaining: 0, dailyLimit: error.dailyLimit);
      if (!isCurrentConversation()) return;
      setState(() {
        _error = error.message;
        _fehlgeschlagen = retry;
      });
    } on CoachChatException catch (error) {
      if (!isCurrentConversation()) return;
      setState(() {
        _error = error.message;
        _fehlgeschlagen = retry;
      });
    } finally {
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _folgeDemEnde());
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
    setState(() {
      if (sessions != null && listRevision == _sessionListRevision) {
        _sessions = sessions;
      }
      _conversationRevision++;
      _activeSessionId = sessionId;
      _messages = loadingMessages;
      _loading = true;
      _fehlgeschlagen = null;
      _error = l10n.coachSessionSwitchedNotice;
      _dropAnswerCue();
    });
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
    setState(() {
      _messages = [
        ...history,
        if (!history.any((message) => message.id == answer.id)) answer,
      ];
      _historyUnavailable = historyUnavailable;
      _loading = false;
      if (historyUnavailable) _error = l10n.coachErrorHistoryUnavailable;
    });
    HapticFeedback.lightImpact();
    _announceAnswer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  bool _isTrainingPlanAdded(ChatMessage message) {
    if (widget.userTrainingPlanSourceIds.contains(message.id)) return true;
    if (message.trainingPlanProposal == null) return false;
    try {
      return widget.userTrainingPlanIds.contains(
        trainingPlanIdForMessage(message.id),
      );
    } on FormatException {
      return false;
    }
  }

  Future<void> _reviewTrainingPlan(ChatMessage message) async {
    final proposal = message.trainingPlanProposal;
    final onCreate = widget.onCreateTrainingPlan;
    final service = widget.service;
    final sessionId = _activeSessionId;
    if (proposal == null ||
        onCreate == null ||
        _reviewingTrainingPlan ||
        _isTrainingPlanAdded(message)) {
      return;
    }
    final String planId;
    try {
      planId = trainingPlanIdForMessage(message.id);
    } on FormatException {
      showAppSnack(
        context,
        context.l10n.coachPlanSaveFailed,
        tone: SnackTone.error,
      );
      return;
    }
    bool isCurrentDraft() =>
        mounted &&
        identical(widget.service, service) &&
        _activeSessionId == sessionId &&
        _messages.any(
          (current) =>
              current.id == message.id &&
              identical(current.trainingPlanProposal, proposal),
        );
    HapticFeedback.selectionClick();
    _inputFocus.unfocus();
    setState(() => _reviewingTrainingPlan = true);
    try {
      await showTrainingPlanEditor(
        context,
        initialDraft: proposal,
        submitLabel: context.l10n.coachPlanAdoptButton,
        confirmationMessage: () =>
            widget.hasTrainingAdoptionConflict?.call(planId) == true
            ? context.l10n.settingsSyncTrainingConflict
            : null,
        onSave: (draft) async {
          // Sheet routes can outlive their original account or conversation.
          // Recheck at the write boundary, not only when opening the sheet.
          if (!isCurrentDraft()) {
            throw StateError('Training draft is no longer active');
          }
          if (_isTrainingPlanAdded(message)) return SyncDelivery.delivered;
          final result = await onCreate(
            TrainingPlan(id: planId, proposal: draft, sourceId: message.id),
          );
          if (!isCurrentDraft()) {
            throw StateError('Training draft is no longer active');
          }
          return result;
        },
      );
    } finally {
      if (mounted) setState(() => _reviewingTrainingPlan = false);
    }
  }

  /// Where a /log card stands, derived from the live history. Deleted wins:
  /// the server refuses that id for good, so it can never be added again.
  _WorkoutLogCardStatus _workoutLogStatus(ChatMessage message) {
    final id = _workoutLogHistoryId(message);
    if (id == null) return _WorkoutLogCardStatus.waiting;
    if (widget.trainingHistoryDeletedIds.contains(id)) {
      return _WorkoutLogCardStatus.removed;
    }
    if (widget.trainingHistoryIds.contains(id)) {
      return _WorkoutLogCardStatus.added;
    }
    return widget.trainingHistoryAuthoritative
        ? _WorkoutLogCardStatus.open
        : _WorkoutLogCardStatus.waiting;
  }

  /// Reviewing a /log card: the log editor, prefilled and editable, is the
  /// confirmation, and its Add is the only write (spec C1). The editor
  /// allocates nothing; every Add carries the card's history id.
  Future<void> _reviewWorkoutLog(ChatMessage message) async {
    final proposal = message.workoutLogProposal;
    final onLog = widget.onLogWorkout;
    final historyId = _workoutLogHistoryId(message);
    final service = widget.service;
    final accountRevision = _trainingAccountRevision;
    final sessionId = _activeSessionId;
    if (proposal == null ||
        onLog == null ||
        historyId == null ||
        _reviewingWorkoutLog ||
        _workoutLogStatus(message) != _WorkoutLogCardStatus.open) {
      return;
    }
    bool isCurrentDraft() =>
        mounted &&
        identical(widget.service, service) &&
        _trainingAccountRevision == accountRevision &&
        _activeSessionId == sessionId &&
        _messages.any(
          (current) =>
              current.id == message.id &&
              identical(current.workoutLogProposal, proposal),
        );
    HapticFeedback.selectionClick();
    // Taken before the sheet: a second tap in this frame opens nothing.
    setState(() => _reviewingWorkoutLog = true);
    // No partial may rewrite the composer under the sheet.
    _endDictationForSheet();
    _inputFocus.unfocus();
    try {
      await showTrainingLogEditor(
        context,
        request: FreeLogRequest(
          historyId: historyId,
          initial: proposal.toDraft(),
          fromCoach: true,
        ),
        history: widget.trainingHistory,
        onSave: (entry) async {
          // Sheet routes can outlive their account or conversation: recheck
          // at the write boundary, before and after the write.
          if (!isCurrentDraft() || entry.id != historyId) {
            throw StateError('Workout draft is no longer active');
          }
          // Another device or an earlier Add got there first: no second row,
          // and a deleted entry is never resurrected.
          if (widget.trainingHistoryDeletedIds.contains(historyId)) {
            return TrainingLogSaveOutcome.deleted;
          }
          if (widget.trainingHistoryIds.contains(historyId)) {
            return TrainingLogSaveOutcome.saved;
          }
          final outcome = await onLog(entry);
          if (!isCurrentDraft()) {
            throw StateError('Workout draft is no longer active');
          }
          return outcome;
        },
      );
    } finally {
      if (mounted) setState(() => _reviewingWorkoutLog = false);
    }
  }

  /// Adopting a /recipe proposal — the ONLY way anything from a coach answer
  /// is ever stored, entirely client-side via the user-confirmed
  /// [CoachChatScreen.onCreateRecipe] hook.
  Future<void> _addProposalToRecipes(ChatMessage message) async {
    final proposal = message.recipeProposal;
    final onCreate = widget.onCreateRecipe;
    if (proposal == null || onCreate == null || _addingRecipe) return;
    if (_isRecipeAdded(message)) return;
    HapticFeedback.selectionClick();
    // Taken before the sheet: the navigator absorbs a second tap once the
    // route is pushed, but not a second accessibility action in that frame.
    setState(() => _addingRecipe = true);
    try {
      final confirmed = await showEatovaSheet<bool>(
        context,
        _RecipeAddSheet(proposal: proposal),
      );
      if (confirmed != true || !mounted) return;
      var imageAsset = '';
      var photoFailed = false;
      final bytes = proposal.imageBytes;
      if (bytes != null) {
        final referenz = await RecipeImageStore.instance.save(bytes: bytes);
        if (!mounted) return;
        // A failed photo save does not discard the confirmed recipe; the
        // outcome message below says so (a separate error toast would be
        // replaced by it at once).
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
      final delivery = await onCreate(recipe);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      showAppSnack(
        context,
        deliveryHint(
          photoFailed
              ? context.l10n.recipesSavedWithoutPhoto(recipe.title)
              : context.l10n.recipesSavedSuccess(recipe.title),
          delivery,
          context.l10n,
        ),
        icon: Icons.bookmark_added_rounded,
      );
    } catch (_) {
      if (mounted) {
        showAppSnack(
          context,
          context.l10n.commonLocalSaveFailed,
          tone: SnackTone.error,
          duration: kSnackError,
        );
      }
    } finally {
      if (mounted) setState(() => _addingRecipe = false);
    }
  }

  /// Base64 inflates by +33%, and the edge function cuts off at 6,000,000
  /// characters (handler.ts:47) with a 413. Stop before the upload, not after.
  static const int _maxImageBytes = 4400000;

  /// The only exit for image bytes from the coach (Review C4).
  ///
  /// [compressMealPhoto] bakes in orientation, scales to 1600 px and wipes the
  /// EXIF container; `image_picker` scales but copies the tags back, so GPS,
  /// timestamp and device serial would reach OpenRouter otherwise. `compute()`
  /// keeps decode/re-encode off the UI isolate; if it fails to start, compress
  /// inline — a stutter beats an upload with coordinates.
  Future<Uint8List> _scrubImage(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }

  /// MIME type from the ACTUAL bytes, not the file name: after the scrub the
  /// image is always JPEG even if the source was PNG or WebP. The file-name
  /// branch is a defensive net since the scrub fails closed (S2).
  String _mimeForBytes(Uint8List bytes, XFile file) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return _mimeTypeFor(file);
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    // Grabbed before the first `await`: safe context access.
    final l10n = context.l10n;
    final service = widget.service;
    final sessionId = _activeSessionId;
    final revision = _conversationRevision;
    // The caption is the draft as it stood when the photo was picked. The
    // field stays typeable during the scrub; edits there no longer drop the
    // photo, they stay in the field (spec §9).
    final draft = _input.text;
    bool isCurrent() => mounted &&
        identical(widget.service, service) &&
        _activeSessionId == sessionId &&
        _conversationRevision == revision &&
        _canInteract;
    // The copy the picker leaves in the app cache; deleted in `finally`, or
    // the user's photos stay on the device forever, even after account
    // deletion.
    XFile? aufnahme;
    try {
      final image = await _picker.pickImage(
        source: source,
        // imageQuality/maxWidth must stay: without them iOS passes the HEIC
        // original through, which package:image cannot decode, so
        // [_scrubImage] would return it unscrubbed.
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (image == null) return;
      aufnahme = image;
      if (!isCurrent()) return;
      final raw = await image.readAsBytes();
      if (!isCurrent()) return;
      final bytes = await _scrubImage(raw);
      if (!isCurrent()) return;
      if (bytes.lengthInBytes > _maxImageBytes) {
        setState(() => _error = l10n.coachErrorImageTooLarge);
        return;
      }
      final typed = _input.text;
      final versand = _send(
        textOverride: draft.trim().isEmpty
            ? l10n.coachImageDefaultCaption
            : draft.trim(),
        imageBytes: bytes,
        imageMimeType: _mimeForBytes(bytes, image),
      );
      // [_send] clears the field on its way out; text typed meanwhile is not
      // part of this message and goes back.
      if (mounted && typed.trim() != draft.trim()) _entwurfZurueck(typed);
      await versand;
    } on PlatformException catch (e) {
      if (!isCurrent()) return;
      setState(() => _error = _permissionMessageFor(source, e, l10n));
    } catch (e) {
      if (!isCurrent()) return;
      setState(() => _error = l10n.coachErrorImageLoadFailed);
    } finally {
      // Only here: by now the bytes are read, scrubbed and sent — the path is
      // needed for the MIME type only, not the content.
      final datei = aufnahme;
      if (datei != null) await deleteMealPhotoTempFile(datei.path);
    }
  }

  String _mimeTypeFor(XFile file) {
    final mime = file.mimeType?.toLowerCase();
    if (mime == 'image/png' || mime == 'image/webp' || mime == 'image/jpeg') {
      return mime!;
    }
    final path = file.path.toLowerCase();
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _permissionMessageFor(
    ImageSource source,
    PlatformException e,
    AppLocalizations l10n,
  ) {
    final permissionText = source == ImageSource.camera
        ? l10n.coachCameraAccessNoun
        : l10n.coachPhotoAccessNoun;
    final lower = '${e.code} ${e.message}'.toLowerCase();
    if (lower.contains('denied') || lower.contains('permission')) {
      return l10n.coachPermissionDenied(permissionText);
    }
    return l10n.coachErrorImageOpenFailed;
  }

  // --- Dictation (spec Part D) ----------------------------------------------

  /// Source of [_speechGeneration] for every screen instance: a token from a
  /// disposed screen can never pass as one of its successor's.
  static int _speechSeq = 0;

  /// The draft a recording started from; dictated text is appended to it.
  String _speechDraft = '';

  /// Dictated text currently shown after [_speechDraft].
  String _speechShown = '';

  /// A graceful stop is draining the final result.
  bool _speechStopping = false;

  /// Draft plus dictation reached the input cap during this recording.
  bool _speechCapReached = false;

  /// Device preference; null until loaded or chosen (then the app language).
  DictationLanguage? _dictationLanguage;
  DictationLanguage _listeningLanguage = DictationLanguage.de;
  bool _screenKeptAwake = false;

  /// Reads the per-device choice in the background, only where the mic
  /// exists (see the composer).
  void _loadDictationLanguage() {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    unawaited(
      widget.dictationLanguageStore.load().then((stored) {
        if (mounted && stored != null) _dictationLanguage ??= stored;
      }),
    );
  }

  void _keepScreenAwake(bool on) {
    if (_screenKeptAwake == on) return;
    _screenKeptAwake = on;
    unawaited(widget.screenAwake.setKeepAwake(on));
  }

  void _setDraft(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// One space between draft and dictation, none after a trailing space
  /// (`/log `).
  static String _withDictation(String draft, String dictated) {
    if (dictated.isEmpty) return draft;
    if (draft.isEmpty || RegExp(r'\s$').hasMatch(draft)) {
      return '$draft$dictated';
    }
    return '$draft $dictated';
  }

  /// Immediate end for hide, background, dispose and account change: the mic
  /// goes off at once and a late result is ignored. Hide and background keep
  /// the text already shown; [discard] (account change) drops this
  /// recording's text. Callers rebuild (setState, build phase or dispose).
  void _cancelSpeechInput({bool discard = false}) {
    _speechGeneration = ++_speechSeq;
    if (!_listening) return;
    _listening = false;
    if (discard) _setDraft(_speechDraft);
    unawaited(widget.speechInput.cancel());
    _keepScreenAwake(false);
  }

  /// A sheet over the composer (attach, brief) reads the draft as it stands:
  /// the recording ends at once and keeps what it showed, so no partial
  /// rewrites the field behind the sheet (R17 D2-M1).
  void _endDictationForSheet() {
    if (_listening) setState(_cancelSpeechInput);
  }

  /// Graceful end (mic, send, input cap): the audio stops and the final
  /// result still lands in the field; [_listening] stays on until it does.
  void _stopSpeechGracefully() {
    if (!_listening || _speechStopping) return;
    _speechStopping = true;
    unawaited(widget.speechInput.stop());
  }

  /// First call in [_send]: a send never interleaves with a recording. The
  /// composer's send only finishes it, so the final text stays for review
  /// and a second tap sends it (never unseen text). Other sends carry their
  /// own visible text (prepared question, retry, brief, photo): the recording
  /// ends at once and keeps what it showed.
  bool _dictationHoldsSend({required bool fromComposer}) {
    if (!_listening) return false;
    if (fromComposer) {
      _stopSpeechGracefully();
      return true;
    }
    setState(_cancelSpeechInput);
    return false;
  }

  Future<void> _toggleSpeechInput() async {
    if (_listening) {
      HapticFeedback.selectionClick();
      _stopSpeechGracefully();
      return;
    }
    // Typing by voice: allowed whenever typing is, even while an answer runs.
    if (!_canType) return;
    HapticFeedback.selectionClick();
    _speechDraft = _input.text;
    await _listen(
      _dictationLanguage ??
          DictationLanguage.forAppLanguage(context.l10n.localeName),
    );
  }

  /// The pill: same draft, other language. Only this recording's text is
  /// replaced; the choice is remembered per device.
  void _switchDictationLanguage() {
    if (!_listening || _speechStopping) return;
    HapticFeedback.selectionClick();
    final next = _listeningLanguage.other;
    _dictationLanguage = next;
    unawaited(widget.dictationLanguageStore.save(next));
    _speechGeneration = ++_speechSeq;
    _setDraft(_speechDraft);
    // Channel order: the cancel reaches the plugin before the new listen.
    unawaited(widget.speechInput.cancel());
    unawaited(_listen(next));
  }

  /// Partials replace the shown dictation live, after the draft.
  void _showDictation(int generation, String text) {
    if (!mounted || generation != _speechGeneration || !_listening) return;
    _speechShown = text.trim();
    final draft = _withDictation(_speechDraft, _speechShown);
    _setDraft(draft);
    // Draft and dictation share the composer cap: stop there, never cut.
    if (!_speechCapReached && _CoachInputLimit.overflow(draft) >= 0) {
      _speechCapReached = true;
      _stopSpeechGracefully();
    }
  }

  /// One recording. Into the field only, never straight to the server: a
  /// misheard sentence would cost a daily slot and seed the auto title. The
  /// user reviews and presses send.
  Future<void> _listen(DictationLanguage language) async {
    // Grabbed before the first `await`: safe context access.
    final l10n = context.l10n;
    final generation = _speechGeneration = ++_speechSeq;
    setState(() {
      _listening = true;
      _listeningLanguage = language;
      _speechShown = '';
      _speechStopping = false;
      _speechCapReached = false;
      _error = null;
    });
    _keepScreenAwake(true);
    var end = CoachSpeechEnd.stopped;
    try {
      final spoken = await widget.speechInput.listen(
        localeId: language.localeId,
        l10n: l10n,
        token: generation,
        onPartial: (text) => _showDictation(generation, text),
        onEnd: (value) => end = value,
      );
      if (!mounted || generation != _speechGeneration) return;
      final text = spoken?.trim() ?? '';
      // An empty final never takes back words already shown.
      final dictated = text.isEmpty ? _speechShown : text;
      final String? hint;
      if (dictated.isEmpty) {
        hint = l10n.coachErrorSpeechEmpty;
      } else if (_speechCapReached || end == CoachSpeechEnd.length) {
        hint = l10n.coachDictationLengthHint;
      } else if (end == CoachSpeechEnd.limit) {
        hint = l10n.coachDictationLimitHint;
      } else {
        hint = null;
      }
      _keepScreenAwake(false);
      setState(() {
        _listening = false;
        if (dictated.isNotEmpty) {
          _setDraft(_withDictation(_speechDraft, dictated));
        }
        if (hint != null) _error = hint;
      });
      if (dictated.isNotEmpty) _inputFocus.requestFocus();
    } on CoachSpeechException catch (e) {
      if (!mounted || generation != _speechGeneration) return;
      _keepScreenAwake(false);
      setState(() {
        _listening = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted || generation != _speechGeneration) return;
      _keepScreenAwake(false);
      setState(() {
        _listening = false;
        _error = l10n.coachSpeechUnavailable;
      });
    }
  }

  void _openAttachSheet() {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    _endDictationForSheet();
    // showEatovaSheet takes a ready widget, not a builder. The `Builder` gets
    // a context BELOW the sheet route; with the screen context `pop()` would
    // hit the top route blindly — the home route after a swipe-dismiss.
    showEatovaSheet<void>(
      context,
      Builder(
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _AttachTile(
                  key: const ValueKey('coach-camera'),
                  icon: Icons.photo_camera_outlined,
                  label: sheetContext.l10n.coachAttachCamera,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.camera);
                  },
                ),
                const SizedBox(height: 6),
                _AttachTile(
                  key: const ValueKey('coach-gallery'),
                  icon: Icons.photo_outlined,
                  label: sheetContext.l10n.coachAttachGallery,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSessionsSheet() {
    HapticFeedback.selectionClick();
    showEatovaSheet<void>(
      context,
      // StatefulBuilder so the sheet rebuilds right after a delete: it does
      // not hang on the page's setState.
      StatefulBuilder(
        builder: (sheetContext, setSheetState) => _SessionsSheet(
          sessions: _sessions,
          activeSessionId: _activeSessionId,
          onNew: () async {
            Navigator.of(sheetContext).pop();
            await _startNewSession();
          },
          onSelect: (id) async {
            Navigator.of(sheetContext).pop();
            await _switchToSession(id);
          },
          onDelete: (id) async {
            await _deleteSession(id);
            // _deleteSession already refreshed _sessions — redraw the sheet.
            if (sheetContext.mounted) setSheetState(() {});
          },
        ),
      ),
    );
  }

  /// (i) sheet: AI disclosure (C8) plus daily quota. Reachable from the header
  /// (i), the empty-state hint and the quota hint.
  void _openCoachInfoSheet() {
    HapticFeedback.selectionClick();
    final quota = _quota;
    showEatovaSheet<void>(
      context,
      // Only a real snapshot may show numbers: [_restFuerAnzeige] would put
      // the default limit here after a failed quota RPC.
      quota == null
          ? const _CoachInfoSheetUnbekannt()
          : _CoachInfoSheet(
              remaining: quota.remaining.clamp(0, quota.dailyLimit),
              dailyLimit: quota.dailyLimit,
            ),
    );
  }

  /// Marks the messages appended since the last build for a one-time
  /// entrance. A load (the first list after loading, or a replaced list)
  /// marks nothing, and neither does an answer whose streamed preview was
  /// already on screen: it takes the preview's place without a second
  /// entrance.
  void _merkeNeueNachrichten() {
    final ids = [for (final message in _messages) message.id];
    final vorher = _gerenderteIds;
    final angehaengt =
        !_warAmLaden &&
        !_loading &&
        ids.length > vorher.length &&
        listEquals(ids.sublist(0, vorher.length), vorher);
    if (angehaengt) {
      for (final message in _messages.skip(vorher.length)) {
        if (message.role == ChatRole.assistant && _vorschauGezeigt) continue;
        _einblenden.add(message.id);
      }
    }
    _gerenderteIds = ids;
    _warAmLaden = _loading;
  }

  @override
  Widget build(BuildContext context) {
    // No hero when the history merely failed to load (S3): the empty state
    // would claim "no conversation yet". Empty conversation + banner instead.
    final isHero = !_loading && _messages.isEmpty && !_historyUnavailable;
    _merkeNeueNachrichten();
    // Every state change that can end a wait rebuilds, so this one place
    // covers the reply, the bootstrap and a session load alike.
    _openQueuedBriefWhenFree();
    return LayoutBuilder(
      builder: (context, constraints) {
        // The floating tab bar's band (from the shell). The composer's own
        // SafeArea sits it on the band, so the header decides on the height
        // that is really left.
        final navInset = MediaQuery.paddingOf(context).bottom;
        // Use the shell's available space, including keyboard and navigation.
        // Secondary header details must not consume the command picker viewport.
        // The tab owns its gutters (20 px sides, the shared title origin on
        // top), so they come off here too.
        final topInset = TabChrome.topInset(context);
        final compactHeader = _CoachTopBar.needsCompactLayout(
          context,
          BoxConstraints(
            maxWidth: math.max(0, constraints.maxWidth - 2 * _kShellInset),
            maxHeight: math.max(
              0,
              constraints.maxHeight - navInset - topInset,
            ),
          ),
        );
        return Column(
          key: const ValueKey('screen-coach'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No divider: the content below fades out under the header,
            // which starts at the title origin shared by every tab.
            Padding(
              padding: EdgeInsets.fromLTRB(
                _kShellInset,
                topInset,
                _kShellInset,
                0,
              ),
              child: _CoachTopBar(
                key: TabChrome.headerKey,
                compact: compactHeader,
                contextShared: widget.userContext != null,
                onInfoTap: _openCoachInfoSheet,
                onSessionsTap: _openSessionsSheet,
              ),
            ),
            Expanded(
              child: _CoachConversationArea(
                feedback: _fehlgeschlagen != null || _error != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_fehlgeschlagen != null)
                            _UnsentNotice(
                              canRetry: _canInteract,
                              onRetry: _wiederholen,
                            ),
                          if (_error != null) _ErrorBanner(text: _error!),
                        ],
                      )
                    : null,
                conversation: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // The answer cue of [_announceAnswer]: a new key per
                    // answer makes a new node. Behind everything, outside the
                    // lazy list (an answer below the fold still speaks) and
                    // never focusable, so it only talks.
                    if (_answerCue != null)
                      Positioned.fill(
                        key: ValueKey<String>('coach-answer-cue-$_answerCue'),
                        child: Semantics(
                          container: true,
                          liveRegion: true,
                          accessibilityFocusBlockType:
                              AccessibilityFocusBlockType.blockNode,
                          label: context.l10n.coachAnswerAnnouncement,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    AnimatedSwitcher(
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 220),
                      ),
                      child: _loading
                          ? const Center(
                              key: ValueKey('coach-loading'),
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                // Color comes from progressIndicatorTheme (t.accent).
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : isHero
                          ? _CoachHero(
                              name: widget.userName,
                              dayBrief: widget.dayBrief,
                              canAsk: _canInteract,
                              onAsk: _sendPrepared,
                              onCommand: _applyCommand,
                              onDisclosureTap: _openCoachInfoSheet,
                            )
                          : _Conversation(
                              controller: _scroll,
                              focus: _inputFocus,
                              messages: _messages,
                              sending: _sendingInActiveSession,
                              preview: _streamVorschau,
                              recipeAddedFor: _isRecipeAdded,
                              // Card buttons stay disabled without a hook
                              // (preview/test) and while an add is running.
                              recipeAddEnabled:
                                  widget.onCreateRecipe != null &&
                                  !_addingRecipe,
                              onAddRecipe: _addProposalToRecipes,
                              planAddedFor: _isTrainingPlanAdded,
                              planReviewEnabled:
                                  widget.onCreateTrainingPlan != null &&
                                  !_reviewingTrainingPlan,
                              onReviewPlan: _reviewTrainingPlan,
                              workoutLogStatusFor: _workoutLogStatus,
                              workoutLogAddable: widget.onLogWorkout != null,
                              workoutLogAddEnabled: !_reviewingWorkoutLog,
                              onAddWorkoutLog: _reviewWorkoutLog,
                              onScroll: _onChatScroll,
                              onMetricsChanged: _onChatMetrics,
                              entersFor: (message) =>
                                  _einblenden.contains(message.id),
                              onEntered: _einblenden.remove,
                              onOpenTraining: widget.onOpenTraining,
                            ),
                    ),
                    // Soft edges instead of hard cuts: content fades out under
                    // the header and above the composer, like the design's
                    // page fade. Decoration only, taps pass through. Not at
                    // the top of the start state: there the orb's halo runs
                    // up behind the header as in the design.
                    if (!isHero)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: _EdgeFade(height: 20, top: true),
                      ),
                    const Align(
                      alignment: Alignment.bottomCenter,
                      child: _EdgeFade(height: 16, top: false),
                    ),
                    ValueListenableBuilder<String>(
                      valueListenable: _draft,
                      builder: (context, draft, _) =>
                          _commandMenuVisibleFor(draft)
                          ? Align(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: _kShellInset,
                                ),
                                child: _CommandSuggestions(
                                  draft: draft,
                                  onPick: _applyCommand,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
            // Only the draft's two consumers rebuild per keystroke; the
            // conversation above stays untouched (perf finding 3, 2026-08-31).
            ValueListenableBuilder<String>(
              valueListenable: _draft,
              builder: (context, draft, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  _Composer(
                    controller: _input,
                    focus: _inputFocus,
                    enabled: _canType,
                    canSend: _canInteract,
                    // Display value, not a state: an unknown quota shows the
                    // default limit so the composer claims neither exhausted nor
                    // a count.
                    remaining: _restFuerAnzeige,
                    draft: draft,
                    listening: _listening,
                    dictationLanguage: _listeningLanguage,
                    onSubmit: () => _send(),
                    onMic: _toggleSpeechInput,
                    onDictationLanguage: _switchDictationLanguage,
                    onAttach: _openAttachSheet,
                    onQuotaTap: _openCoachInfoSheet,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A strip that blends scrolled content into the page background at the top
/// or bottom edge of the conversation area.
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.height, required this.top});

  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) {
    final bg = context.t.bg;
    final clear = bg.withValues(alpha: 0);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: top ? [bg, clear] : [clear, bg],
            ),
          ),
        ),
      ),
    );
  }
}

/// Feedback shares the remaining viewport with the conversation. Long errors
/// stay scrollable without displacing the composer above an open keyboard.
class _CoachConversationArea extends StatelessWidget {
  const _CoachConversationArea({required this.conversation, this.feedback});

  final Widget conversation;
  final Widget? feedback;

  // The boundary matters because of the LayoutBuilder: every rebuild below it
  // (orb breath, thinking dots, each streamed token) relayouts it, and a
  // relayout repaints up to the nearest boundary. Without one that was the
  // whole tab, header and composer included, on every animation frame.
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: conversation),
          if (feedback != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .6,
              ),
              child: SingleChildScrollView(
                key: const ValueKey('coach-feedback-scroll'),
                padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
                child: feedback,
              ),
            ),
        ],
      ),
    ),
  );
}

/// What a proposal request hands [_CoachChatScreenState._sendProposalRequest]:
/// the finished answer bubble plus the session and quota the server named.
typedef _ProposalAnswer = ({
  ChatMessage answer,
  String sessionId,
  int? remaining,
  int? dailyLimit,
});

/// A send attempt that never reached the server — marker and retry job.
///
/// Holds everything the second attempt needs instead of reconstructing it from
/// the input field: [text] is the displayed text, [imageBytes] the already
/// scrubbed image. Keeps the retry bit-identical and free of a second
/// compression/EXIF scrub.
class _FehlgeschlageneSendung {
  const _FehlgeschlageneSendung({
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

/// "Not sent" under the history, with the retry button next to it.
///
/// Right-aligned like the user bubbles: the error belongs to the user's own
/// message, which would otherwise look delivered. The button disappears
/// instead of sitting disabled when nothing can be sent (request in flight,
/// quota exhausted); the marker stays in both cases.
class _UnsentNotice extends StatelessWidget {
  const _UnsentNotice({required this.canRetry, required this.onRetry});

  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      key: const ValueKey('coach-unsent'),
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 13, color: t.warning),
          const SizedBox(width: 5),
          Flexible(
            // Appears without focus moving: a live region, so a screen
            // reader learns the question did not go out.
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                l10n.coachMessageNotSent,
                style: AppType.ui(
                  11.5,
                  weight: FontWeight.w600,
                  color: t.warning,
                ),
              ),
            ),
          ),
          if (canRetry) ...<Widget>[
            const SizedBox(width: 6),
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(rPill),
              child: InkWell(
                key: const ValueKey('coach-unsent-retry'),
                onTap: onRetry,
                borderRadius: BorderRadius.circular(rPill),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.refresh_rounded, size: 14, color: t.accent),
                      const SizedBox(width: 5),
                      Text(
                        l10n.coachMessageRetry,
                        style: AppType.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: t.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// (i) sheet for "daily quota unknown" — twin of [_CoachInfoSheet] without its
/// number part.
///
/// [_CoachInfoSheet] takes two `int` and would show the default limit after a
/// failed quota RPC, i.e. claim a full quota exactly when the app knows
/// nothing. Hence a number-free line and NO bar: an empty bar reads as spent,
/// a full one as free, and both would be a claim.
///
/// The C8 disclosure part is deliberately identical to the twin and uses the
/// same l10n keys. Merging them needs a nullable snapshot in
/// [_CoachInfoSheet]'s signature (a change in `coach_composer.dart`) and is
/// still open. Until then `test/coach_ai_disclosure_test.dart` checks BOTH
/// versions against the same key list, so an unmirrored edit turns red.
class _CoachInfoSheetUnbekannt extends StatelessWidget {
  const _CoachInfoSheetUnbekannt();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.coachTitle,
                style: AppType.display(
                  20,
                  weight: FontWeight.w700,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoIntro,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoDataLabel),
              const SizedBox(height: 8),
              _InfoBullet(l10n.coachInfoBulletWeight),
              _InfoBullet(l10n.coachInfoBulletMacros),
              _InfoBullet(l10n.coachInfoBulletMeals),
              const SizedBox(height: 12),
              Text(
                l10n.coachInfoProvider,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: t.line),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoLimitLabel),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoLimitUnknown,
                key: const ValueKey('coach-info-limit-unbekannt'),
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
