import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/day_math.dart';
import '../../services/kcal_format.dart';
import '../../theme/app_tokens.dart';
import '../design/surfaces.dart' show HeadingSemantics;

/// The diary owns its gutters so its entry dock can meet the navigation bar.
class FoodPageHeader extends StatelessWidget {
  const FoodPageHeader({
    super.key,
    required this.consumedKcal,
    required this.loading,
    required this.onTrends,
    this.onOptions,
  });

  final int consumedKcal;
  final bool loading;
  final VoidCallback onTrends;
  final ValueChanged<BuildContext>? onOptions;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: HeadingSemantics(
            level: 1,
            child: Text(l10n.navFood, style: AppType.display(34, color: t.ink)),
          ),
        ),
        if (onOptions != null)
          Builder(
            builder: (anchor) => IconButton(
              key: const ValueKey('food-options'),
              tooltip: l10n.foodOptions,
              icon: Icon(Icons.more_horiz_rounded, color: t.ink2),
              onPressed: () => onOptions!(anchor),
            ),
          ),
      ],
    );
    final total = Material(
      color: t.brandSurface,
      borderRadius: BorderRadius.circular(rControl),
      child: InkWell(
        key: const ValueKey('topbar-trends'),
        borderRadius: BorderRadius.circular(rControl),
        onTap: onTrends,
        child: Semantics(
          button: true,
          hint: l10n.foodSemanticsTrends,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  loading
                      ? '—'
                      : formatThousands(consumedKcal, l10n.localeName),
                  key: const ValueKey('food-day-total'),
                  style: AppType.display(
                    25,
                    color: t.onBrandSurface,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  l10n.foodKcalLoggedLabel,
                  style: AppType.ui(
                    10,
                    weight: FontWeight.w600,
                    color: t.accent,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 12), total],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 12),
              total,
            ],
          );
        },
      ),
    );
  }
}

class FoodDayNavigation extends StatelessWidget {
  const FoodDayNavigation({
    super.key,
    required this.day,
    required this.label,
    required this.onSelected,
    required this.onCalendar,
  });

  final DateTime day;
  final String label;
  final ValueChanged<DateTime> onSelected;
  final VoidCallback onCalendar;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final today = DateUtils.dateOnly(clock.now());
    final first = DateTime(today.year - 2, today.month, today.day);
    return Padding(
      key: const ValueKey('food-date-strip'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          IconButton.outlined(
            key: const ValueKey('food-date-previous'),
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              side: BorderSide(color: t.line),
            ),
            tooltip: l10n.todaySemanticsDatePrev,
            onPressed: day.isAfter(first)
                ? () => onSelected(addDays(day, -1))
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: InkWell(
              key: const ValueKey('food-date-calendar'),
              borderRadius: BorderRadius.circular(rControl),
              onTap: onCalendar,
              child: Semantics(
                button: true,
                hint: l10n.foodCalendarButtonSemantics,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 18,
                        color: t.ink2,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          label,
                          key: const ValueKey('food-date-selected-label'),
                          textAlign: TextAlign.center,
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton.outlined(
            key: const ValueKey('food-date-next'),
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              side: BorderSide(color: t.line),
            ),
            tooltip: l10n.todaySemanticsDateNext,
            onPressed: day.isBefore(today)
                ? () => onSelected(addDays(day, 1))
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

/// A fixed, quiet capture surface; the actual search input lives in its sheet.
class FoodEntryDock extends StatelessWidget {
  const FoodEntryDock({
    super.key,
    required this.onSearch,
    required this.onCamera,
    required this.onBarcode,
    required this.onManual,
    this.enabled = true,
  });

  final VoidCallback onSearch, onCamera, onBarcode, onManual;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Material(
      key: const ValueKey('food-entry-dock'),
      color: t.brandSurface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(rSheet)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: t.surf,
              borderRadius: BorderRadius.circular(rControl),
              child: InkWell(
                key: const ValueKey('food-search'),
                borderRadius: BorderRadius.circular(rControl),
                onTap: enabled ? onSearch : null,
                child: Semantics(
                  button: true,
                  enabled: enabled,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded, size: 22, color: t.ink2),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.foodSearchPlaceholder,
                            style: AppType.ui(14, color: t.ink2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth < 300 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20;
                final actions = [
                  _DockAction(
                    actionKey: const ValueKey('food-action-ai'),
                    icon: Icons.photo_camera_outlined,
                    label: l10n.recipesCameraAction,
                    onTap: enabled ? onCamera : null,
                    stacked: stacked,
                  ),
                  _DockAction(
                    actionKey: const ValueKey('food-action-barcode'),
                    icon: Icons.qr_code_scanner_rounded,
                    label: l10n.foodActionBarcode,
                    onTap: enabled ? onBarcode : null,
                    stacked: stacked,
                  ),
                  _DockAction(
                    actionKey: const ValueKey('food-action-manual'),
                    icon: Icons.edit_outlined,
                    label: l10n.foodSourceManual,
                    onTap: enabled ? onManual : null,
                    stacked: stacked,
                  ),
                ];
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: actions,
                  );
                }
                return Row(
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0)
                        Container(
                          height: 22,
                          width: 1,
                          color: t.accent.withValues(alpha: 0.18),
                        ),
                      Expanded(child: actions[i]),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.stacked,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool stacked;

  @override
  Widget build(BuildContext context) => InkWell(
    key: actionKey,
    onTap: onTap,
    borderRadius: BorderRadius.circular(rControl),
    child: Semantics(
      button: true,
      enabled: onTap != null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
        child: Row(
          mainAxisAlignment: stacked
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: context.t.accent),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                style: AppType.ui(
                  12,
                  weight: FontWeight.w600,
                  color: context.t.onBrandSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
