/// Coach tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility
/// and [CoachChatScreen] stays the entry point. The iOS MethodChannel
/// `eatova/speech` lives in coach_speech.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../models/coach_recipe_proposal.dart';
import '../../models/fitness_recipe.dart';
import '../../services/coach_chat_service.dart';
import '../../services/meal_photo_compressor.dart';
import '../../services/meal_photo_temp_file.dart';
import '../../services/recipe_image_store.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../today/today_texts.dart' show greetingForHour;

part 'coach_speech.dart';
part 'coach_top_bar.dart';
part 'coach_hero.dart';
part 'coach_orb.dart';
part 'coach_message_list.dart';
part 'coach_composer.dart';
part 'coach_recipe.dart';
part 'coach_sessions.dart';

/// Coach chat: Grok-based fitness/nutrition coach.
///
/// Header with state line plus streak/(i)/sessions; empty state is the
/// animated [CoachOrb] with greeting, AI disclosure and suggestions;
/// otherwise message bubbles above the composer capsule.
class CoachChatScreen extends StatefulWidget {
  const CoachChatScreen({
    super.key,
    required this.service,
    this.userName = 'Moritz',
    this.streak = 0,
    this.userContext,
    this.imagePicker,
    this.speechInput = const CoachSpeechInput(),
    this.onCreateRecipe,
    this.userRecipeSlugs = const <String>{},
  });

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

  /// Streak for the pill top left. Callers pass
  /// `lifetimeStats.effectiveStreakOn(now)`, never `currentStreak` directly —
  /// a broken chain would otherwise not show 0.
  final int streak;

  /// Compact snapshot of profile + daily balance handed to the coach as
  /// context so it can advise concretely instead of generically.
  final String? userContext;

  final ImagePicker? imagePicker;
  final CoachSpeechInput speechInput;

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

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
  String? _activeSessionId;
  bool _loading = true;
  bool _listening = false;
  String _draft = '';
  String? _error;

  /// The active session's history failed to load — the hero empty state must
  /// then not present it as "empty".
  bool _historyUnavailable = false;

  /// An add is running (store image + createUserRecipe) — locks all card
  /// buttons until it finishes.
  bool _addingRecipe = false;

  /// How many send jobs (chat or recipe) are in flight.
  ///
  /// Counts per USER, not per session, because the quota does too: a plain
  /// `bool` reset on session switch let two requests run in parallel and burn
  /// two daily slots from one interaction. Only [_sendevorgangBeendet]
  /// decrements, from a `finally` — a discarded answer must free the counter
  /// too, or the composer stays locked forever.
  int _laufendeSendungen = 0;

  bool get _sending => _laufendeSendungen > 0;

  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  /// Only a *known* empty quota blocks. An unknown state (cold start without
  /// network) deliberately does not: the server decides and answers 429.
  bool get _kontingentErschoepft {
    final quota = _quota;
    return quota != null && quota.remaining <= 0;
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
    _input.addListener(() {
      if (_draft != _input.text) setState(() => _draft = _input.text);
    });
    // No service = not logged in; that branch needs a localized error text and
    // `context.l10n` is not allowed in initState — didChangeDependencies does
    // it once before the first frame.
    if (widget.service != null) {
      _bootstrap();
    }
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
    _sichtbar = sichtbar;
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
    await _refreshQuota(svc);
    // The error banner is feedback on an action, not a permanent state.
    if (mounted && _error != null) setState(() => _error = null);
  }

  /// Second trigger for the refresh path: [didChangeDependencies] only fires
  /// on a `TickerMode` edge, i.e. on a tab switch. Backgrounding the app while
  /// the coach tab is already on top produces no edge, so an exhausted quota
  /// would keep the composer locked past midnight. Same guards as the tab
  /// path, so a resume on another tab issues no request.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    final svc = widget.service;
    if (!_sichtbar || svc == null || _loading) return;
    unawaited(_beiRueckkehr(svc));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
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
    final activeId = sessions.isNotEmpty
        ? sessions.first.id
        : await svc.ensureDefaultSession();
    if (activeId == null) {
      if (!mounted) return;
      // After at least one `await`: Localizations is guaranteed to be there.
      setState(() {
        _loading = false;
        _error = context.l10n.coachErrorNoSession;
      });
      return;
    }
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(activeId);
    } on CoachDataUnavailable {
      // "Not loadable" is not "empty": an empty _messages would show the hero
      // state and present the history as deleted.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    _historyUnavailable = false;
    history = await _hydrateProposalImages(history);
    // Unknown stays unknown: the last known state survives instead of being
    // replaced by a guess.
    ChatQuotaSnapshot? quota = _quota;
    try {
      quota = await svc.loadQuotaToday();
    } on CoachDataUnavailable {
      // Intentionally empty — `quota` keeps the known state.
    }
    var refreshedSessions = sessions;
    if (sessions.isEmpty) {
      try {
        refreshedSessions = await svc.loadSessions();
      } on CoachDataUnavailable {
        refreshedSessions = _sessions;
      }
    }
    if (!mounted) return;
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
    final ChatQuotaSnapshot frisch;
    try {
      frisch = await svc.loadQuotaToday();
    } on CoachDataUnavailable {
      return;
    }
    if (mounted) setState(() => _quota = frisch);
  }

  Future<void> _refreshSessions() async {
    final svc = widget.service;
    if (svc == null) return;
    final List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Keep the last known state: an outage must not empty the sessions
      // sheet and claim there are no conversations.
      return;
    }
    if (!mounted) return;
    setState(() => _sessions = sessions);
  }

  /// Switches the displayed conversation.
  ///
  /// Every exit checks `_activeSessionId != sessionId`: the screen stays
  /// mounted, so `mounted` alone would let a slow load of A write its history
  /// (or its error state) into the view while C is on screen.
  Future<void> _switchToSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    if (_activeSessionId == sessionId) return;
    setState(() {
      _loading = true;
      _activeSessionId = sessionId;
      _messages = const <ChatMessage>[];
      // The undelivered question belongs to the session being left; its retry
      // job would otherwise land in the new one.
      _fehlgeschlagen = null;
    });
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      // The error belongs to the session that caused it, or C would carry A's
      // banner and `_historyUnavailable` state.
      if (!mounted || _activeSessionId != sessionId) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    history = await _hydrateProposalImages(history);
    if (!mounted || _activeSessionId != sessionId) return;
    setState(() {
      _messages = history;
      _historyUnavailable = false;
      _loading = false;
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
    final id = await svc.createSession();
    if (id == null) return;
    await _refreshSessions();
    if (!mounted || _activeSessionId != vorher) return;
    setState(() {
      _activeSessionId = id;
      _messages = const <ChatMessage>[];
      _error = null;
      _fehlgeschlagen = null;
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
        duration: kSnackError,
      );
      return;
    }
    final wasActive = _activeSessionId == sessionId;
    await _refreshSessions();
    if (!mounted) return;
    if (wasActive) {
      if (_sessions.isNotEmpty) {
        await _switchToSession(_sessions.first.id);
      } else {
        // Last session deleted: recreate the default AND reload, so list and
        // sheet show the new session instead of being empty.
        final fallback = await svc.ensureDefaultSession();
        if (fallback != null) {
          await _refreshSessions();
          await _switchToSession(fallback);
        }
      }
    }
  }

  void _scrollToEnd() {
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
    final ziel = liste.maxScrollExtent + 240;
    final dauer = motionDuration(context, const Duration(milliseconds: 260));
    // No `animateTo(..., Duration.zero)`: DrivenScrollActivity asserts
    // `duration > Duration.zero`. Reduced motion jumps instead of gliding.
    if (dauer == Duration.zero) {
      liste.jumpTo(ziel.clamp(0.0, liste.maxScrollExtent));
      return;
    }
    liste.animateTo(ziel, duration: dauer, curve: Curves.easeOutCubic);
  }

  Future<void> _send({
    String? textOverride,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async {
    // Grabbed before the first `await`: safe context access.
    final l10n = context.l10n;
    final svc = widget.service;
    final sessionId = _activeSessionId;
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

    // Slash commands (only /recipe), text-only: an attached photo is a normal
    // coach question, not a command. An unknown /-command never reaches the
    // model — that would burn a daily slot on a typo.
    if (!hasImage && text.startsWith('/')) {
      final recipeWish = _recipeWishFrom(text);
      if (recipeWish == null) {
        setState(() => _error = l10n.coachCommandUnknownHint);
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
    final entwurf = _input.text;
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
      _messages = [..._messages, userMsg];
      _input.clear();
      _draft = '';
      _laufendeSendungen++;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    try {
      final res = await svc.send(
        displayText,
        sessionId: sessionId,
        imageBase64: hasImage ? base64Encode(imageBytes) : null,
        imageMimeType: hasImage ? (imageMimeType ?? 'image/jpeg') : null,
        userContext: widget.userContext,
      );
      // The daily slot is spent even if the answer is discarded — hence
      // before the session comparison.
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      // Answer and error belong to the session the question came from;
      // switching stays possible while sending, and `mounted` alone does not
      // cover it because the screen stays mounted.
      if (!mounted || _activeSessionId != sessionId) return;
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            id: 'local-r-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.assistant,
            content: res.reply,
            createdAt: DateTime.now(),
            refusal: res.refusal,
          ),
        ];
      });
      HapticFeedback.lightImpact();
      // Refresh sessions in the background so auto title / last_message_at are
      // current in the sheet without blocking the send flow.
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted) return;
      // The server named the limit explicitly, so this replaces any prior
      // state regardless of the open session: the limit is per user.
      setState(() {
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (_activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      // Marked here too: the slot was gone, the question did not go out. The
      // retry button hangs on [_canInteract] and stays off, but the marker
      // remains — otherwise the bubble would look sent.
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!mounted || _activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      // On EVERY exit, including the `return`s that discard the answer after
      // a session switch — otherwise the composer locks until cold start.
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  /// Takes over a quota state the server just named.
  ///
  /// Called before the session comparison on purpose: the quota is per user,
  /// so a discarded answer still spent the slot. Older function deployments
  /// send no limit and fall back to the current display value.
  void _quotaUebernehmen({required int? remaining, required int? dailyLimit}) {
    if (remaining == null || !mounted) return;
    final limit = dailyLimit ?? _limitFuerAnzeige;
    final frei = remaining.clamp(0, limit);
    setState(() {
      _quota = ChatQuotaSnapshot(
        used: limit - frei,
        remaining: frei,
        dailyLimit: limit,
      );
    });
  }

  /// Counterpart to `_laufendeSendungen++`; belongs in a `finally` so every
  /// exit counts. After unmount only the bookkeeping runs, no setState.
  void _sendevorgangBeendet() {
    final rest = math.max(0, _laufendeSendungen - 1);
    if (!mounted) {
      _laufendeSendungen = rest;
      return;
    }
    setState(() => _laufendeSendungen = rest);
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
    // The restored draft belongs to this message and is consumed by the
    // retry. A newly typed text must survive: [_send] always clears the field,
    // even with `textOverride`.
    final fremderEntwurf =
        _input.text.trim() == auftrag.text.trim() ? '' : _input.text;
    setState(() {
      _messages = _messages
          .where((m) => m.id != auftrag.messageId)
          .toList(growable: false);
      _fehlgeschlagen = null;
      _error = null;
    });
    await _send(
      textOverride: auftrag.text,
      imageBytes: auftrag.imageBytes,
      imageMimeType: auftrag.imageMimeType,
    );
    if (mounted) _entwurfZurueck(fremderEntwurf);
  }

  /// Puts the typed text back into the field after a failure — it was never
  /// sent. A newly typed draft wins: typing is allowed while an answer is in
  /// flight ([_canType]), and overwriting it would be worse.
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

  /// The command menu shows while the draft looks like a started command:
  /// starts with "/", no whitespace yet, and is a prefix of "/recipe".
  bool get _commandMenuVisible {
    final draft = _draft.trimLeft();
    if (!draft.startsWith('/')) return false;
    if (draft.contains(' ') || draft.contains('\n')) return false;
    return '/recipe'.startsWith(draft.toLowerCase());
  }

  /// Tap on a menu entry: command plus separating space into the field,
  /// cursor at the end.
  void _applyCommand(String command) {
    HapticFeedback.selectionClick();
    _input.text = '$command ';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _inputFocus.requestFocus();
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
    for (var i = 0; i < result.length; i++) {
      final message = result[i];
      final proposal = message.recipeProposal;
      if (proposal == null || proposal.imageBytes != null) continue;
      final bytes = await RecipeImageStore.instance.readProposalImage(
        message.id,
      );
      if (bytes == null) continue;
      result[i] = ChatMessage(
        id: message.id,
        role: message.role,
        content: message.content,
        createdAt: message.createdAt,
        refusal: message.refusal,
        recipeProposal: proposal.withImageBytes(bytes),
      );
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
    HapticFeedback.selectionClick();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    final entwurf = _input.text;
    // As in [_send]: [displayText] carries the command, so a retry lands in
    // this branch again by itself.
    final auftrag = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
    );
    setState(() {
      _messages = [..._messages, userMsg];
      _input.clear();
      _draft = '';
      _laufendeSendungen++;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    try {
      final res = await svc.requestRecipe(
        wish,
        sessionId: sessionId,
        locale: l10n.localeName,
        userContext: widget.userContext,
      );
      // As in [_send]: the slot is spent even if the card is discarded.
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      // Session comparison as in [_send]: the card belongs to the session the
      // wish came from.
      if (!mounted || _activeSessionId != sessionId) return;
      // Store the image under the SERVER message id, so history reconstruction
      // and the live card use the same key.
      final serverId = res.assistantMessageId;
      final imageBytes = res.proposal?.imageBytes;
      if (serverId != null && imageBytes != null) {
        unawaited(
          RecipeImageStore.instance.saveProposalImage(
            messageId: serverId,
            bytes: imageBytes,
          ),
        );
      }
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            id: serverId ?? 'local-r-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.assistant,
            content: res.reply,
            createdAt: DateTime.now(),
            refusal: res.refusal,
            recipeProposal: res.proposal,
          ),
        ];
      });
      HapticFeedback.lightImpact();
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted) return;
      // As in [_send]: the limit is per user, not per session.
      setState(() {
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (_activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!mounted || _activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
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
    final confirmed = await showEatovaSheet<bool>(
      context,
      _RecipeAddSheet(proposal: proposal),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _addingRecipe = true);
    var imageAsset = '';
    final bytes = proposal.imageBytes;
    if (bytes != null) {
      final referenz = await RecipeImageStore.instance.save(bytes: bytes);
      if (!mounted) return;
      if (referenz == null) {
        // As in the manual form: the recipe is created anyway, just without
        // an image, and the user is told.
        showAppSnack(
          context,
          context.l10n.recipesPhotoSaveFailedError,
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
        );
      } else {
        imageAsset = referenz;
      }
    }

    final recipe = proposal.toFitnessRecipe(
      imageAsset: imageAsset,
      slug: FitnessRecipe.coachProposalSlug(message.id),
    );
    // Gap-E pattern (recipes_screen): the message waits for the outcome
    // instead of asserting it; the store caps the wait.
    final ausgang = await onCreate(recipe);
    if (!mounted) return;
    setState(() {
      _addingRecipe = false;
    });
    HapticFeedback.lightImpact();
    showAppSnack(
      context,
      deliveryHint(
        context.l10n.recipesSavedSuccess(recipe.title),
        ausgang,
        context.l10n,
      ),
      icon: Icons.bookmark_added_rounded,
    );
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
      final raw = await image.readAsBytes();
      final bytes = await _scrubImage(raw);
      if (!mounted) return;
      if (bytes.lengthInBytes > _maxImageBytes) {
        setState(() => _error = l10n.coachErrorImageTooLarge);
        return;
      }
      await _send(
        textOverride: _input.text.trim().isEmpty
            ? l10n.coachImageDefaultCaption
            : _input.text.trim(),
        imageBytes: bytes,
        imageMimeType: _mimeForBytes(bytes, image),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = _permissionMessageFor(source, e, l10n));
    } catch (e) {
      if (!mounted) return;
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

  Future<void> _toggleSpeechInput() async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    if (_listening) {
      await widget.speechInput.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    // Grabbed before the first `await`: safe context access.
    final l10n = context.l10n;
    setState(() {
      _listening = true;
      _error = null;
    });
    try {
      // Dictation locale follows the app language: 'en' -> 'en_US', anything
      // else falls back to 'de_DE'.
      final speechLocaleId = l10n.localeName == 'en' ? 'en_US' : 'de_DE';
      final spokenText = await widget.speechInput.listen(
        localeId: speechLocaleId,
        l10n: l10n,
      );
      if (!mounted) return;
      setState(() => _listening = false);
      final text = spokenText?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = l10n.coachErrorSpeechEmpty);
        return;
      }
      _input.text = text;
      await _send(textOverride: text);
    } on CoachSpeechException catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = l10n.coachSpeechUnavailable;
      });
    }
  }

  void _openAttachSheet() {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
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
            if (mounted) setSheetState(() {});
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

  @override
  Widget build(BuildContext context) {
    // No hero when the history merely failed to load (S3): the empty state
    // would claim "no conversation yet". Empty conversation + banner instead.
    final isHero = !_loading && _messages.isEmpty && !_historyUnavailable;
    return Column(
      key: const ValueKey('screen-coach'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The header brings its own spacing (divider + 14 px).
        _CoachTopBar(
          streak: widget.streak,
          onInfoTap: _openCoachInfoSheet,
          onSessionsTap: _openSessionsSheet,
        ),
        Expanded(
          child: AnimatedSwitcher(
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : isHero
                ? _CoachHero(
                    name: widget.userName,
                    onDisclosureTap: _openCoachInfoSheet,
                  )
                : _Conversation(
                    controller: _scroll,
                    focus: _inputFocus,
                    messages: _messages,
                    sending: _sending,
                    recipeAddedFor: _isRecipeAdded,
                    // Card buttons stay disabled without a hook
                    // (preview/test) and while an add is running.
                    recipeAddEnabled:
                        widget.onCreateRecipe != null && !_addingRecipe,
                    onAddRecipe: _addProposalToRecipes,
                  ),
          ),
        ),
        // Right under the history, next to the bubble it refers to: the failed
        // question is the last one.
        if (_fehlgeschlagen != null)
          _UnsentNotice(canRetry: _canInteract, onRetry: _wiederholen),
        if (_error != null) _ErrorBanner(text: _error!),
        // Command menu: appears above the composer when typing "/"; a tap
        // completes the command.
        if (_commandMenuVisible) _CommandSuggestions(onPick: _applyCommand),
        const SizedBox(height: 8),
        _Composer(
          controller: _input,
          focus: _inputFocus,
          enabled: _canType,
          canSend: _canInteract,
          // Display value, not a state: an unknown quota shows the default
          // limit so the composer claims neither exhausted nor a count.
          remaining: _restFuerAnzeige,
          draft: _draft,
          listening: _listening,
          onSubmit: () => _send(),
          onMic: _toggleSpeechInput,
          onAttach: _openAttachSheet,
          onQuotaTap: _openCoachInfoSheet,
        ),
      ],
    );
  }
}

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
  });

  /// Id of the bubble in the history; the retry removes exactly this one, so
  /// no duplicate appears.
  final String messageId;

  final String text;
  final Uint8List? imageBytes;
  final String? imageMimeType;
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
            child: Text(
              l10n.coachMessageNotSent,
              style: AppType.ui(
                11.5,
                weight: FontWeight.w600,
                color: t.warning,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                style:
                    AppType.display(20, weight: FontWeight.w700, color: t.ink),
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
