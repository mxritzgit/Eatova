import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/coach_training_context.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
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
        _goalRequiredError = _goal.text.trim().isEmpty;
        _error = l10n.coachBriefInvalid;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = widget.selectedPlan;
    return SingleChildScrollView(
      key: const ValueKey('coach-brief-scroll'),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const ValueKey('coach-brief-close'),
              tooltip: l10n.trainingPageCancel,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          HeadingSemantics(
            level: 1,
            child: Text(
              l10n.coachBriefTitle,
              style: AppType.display(24, color: t.ink, height: 1.15),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.coachBriefDataUsed,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 20),
          if (plan != null) ...[
            Text(
              l10n.coachBriefSelectedPlan,
              style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
            ),
            const SizedBox(height: 8),
            _PlanPreviewCard(plan: plan),
            const SizedBox(height: 20),
            _choices(
              l10n.coachBriefIntent,
              CoachTrainingIntent.values.where(
                (v) => v != CoachTrainingIntent.create,
              ),
              _intent,
              (v) => v == CoachTrainingIntent.discuss
                  ? l10n.coachBriefDiscuss
                  : l10n.coachBriefAdapt,
              (v) => setState(() => _intent = v),
            ),
          ],
          _textField(
            'coach-brief-goal',
            l10n.coachBriefGoal,
            _goal,
            _goalFocus,
            200,
          ),
          _choices(
            l10n.coachBriefExperience,
            CoachTrainingExperience.values,
            _experience,
            (v) => switch (v) {
              CoachTrainingExperience.beginner => l10n.coachBriefBeginner,
              CoachTrainingExperience.intermediate =>
                l10n.coachBriefIntermediate,
              CoachTrainingExperience.advanced => l10n.coachBriefAdvanced,
            },
            (v) => setState(() => _experience = v),
          ),
          _choices(
            l10n.coachBriefEquipment,
            CoachTrainingEquipment.values,
            _equipment,
            (v) => switch (v) {
              CoachTrainingEquipment.bodyweight => l10n.coachBriefBodyweight,
              CoachTrainingEquipment.dumbbells => l10n.coachBriefDumbbells,
              CoachTrainingEquipment.gym => l10n.coachBriefGym,
            },
            (v) => setState(() => _equipment = v),
          ),
          _choices(
            l10n.coachBriefSessions,
            List.generate(7, (i) => i + 1),
            _sessions,
            (v) => '$v',
            (v) => setState(() => _sessions = v),
          ),
          _choices(
            l10n.coachBriefMinutes,
            const [15, 20, 30, 45, 60, 90],
            _minutes,
            (v) => '$v',
            (v) => setState(() => _minutes = v),
          ),
          _textField(
            'coach-brief-wish',
            l10n.coachBriefWish,
            _wish,
            _wishFocus,
            1000,
          ),
          Text(
            l10n.coachBriefDraftNotice,
            style: AppType.ui(14, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: AppType.ui(14, color: t.danger, height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
          ],
          PrimaryActionButton(
            key: const ValueKey('coach-brief-submit'),
            label: _intent == CoachTrainingIntent.discuss
                ? l10n.coachBriefSendDiscussion
                : l10n.coachBriefGenerate,
            onTap: _submitted ? null : _submit,
          ),
        ],
      ),
    );
  }

  Widget _choices<T>(
    String label,
    Iterable<T> values,
    T selected,
    String Function(T) title,
    ValueChanged<T> onSelect,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppType.ui(
              14,
              weight: FontWeight.w600,
              color: context.t.ink,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                // The app's selection chip, held to the 44 px touch floor.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: FilterChipPill(
                    label: title(value),
                    selected: value == selected,
                    onTap: () => onSelect(value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(
    String key,
    String label,
    TextEditingController controller,
    FocusNode focus,
    int maximum,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppType.ui(
              14,
              weight: FontWeight.w600,
              color: context.t.ink,
            ),
          ),
          const SizedBox(height: 8),
          FieldCapsule(
            focusNode: focus,
            child: TextField(
              key: ValueKey(key),
              controller: controller,
              focusNode: focus,
              minLines: 1,
              maxLines: 4,
              maxLength: maximum,
              inputFormatters: [LengthLimitingTextInputFormatter(maximum)],
              decoration: InputDecoration(
                labelText: label,
                floatingLabelBehavior: FloatingLabelBehavior.never,
                border: InputBorder.none,
                counterText: '',
                errorText: controller == _goal && _goalRequiredError
                    ? context.l10n.trainingPageRequired
                    : null,
              ),
              style: AppType.ui(15, color: context.t.ink),
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
        ],
      ),
    );
  }
}

/// The plan sent along with the brief: a card whose header row names the plan
/// and opens its workouts below.
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
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  // From 1.5x text the tile gives its width to the title.
                  if (MediaQuery.textScalerOf(context).scale(16) <= 24) ...[
                    IconTile.custom(
                      color: t.accent,
                      size: 40,
                      child: const AppIcon(AppSymbol.training, size: 20),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          plan.title,
                          style: AppType.ui(
                            16,
                            weight: FontWeight.w700,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.coachBriefPreviewPlan,
                          style: AppType.ui(13, color: t.ink2, height: 1.35),
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
