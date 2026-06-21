import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../common/motion.dart';

class ShiftFitBottomNav extends StatelessWidget {
  const ShiftFitBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _items = [
    (Icons.home_rounded, 'Heute'),
    (Icons.fitness_center_rounded, 'Training'),
    (Icons.insights_rounded, 'Trends'),
    (Icons.restaurant_rounded, 'Food'),
    (Icons.menu_book_rounded, 'Rezepte'),
    (Icons.chat_bubble_outline_rounded, 'Coach'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: const BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: hairline)),
        boxShadow: [
          BoxShadow(
            color: shadowTint,
            blurRadius: 24,
            offset: Offset(0, -8),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: _NavItem(
                key: ValueKey('nav-${_items[i].$2}'),
                icon: _items[i].$1,
                label: _items[i].$2,
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? lime : textMuted;
    // A11y: unter "Bewegung reduzieren" die Tab-Wechsel-Animation auf 0.
    final navMotion = motionDuration(context, const Duration(milliseconds: 220));
    // A11y: Tab als Button mit Auswahl-Status ansagen; die inneren Glyphen/
    // Texte aus dem Semantics-Baum nehmen, damit nur ein Label vorliegt.
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: navMotion,
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 6),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color:
                  selected ? lime.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(rCard),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: selected ? 1.12 : 1.0,
                  duration: navMotion,
                  curve: Curves.easeOutBack,
                  child: Icon(icon, size: 22, color: color),
                ),
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: navMotion,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    letterSpacing: -0.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
