import 'package:flutter/material.dart';

import '../../models/exercises/workout.dart';
import '../../theme/app_colors.dart';

/// Tappable card for a single guided [Workout] in the Übungen tab. Shows the
/// title, subtitle, a meta row (Übungen + Minuten) and the deduplicated focus
/// chips derived from the steps' clips, plus a clear lime play affordance.
///
/// Visuals follow the design tokens: [surface] body, [cardShadow] elevation,
/// [rCard] radius and [hairline] detailing. Tapping invokes [onTap].
class WorkoutCard extends StatelessWidget {
  const WorkoutCard({
    super.key,
    required this.workout,
    required this.onTap,
  });

  final Workout workout;
  final VoidCallback onTap;

  /// Distinct muscle focuses across the workout's steps, in first-seen order,
  /// e.g. `Beine · Cardio · Core`. Deduplicated so a focus shows only once.
  List<String> get _focusTags {
    final List<String> tags = <String>[];
    for (final WorkoutStep step in workout.steps) {
      final String focus = step.clip.focus;
      if (!tags.contains(focus)) tags.add(focus);
    }
    return tags;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> focusTags = _focusTags;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rCard),
        boxShadow: cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('workout-card-${workout.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(rCard),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(rCard),
              border: Border.all(color: hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            workout.title,
                            style: const TextStyle(
                              color: textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            workout.subtitle,
                            style: const TextStyle(
                              color: textMuted,
                              fontSize: 12.5,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    const _PlayPill(),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    _MetaItem(
                      icon: Icons.fitness_center_rounded,
                      label: '${workout.exerciseCount} Übungen',
                    ),
                    const SizedBox(width: 8),
                    _MetaItem(
                      icon: Icons.schedule_rounded,
                      label: 'ca. ${workout.totalMinutes} Min',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String focus in focusTags) _FocusChip(label: focus),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Round lime play button signalling the card starts the workout.
class _PlayPill extends StatelessWidget {
  const _PlayPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: const BoxDecoration(
        color: lime,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: bg,
        size: 28,
      ),
    );
  }
}

/// Compact icon + label used for the workout meta row (count, duration).
class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: textMuted),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small lime-tinted chip for a single muscle focus.
class _FocusChip extends StatelessWidget {
  const _FocusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: lime.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rChip),
        border: Border.all(color: lime.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: lime,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
