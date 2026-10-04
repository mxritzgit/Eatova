import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_context.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../onboarding/onboarding_controls.dart';
import '../training/training_exercise_list.dart';

final class CoachTrainingBriefSubmission {
  const CoachTrainingBriefSubmission(this.wish, this.context);

  final String wish;
  final CoachTrainingContext context;
}

Future<CoachTrainingBriefSubmission?> showCoachTrainingBrief(
  BuildContext context, {
  TrainingPlan? selectedPlan,
  String initialWish = '',
  required bool Function() canSubmit,
  required ValueListenable<bool> isActive,
}) => showEatovaSheet<CoachTrainingBriefSubmission>(
  context,
  _CoachTrainingBrief(
    selectedPlan: selectedPlan,
    initialWish: initialWish,
    canSubmit: canSubmit,
    isActive: isActive,
  ),
  dragHandle: false,
);

/// Sessions per week the brief offers (the context's own bounds).
const int _sessionsMin = 1;
const int _sessionsMax = 7;

/// Minutes per session the brief offers, stepped through in order.
const List<int> _minuteSteps = [15, 20, 30, 45, 60, 90];

/// Base duration of the brief's selection changes.
const Duration _kSelect = Duration(milliseconds: 180);

class _CoachTrainingBrief extends StatefulWidget {
  const _CoachTrainingBrief({
    this.selectedPlan,
    required this.initialWish,
    required this.canSubmit,
    required this.isActive,
  });

  final TrainingPlan? selectedPlan;
  final String initialWish;
  final bool Function() canSubmit;
  final ValueListenable<bool> isActive;

  @override
  State<_CoachTrainingBrief> createState() => _CoachTrainingBriefState();
}

class _CoachTrainingBriefState extends State<_CoachTrainingBrief> {
  final _goal = TextEditingController();
  late final _wish = TextEditingController(text: widget.initialWish);
  final _goalFocus = FocusNode();
  final _wishFocus = FocusNode();
  late var _intent = widget.selectedPlan == null
      ? CoachTrainingIntent.create
      : CoachTrainingIntent.discuss;
  var _experience = CoachTrainingExperience.beginner;
  var _equipment = CoachTrainingEquipment.bodyweight;
  var _sessions = 3;
  var _minutes = 30;
  String? _error;
  bool _initialized = false;
  bool _submitted = false;
  bool _goalRequiredError = false;

  /// "Own goal" was chosen: the goal field stays open even when its text
  /// equals a quick goal.
  bool _customGoal = false;

  @override
  void initState() {
    super.initState();
    widget.isActive.addListener(_closeRetiredBrief);
    _goalFocus.addListener(_validateGoalOnBlur);
  }

  void _validateGoalOnBlur() {
    if (!_goalFocus.hasFocus) {
      setState(() => _goalRequiredError = _goal.text.trim().isEmpty);
    }
  }

  void _closeRetiredBrief() {
    if (widget.isActive.value) return;
    // An account transition may occur during the parent's build. Remove only
    // this route, after that frame, even if another route covers it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _goal.text = widget.selectedPlan?.goal.isNotEmpty == true
          ? widget.selectedPlan!.goal
          : context.l10n.coachBriefDefaultGoal;
    }
  }

  @override
  void dispose() {
    widget.isActive.removeListener(_closeRetiredBrief);
    _goalFocus.removeListener(_validateGoalOnBlur);
    _goal.dispose();
    _wish.dispose();
    _goalFocus.dispose();
    _wishFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted) return;
    final l10n = context.l10n;
    if (!widget.isActive.value || !widget.canSubmit()) {
      setState(() => _error = l10n.coachBriefUnavailable);
      return;
    }
    try {
      final brief = CoachTrainingContext(
        intent: _intent,
        goal: _goal.text.trim(),
        experience: _experience,
        equipment: _equipment,
        sessionsPerWeek: _sessions,
        minutesPerSession: _minutes,
        selectedPlan: widget.selectedPlan?.proposal,
      );
      final wish = _wish.text.trim();
      if (wish.length > 1000 ||
          RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(wish) ||
          wish.startsWith('/')) {
        throw const FormatException('Invalid training wish');
      }
      setState(() => _submitted = true);
      Navigator.pop(
        context,
        CoachTrainingBriefSubmission(
          wish.isEmpty
              ? switch (_intent) {
                  CoachTrainingIntent.create => l10n.coachBriefCreateWish,
                  CoachTrainingIntent.adapt => l10n.coachBriefAdaptWish,
                  CoachTrainingIntent.discuss => l10n.coachBriefDiscussWish,
                }
              : wish,
          brief,
        ),
      );
    } on FormatException {
      setState(() {
        // An empty goal can only come from the own-goal field: open it so
        // the error shows where the fix is.
        if (_goal.text.trim().isEmpty) _customGoal = true;
        _goalRequiredError = _goal.text.trim().isEmpty;
        _error = l10n.coachBriefInvalid;
      });
    }
  }

  /// The quick goals: (key suffix, text written into the goal field).
  List<(String, String)> _goalPresets(AppLocalizations l10n) => [
    ('general', l10n.coachBriefDefaultGoal),
    ('strength', l10n.coachBriefGoalStrength),
    ('muscle', l10n.coachBriefGoalMuscle),
    ('fat-loss', l10n.coachBriefGoalFatLoss),
    ('endurance', l10n.coachBriefGoalEndurance),
  ];

  /// The quick goal the field's text names, or null for an own goal.
  String? _goalPreset(AppLocalizations l10n) {
    if (_customGoal) return null;
    final text = _goal.text.trim().toLowerCase();
    for (final (_, preset) in _goalPresets(l10n)) {
      if (preset.toLowerCase() == text) return preset;
    }
    return null;
  }

  void _pickGoal(String preset) {
    HapticFeedback.selectionClick();
    _goalFocus.unfocus();
    setState(() {
      _customGoal = false;
      _goal.text = preset;
      _goalRequiredError = false;
      _error = null;
    });
  }

  void _pickOwnGoal() {
    if (!_customGoal) HapticFeedback.selectionClick();
    setState(() => _customGoal = true);
    // The field mounts with this build. Its text stays selected, so typing
    // replaces a quick goal and a tap keeps it for refining.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _goal.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _goal.text.length,
      );
      _goalFocus.requestFocus();
    });
  }

  void _choose(VoidCallback change) {
    HapticFeedback.selectionClick();
    setState(() {
      change();
      _error = null;
    });
  }

  void _stepSessions(int delta) => _choose(
    () => _sessions = (_sessions + delta).clamp(_sessionsMin, _sessionsMax),
  );

  void _stepMinutes(int delta) => _choose(() {
    final index = (_minuteSteps.indexOf(_minutes) + delta).clamp(
      0,
      _minuteSteps.length - 1,
    );
    _minutes = _minuteSteps[index];
  });

  String _equipmentLabel(AppLocalizations l10n, CoachTrainingEquipment v) =>
      switch (v) {
        CoachTrainingEquipment.bodyweight => l10n.coachBriefBodyweight,
        CoachTrainingEquipment.dumbbells => l10n.coachBriefDumbbells,
        CoachTrainingEquipment.gym => l10n.coachBriefGym,
      };

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Large text or a short sheet (the keyboard is up) lets the title
        // scroll and keeps only action and cost in the bar: at 2x a pinned
        // two-line title and a two-line summary left the form a sliver.
        final compact = scale > 1.35 || constraints.maxHeight < 560;
        final header = _header(context, compact: compact);
        // One element tree for both layouts: the keyboard can flip
        // [compact], and a reshaped column would rebuild the fields and drop
        // the focused one.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Visibility(visible: !compact, child: header),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('coach-brief-scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Visibility(visible: compact, child: header),
                    ..._content(context),
                  ],
                ),
              ),
            ),
            _bar(context, compact: compact),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 0 : 20, 4, compact ? 0 : 12, 6),
      // Top-aligned: a title that wraps at large text must not push the
      // close button down behind the action bar.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              // Centres one line of title on the 48 px button.
              padding: const EdgeInsets.only(top: 10),
              child: HeadingSemantics(
                level: 1,
                child: Text(
                  l10n.coachBriefTitle,
                  style: AppType.display(24, color: t.ink, height: 1.15),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('coach-brief-close'),
            tooltip: l10n.trainingPageClose,
            onPressed: () => Navigator.pop(context),
            style: IconButton.styleFrom(backgroundColor: t.surf2),
            icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = widget.selectedPlan;
    return [
      Text(
        l10n.coachBriefLead,
        style: AppType.ui(14, color: t.ink2, height: 1.45),
      ),
      const SizedBox(height: 12),
      _SharedNote(
        text: plan == null
            ? l10n.coachBriefShared
            : l10n.coachBriefSharedWithPlan,
      ),
      if (plan != null) ...[
        const SizedBox(height: 16),
        _PlanPreviewCard(plan: plan),
        _section(context, l10n.coachBriefIntent),
        OnboardingOptionCard(
          actionKey: const ValueKey('coach-brief-intent-adapt'),
          selected: _intent == CoachTrainingIntent.adapt,
          onTap: () => _choose(() => _intent = CoachTrainingIntent.adapt),
          title: l10n.coachBriefAdapt,
          subtitle: l10n.coachBriefAdaptHint,
          leading: const OnboardingGlyphTile(icon: Icons.tune_rounded),
        ),
        const SizedBox(height: 10),
        OnboardingOptionCard(
          actionKey: const ValueKey('coach-brief-intent-discuss'),
          selected: _intent == CoachTrainingIntent.discuss,
          onTap: () => _choose(() => _intent = CoachTrainingIntent.discuss),
          title: l10n.coachBriefDiscuss,
          subtitle: l10n.coachBriefDiscussHint,
          leading: const OnboardingGlyphTile(icon: Icons.forum_outlined),
        ),
      ],
      _section(context, l10n.coachBriefGoal),
      _goalChoices(context),
      _section(context, l10n.coachBriefExperience),
      _BriefSegments<CoachTrainingExperience>(
        keyPrefix: 'coach-brief-experience',
        values: CoachTrainingExperience.values,
        selected: _experience,
        onChanged: (v) => _choose(() => _experience = v),
        labelOf: (v) => switch (v) {
          CoachTrainingExperience.beginner => l10n.coachBriefBeginner,
          CoachTrainingExperience.intermediate => l10n.coachBriefIntermediate,
          CoachTrainingExperience.advanced => l10n.coachBriefAdvanced,
        },
        iconOf: (v, color) => _LevelMark(level: v.index + 1, color: color),
      ),
      _section(context, l10n.coachBriefEquipment),
      _BriefSegments<CoachTrainingEquipment>(
        keyPrefix: 'coach-brief-equipment',
        values: CoachTrainingEquipment.values,
        selected: _equipment,
        onChanged: (v) => _choose(() => _equipment = v),
        labelOf: (v) => _equipmentLabel(l10n, v),
        iconOf: (v, color) => Icon(
          switch (v) {
            CoachTrainingEquipment.bodyweight =>
              Icons.accessibility_new_rounded,
            CoachTrainingEquipment.dumbbells => Icons.fitness_center_rounded,
            CoachTrainingEquipment.gym => Icons.warehouse_rounded,
          },
          size: 20,
          color: color,
        ),
      ),
      _section(context, l10n.coachBriefSchedule),
      AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            _StepperRow(
              keyPrefix: 'coach-brief-sessions',
              label: l10n.coachBriefSessions,
              number: '$_sessions',
              unit: '×',
              unitAsNumber: true,
              spoken: l10n.coachBriefSessionsValue,
              value: _sessions,
              canDecrease: _sessions > _sessionsMin,
              canIncrease: _sessions < _sessionsMax,
              onStep: _stepSessions,
            ),
            Divider(
              height: 1,
              thickness: 1,
              indent: 16,
              endIndent: 16,
              color: t.line,
            ),
            _StepperRow(
              keyPrefix: 'coach-brief-minutes',
              label: l10n.coachBriefMinutes,
              number: '$_minutes',
              unit: ' ${l10n.coachBriefMinutesUnit}',
              spoken: l10n.coachBriefMinutesValue,
              value: _minutes,
              nextUp: _minuteSteps.firstWhere(
                (m) => m > _minutes,
                orElse: () => _minutes,
              ),
              nextDown: _minuteSteps.lastWhere(
                (m) => m < _minutes,
                orElse: () => _minutes,
              ),
              canDecrease: _minutes > _minuteSteps.first,
              canIncrease: _minutes < _minuteSteps.last,
              onStep: _stepMinutes,
            ),
          ],
        ),
      ),
      _section(context, l10n.coachBriefWish),
      _field(
        key: 'coach-brief-wish',
        label: l10n.coachBriefWish,
        hint: l10n.coachBriefWishHint,
        controller: _wish,
        focus: _wishFocus,
        maximum: 1000,
      ),
    ];
  }

  /// A section's label, a heading for screen-reader navigation.
  Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: HeadingSemantics(
      level: 2,
      child: Text(
        label,
        style: AppType.ui(15, weight: FontWeight.w700, color: context.t.ink),
      ),
    ),
  );

  /// Quick goals as chips that write into the goal field; "Own goal" opens
  /// the field itself.
  Widget _goalChoices(BuildContext context) {
    final l10n = context.l10n;
    final preset = _goalPreset(l10n);
    final ownGoal = preset == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (key, text) in _goalPresets(l10n))
              FilterChipPill(
                key: ValueKey('coach-brief-goal-$key'),
                label: text,
                selected: text == preset,
                onTap: () => _pickGoal(text),
              ),
            FilterChipPill(
              key: const ValueKey('coach-brief-goal-own'),
              label: l10n.coachBriefGoalOwn,
              icon: Icons.edit_rounded,
              selected: ownGoal,
              onTap: _pickOwnGoal,
            ),
          ],
        ),
        maybeAnimatedSize(
          context,
          duration: _kSelect,
          curve: kMotionCurve,
          alignment: Alignment.topCenter,
          child: ownGoal
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _field(
                    key: 'coach-brief-goal',
                    label: l10n.coachBriefGoal,
                    hint: l10n.coachBriefGoalHint,
                    controller: _goal,
                    focus: _goalFocus,
                    maximum: 200,
                    error: _goalRequiredError
                        ? l10n.trainingPageRequired
                        : null,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// A [SheetField]-style capsule that starts at one line and grows to four.
  Widget _field({
    required String key,
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focus,
    required int maximum,
    String? error,
  }) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldCapsule(
          focusNode: focus,
          error: error != null,
          child: Semantics(
            label: label,
            child: TextField(
              key: ValueKey(key),
              controller: controller,
              focusNode: focus,
              minLines: 1,
              maxLines: 4,
              maxLength: maximum,
              inputFormatters: [LengthLimitingTextInputFormatter(maximum)],
              textCapitalization: TextCapitalization.sentences,
              cursorColor: t.accent,
              style: AppType.ui(15, color: t.ink),
              decoration: InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                isDense: true,
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
                hintText: hint,
                hintStyle: AppType.ui(15, color: t.ink2),
              ),
              onChanged: (_) {
                if (_error != null || _goalRequiredError) {
                  setState(() {
                    _error = null;
                    if (_goal.text.trim().isNotEmpty) {
                      _goalRequiredError = false;
                    }
                  });
                }
              },
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(
            error,
            style: AppType.ui(13, weight: FontWeight.w500, color: t.danger),
          ),
        ],
      ],
    );
  }

  /// The pinned bar: what will be asked, the one action, what it costs.
  Widget _bar(BuildContext context, {required bool compact}) {
    final t = context.t;
    final l10n = context.l10n;
    final summary = [
      l10n.coachBriefSessionsValue(_sessions),
      l10n.coachBriefMinutesValue(_minutes),
      _equipmentLabel(l10n, _equipment),
    ].join(' · ');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: AppType.ui(14, color: t.danger, height: 1.4),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Visibility(
                visible: !compact,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    summary,
                    key: const ValueKey('coach-brief-summary'),
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      13.5,
                      weight: FontWeight.w600,
                      color: t.inkMuted,
                    ),
                  ),
                ),
              ),
              PrimaryActionButton(
                key: const ValueKey('coach-brief-submit'),
                label: switch (_intent) {
                  CoachTrainingIntent.create => l10n.coachBriefGenerate,
                  CoachTrainingIntent.adapt => l10n.coachBriefSendAdapt,
                  CoachTrainingIntent.discuss => l10n.coachBriefSendDiscussion,
                },
                onTap: _submitted ? null : _submit,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.coachBriefQuota,
                key: const ValueKey('coach-brief-quota'),
                textAlign: TextAlign.center,
                style: AppType.ui(12, color: t.ink3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What leaves the device with this request, as one quiet row.
class _SharedNote extends StatelessWidget {
  const _SharedNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The glyph sits centred on the first line at any text size.
    final firstLine = MediaQuery.textScalerOf(context).scale(13) * 1.35;
    return Container(
      key: const ValueKey('coach-brief-shared'),
      padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: math.max(0, (firstLine - 16) / 2)),
            child: Icon(Icons.lock_outline_rounded, size: 16, color: t.ink2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(13, color: t.ink2, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single choice of three: icon over label in one track, the chosen
/// segment in the accent fill ([SelectionTone]). When a label's longest word
/// would not fit a third of the track at the current text size, the options
/// stack into rows of icon and label inside the same track.
class _BriefSegments<T extends Enum> extends StatelessWidget {
  const _BriefSegments({
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.labelOf,
    required this.iconOf,
  });

  final String keyPrefix;
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;

  /// The glyph in the given ink.
  final Widget Function(T, Color) iconOf;

  static const double _inset = 4;

  TextStyle _labelStyle(Color color) =>
      AppType.ui(13, weight: FontWeight.w700, color: color, height: 1.2);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return LayoutBuilder(
      builder: (context, constraints) {
        final perSegment = (constraints.maxWidth - _inset * 2) / values.length;
        var widestWord = 0.0;
        for (final value in values) {
          for (final word in labelOf(value).split(' ')) {
            final painter = TextPainter(
              text: TextSpan(text: word, style: _labelStyle(t.ink)),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
            )..layout();
            widestWord = math.max(widestWord, painter.width);
            painter.dispose();
          }
        }
        final stacked = widestWord + 16 > perSegment;
        final segments = [
          for (final value in values) _segment(context, value, stacked),
        ];
        return Container(
          padding: const EdgeInsets.all(_inset),
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rControl + _inset),
            border: Border.all(color: t.line),
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: segments,
                )
              : IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final segment in segments) Expanded(child: segment),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _segment(BuildContext context, T value, bool stacked) {
    final t = context.t;
    final on = value == selected;
    final glyph = ExcludeSemantics(
      child: iconOf(value, on ? t.onSelected : t.ink2),
    );
    final label = Text(
      labelOf(value),
      textAlign: stacked ? TextAlign.start : TextAlign.center,
      style: _labelStyle(on ? t.onSelected : t.inkMuted),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rControl),
    );
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        child: Material(
          color: on ? t.selectedFill : Colors.transparent,
          animationDuration: motionDuration(context, _kSelect),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('$keyPrefix-${value.name}'),
            onTap: () {
              if (!on) onChanged(value);
            },
            customBorder: shape,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: stacked ? 48 : 64),
              child: Padding(
                padding: stacked
                    ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                    : const EdgeInsets.fromLTRB(6, 12, 6, 12),
                child: stacked
                    ? Row(
                        children: [
                          glyph,
                          const SizedBox(width: 12),
                          Expanded(child: label),
                        ],
                      )
                    // Top-aligned: a label on two lines keeps its glyph in
                    // line with the others.
                    : Column(
                        children: [glyph, const SizedBox(height: 6), label],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [level] of three rising bars: how much training experience, readable
/// before the word.
class _LevelMark extends StatelessWidget {
  const _LevelMark({required this.level, required this.color});

  final int level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 2.5),
              Container(
                width: 4.5,
                height: 6.0 + 5 * i,
                decoration: BoxDecoration(
                  color: i < level ? color : color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A labelled number with round minus and plus buttons. Screen readers get
/// one adjustable node (label, value, swipe up and down) besides the
/// buttons.
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.keyPrefix,
    required this.label,
    required this.number,
    required this.unit,
    required this.spoken,
    required this.value,
    required this.canDecrease,
    required this.canIncrease,
    required this.onStep,
    this.unitAsNumber = false,
    this.nextUp,
    this.nextDown,
  });

  /// Width of the reading between the buttons, at 1.0 text: "90 min" fits,
  /// and both rows' buttons line up.
  static const double _readingWidth = 80;

  final String keyPrefix;
  final String label;
  final String number;
  final String unit;

  /// Draws [unit] at the number's size ("4×"), not as a small suffix.
  final bool unitAsNumber;

  /// Spoken form of a value ("3× a week").
  final String Function(int) spoken;
  final int value;

  /// The values one step away; default `value ± 1`.
  final int? nextUp;
  final int? nextDown;
  final bool canDecrease;
  final bool canIncrease;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final span = TextSpan(
      children: [
        TextSpan(
          text: number,
          style: AppType.display(22, color: t.ink, height: 1.1),
        ),
        TextSpan(
          text: unit,
          style: unitAsNumber
              ? AppType.display(22, color: t.ink2, height: 1.1)
              : AppType.display(15, weight: FontWeight.w700, color: t.ink2),
        ),
      ],
    );
    final scaler = MediaQuery.textScalerOf(context);
    final measure = TextPainter(
      text: span,
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final readingWidth = math.max(scaler.scale(_readingWidth), measure.width);
    measure.dispose();
    final reading = ExcludeSemantics(
      child: Text.rich(
        span,
        key: ValueKey('$keyPrefix-value'),
        textAlign: TextAlign.center,
        maxLines: 1,
      ),
    );
    Widget button(int step) => _StepButton(
      actionKey: ValueKey('$keyPrefix-${step < 0 ? 'dec' : 'inc'}'),
      icon: step < 0 ? Icons.remove_rounded : Icons.add_rounded,
      semanticLabel: step < 0
          ? l10n.onboardingStepDownSemanticLabel
          : l10n.onboardingStepUpSemanticLabel,
      onTap: (step < 0 ? canDecrease : canIncrease) ? () => onStep(step) : null,
    );
    final title = ExcludeSemantics(
      child: Text(
        label,
        style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
      ),
    );
    return Semantics(
      container: true,
      label: label,
      value: spoken(value),
      increasedValue: canIncrease ? spoken(nextUp ?? value + 1) : null,
      decreasedValue: canDecrease ? spoken(nextDown ?? value - 1) : null,
      onIncrease: canIncrease ? () => onStep(1) : null,
      onDecrease: canDecrease ? () => onStep(-1) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Side by side while the label keeps ~110 px of 1.0 text;
            // stacked, the reading takes the row and only it may shrink.
            final stacked =
                constraints.maxWidth - 2 * _StepButton.size - readingWidth <
                scaler.scale(110);
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      button(-1),
                      Expanded(
                        child: FittedBox(fit: BoxFit.scaleDown, child: reading),
                      ),
                      button(1),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                button(-1),
                SizedBox(width: readingWidth, child: reading),
                button(1),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Round 44 px stepper button in the accent tint.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.actionKey,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  static const double size = 44;

  final Key actionKey;
  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: PressScale(
        enabled: enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Material(
            color: t.accentTint,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: actionKey,
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: size,
                child: Icon(icon, size: 22, color: t.accentText),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The plan sent along with the brief: a compact row that names the plan and
/// opens its workouts below.
class _PlanPreviewCard extends StatefulWidget {
  const _PlanPreviewCard({required this.plan});

  final TrainingPlan plan;

  @override
  State<_PlanPreviewCard> createState() => _PlanPreviewCardState();
}

class _PlanPreviewCardState extends State<_PlanPreviewCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = widget.plan;
    const motion = Duration(milliseconds: 180);
    final header = Semantics(
      button: true,
      expanded: _open,
      label: '${plan.title}, ${l10n.coachBriefPreviewPlan}',
      child: InkWell(
        key: const ValueKey('coach-brief-plan-preview'),
        onTap: () => setState(() => _open = !_open),
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  // From 1.5x text the tile gives its width to the title.
                  if (MediaQuery.textScalerOf(context).scale(16) <= 24) ...[
                    IconTile.custom(
                      color: t.accent,
                      size: 36,
                      child: const AppIcon(AppSymbol.training, size: 18),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.coachBriefSelectedPlan.toUpperCase(),
                          style: AppType.sectionEyebrow(t.ink3, size: 11),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          plan.title,
                          style: AppType.ui(
                            15,
                            weight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: motionDuration(context, motion),
                    curve: kMotionCurve,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 22,
                      color: t.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, thickness: 1, color: t.line),
          const SizedBox(height: 12),
          if (plan.description.isNotEmpty)
            Text(
              plan.description,
              style: AppType.ui(14, color: t.ink2, height: 1.45),
            ),
          if (plan.goal.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              plan.goal,
              style: AppType.ui(
                14,
                weight: FontWeight.w600,
                color: t.accentText,
              ),
            ),
          ],
          for (final workout in plan.workouts) ...[
            const SizedBox(height: 14),
            Text(
              workout.title,
              style: AppType.ui(15, weight: FontWeight.w700, color: t.ink),
            ),
            if (workout.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  workout.description,
                  style: AppType.ui(14, color: t.ink2, height: 1.45),
                ),
              ),
            TrainingExerciseList(exercises: workout.exercises),
          ],
        ],
      ),
    );
    return AppCard(
      clip: true,
      radius: rTile,
      // Own ink layer: the card's fill would hide the sheet's ripples.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            maybeAnimatedSize(
              context,
              duration: motion,
              curve: kMotionCurve,
              alignment: Alignment.topCenter,
              child: _open ? body : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
