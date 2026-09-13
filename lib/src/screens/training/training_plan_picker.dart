import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/training_plan.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'training_studio_widgets.dart';

enum TrainingPlanLibraryAction { create, coach }

/// Selection is returned to the account-bound caller; this sheet never writes.
class TrainingPlanPicker extends StatefulWidget {
  const TrainingPlanPicker({
    super.key,
    required this.plans,
    this.selectedPlanId,
  });

  final List<TrainingPlan> plans;
  final String? selectedPlanId;

  @override
  State<TrainingPlanPicker> createState() => _TrainingPlanPickerState();
}

class _TrainingPlanPickerState extends State<TrainingPlanPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plans =
        widget.plans
            .where(
              (plan) => [
                plan.title,
                plan.goal,
                ...plan.workouts.map((workout) => workout.title),
              ].join(' ').toLowerCase().contains(_query),
            )
            .toList()
          ..sort((a, b) {
            if (a.id == b.id) return 0;
            if (a.id == widget.selectedPlanId) return -1;
            if (b.id == widget.selectedPlanId) return 1;
            return widget.plans.indexOf(a).compareTo(widget.plans.indexOf(b));
          });
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('training-plan-library-scroll'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.trainingPagePlans,
                        style: AppType.display(28, color: t.ink),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        l10n.trainingStudioLibrarySubtitle,
                        style: AppType.ui(14, color: t.ink2, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SquareIconButton(
                  key: const ValueKey('training-library-close'),
                  icon: Icons.close_rounded,
                  semanticLabel: l10n.trainingPageClose,
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 22),
            SheetField(
              key: const ValueKey('training-plan-search'),
              controller: _search,
              hint: l10n.trainingStudioSearch,
              semanticLabel: l10n.trainingStudioSearch,
              prefix: Icon(Icons.search_rounded, color: t.ink2),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 20),
            for (final plan in plans) ...[
              _PlanCard(
                key: ValueKey(plan.id),
                plan: plan,
                selected: plan.id == widget.selectedPlanId,
              ),
              const SizedBox(height: 12),
            ],
            if (plans.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  widget.plans.isEmpty
                      ? l10n.trainingStudioLibraryEmpty
                      : l10n.trainingStudioNoPlans,
                  style: AppType.ui(16, color: t.ink2, height: 1.5),
                ),
              ),
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('training-library-create'),
              onPressed: () =>
                  Navigator.pop(context, TrainingPlanLibraryAction.create),
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.trainingPageCreate),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                backgroundColor: t.surf2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('training-library-coach'),
              onPressed: () =>
                  Navigator.pop(context, TrainingPlanLibraryAction.coach),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: Text(l10n.trainingPageCoach),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatefulWidget {
  const _PlanCard({super.key, required this.plan, required this.selected});
  final TrainingPlan plan;
  final bool selected;

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final plan = widget.plan;
    final selected = widget.selected;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? t.surf : t.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(
            color: selected ? t.lime.withValues(alpha: 0.65) : t.line,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('training-select-${plan.id}'),
          onTap: () => Navigator.pop(context, plan.id),
          child: Stack(
            children: [
              if (selected)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 190,
                  child: IgnorePointer(
                    child: TrainingStudioArtwork(backgroundColor: t.surf),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            selected
                                ? l10n.trainingStudioSelected
                                : l10n.trainingPageWorkoutCount(
                                    plan.workouts.length,
                                  ),
                            style: AppType.ui(
                              12,
                              weight: FontWeight.w700,
                              color: selected ? t.lime : t.ink2,
                            ),
                          ),
                        ),
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.arrow_outward_rounded,
                          size: 21,
                          color: selected ? t.lime : t.ink2,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      plan.title,
                      style: AppType.display(
                        MediaQuery.textScalerOf(context).scale(16) > 24
                            ? 20
                            : selected
                            ? 26
                            : 23,
                        color: t.ink,
                        height: 1.15,
                      ),
                    ),
                    if (plan.goal.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        plan.goal,
                        style: AppType.ui(14, color: t.ink2, height: 1.45),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Divider(color: t.line, height: 1),
                    const SizedBox(height: 12),
                    for (var i = 0; i < plan.workouts.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 30,
                              child: Text(
                                String.fromCharCode(65 + i),
                                style: AppType.ui(
                                  13,
                                  weight: FontWeight.w700,
                                  color: t.lime,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                plan.workouts[i].title,
                                style: AppType.ui(14, color: t.ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (plan.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      TextButton(
                        key: ValueKey('training-plan-description-${plan.id}'),
                        onPressed: () => setState(() => _details = !_details),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                l10n.trainingStudioPlanDescription,
                                style: AppType.ui(13, color: t.ink2),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              _details
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18,
                              color: t.ink2,
                            ),
                          ],
                        ),
                      ),
                      if (_details)
                        Text(
                          plan.description,
                          style: AppType.ui(14, color: t.ink2, height: 1.5),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
