/// Coach tab — a library assembled from the `part` files below.
///
/// Mechanical split only; library-private `_` classes keep their visibility
/// and [CoachChatScreen] stays the entry point. The Coach's adapter over the
/// shared `eatova/speech` channel (services/speech_input.dart) lives in
/// coach_speech.dart.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/semantics.dart'
    show AccessibilityFocusBlockType, CustomSemanticsAction, SemanticsService;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/ai_consent.dart' show AiReportTarget;
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
import '../../models/user_profile.dart' show FoodPreferences;
import '../../services/coach_chat_service.dart';
import '../../services/coach_quota_reset.dart';
import '../../services/dictation_language.dart';
import '../../services/kcal_format.dart';
import '../../services/local_day.dart';
import '../../services/meal_photo_compressor.dart';
import '../../services/meal_photo_temp_file.dart';
import '../../services/screen_awake.dart';
import '../../services/speech_input.dart';
import '../../services/sync_error_messages.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart' show MealSlotStyle;
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/common/text_length_limit.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_photo.dart' show RecipeArt;
import '../../widgets/recipes/recipe_sections.dart';
import '../../widgets/shared/ai_consent_sheet.dart';
import '../../widgets/shared/ai_report_sheet.dart';
import '../today/today_texts.dart' show greetingForHour;
import '../training/training_log_editor.dart';
import '../training/training_plan_editor.dart';
import 'coach_chat_controller.dart';
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
    this.recipePreferences,
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
    this.onDescribeMeal,
    this.onOpenRecipe,
    this.questionDraftRequest = 0,
    this.questionDraft = '',
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

  /// `/meal` (2026-10-22): opens the describe sheet for today, prefilled
  /// with the text ('' opens it empty), and returns true once a meal was
  /// added there. No coach request; the sheet's Add is the confirmation.
  /// null: the command does nothing (previews, signed out).
  final Future<bool> Function(String text)? onDescribeMeal;

  /// "Open" on the toast of a saved /recipe proposal; null shows none.
  final ValueChanged<FitnessRecipe>? onOpenRecipe;

  /// Increment to put [questionDraft] into the composer, unsent: a prepared
  /// question from another tab (the weekly result card, Trends). Sending it
  /// stays the user's tap, so it costs a question only then.
  final int questionDraftRequest;
  final String questionDraft;

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

  /// Diet, avoided foods and dislikes for /recipe (C3): the only profile data
  /// a recipe request carries, as its own narrow field. Null sends none.
  final FoodPreferences? recipePreferences;

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

  /// Sessions, history, sending, the answer wait, the quota and the banner
  /// (see [CoachChatController]).
  late final CoachChatController _coach;

  bool _listening = false;

  /// Current recording; also its native token. Drawn from [_speechSeq].
  int _speechGeneration = 0;

  /// Draft text as a [ValueNotifier], deliberately NOT screen state: its only
  /// consumers are the composer and the command menu, and a per-keystroke
  /// `setState` rebuilt the whole screen including every visible bubble (perf
  /// finding 3, 2026-08-31). The send paths read `_input.text` directly.
  final ValueNotifier<String> _draft = ValueNotifier<String>('');

  bool _reviewingTrainingPlan = false;
  bool _reviewingWorkoutLog = false;
  bool _briefingTrainingPlan = false;
  ValueNotifier<bool>? _briefIsActive;

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

  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  @override
  void initState() {
    super.initState();
    _coach = CoachChatController(
      service: widget.service,
      hooks: _CoachScreenHooks(this),
      // Read when a request starts, so it follows the current widget.
      requestInputs: () => CoachRequestInputs(
        userContext: widget.userContext,
        recipePreferences: widget.recipePreferences,
        recipeTargetLine: switch (widget.dayBrief) {
          final brief? when mounted => coachRecipeTargetLine(
            brief,
            context.l10n,
          ),
          _ => null,
        },
      ),
      inBackground: () => switch (WidgetsBinding.instance.lifecycleState) {
        AppLifecycleState.paused ||
        AppLifecycleState.hidden ||
        AppLifecycleState.detached => true,
        _ => false,
      },
    );
    WidgetsBinding.instance.addObserver(this);
    // ValueNotifier dedupes identical assignments, so no equality check here.
    _input.addListener(() => _draft.value = _input.text);
    _loadDictationLanguage();
    // No service = not logged in; that branch needs a localized error text and
    // `context.l10n` is not allowed in initState — didChangeDependencies does
    // it once before the first frame.
    if (widget.service != null) {
      _coach.bootstrap();
    }
    if (widget.planDraftRequest > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openTrainingBrief(selectedPlan: widget.selectedPlanForCoach);
      });
    }
    if (widget.logDraftRequest > 0) _prepareLogDraft();
    if (widget.questionDraftRequest > 0) _prepareQuestionDraft();
  }

  @override
  void didUpdateWidget(covariant CoachChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.service, oldWidget.service)) {
      // The old account's answer wait ends there; its results are fenced out.
      _coach.updateService(widget.service);
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
    if (widget.questionDraftRequest != oldWidget.questionDraftRequest) {
      _prepareQuestionDraft();
    }
  }

  /// After the frame, like [_prepareLogDraft]: [CoachChatScreen.questionDraft]
  /// goes into the composer, unsent. An own draft stays behind it; one that
  /// would no longer fit the input cap is left alone.
  void _prepareQuestionDraft() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final question = widget.questionDraft.trim();
      if (!mounted || question.isEmpty || _listening) return;
      final draft = _input.text.trim();
      final text = RegExp(r'^(/\S*)?$').hasMatch(draft)
          ? question
          : draft.startsWith(question)
          ? draft
          : '$question $draft';
      if (!_coachInputLimit.fits(text)) return;
      _setDraft(text);
      _inputFocus.requestFocus();
    });
  }

  /// After the frame: the request arrives during a build. The user asked from
  /// Training and never saw the composer, so an unsent draft is kept: the
  /// command goes in front of it, the cursor right after the command.
  void _prepareLogDraft() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final draft = _input.text;
      final command = _CoachCommand.log.token;
      // Empty or a bare command ("/re", "/recipe "): nothing worth keeping.
      // A running dictation keeps its words through the command's own path.
      if (_listening || RegExp(r'^(/\S*)?$').hasMatch(draft.trim())) {
        _applyCommand(command);
        return;
      }
      final isLog = CoachChatController.workoutLogWishFrom(draft) != null;
      final text = isLog ? draft : '$command ${draft.trimLeft()}';
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: isLog ? text.length : command.length + 1,
        ),
      );
      _inputFocus.requestFocus();
    });
  }

  /// Whether the tab is visible, tracked via `TickerMode`: this screen lives
  /// in an `IndexedStack` and stays mounted, so the bootstrap runs once per
  /// app run and a stale quota, error banner or failed session would persist
  /// until cold start. A flip to `true` triggers
  /// [CoachChatController.returnToChat].
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
    // The controller's banner texts follow the app language.
    _coach.l10n = context.l10n;
    if (widget.service == null && !_notEingeloggtGemeldet) {
      _notEingeloggtGemeldet = true;
      _coach.reportSignedOut();
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
    if (!wurdeSichtbar || svc == null || _coach.loading) return;
    // After the frame: the return notifies, and this runs mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_coach.returnToChat(svc));
    });
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
      _coach.appPaused();
      if (_listening) setState(_cancelSpeechInput);
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    _coach.appResumed();
    final svc = widget.service;
    if (!_sichtbar || svc == null || _coach.loading) return;
    unawaited(_coach.returnToChat(svc));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Ends the answer wait too.
    _coach.dispose();
    _briefIsActive?.value = false;
    _answerCueTimer?.cancel();
    _cancelSpeechInput();
    _input.dispose();
    _draft.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _startNewSession() async {
    final svc = widget.service;
    if (svc == null) return;
    HapticFeedback.selectionClick();
    final l10n = context.l10n;
    final created = await _coach.startNewSession();
    // The sheet has closed; without this the tap simply did nothing.
    if (!created && mounted && identical(widget.service, svc)) {
      showAppSnack(
        context,
        l10n.coachErrorNewSessionFailed,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
    }
  }

  Future<void> _deleteSession(String sessionId) async {
    if (widget.service == null) return;
    final deleted = await _coach.deleteSession(sessionId);
    // S8: the snack sits above the still-open sessions sheet.
    if (deleted || !mounted) return;
    showAppSnack(
      context,
      context.l10n.coachErrorDeleteFailed,
      icon: Icons.error_outline_rounded,
      tone: SnackTone.error,
      duration: kSnackError,
    );
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

  /// "Report answer" / "Report picture" (2026-10-19): the message id, the
  /// conversation and a reason, never the text. The session lets the
  /// operator find an answer the device still holds under a local id.
  void _report(ChatMessage message, AiReportTarget target) {
    _endDictationForSheet();
    _inputFocus.unfocus();
    unawaited(
      reportAiOutput(
        context,
        messageId: message.id,
        sessionId: _coach.activeSessionId,
        target: target,
      ),
    );
  }

  /// The AI consent before anything leaves for coach-chat (2026-10-19): at
  /// once when it is known, through the consent sheet otherwise. False means
  /// the request must not go out.
  Future<bool> _aiConsentFirst() async {
    if (aiConsentSettled(context)) return true;
    final granted = await ensureAiConsent(context);
    return granted && mounted;
  }

  /// Every send of the screen: the composer, a prepared question, a retry, a
  /// brief or a photo. A running dictation goes first; the controller does
  /// the rest, and clears the composer before its first await.
  ///
  /// Nothing passes without the AI consent. Callers that put a draft back
  /// after the send ask first ([_aiConsentFirst]), so with a known consent
  /// this stays synchronous up to the controller's clear.
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
    if (!aiConsentSettled(context) && !await _aiConsentFirst()) return;
    await _coach.send(
      textOverride ?? _input.text,
      imageBytes: imageBytes,
      imageMimeType: imageMimeType,
      trainingContext: trainingContext,
    );
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

  /// Retries the last undelivered question: the same bubble, text and image
  /// go out again ([CoachChatController.withdrawFailedSend]).
  Future<void> _wiederholen() async {
    if (_coach.failedSend == null || !_coach.canInteract) return;
    // Before the withdrawal: a declined consent keeps the unsent marker.
    if (!await _aiConsentFirst()) return;
    final auftrag = _coach.failedSend;
    if (auftrag == null || !_coach.canInteract) return;
    // A newly typed text must survive: [_send] always clears the field, even
    // with `textOverride`. The failed question itself typed again is consumed
    // by the retry, not restored.
    final fremderEntwurf = _input.text.trim() == auftrag.text.trim()
        ? ''
        : _input.text;
    _coach.withdrawFailedSend();
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

  /// Restores a draft a send had to clear. A failed question is NOT put back
  /// here — the unsent marker is its single home, or the send button would
  /// create a duplicate next to the retry. The one exception is a request
  /// the server cannot take ([CoachRequestUnsupported]): it gets no marker.
  void _entwurfZurueck(String entwurf) {
    if (entwurf.isEmpty || _input.text.isNotEmpty) return;
    _input.text = entwurf;
    _input.selection = TextSelection.collapsed(offset: entwurf.length);
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
    if (!_coach.canInteract) return;
    if (!await _aiConsentFirst() || !_coach.canInteract) return;
    final entwurf = _input.text;
    final versand = _send(textOverride: prompt);
    if (mounted) _entwurfZurueck(entwurf);
    await versand;
  }

  /// Plan discovery opens a brief and meal discovery the describe sheet;
  /// recipe and log discovery prepare the composer.
  void _applyCommand(String command) {
    if (command == _CoachCommand.plan.token) {
      unawaited(_openTrainingBrief());
      return;
    }
    if (command == _CoachCommand.meal.token) {
      // A typed `/meal …` draft goes into the sheet, like `/plan …` into
      // the brief; the bare token from the menu opens it empty.
      unawaited(
        _openMealDescribe(CoachChatController.mealTextFrom(_input.text) ?? ''),
      );
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

  /// The describe sheet is open; a second /meal waits for it to close.
  bool _describingMeal = false;

  /// `/meal` (2026-10-22): the describe sheet, prefilled with [text], without
  /// a coach request ([CoachChatScreen.onDescribeMeal]). Its Add logs the
  /// meal; only then does the composer empty, so a closed sheet loses no
  /// typing.
  Future<void> _openMealDescribe(String text) async {
    final open = widget.onDescribeMeal;
    if (open == null || _describingMeal) return;
    HapticFeedback.selectionClick();
    _endDictationForSheet();
    _inputFocus.unfocus();
    final draft = _input.text;
    _describingMeal = true;
    try {
      final added = await open(text);
      // Only the /meal draft that went into the sheet goes; text typed
      // since then stays.
      if (added &&
          mounted &&
          _input.text == draft &&
          CoachChatController.mealTextFrom(draft) != null) {
        _input.clear();
      }
    } finally {
      _describingMeal = false;
    }
  }

  Future<void> _openTrainingBrief({
    TrainingPlan? selectedPlan,
    bool sessionRetried = false,
  }) async {
    if (_briefingTrainingPlan) return;
    // A running request or a loading chat is a wait, not a refusal.
    if (_coach.sending || _coach.loading) {
      _queuedBrief = (
        selectedPlan: selectedPlan,
        sessionRetried: sessionRetried,
      );
      return;
    }
    // No session yet (an offline first visit): load it once more, as a tab
    // return would, before giving up on the brief.
    if (widget.service != null &&
        _coach.activeSessionId == null &&
        !sessionRetried) {
      _queuedBrief = (selectedPlan: selectedPlan, sessionRetried: true);
      unawaited(_coach.bootstrap());
      return;
    }
    // Nothing could be sent from the brief: say why up front instead of
    // after the whole form is filled in.
    final locked = _coach.lockReason;
    if (locked != null) {
      _coach.showError(locked);
      return;
    }
    // The consent comes before the form, so a decline loses no typing.
    _briefingTrainingPlan = true;
    final bool consented;
    try {
      consented = await _aiConsentFirst();
    } finally {
      _briefingTrainingPlan = false;
    }
    if (!consented || !mounted) return;
    final service = widget.service;
    final revision = _coach.accountRevision;
    final session = _coach.activeSessionId;
    bool sourceIsCurrent() => mounted &&
        identical(widget.service, service) &&
        _coach.accountRevision == revision &&
        (session == null || _coach.activeSessionId == session) &&
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
        initialWish: CoachChatController.planWishFrom(_input.text) ?? '',
        canSubmit: () => sourceIsCurrent() && _coach.canInteract,
        isActive: active,
      );
    } finally {
      // Released with the sheet, not the request: a brief asked for while
      // the plan generates is queued instead of dropped.
      _briefingTrainingPlan = false;
      if (identical(_briefIsActive, active)) _briefIsActive = null;
      active.dispose();
    }
    if (submitted == null || !sourceIsCurrent() || !_coach.canInteract) return;
    // Only this explicit submission can consume a request. Keep the snapshot
    // on its retry job, never implicitly attach it to later ordinary chat.
    // A typed `/plan` draft went into the brief; any other draft survives
    // the send, as with a prepared question.
    final draft = _input.text;
    final versand = _send(
      textOverride: '/plan ${submitted.wish}',
      trainingContext: submitted.context,
    );
    if (mounted && CoachChatController.planWishFrom(draft) == null) {
      _entwurfZurueck(draft);
    }
    await versand;
  }

  /// Opens a brief that waited for a request or a load ([_queuedBrief]).
  /// Never on top of another sheet or page: it stays queued, and the
  /// rebuild when that route closes opens it.
  void _openQueuedBriefWhenFree() {
    if (_queuedBrief == null ||
        _queuedBriefScheduled ||
        _coach.sending ||
        _coach.loading ||
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
    final sessionId = _coach.activeSessionId;
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
        _coach.activeSessionId == sessionId &&
        _coach.messages.any(
          (current) =>
              current.id == message.id &&
              identical(current.trainingPlanProposal, proposal),
        );
    HapticFeedback.selectionClick();
    _endDictationForSheet();
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
    final accountRevision = _coach.accountRevision;
    final sessionId = _coach.activeSessionId;
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
        _coach.accountRevision == accountRevision &&
        _coach.activeSessionId == sessionId &&
        _coach.messages.any(
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
          // Ids and receipts that are not authoritative may be stale: no
          // write until the history is known again.
          if (!widget.trainingHistoryAuthoritative) {
            throw StateError('Workout history is not known');
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

  /// Adopting a /recipe proposal ([CoachChatController.adoptRecipe]): the
  /// confirmation sheet and the outcome message live here.
  Future<void> _addProposalToRecipes(ChatMessage message) async {
    final proposal = message.recipeProposal;
    final onCreate = widget.onCreateRecipe;
    if (proposal == null || onCreate == null || _coach.addingRecipe) return;
    if (_isRecipeAdded(message)) return;
    HapticFeedback.selectionClick();
    try {
      final adopted = await _coach.adoptRecipe(
        message,
        confirm: () {
          _endDictationForSheet();
          return showEatovaSheet<bool>(
            context,
            _RecipeAddSheet(proposal: proposal),
          );
        },
        create: onCreate,
      );
      if (adopted == null || !mounted) return;
      HapticFeedback.lightImpact();
      final openRecipe = widget.onOpenRecipe;
      showAppSnack(
        context,
        deliveryHint(
          adopted.photoFailed
              ? context.l10n.recipesSavedWithoutPhoto(adopted.recipe.title)
              : context.l10n.recipesSavedSuccess(adopted.recipe.title),
          adopted.delivery,
          context.l10n,
        ),
        icon: Icons.bookmark_added_rounded,
        action: openRecipe == null
            ? null
            : SnackBarAction(
                label: context.l10n.coachRecipeSavedOpen,
                onPressed: () => openRecipe(adopted.recipe),
              ),
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
    if (!_coach.canInteract) return;
    // Before the picker: the photo goes to the provider with the question.
    if (!await _aiConsentFirst() || !mounted || !_coach.canInteract) return;
    HapticFeedback.selectionClick();
    // Grabbed after the mounted check and before the picker's `await`: safe
    // context access.
    final l10n = context.l10n;
    final service = widget.service;
    final sessionId = _coach.activeSessionId;
    final revision = _coach.conversationRevision;
    // The caption is the draft as it stood when the photo was picked. The
    // field stays typeable during the scrub; edits there no longer drop the
    // photo, they stay in the field (spec §9).
    final draft = _input.text;
    bool isCurrent() => mounted &&
        identical(widget.service, service) &&
        _coach.activeSessionId == sessionId &&
        _coach.conversationRevision == revision &&
        _coach.canInteract;
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
        _coach.showError(l10n.coachErrorImageTooLarge);
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
      _coach.showError(_permissionMessageFor(source, e, l10n));
    } catch (e) {
      if (!isCurrent()) return;
      _coach.showError(l10n.coachErrorImageLoadFailed);
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

  /// Every sheet over the composer (attach, brief, reviews, sessions, info)
  /// reads the draft as it stands: the recording ends at once and keeps what
  /// it showed, so no partial rewrites the field behind the sheet and no mic
  /// stays live without a visible stop (R17 D2-M1).
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
    if (!_coach.canType) return;
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
    if (!_speechCapReached && _coachInputLimit.overflow(draft) >= 0) {
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
    _coach.showError(null);
    setState(() {
      _listening = true;
      _listeningLanguage = language;
      _speechShown = '';
      _speechStopping = false;
      _speechCapReached = false;
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
      });
      if (hint != null) _coach.showError(hint);
      if (dictated.isNotEmpty) _inputFocus.requestFocus();
    } on CoachSpeechException catch (e) {
      if (!mounted || generation != _speechGeneration) return;
      _keepScreenAwake(false);
      setState(() => _listening = false);
      _coach.showError(e.message);
    } catch (_) {
      if (!mounted || generation != _speechGeneration) return;
      _keepScreenAwake(false);
      setState(() => _listening = false);
      _coach.showError(l10n.coachSpeechUnavailable);
    }
  }

  void _openAttachSheet() {
    if (!_coach.canInteract) return;
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
    _endDictationForSheet();
    showEatovaSheet<void>(
      context,
      // StatefulBuilder so the sheet rebuilds right after a delete: it does
      // not hang on the page's setState.
      StatefulBuilder(
        builder: (sheetContext, setSheetState) => _SessionsSheet(
          sessions: _coach.sessions,
          activeSessionId: _coach.activeSessionId,
          onNew: () async {
            Navigator.of(sheetContext).pop();
            await _startNewSession();
          },
          onSelect: (id) async {
            Navigator.of(sheetContext).pop();
            await _coach.switchToSession(id);
          },
          onDelete: (id) async {
            await _deleteSession(id);
            // The delete already refreshed the list — redraw the sheet.
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
    _endDictationForSheet();
    final quota = _coach.quota;
    showEatovaSheet<void>(
      context,
      // Only a real snapshot may show numbers: the display fallback would put
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
    final ids = [for (final message in _coach.messages) message.id];
    final vorher = _gerenderteIds;
    final angehaengt =
        !_warAmLaden &&
        !_coach.loading &&
        ids.length > vorher.length &&
        listEquals(ids.sublist(0, vorher.length), vorher);
    if (angehaengt) {
      for (final message in _coach.messages.skip(vorher.length)) {
        if (message.role == ChatRole.assistant && _coach.previewShown) continue;
        _einblenden.add(message.id);
      }
    }
    _gerenderteIds = ids;
    _warAmLaden = _coach.loading;
  }

  /// Rebuilds for the screen's own state and for every controller change.
  /// The builder keeps this State's context, so the screen's dependencies
  /// stay where they were before the controller.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _coach,
    builder: (_, _) => _buildCoach(context),
  );

  Widget _buildCoach(BuildContext context) {
    // No hero when the history merely failed to load (S3): the empty state
    // would claim "no conversation yet". Empty conversation + banner instead.
    final isHero = !_coach.loading &&
        _coach.messages.isEmpty &&
        !_coach.historyUnavailable;
    _merkeNeueNachrichten();
    // Every state change that can end a wait rebuilds, so this one place
    // covers the reply, the bootstrap and a session load alike.
    _openQueuedBriefWhenFree();
    final error = _coach.error;
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
                feedback: _coach.failedSend != null || error != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_coach.failedSend != null)
                            _UnsentNotice(
                              canRetry: _coach.canInteract,
                              onRetry: _wiederholen,
                            ),
                          if (error != null)
                            _ErrorBanner(
                              text: error,
                              // An offline first visit or a failed history
                              // load: nothing else would reload it.
                              onRetry: _coach.canRetryLoad
                                  ? () => unawaited(_coach.retryLoad())
                                  : null,
                            ),
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
                      child: _coach.loading
                          ? const Center(
                              key: ValueKey('coach-loading'),
                              child: AppSpinner(strokeWidth: 2),
                            )
                          : isHero
                          ? _CoachHero(
                              name: widget.userName,
                              dayBrief: widget.dayBrief,
                              canAsk: _coach.canInteract,
                              onAsk: _sendPrepared,
                              onCommand: _applyCommand,
                              onDisclosureTap: _openCoachInfoSheet,
                            )
                          : _Conversation(
                              controller: _scroll,
                              focus: _inputFocus,
                              messages: _coach.messages,
                              sending: _coach.sendingInActiveSession,
                              preview: _coach.preview,
                              recipeAddedFor: _isRecipeAdded,
                              // Card buttons stay disabled without a hook
                              // (preview/test) and while an add is running.
                              recipeAddEnabled:
                                  widget.onCreateRecipe != null &&
                                  !_coach.addingRecipe,
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
                              onReport: (message) => _report(
                                message,
                                AiReportTarget.answer,
                              ),
                              onReportImage: (message) => _report(
                                message,
                                AiReportTarget.recipeImage,
                              ),
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
                    enabled: _coach.canType,
                    canSend: _coach.canInteract,
                    // Null while unknown: the composer then claims neither
                    // exhausted nor a count.
                    quota: _coach.quota,
                    counterHidden: _commandMenuVisibleFor(draft),
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

/// The screen's reactions to controller transitions.
class _CoachScreenHooks extends CoachChatViewHooks {
  _CoachScreenHooks(this._state);

  final _CoachChatScreenState _state;

  @override
  void conversationShown() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _state._scrollToEnd());

  @override
  void conversationReplaced() => _state._dropAnswerCue();

  @override
  void questionSent() {
    HapticFeedback.selectionClick();
    _state._input.clear();
    _state._draft.value = '';
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _state._scrollToEnd(sanft: true),
    );
  }

  /// When the dots turn into text the bubble takes the row's place; a reader
  /// at the end keeps it in view, and later deltas follow via
  /// `_onChatMetrics`. A reader scrolled up is never moved.
  @override
  void previewStarted() => WidgetsBinding.instance.addPostFrameCallback(
    (_) => _state._folgeDemEnde(),
  );

  @override
  void answerArrived() {
    HapticFeedback.lightImpact();
    _state._announceAnswer();
  }

  @override
  void sendFinished() => WidgetsBinding.instance.addPostFrameCallback(
    (_) => _state._folgeDemEnde(),
  );

  @override
  void draftReturned(String text) => _state._entwurfZurueck(text);

  @override
  void mealDescribeRequested(String text) =>
      unawaited(_state._openMealDescribe(text));
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
      // Wrap, not Row: at 2x text on a narrow phone the retry button moves
      // under the marker instead of running off the screen.
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
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
            ],
          ),
          if (canRetry)
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
                      Icon(
                        Icons.refresh_rounded,
                        size: 14,
                        color: t.accentText,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          l10n.coachMessageRetry,
                          style: AppType.ui(
                            11.5,
                            weight: FontWeight.w700,
                            color: t.accentText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
              SheetTitle(l10n.coachTitle),
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
              _InfoBullet(l10n.coachInfoBulletPlan),
              _InfoBullet(l10n.foodPrefsCoachInfoBullet),
              const SizedBox(height: 12),
              Text(
                l10n.coachInfoProvider,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.coachReportHint,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: t.line),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoLimitLabel),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoLimitUnknown(
                  coachQuotaResetLabel(l10n.localeName),
                ),
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
