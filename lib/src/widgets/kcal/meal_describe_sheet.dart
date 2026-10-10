import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/logged_meal.dart';
import '../../models/meal_analysis_request.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../models/number_input.dart';
import '../../services/dictation_language.dart';
import '../../services/meal_analyzer.dart';
import '../../services/meal_describer.dart';
import '../../services/meal_description_matcher.dart';
import '../../services/screen_awake.dart';
import '../../services/speech_input.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../common/decimal_text.dart';
import '../common/lively.dart';
import '../common/motion.dart';
import '../common/persistence_action.dart';
import '../design/design.dart';
import 'meal_analysis_sheet.dart';
import 'meal_slot_picker.dart';
import 'saved_meal_presentation.dart';

part 'meal_describe_draft.dart';

// Describe a meal by text or voice (docs/MEAL-DESCRIBE.md): the input, the
// working step and the editable draft in one sheet. Nothing reaches the diary
// before Add; logging runs through the add sheet's own path.

/// `analyze-meal`'s describe-mode bounds on `mealText`, in UTF-16 units.
const int kMealDescribeMinChars = MealDescriber.minTextLength;
const int kMealDescribeMaxChars = MealDescriber.maxTextLength;

/// From which length the character counter shows.
const int _lengthHintFrom = kMealDescribeMaxChars - 60;

/// Owner of the screen-awake hold while dictating (see [ScreenAwake]).
const String _screenAwakeOwner = 'meal-describe';

/// How long a graceful stop may take before the sheet ends the recording
/// itself; the iOS plugin waits up to 1.5 s for its final result.
const Duration _stopGrace = Duration(seconds: 3);

/// The hint under the field for an answer about the description itself (no
/// food in it, outside the bounds), else null. Those send the user back to
/// the text; every other error goes to the error card
/// ([mealDescribeErrorMessage]).
String? mealDescribeInputNotice(
  Object error,
  AppLocalizations l10n,
) => switch (error) {
  MealAnalysisServerError(code: 'no_food_in_text') => l10n.foodDescribeNoFood,
  MealAnalysisServerError(code: 'invalid_meal_text') =>
    l10n.foodDescribeInvalidText(kMealDescribeMinChars, kMealDescribeMaxChars),
  _ => null,
};

/// [mealAnalysisErrorMessage] for a description: texts that speak of a photo
/// get their own. The quota is the photo scan's, hence "meal analyses".
String mealDescribeErrorMessage(Object error, AppLocalizations l10n) {
  final fallback = l10n.foodAnalysisFailedMessage;
  return switch (error) {
    MealAnalysisReauthRequired() => l10n.foodDescribeReauthRequired,
    MealAnalysisRateLimited(:final resetAt) =>
      resetAt != null && resetAt.isAfter(clock.now())
          ? l10n.foodDescribeRateLimitUntil(mealAnalysisClockLabel(resetAt))
          : l10n.foodDescribeRateLimit,
    // A function without describe mode refuses `mealText` (invalid_body) or
    // asks for a photo, and a few hundred characters are never too large:
    // the service, not the user's connection, text or picture.
    MealImageTooLarge() ||
    MealAnalysisServerError(
      code: 'invalid_body' ||
          'missing_image' ||
          'invalid_image_base64' ||
          'image_too_small',
    ) => l10n.foodAnalysisServiceUnavailableMessage,
    // A describe body carries no hint; the photo's text would mislead.
    MealAnalysisServerError(code: 'invalid_hint') => fallback,
    _ => mealAnalysisErrorMessage(error, fallback, l10n),
  };
}

/// A described meal that was logged; null from [showMealDescribeSheet] means
/// closed without logging.
class MealDescribeOutcome {
  /// Logged with the draft's Add; the caller confirms it with its snack.
  const MealDescribeOutcome.added(MealAnalysisResult this.result, this.slot);

  /// Logged from the review sheet ("Edit"), which confirmed it already.
  const MealDescribeOutcome.addedInReview(this.slot) : result = null;

  final MealAnalysisResult? result;
  final MealSlot slot;
}

/// Opens the describe sheet. [onAdd] is the add sheet's logging path; it runs
/// at most once, on Add (or inside the review sheet opened by Edit).
Future<MealDescribeOutcome?> showMealDescribeSheet(
  BuildContext context, {
  required MealSlot initialSlot,
  required MealDescriber describer,
  required MealDescriptionMatcher matcher,
  required FutureOr<String> Function(MealAnalysisResult, MealSlot) onAdd,
  required FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal,
  bool Function(MealAnalysisResult)? isFavorite,
  PersistValueChanged<MealAnalysisResult>? onToggleFavorite,
  SpeechInput speechInput = const SpeechInput(),
  ScreenAwake screenAwake = const MethodChannelScreenAwake(),
  DictationLanguageStore dictationLanguageStore =
      const PrefsDictationLanguageStore(),
  String? contextLabel,
}) {
  // Own shell and handle: a pull on Material's handle would bypass the
  // discard guard (see SheetDismissGuard).
  return showModalBottomSheet<MealDescribeOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
    builder: (_) => MealDescribeSheet(
      initialSlot: initialSlot,
      describer: describer,
      matcher: matcher,
      onAdd: onAdd,
      onUpdateMeal: onUpdateMeal,
      isFavorite: isFavorite,
      onToggleFavorite: onToggleFavorite,
      speechInput: speechInput,
      screenAwake: screenAwake,
      dictationLanguageStore: dictationLanguageStore,
      contextLabel: contextLabel,
    ),
  );
}

class MealDescribeSheet extends StatefulWidget {
  const MealDescribeSheet({
    super.key,
    required this.initialSlot,
    required this.describer,
    required this.matcher,
    required this.onAdd,
    required this.onUpdateMeal,
    this.isFavorite,
    this.onToggleFavorite,
    this.speechInput = const SpeechInput(),
    this.screenAwake = const MethodChannelScreenAwake(),
    this.dictationLanguageStore = const PrefsDictationLanguageStore(),
    this.contextLabel,
  });

  final MealSlot initialSlot;
  final MealDescriber describer;
  final MealDescriptionMatcher matcher;
  final FutureOr<String> Function(MealAnalysisResult, MealSlot) onAdd;
  final FutureOr<void> Function(String id, MealAnalysisResult scaled)
  onUpdateMeal;
  final bool Function(MealAnalysisResult)? isFavorite;
  final PersistValueChanged<MealAnalysisResult>? onToggleFavorite;
  final SpeechInput speechInput;
  final ScreenAwake screenAwake;
  final DictationLanguageStore dictationLanguageStore;

  /// The diary day when it is not today, shown above the slot picker.
  final String? contextLabel;

  @override
  State<MealDescribeSheet> createState() => _MealDescribeSheetState();
}

enum _Step { input, working, draft }

enum _Phase { understand, match }

/// A hint under the text field or the voice card.
class _Notice {
  const _Notice(this.text, {this.error = false});
  final String text;

  /// Error tone (failed, refused); otherwise a calm hint.
  final bool error;
}

class _MealDescribeSheetState extends State<MealDescribeSheet>
    with WidgetsBindingObserver {
  final TextEditingController _text = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  late MealSlot _slot = widget.initialSlot;
  _Step _step = _Step.input;
  String _lastText = '';

  /// Under the text field: no food found, text refused.
  _Notice? _inputNotice;

  // --- Working ---------------------------------------------------------------
  int _run = 0;
  MealAnalysisCancellation? _cancellation;
  _Phase _phase = _Phase.understand;
  Object? _error;
  bool _slow = false;
  Timer? _slowTimer;

  // --- Draft -----------------------------------------------------------------
  MealDescriptionDraft? _draft;
  bool _adding = false;
  bool _added = false;

  // --- Dictation -------------------------------------------------------------
  late final bool _micSupported = SpeechInput.supportedOn(
    defaultTargetPlatform,
  );

  /// iOS streams partials from an in-app recognizer; Android hands over to
  /// the system dialog and only answers at the end.
  late final bool _inAppRecognizer = SpeechInput.streamsPartialsOn(
    defaultTargetPlatform,
  );

  /// Token source, disjoint from the Coach's so a token can never pass for
  /// one of its recordings on the shared channel.
  static int _speechSeq = 1 << 20;
  int _speechToken = 0;
  bool _listening = false;
  bool _speechStopping = false;
  bool _submitAfterSpeech = false;
  bool _speechCapReached = false;
  String _speechPrefix = '';
  String _speechShown = '';
  Timer? _stopTimer;
  bool _screenHeld = false;

  /// Device preference; null until loaded or chosen (then the app language).
  DictationLanguage? _dictationLanguage;
  DictationLanguage _listeningLanguage = DictationLanguage.de;

  /// Under the voice card: why a recording ended or failed.
  _Notice? _voiceNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(_onTextChanged);
    if (_micSupported) {
      unawaited(
        widget.dictationLanguageStore.load().then((stored) {
          if (mounted && stored != null && _dictationLanguage == null) {
            setState(() => _dictationLanguage = stored);
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelSpeech();
    _holdScreen(false);
    if (_step == _Step.working) _cancellation?.cancel();
    _slowTimer?.cancel();
    _stopTimer?.cancel();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _textFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_listening) return;
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached) {
      return;
    }
    // Android's recognizer is a system activity in front of the app, so its
    // own appearance pauses the app; ending the dictation there would end
    // every dictation. The in-app recognizer stops with the app.
    if (!_inAppRecognizer) return;
    setState(_cancelSpeech);
  }

  void _onTextChanged() {
    final text = _text.text;
    if (text == _lastText) return;
    _lastText = text;
    setState(() {
      // Editing answers the hint; dictation writes the field itself.
      if (!_listening) {
        _inputNotice = null;
        _voiceNotice = null;
      }
    });
  }

  String get _trimmed => _text.text.trim();

  /// What the server accepts, counted as it counts (normalized); the raw
  /// field is capped at the same length, so this only adds the minimum.
  bool get _canSubmit =>
      isValidMealText(_text.text) && !_adding && !_dialogListening;

  /// Android's system dialog owns the recording until it answers: a tap that
  /// reaches the sheet before the dialog covers it must neither end nor
  /// restart the recording, or the dialog's answer would be dropped.
  bool get _dialogListening => _listening && !_inAppRecognizer;

  /// No voice control acts while a stop drains (iOS) or the dialog runs.
  bool get _voiceLocked => _speechStopping || _dialogListening;

  /// Typed or dictated content that a close would lose.
  bool get _dirty => _trimmed.isNotEmpty && !_added;

  DictationLanguage get _preferredLanguage =>
      _dictationLanguage ??
      DictationLanguage.forAppLanguage(context.l10n.localeName);

  // --- Dictation ---------------------------------------------------------------

  void _holdScreen(bool on) {
    if (_screenHeld == on) return;
    _screenHeld = on;
    unawaited(widget.screenAwake.setKeepAwake(on, owner: _screenAwakeOwner));
  }

  void _setText(String text) {
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// One space between the typed text and the dictation, none after a
  /// trailing space.
  static String _joined(String prefix, String dictated) {
    if (dictated.isEmpty) return prefix;
    if (prefix.isEmpty || RegExp(r'\s$').hasMatch(prefix)) {
      return '$prefix$dictated';
    }
    return '$prefix $dictated';
  }

  /// [text] within the field's cap, cut at a character boundary: iOS may
  /// deliver a little more than `maxChars`.
  static String _capped(String text) {
    if (text.length <= kMealDescribeMaxChars) return text;
    final kept = StringBuffer();
    for (final character in text.characters) {
      if (kept.length + character.length > kMealDescribeMaxChars) break;
      kept.write(character);
    }
    return kept.toString().trimRight();
  }

  /// Characters the dictation may add after [_speechPrefix].
  int get _speechRoom {
    final prefix = _speechPrefix;
    final gap = prefix.isEmpty || RegExp(r'\s$').hasMatch(prefix) ? 0 : 1;
    return kMealDescribeMaxChars - prefix.length - gap;
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      HapticFeedback.selectionClick();
      _stopSpeech();
      return;
    }
    if (_step != _Step.input || _adding) return;
    _speechPrefix = _text.text;
    if (_speechRoom < kMealDescribeMinChars) {
      setState(
        () => _voiceNotice = _Notice(context.l10n.foodDescribeSpeechLength),
      );
      return;
    }
    HapticFeedback.selectionClick();
    // The keyboard (and its own dictation) yields to Eatova's recording.
    _textFocus.unfocus();
    await _listen(_preferredLanguage);
  }

  /// The pill: idle it picks the language of the next recording; while
  /// listening it restarts this recording in the other language.
  void _switchLanguage() {
    if (_voiceLocked) return;
    HapticFeedback.selectionClick();
    final next = (_listening ? _listeningLanguage : _preferredLanguage).other;
    setState(() => _dictationLanguage = next);
    unawaited(widget.dictationLanguageStore.save(next));
    if (!_listening) return;
    _speechToken = ++_speechSeq;
    _setText(_speechPrefix);
    // Channel order: the cancel reaches the plugin before the new listen.
    unawaited(widget.speechInput.cancel());
    unawaited(_listen(next));
  }

  /// Graceful: the audio stops and the final text still lands in the field.
  /// Android's dialog stops itself and always answers.
  void _stopSpeech() {
    if (!_listening || _voiceLocked) return;
    setState(() => _speechStopping = true);
    unawaited(widget.speechInput.stop());
    final token = _speechToken;
    _stopTimer?.cancel();
    _stopTimer = Timer(_stopGrace, () {
      // A recognizer that never answers must not hold the sheet hostage:
      // keep what was shown and end the recording here.
      if (!mounted || token != _speechToken || !_listening) return;
      _speechToken = ++_speechSeq;
      unawaited(widget.speechInput.cancel());
      _finishListening(_speechShown, null);
    });
  }

  /// Immediate (dispose, background): the mic goes off at once and a late
  /// result is ignored; text already shown stays. Callers rebuild.
  void _cancelSpeech() {
    _speechToken = ++_speechSeq;
    _stopTimer?.cancel();
    _submitAfterSpeech = false;
    if (!_listening) return;
    _listening = false;
    _speechStopping = false;
    unawaited(widget.speechInput.cancel());
    _holdScreen(false);
  }

  void _showPartial(int token, String text) {
    if (!mounted || token != _speechToken || !_listening) return;
    _speechShown = text.trim();
    final joined = _joined(_speechPrefix, _speechShown);
    _setText(_capped(joined));
    // The cap ends the recording.
    if (!_speechCapReached && joined.length >= kMealDescribeMaxChars) {
      _speechCapReached = true;
      _stopSpeech();
    }
  }

  /// One recording, into the field only: the user reads it before sending.
  Future<void> _listen(DictationLanguage language) async {
    final l10n = context.l10n;
    final token = _speechToken = ++_speechSeq;
    setState(() {
      _listening = true;
      _listeningLanguage = language;
      _speechShown = '';
      _speechStopping = false;
      _speechCapReached = false;
      _voiceNotice = null;
      _inputNotice = null;
    });
    _holdScreen(true);
    var end = SpeechEnd.stopped;
    try {
      final spoken = await widget.speechInput.listen(
        localeId: language.localeId,
        token: token,
        vocabulary: SpeechVocabulary.food,
        maxChars: _speechRoom,
        onPartial: (text) => _showPartial(token, text),
        onEnd: (value) => end = value,
      );
      if (!mounted || token != _speechToken) return;
      final text = spoken?.trim() ?? '';
      // An empty final never takes back words already shown.
      final dictated = text.isEmpty ? _speechShown : text;
      final _Notice? notice;
      if (dictated.isEmpty) {
        // A dismissed system dialog was the user's choice and said its own
        // "didn't catch that"; only a recording that heard nothing gets one.
        notice = end == SpeechEnd.dismissed
            ? null
            : _Notice(l10n.foodDescribeSpeechEmpty);
      } else if (_speechCapReached || end == SpeechEnd.length) {
        notice = _Notice(l10n.foodDescribeSpeechLength);
      } else if (end == SpeechEnd.limit) {
        notice = _Notice(l10n.foodDescribeSpeechLimit);
      } else {
        notice = null;
      }
      _finishListening(dictated, notice);
    } on SpeechInputException catch (e) {
      if (!mounted || token != _speechToken) return;
      _finishListening(
        '',
        _Notice(_speechFailure(e.failure, l10n), error: true),
      );
    } catch (_) {
      if (!mounted || token != _speechToken) return;
      _finishListening('', _Notice(l10n.foodDescribeSpeechFailed, error: true));
    }
  }

  void _finishListening(String dictated, _Notice? notice) {
    _stopTimer?.cancel();
    _holdScreen(false);
    final submit = _submitAfterSpeech;
    _submitAfterSpeech = false;
    _listening = false;
    _speechStopping = false;
    if (dictated.isNotEmpty) {
      _setText(_capped(_joined(_speechPrefix, dictated)));
    }
    setState(() => _voiceNotice = notice);
    if (submit) _submit();
  }

  static String _speechFailure(SpeechFailure failure, AppLocalizations l10n) =>
      switch (failure) {
        SpeechFailure.permissionDenied =>
          l10n.foodDescribeSpeechPermissionDenied,
        SpeechFailure.unavailable => l10n.foodDescribeSpeechUnavailable,
        SpeechFailure.busy => l10n.foodDescribeSpeechBusy,
        SpeechFailure.failed => l10n.foodDescribeSpeechFailed,
      };

  // --- Describe and match --------------------------------------------------------

  void _submit() {
    if (_step != _Step.input || _dialogListening) return;
    if (_listening) {
      // The recording ends first; its final text is what gets described.
      _submitAfterSpeech = true;
      _stopSpeech();
      return;
    }
    if (!_canSubmit) return;
    _textFocus.unfocus();
    unawaited(_describe());
  }

  Future<void> _describe() async {
    final run = ++_run;
    final cancellation = _cancellation = MealAnalysisCancellation();
    final text = _trimmed;
    final language = context.l10n.localeName;
    setState(() {
      _step = _Step.working;
      _phase = _Phase.understand;
      _error = null;
      _slow = false;
      _inputNotice = null;
      _voiceNotice = null;
    });
    _slowTimer?.cancel();
    _slowTimer = Timer(MealAnalysisSheet.slowAfter, () {
      if (!mounted || run != _run || _step != _Step.working) return;
      setState(() => _slow = true);
    });
    try {
      final meal = await widget.describer.describe(
        text,
        language: language,
        cancellation: cancellation,
      );
      if (!mounted || run != _run) return;
      setState(() => _phase = _Phase.match);
      final draft = await widget.matcher.match(meal);
      if (!mounted || run != _run) return;
      _slowTimer?.cancel();
      setState(() {
        _draft = draft;
        _slot = draft.slotHint ?? _slot;
        _step = _Step.draft;
        _cancellation = null;
      });
      _jumpToTop();
    } catch (error) {
      if (!mounted || run != _run) return;
      _slowTimer?.cancel();
      _cancellation = null;
      // Our own cancel already went back to the text.
      if (error is MealAnalysisCancelled) return;
      final notice = mealDescribeInputNotice(error, context.l10n);
      if (notice != null) {
        setState(() {
          _step = _Step.input;
          _inputNotice = _Notice(notice, error: true);
        });
        return;
      }
      setState(() {
        _error = error;
        _slow = false;
      });
    }
  }

  void _cancelWork() {
    _run++;
    _cancellation?.cancel();
    _cancellation = null;
    _slowTimer?.cancel();
    setState(() {
      _step = _Step.input;
      _error = null;
      _slow = false;
    });
  }

  /// Back to the text, which stays as it was; a draft is dropped.
  void _backToText() {
    _run++;
    setState(() {
      _step = _Step.input;
      _error = null;
      _draft = null;
    });
    _jumpToTop();
  }

  void _jumpToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  static bool _retryable(Object error) =>
      error is! MealAnalysisRateLimited && error is! MealAnalysisReauthRequired;

  // --- Draft ---------------------------------------------------------------------

  Future<void> _editLine(int index) async {
    final draft = _draft;
    if (draft == null || _adding) return;
    final edit = await showEatovaSheet<_LineEdit>(
      context,
      _DraftLineEditor(item: draft.items[index]),
    );
    if (!mounted || edit == null || !identical(_draft, draft)) return;
    if (!edit.removed) {
      setState(() => _draft = draft.replaceItem(index, edit.item!));
      return;
    }
    final removed = draft.removeItem(index);
    setState(() => _draft = removed);
    final l10n = context.l10n;
    final line = draft.items[index];
    showAppSnack(
      context,
      // The name as the line showed it, without the brand suffix.
      l10n.foodDescribeLineRemoved(_candidateName(line.selected, line).$1),
      icon: Icons.delete_outline_rounded,
      tone: SnackTone.neutral,
      action: SnackBarAction(
        label: l10n.commonUndo,
        onPressed: () {
          if (mounted && identical(_draft, removed)) {
            setState(() => _draft = draft);
          }
        },
      ),
    );
  }

  Future<void> _add() async {
    final draft = _draft;
    // Set before the first await: a second tap finds the flag.
    // The draft's own log guard: lines left and more than 0 kcal.
    if (draft == null || !draft.isLoggable || _adding || _added) return;
    final result = draft.toResult();
    final slot = _slot;
    setState(() => _adding = true);
    final saved = await tryPersistChange(context, () async {
      await widget.onAdd(result, slot);
    });
    if (!mounted) return;
    if (!saved) {
      setState(() => _adding = false);
      return;
    }
    _added = true;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(MealDescribeOutcome.added(result, slot));
  }

  /// The existing analysis sheet with the draft's result: components,
  /// weight, favorite. A meal added there closes this sheet too.
  Future<void> _review() async {
    final draft = _draft;
    if (draft == null || draft.items.isEmpty || _adding || _added) return;
    MealSlot? loggedSlot;
    await showMealAnalysisSheet(
      context,
      slot: _slot,
      resultFuture: Future<MealAnalysisResult>.value(draft.toResult()),
      previewImage: null,
      onAdd: (result, slot) async {
        final id = await widget.onAdd(result, slot);
        loggedSlot = slot;
        return id;
      },
      onUpdateMeal: widget.onUpdateMeal,
      isFavorite: widget.isFavorite,
      onToggleFavorite: widget.onToggleFavorite,
      failureMessage: context.l10n.foodAnalysisFailedMessage,
    );
    final slot = loggedSlot;
    if (!mounted || slot == null) return;
    _added = true;
    Navigator.of(context).pop(MealDescribeOutcome.addedInReview(slot));
  }

  // --- Closing -------------------------------------------------------------------

  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_adding || _discardDialogOpen) return;
    // No live mic behind the dialog, as under the Coach's sheets: the
    // recording ends at once and keeps what it showed. Android's dialog
    // answers on its own.
    if (_listening && _inAppRecognizer) setState(_cancelSpeech);
    _discardDialogOpen = true;
    final l10n = context.l10n;
    final discard = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        key: const ValueKey('describe-discard-dialog'),
        title: l10n.foodDescribeDiscardTitle,
        body: l10n.foodDescribeDiscardBody,
        icon: Icons.edit_off_rounded,
        destructive: true,
        cancelKey: const ValueKey('describe-discard-cancel'),
        cancelLabel: l10n.foodDiscardChangesKeepEditing,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        confirmKey: const ValueKey('describe-discard-confirm'),
        confirmLabel: l10n.foodDiscardChangesConfirm,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    _discardDialogOpen = false;
    if (!mounted || discard != true) return;
    Navigator.of(context).pop();
  }

  // --- Build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => CommitDismissGuard(
    pending: _adding,
    child: PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askDiscard();
      },
      child: SheetDismissGuard(
        active: _dirty,
        followDrag: true,
        onDismissAttempt: _askDiscard,
        child: _buildSheet(context),
      ),
    ),
  );

  Widget _buildSheet(BuildContext context) {
    final t = context.t;
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = sheetMaxHeightOf(context);
    final keyboard = mediaQuery.viewInsets.bottom;
    final largeText = mediaQuery.textScaler.scale(14) > 21;
    final draft = _draft;
    // The draft's totals and actions stay in reach where there is room; large
    // text and short windows keep them at the end of the scroll.
    final pinFooter =
        _step == _Step.draft &&
        draft != null &&
        maxHeight >= 560 &&
        mediaQuery.size.width >= 340 &&
        mediaQuery.textScaler.scale(14) <= 21;
    final footer = draft == null
        ? null
        : _DraftFooter(
            draft: draft,
            adding: _adding,
            onEdit: _review,
            onAdd: _add,
          );

    final body = switch (_step) {
      _Step.input => _buildInput(context),
      _Step.working => _buildWorking(context),
      _Step.draft => _DraftView(
        draft: draft!,
        description: _trimmed,
        onEditText: _backToText,
        onEditLine: _editLine,
      ),
    };

    final sheet = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHandle(
          padding: const EdgeInsets.only(top: 10, bottom: 12),
          onDismiss: () => Navigator.of(context).maybePop(),
        ),
        _Header(
          step: _step,
          // Large text: the context line scrolls with the content, so the
          // fixed head stays short.
          compact: keyboard > 0 || largeText,
          onClose: () => Navigator.of(context).maybePop(),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('meal-describe-scroll'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              pinFooter ? 12 : 24 + mediaQuery.viewPadding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (largeText) ...[
                  Text(
                    _Header.subtitleFor(_step, context.l10n),
                    style: AppType.ui(12.5, color: t.ink2, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.contextLabel != null) ...[
                  Text(
                    widget.contextLabel!,
                    style: AppType.ui(12, color: t.ink2),
                  ),
                  const SizedBox(height: 8),
                ],
                MealSlotPicker(
                  selected: _slot,
                  keyPrefix: 'describe-slot-',
                  onSelected: (slot) => setState(() => _slot = slot),
                ),
                const SizedBox(height: 16),
                maybeAnimatedSize(
                  context,
                  duration: const Duration(milliseconds: 220),
                  curve: kMotionCurve,
                  alignment: Alignment.topCenter,
                  child: LivelyEntrance(key: ValueKey(_step), child: body),
                ),
                if (_step == _Step.draft && !pinFooter && footer != null) ...[
                  const SizedBox(height: 20),
                  footer,
                ],
              ],
            ),
          ),
        ),
        if (pinFooter && footer != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.line)),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                14,
                20,
                14 + mediaQuery.viewPadding.bottom,
              ),
              child: footer,
            ),
          ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Container(
        key: const ValueKey('meal-describe-sheet'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: ShapeDecoration(
          color: t.bg,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(rSheet),
            ),
            side: BorderSide(color: t.lineStrong),
          ),
        ),
        child: SnackHost(measureToast: true, child: sheet),
      ),
    );
  }

  Widget _buildInput(BuildContext context) {
    final l10n = context.l10n;
    final inputNotice = _inputNotice;
    final voiceNotice = _voiceNotice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DescribeField(
          controller: _text,
          focusNode: _textFocus,
          listening: _listening,
          error: inputNotice?.error ?? false,
          onTapWhileListening: _stopSpeech,
          onSubmitted: _submit,
        ),
        if (inputNotice != null) ...[
          const SizedBox(height: 10),
          _InlineNotice(
            key: const ValueKey('meal-describe-notice'),
            notice: inputNotice,
          ),
        ],
        if (_micSupported) ...[
          const SizedBox(height: 12),
          _VoiceCard(
            listening: _listening,
            locked: _voiceLocked,
            language: _listening ? _listeningLanguage : _preferredLanguage,
            onMic: _toggleMic,
            onLanguage: _switchLanguage,
          ),
          if (voiceNotice != null) ...[
            const SizedBox(height: 10),
            _InlineNotice(
              key: const ValueKey('meal-describe-voice-notice'),
              notice: voiceNotice,
            ),
          ],
        ],
        const SizedBox(height: 20),
        PrimaryActionButton(
          key: const ValueKey('meal-describe-submit'),
          label: l10n.foodDescribeSubmit,
          icon: Icons.auto_awesome_rounded,
          onTap: _canSubmit ? _submit : null,
        ),
      ],
    );
  }

  Widget _buildWorking(BuildContext context) {
    final error = _error;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error == null) ...[
          _WorkingCard(phase: _phase),
          const SizedBox(height: 14),
          _DescriptionText(text: _trimmed),
          const SizedBox(height: 14),
          _WorkingFooter(slow: _slow, onCancel: _cancelWork),
        ] else ...[
          _ErrorCard(
            message: mealDescribeErrorMessage(error, l10n),
            onRetry: _retryable(error) ? () => unawaited(_describe()) : null,
            onEditText: _backToText,
          ),
          const SizedBox(height: 14),
          _DescriptionText(text: _trimmed),
        ],
      ],
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────────────

/// The manual sheet's head: display title, one line of context, the round
/// close button. The context line steps aside while the keyboard is open.
class _Header extends StatelessWidget {
  const _Header({
    required this.step,
    required this.compact,
    required this.onClose,
  });

  final _Step step;
  final bool compact;
  final VoidCallback onClose;

  static String subtitleFor(_Step step, AppLocalizations l10n) =>
      step == _Step.draft
      ? l10n.foodDescribeReviewSubtitle
      : l10n.foodDescribeSubtitle;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final review = step == _Step.draft;
    final title = review
        ? l10n.foodDescribeReviewTitle
        : l10n.foodDescribeTitle;
    final subtitle = subtitleFor(step, l10n);
    final large = MediaQuery.textScalerOf(context).scale(24) > 36;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                HeadingSemantics(
                  level: 1,
                  child: Text(
                    title,
                    key: const ValueKey('meal-describe-title'),
                    // A 30 px heading is large text already; beyond it a
                    // word like "beschreiben" would break at 320 px.
                    textScaler: MediaQuery.textScalerOf(
                      context,
                    ).clamp(maxScaleFactor: 1.5),
                    style: AppType.display(
                      large ? 20 : 24,
                      color: t.ink,
                      height: 1.15,
                    ),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: AppType.ui(12.5, color: t.ink2, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('meal-describe-close'),
            tooltip: l10n.commonClose,
            onPressed: onClose,
            style: IconButton.styleFrom(backgroundColor: t.surf2),
            icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
          ),
        ],
      ),
    );
  }
}

// ─── Input ──────────────────────────────────────────────────────────────────

/// Keeps the text inside the server's cap. Rejects instead of truncating, and
/// an edit that shortens an over-long text (dictation writes the controller
/// directly) always passes, like the Coach composer.
class _DescribeInputLimit extends TextInputFormatter {
  const _DescribeInputLimit();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final over = newValue.text.length - kMealDescribeMaxChars;
    if (over <= 0 || over < oldValue.text.length - kMealDescribeMaxChars) {
      return newValue;
    }
    return oldValue;
  }
}

/// The description capsule: several lines on the soft field fill. While
/// dictating it shows the transcript and is read-only.
class _DescribeField extends StatelessWidget {
  const _DescribeField({
    required this.controller,
    required this.focusNode,
    required this.listening,
    required this.error,
    required this.onTapWhileListening,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool listening;
  final bool error;
  final VoidCallback onTapWhileListening;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final length = controller.text.length;
    final over = length > kMealDescribeMaxChars;
    final showCount = length >= _lengthHintFrom;
    return FieldCapsule(
      focusNode: focusNode,
      focused: listening ? true : null,
      error: error || over,
      padding: const EdgeInsets.fromLTRB(16, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: l10n.foodDescribeFieldLabel,
            child: TextField(
              key: const ValueKey('meal-describe-input'),
              controller: controller,
              focusNode: focusNode,
              readOnly: listening,
              onTap: listening ? onTapWhileListening : null,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmitted(),
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: const [_DescribeInputLimit()],
              cursorColor: t.accent,
              cursorOpacityAnimates: false,
              style: AppType.ui(17, color: t.ink, height: 1.4),
              decoration: InputDecoration(
                // All borders and the fill off: the capsule is the field.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: listening
                    ? l10n.foodDescribeMicListening
                    : l10n.foodDescribeFieldHint,
                hintMaxLines: 3,
                hintStyle: AppType.ui(17, color: t.ink2, height: 1.4),
              ),
            ),
          ),
          if (showCount)
            Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                liveRegion: true,
                child: Text(
                  over
                      ? l10n.foodDescribeLengthReached(kMealDescribeMaxChars)
                      : l10n.foodDescribeLengthHint(
                          length,
                          kMealDescribeMaxChars,
                        ),
                  key: const ValueKey('meal-describe-length'),
                  style: AppType.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: over ? t.warning : t.ink2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Eatova's own dictation: a large mic disc with a line of copy, and the
/// DE/EN pill. Listening turns the disc into a pulsing stop button.
class _VoiceCard extends StatelessWidget {
  const _VoiceCard({
    required this.listening,
    required this.locked,
    required this.language,
    required this.onMic,
    required this.onLanguage,
  });

  final bool listening;

  /// Mic and pill do nothing: a stop drains, or the system dialog runs.
  final bool locked;
  final DictationLanguage language;
  final VoidCallback onMic;
  final VoidCallback onLanguage;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final radius = BorderRadius.circular(rCard);
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          listening ? l10n.foodDescribeMicListening : l10n.foodDescribeMicTitle,
          style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
        ),
        const SizedBox(height: 2),
        Text(
          listening
              ? l10n.foodDescribeMicListeningHint
              : l10n.foodDescribeMicHint,
          style: AppType.ui(12.5, color: t.ink2, height: 1.3),
        ),
      ],
    );
    return AnimatedContainer(
      key: const ValueKey('meal-describe-voice'),
      duration: motionDuration(context, kSelectionDuration),
      curve: kMotionCurve,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: listening ? t.accent : t.cardBorder,
          width: kSelectionEdge,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            listening ? t.accentTintStrong : t.accentTint,
            t.accentTint.withValues(alpha: 0),
          ],
        ),
      ),
      child: _layout(
        stacked: MediaQuery.textScalerOf(context).scale(14) > 21,
        mic: Semantics(
          key: const ValueKey('meal-describe-mic'),
          button: true,
          enabled: !locked,
          label: listening
              ? l10n.foodDescribeMicStop
              : l10n.foodDescribeMicStart,
          onTap: locked ? null : onMic,
          excludeSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: locked ? null : onMic,
              borderRadius: radius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 76),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                  child: Builder(
                    builder: (context) =>
                        MediaQuery.textScalerOf(context).scale(14) > 21
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _MicDisc(listening: listening),
                              const SizedBox(height: 12),
                              copy,
                            ],
                          )
                        : Row(
                            children: [
                              _MicDisc(listening: listening),
                              const SizedBox(width: 14),
                              Expanded(child: copy),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        pill: _LanguagePill(
          language: language,
          restarts: listening,
          enabled: !locked,
          onTap: onLanguage,
        ),
      ),
    );
  }

  /// Side by side; at large text the copy moves under the disc and the pill
  /// to the top corner, so neither squeezes the words.
  static Widget _layout({
    required bool stacked,
    required Widget mic,
    required Widget pill,
  }) {
    if (stacked) {
      return Stack(
        fit: StackFit.passthrough,
        children: [
          mic,
          Positioned(top: 8, right: 8, child: pill),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: mic),
        pill,
        const SizedBox(width: 8),
      ],
    );
  }
}

/// The 52 px disc: a soft accent mic at rest; while listening the filled
/// accent stop mark with a ring that pulses (static under reduced motion).
class _MicDisc extends StatefulWidget {
  const _MicDisc({required this.listening});

  final bool listening;

  @override
  State<_MicDisc> createState() => _MicDiscState();
}

class _MicDiscState extends State<_MicDisc>
    with SingleTickerProviderStateMixin {
  static const double _size = 52;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MicDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.listening && !reducedMotion(context)) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final listening = widget.listening;
    final disc = AnimatedContainer(
      duration: motionDuration(context, kSelectionDuration),
      curve: kMotionCurve,
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: listening ? t.accentFill : t.accentTintStrong,
        boxShadow: [
          BoxShadow(
            color: listening ? t.accentGlow : t.accentGlow.withValues(alpha: 0),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(
        listening ? Icons.stop_rounded : Icons.mic_none_rounded,
        size: listening ? 24 : 26,
        color: listening ? t.onAccentFill : t.accentText,
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (listening)
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) {
                    final reduce = reducedMotion(context);
                    final v = reduce ? 0.35 : _pulse.value;
                    final grow = _size + 22 * v;
                    return Container(
                      width: grow,
                      height: grow,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: t.accent.withValues(
                            alpha: reduce ? 0.45 : 0.55 * (1 - v),
                          ),
                          width: 2,
                        ),
                      ),
                    );
                  },
                ),
              ),
            disc,
          ],
        ),
      ),
    );
  }
}

/// DE/EN pill next to the mic. Apple recognizes one language per session,
/// so the language is visible before speaking and switchable while listening.
class _LanguagePill extends StatelessWidget {
  const _LanguagePill({
    required this.language,
    required this.restarts,
    required this.enabled,
    required this.onTap,
  });

  final DictationLanguage language;

  /// Listening: a tap restarts the recording in the other language.
  final bool restarts;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    String name(DictationLanguage value) => value == DictationLanguage.de
        ? l10n.coachDictationLanguageGerman
        : l10n.coachDictationLanguageEnglish;
    final other = name(language.other);
    return Semantics(
      key: const ValueKey('meal-describe-language'),
      button: true,
      enabled: enabled,
      label: l10n.coachDictationLanguageLabel(name(language)),
      hint: restarts
          ? l10n.foodDescribeLanguageRestartHint(other)
          : l10n.foodDescribeLanguageSwitchHint(other),
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: t.surf,
                  borderRadius: BorderRadius.circular(rPill),
                  border: Border.all(color: t.lineStrong),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.translate_rounded, size: 14, color: t.ink2),
                    const SizedBox(width: 5),
                    Text(
                      language == DictationLanguage.de
                          ? l10n.coachDictationLanguageDe
                          : l10n.coachDictationLanguageEn,
                      style: AppType.ui(
                        12.5,
                        weight: FontWeight.w700,
                        color: t.accentText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One calm line with an icon under a field or card; announced when it
/// appears.
class _InlineNotice extends StatelessWidget {
  const _InlineNotice({super.key, required this.notice});

  final _Notice notice;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = notice.error ? t.warning : t.ink2;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                notice.error
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                size: 17,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                notice.text,
                style: AppType.ui(
                  13,
                  weight: FontWeight.w500,
                  color: notice.error ? t.ink : t.ink2,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Working ────────────────────────────────────────────────────────────────

/// The scan's loading card, with the two real phases instead of timed
/// stages: understanding the sentence, then matching products.
class _WorkingCard extends StatefulWidget {
  const _WorkingCard({required this.phase});

  final _Phase phase;

  @override
  State<_WorkingCard> createState() => _WorkingCardState();
}

class _WorkingCardState extends State<_WorkingCard>
    with SingleTickerProviderStateMixin {
  // Feedback, not decoration: deliberately not via motionDuration, or the
  // bar would sit at its end from the first frame (as in MealLoadingCard).
  late final AnimationController _progress = AnimationController(vsync: this);

  static const Duration _understand = Duration(seconds: 6);
  static const Duration _match = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _animate();
  }

  @override
  void didUpdateWidget(covariant _WorkingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _animate();
  }

  void _animate() {
    if (widget.phase == _Phase.understand) {
      _progress.animateTo(0.6, duration: _understand, curve: Curves.easeOut);
    } else {
      _progress.animateTo(0.95, duration: _match, curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final understand = widget.phase == _Phase.understand;
    return AppCard(
      key: const ValueKey('meal-describe-working'),
      color: t.brandSurface,
      radius: rHero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                IconTile(
                  icon: understand
                      ? Icons.auto_awesome_rounded
                      : Icons.manage_search_rounded,
                  color: t.accent,
                  size: 38,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        understand
                            ? l10n.foodDescribeStageUnderstand
                            : l10n.foodDescribeStageMatch,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.onBrandSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.foodLoadingStepOf(understand ? 1 : 2, 2),
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w500,
                          color: t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(rPill),
            child: AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => LinearProgressIndicator(
                value: _progress.value,
                minHeight: 3,
                backgroundColor: t.tile,
                color: t.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The text being described, set off by an accent rule.
class _DescriptionText extends StatelessWidget {
  const _DescriptionText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: t.accent, width: 3)),
      ),
      child: Text(
        text,
        key: const ValueKey('meal-describe-quote'),
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
        style: AppType.ui(14, color: t.ink2, height: 1.45),
      ),
    );
  }
}

/// Cancel is there from the start; after [MealAnalysisSheet.slowAfter] the
/// wait gets the photo scan's "taking longer" line.
class _WorkingFooter extends StatelessWidget {
  const _WorkingFooter({required this.slow, required this.onCancel});

  final bool slow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: slow
              ? Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.foodAnalysisSlowHint,
                    key: const ValueKey('meal-describe-slow-hint'),
                    style: AppType.ui(
                      12.5,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 12),
        SoftPillButton(
          key: const ValueKey('meal-describe-cancel'),
          label: l10n.commonCancel,
          onTap: onCancel,
          tone: SoftPillTone.neutral,
        ),
      ],
    );
  }
}

/// The scan's error card: what went wrong, retry where it can help, and the
/// way back to the text.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.onRetry,
    required this.onEditText,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onEditText;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      key: const ValueKey('meal-describe-error'),
      radius: rCard,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: t.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.foodAnalysisErrorTitle,
                  style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey('meal-describe-error-message'),
              style: AppType.ui(13, color: t.ink2, height: 1.4),
            ),
          ),
          const SizedBox(height: 14),
          if (onRetry != null) ...[
            PrimaryActionButton(
              key: const ValueKey('meal-describe-retry'),
              label: l10n.foodAnalysisRetryButton,
              icon: Icons.refresh_rounded,
              onTap: onRetry,
              height: 48,
            ),
            const SizedBox(height: 8),
          ],
          SoftPillButton(
            key: const ValueKey('meal-describe-edit-text'),
            label: l10n.foodDescribeEditText,
            icon: Icons.edit_outlined,
            onTap: onEditText,
            tone: onRetry == null ? SoftPillTone.accent : SoftPillTone.neutral,
            expand: true,
          ),
        ],
      ),
    );
  }
}
