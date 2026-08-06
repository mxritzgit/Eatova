import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../models/logged_meal.dart';
import '../../models/macro_progress.dart';
import '../../models/user_profile.dart';
import '../../theme/app_colors.dart';
import '../../theme/meal_slot_style.dart';
import '../common/basic_widgets.dart';
import 'edit_meal_sheet.dart';

class CaloriesOverviewCard extends StatelessWidget {
  const CaloriesOverviewCard({
    super.key,
    required this.dailyConsumedKcal,
    required this.kcalGoal,
    this.burnedKcal = 0,
    required this.macroProgress,
    required this.profile,
  });

  final int dailyConsumedKcal;
  final int kcalGoal;
  final int burnedKcal;
  final MacroProgress macroProgress;
  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final goal = kcalGoal <= 0 ? 1 : kcalGoal;
    final eaten = dailyConsumedKcal.clamp(0, 99999).toInt();
    final burned = burnedKcal.clamp(0, 99999).toInt();
    final adjustedGoal = goal + burned;
    final remaining = (adjustedGoal - eaten).clamp(-99999, 99999).toInt();
    final progress = (eaten / adjustedGoal).clamp(0.0, 1.0);
    final remainingColor = remaining >= 0 ? forgeLime : danger;

    // Die Karte laeuft im Food-Tab in einer festen Flex-Hoehe. Die Stufen
    // muessen daher mit der Systemschrift mitwandern: bei 1.3x (App-Cap, s.
    // EatovaApp) braucht derselbe Inhalt ~30 % mehr Hoehe, sonst kippt die
    // Karte in einen Bottom-Overflow.
    final textScale = MediaQuery.textScalerOf(context).scale(100) / 100;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : double.infinity;
        final compact = maxHeight < 265 * textScale;
        final tight = maxHeight < 200 * textScale;
        final padding = EdgeInsets.all(tight ? 10 : (compact ? 14 : 18));
        final ringSize = tight ? 54.0 : (compact ? 72.0 : 92.0);
        final remainingSize = tight ? 28.0 : (compact ? 38.0 : 46.0);
        final titleGap = tight ? 3.0 : (compact ? 6.0 : 8.0);
        final statsGap = tight ? 5.0 : (compact ? 8.0 : 12.0);
        final macrosGap = tight ? 6.0 : (compact ? 10.0 : 14.0);

        // spaceBetween in allen Stufen: der Inhalt passt jetzt ueberall in die
        // Stufe, restliche Hoehe wird gleichmaessig auf die Bloecke verteilt
        // statt als Leerraum unten zu haengen.
        final content = Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'VERBLEIBENDE KCAL',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                      SizedBox(height: titleGap),
                      // Einheit sitzt auf der Grundlinie neben der Zahl statt
                      // in einer eigenen Zeile: spart Hoehe und liest sich als
                      // ein Wert. Das frueher darunter stehende „Ziel: …" ist
                      // raus — die ZIEL-Kachel darunter zeigt exakt dasselbe.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              _formatThousands(remaining),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: remainingColor,
                                fontSize: remainingSize,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                                letterSpacing: compact ? -1.4 : -1.8,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              'kcal',
                              style: TextStyle(
                                color: textMuted,
                                fontSize: tight ? 12 : 13,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: compact ? 8 : 10),
                SizedBox(
                  width: ringSize,
                  height: ringSize,
                  child: _ProgressRing(
                    progress: progress,
                    strokeWidth: compact ? 8 : 10,
                    // Nur die Prozentzahl im Ring. Das fruehere „des Ziels"
                    // darunter passte nie in den Innenkreis und schnitt den
                    // Ring optisch an — und der Bezug steht ohnehin links
                    // („VERBLEIBENDE KCAL") und in der ZIEL-Statistik.
                    child: Text(
                      '${(progress * 100).round()}%',
                      maxLines: 1,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: tight ? 17 : (compact ? 20 : 24),
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: statsGap),
            // Statistikzeile ohne Kacheln: drei Werte, durch Haarlinien
            // getrennt. Die frueheren Boxen waren ein Rahmen im Rahmen im
            // Rahmen — die Trenner leisten dasselbe mit einem Pixel.
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    icon: Icons.gps_fixed_rounded,
                    iconColor: forgeLime,
                    label: 'ZIEL',
                    value: '${_formatThousands(goal)} kcal',
                    compact: compact,
                    tight: tight,
                  ),
                ),
                const _StatDivider(),
                Expanded(
                  child: _StatTile(
                    icon: Icons.restaurant_rounded,
                    iconColor: forgeLime,
                    label: 'GEGESSEN',
                    value: '${_formatThousands(eaten)} kcal',
                    valueKey: const ValueKey('analyse-daily-kcal-total'),
                    compact: compact,
                    tight: tight,
                  ),
                ),
                const _StatDivider(),
                Expanded(
                  child: _StatTile(
                    icon: Icons.local_fire_department_outlined,
                    iconColor: cyan,
                    label: 'VERBRANNT',
                    value: burned == 0
                        ? '—'
                        : '${_formatThousands(burned)} kcal',
                    compact: compact,
                    tight: tight,
                  ),
                ),
              ],
            ),
            SizedBox(height: macrosGap),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _InlineMacroBar(
                    label: 'Proteine',
                    current: macroProgress.proteinG,
                    goal: profile.proteinGoalG.toDouble(),
                    color: forgeLime,
                    compact: compact,
                    tight: tight,
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Expanded(
                  child: _InlineMacroBar(
                    label: 'Kohlenhydrate',
                    current: macroProgress.carbsG,
                    goal: profile.carbsGoalG.toDouble(),
                    color: macroCarbs,
                    compact: compact,
                    tight: tight,
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Expanded(
                  child: _InlineMacroBar(
                    label: 'Fette',
                    current: macroProgress.fatG,
                    goal: profile.fatGoalG.toDouble(),
                    color: macroFat,
                    compact: compact,
                    tight: tight,
                  ),
                ),
              ],
            ),
          ],
        );

        return _GlassPanel(
          key: const ValueKey('analyse-daily-kcal-card'),
          padding: padding,
          child: content,
        );
      },
    );
  }
}

/// Translucent „Glass"-Panel im Stitch-„FORGE"-Stil: weicher forgeLime-Glow
/// oben-rechts, darüber ein BackdropFilter-Blur und ein transluzenter Fill mit
/// Hairline-Rand. Ersetzt die solide [AppCard] NUR für die Kalorienkarte.
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    super.key,
    required this.child,
    required this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: das doppelte Blur (BackdropFilter sigma 20 +
    // ImageFiltered sigma 40) ist teuer. Eigener Layer -> kein erneutes Blur-
    // Re-Raster, nur weil ein umgebender Repaint stattfindet.
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(rCard)),
          boxShadow: cardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(rCard),
          child: Stack(
            children: [
              // 1) Dekorativer, weicher forgeLime-Glow oben-rechts.
              Positioned(
                top: -50,
                right: -40,
                child: IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: forgeLime.withValues(alpha: 0.10),
                      ),
                    ),
                  ),
                ),
              ),
              // 2) Transluzentes Panel: Backdrop-Blur + Glass-Fill + Hairline.
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: forgeGlassFill,
                      borderRadius: BorderRadius.circular(rCard),
                      border: Border.all(color: forgeGlassBorder),
                    ),
                  ),
                ),
              ),
              // 3) Inhalt.
              Padding(
                padding: padding,
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Schmaler Inline-Makro-Balken (Label + aktuell/ziel-g + dünner Balken).
class _InlineMacroBar extends StatelessWidget {
  const _InlineMacroBar({
    required this.label,
    required this.current,
    required this.goal,
    required this.color,
    this.compact = false,
    this.tight = false,
  });

  final String label;
  final double current;
  final double goal;
  final Color color;
  final bool compact;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final ratio = goal <= 0 ? 0.0 : (current / goal).clamp(0.0, 1.0).toDouble();
    final currentG = current.round();
    final goalG = goal.round();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Name tritt zurueck, die Gramm-Zahl ist der Wert, den man abliest.
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: textMuted,
            fontSize: tight ? 10 : (compact ? 10.5 : 11),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
        SizedBox(height: tight ? 3 : 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            // surfaceSoft verschwindet auf dem Glas-Panel fast — die leere
            // Spur braucht eine eigene, vom Untergrund unabhaengige Deckkraft.
            backgroundColor: hairline,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        SizedBox(height: tight ? 3 : 5),
        Text(
          '$currentG/${goalG}g',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: textPrimary,
            fontSize: tight ? 10.5 : 11.5,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.valueKey,
    this.compact = false,
    this.tight = false,
  });

  final IconData icon;
  final Color iconColor;
  final String label;

  /// Fertig formatierter Wert inklusive Einheit (z. B. `'590 kcal'`).
  final String value;
  final Key? valueKey;
  final bool compact;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: iconColor, size: compact ? 10 : 12),
              SizedBox(width: compact ? 3 : 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: tight ? 8 : (compact ? 8.2 : 9),
                    fontWeight: FontWeight.w600,
                    letterSpacing: compact ? 0.35 : 0.6,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: tight ? 2 : 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              style: TextStyle(
                color: textPrimary,
                fontSize: tight ? 11.5 : (compact ? 12.5 : 14),
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Haarlinie zwischen zwei Werten der Statistikzeile. Bewusst kuerzer als die
/// Zeile hoch ist — ein Trenner soll gliedern, nicht ein Gitter aufziehen.
class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 24, color: hairline);
  }
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.progress,
    required this.child,
    this.strokeWidth = 10,
  });

  final double progress;
  final Widget child;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: eigener Layer fuer den Ring, damit scrollende/animierte
    // Geschwister ihn nicht mit-rasterisieren.
    return RepaintBoundary(
      child: CustomPaint(
        painter: _RingPainter(progress: progress, strokeWidth: strokeWidth),
        // Inhalt auf die Innenflaeche begrenzen: ohne das Inset lief das Label
        // („des Ziels") ueber den Ring hinaus und schnitt ihn optisch an.
        child: Padding(
          padding: EdgeInsets.all(strokeWidth + 3),
          child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: child),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.strokeWidth});

  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = strokeWidth;
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    final center = rect.center;
    final radius = rect.width / 2;

    final track = Paint()
      ..color = surfaceSoft
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    const startAngle = -math.pi / 2;
    final sweep = 2 * math.pi * progress;

    final gradient = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      transform: const GradientRotation(-math.pi / 2),
      // Energy ring is a single brand metric: forgeLime only, soft fade-in start.
      colors: [forgeLime.withValues(alpha: 0.45), forgeLime, forgeLime, forgeLime],
      stops: const [0.0, 0.45, 0.85, 1.0],
    );

    final arc = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, sweep, false, arc);

    const dotAngle = startAngle;
    final dotPos = Offset(
      center.dx + radius * math.cos(dotAngle),
      center.dy + radius * math.sin(dotAngle),
    );
    final dotPaint = Paint()..color = forgeLime.withValues(alpha: 0.9);
    canvas.drawCircle(dotPos, stroke / 2 + 2, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.strokeWidth != strokeWidth;
}

class MealsTodayCard extends StatelessWidget {
  const MealsTodayCard({
    super.key,
    required this.meals,
    this.onMealTap,
    this.onRemoveMeal,
  });

  final List<LoggedMeal> meals;
  final ValueChanged<MealSlot>? onMealTap;
  final ValueChanged<String>? onRemoveMeal;

  @override
  Widget build(BuildContext context) {
    final overallTotal =
        meals.fold<int>(0, (sum, m) => sum + m.result.caloriesKcal);
    // Kopie absteigend nach Zeitpunkt sortieren — Original nicht mutieren.
    final sorted = List<LoggedMeal>.of(meals)
      ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const Text(
          'Verlauf',
          style: TextStyle(
            color: textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const Spacer(),
        if (sorted.isNotEmpty) ...[
          Text(
            _formatThousands(overallTotal),
            style: const TextStyle(
              color: textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 3),
          const Text(
            'kcal',
            style: TextStyle(
              color: textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );

    return AppCard(
      key: const ValueKey('kcal-meals-today-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 6),
          Expanded(
            child: sorted.isEmpty
                ? const _HistoryEmptyState()
                // Weicher Fade an der Unterkante statt harter Schnittlinie,
                // wenn die Liste laenger als die Karte ist.
                : ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0.0, 0.93, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: SlidableAutoCloseBehavior(
                      child: ListView.separated(
                        key: const ValueKey('food-history'),
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: sorted.length,
                        // Haarlinie ab dem Icon eingerueckt — trennt die
                        // Zeilen, ohne die Liste in ein Gitter zu zerlegen.
                        separatorBuilder: (context, _) => const Padding(
                          padding: EdgeInsets.only(left: 48),
                          child: Divider(
                            height: 1,
                            thickness: 1,
                            color: hairline,
                          ),
                        ),
                        itemBuilder: (context, index) {
                          final meal = sorted[index];
                          // Bearbeiten-Sheet, wenn die Home-Schale den
                          // MealEditScope bereitstellt: Tap auf den Eintrag
                          // editiert GENAU DIESE Mahlzeit (Portion/Slot/Tag).
                          // Ohne Scope (Preview/Standalone) bleibt das alte
                          // Verhalten: Tap oeffnet das Add-Sheet des Slots.
                          final editScope = MealEditScope.maybeOf(context);
                          final VoidCallback? tap;
                          if (editScope != null) {
                            tap = () => showEditMealSheet(
                                  context,
                                  meal: meal,
                                  onUpdateMeal: editScope.onUpdateMeal,
                                  onRemoveMeal: editScope.onRemoveMeal,
                                );
                          } else if (onMealTap != null) {
                            tap = () => onMealTap!(meal.slot);
                          } else {
                            tap = null;
                          }
                          final entry = _HistoryEntry(
                            key: ValueKey('food-history-entry-$index'),
                            meal: meal,
                            index: index,
                            onTap: tap,
                          );
                          // Ohne Lösch-Callback: schlichte Zeile (kein Swipe).
                          if (onRemoveMeal == null) return entry;
                          // Links-Swipe: Zeile + Lösch-Button laufen gemeinsam
                          // (ScrollMotion), ClipRRect haelt alles in der
                          // Zeilenbreite statt aus der Karte zu ragen. Ganz
                          // durchwischen loescht direkt (DismissiblePane);
                          // Tap auf den Button animiert die Zeile erst raus
                          // und entfernt sie dann aus dem Store.
                          return ClipRRect(
                            key: ValueKey('food-history-clip-${meal.id}'),
                            borderRadius: BorderRadius.circular(rControl),
                            child: Slidable(
                              key: ValueKey('slide-${meal.id}'),
                              groupTag: 'food-history',
                              endActionPane: ActionPane(
                                motion: const ScrollMotion(),
                                extentRatio: _deleteExtent,
                                dismissible: DismissiblePane(
                                  onDismissed: () => onRemoveMeal!(meal.id),
                                ),
                                children: [
                                  _DeleteMealAction(
                                    key: ValueKey('food-history-delete-$index'),
                                    onDelete: () => onRemoveMeal!(meal.id),
                                  ),
                                ],
                              ),
                              child: entry,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: surfaceSoft,
              borderRadius: BorderRadius.circular(rPill),
            ),
            child: const Icon(
              Icons.restaurant_rounded,
              color: textMuted,
              size: 20,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Noch nichts geloggt',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tippe oben auf KI-Scan, Barcode oder Suche.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textMuted,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Anteil der Zeilenbreite, den die aufgezogene Lösch-Aktion einnimmt.
/// Auch das Fenster der Reveal-Animation: der SlidableController laeuft beim
/// Aufziehen von 0 bis genau zu diesem Wert (und beim Dismiss weiter bis 1).
const double _deleteExtent = 0.26;

class _DeleteMealAction extends StatelessWidget {
  const _DeleteMealAction({super.key, required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final controller = Slidable.of(context);
    final reveal = controller == null
        ? const AlwaysStoppedAnimation<double>(1)
        : CurvedAnimation(
            parent: controller.animation,
            curve: const Interval(0.0, _deleteExtent, curve: Curves.easeOutCubic),
          );
    return CustomSlidableAction(
      // Kein autoClose: das wuerde direkt nach dem Tap ein close() feuern und
      // die dismiss()-Animation abwuergen -> onDelete liefe nie.
      autoClose: false,
      onPressed: (actionContext) {
        HapticFeedback.mediumImpact();
        final slidable = Slidable.of(actionContext);
        if (slidable == null) {
          onDelete();
          return;
        }
        // Erst die Zeile rausschieben + Luecke zusammenziehen, dann loeschen —
        // sonst springt die Liste hart, sobald der Store neu baut.
        slidable.dismiss(
          ResizeRequest(const Duration(milliseconds: 220), onDelete),
        );
      },
      backgroundColor: Colors.transparent,
      foregroundColor: danger,
      padding: EdgeInsets.zero,
      child: FadeTransition(
        opacity: reveal,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(reveal),
          child: Semantics(
            button: true,
            label: 'Eintrag löschen',
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: danger.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: danger.withValues(alpha: 0.25)),
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: danger,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryEntry extends StatefulWidget {
  const _HistoryEntry({
    super.key,
    required this.meal,
    required this.index,
    required this.onTap,
  });

  final LoggedMeal meal;
  final int index;
  final VoidCallback? onTap;

  @override
  State<_HistoryEntry> createState() => _HistoryEntryState();
}

class _HistoryEntryState extends State<_HistoryEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final CurvedAnimation _in =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    // Sanfter Stagger beim Listenaufbau; einzelne neue Eintraege sliden ohne
    // spuerbare Wartezeit rein. Ueber die id-Keys der Slidable-Wrapper bleibt
    // der State pro Mahlzeit erhalten -> kein Re-Play beim Loeschen anderer.
    final delay = Duration(milliseconds: 40 * math.min(widget.index, 5));
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _in.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meal = widget.meal;
    final grams = meal.result.estimatedGrams;
    final amount = grams > 0 ? '~$grams g' : '1 Portion';
    // Icon + Farbe kommen aus der gemeinsamen Slot-Zuordnung, damit eine
    // Mahlzeit im Verlauf genauso aussieht wie im Add-Sheet.
    final accent = meal.slot.accent;

    return FadeTransition(
      opacity: _in,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.20),
          end: Offset.zero,
        ).animate(_in),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(rControl),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                  child: Icon(meal.slot.icon, color: accent, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        meal.result.mealName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${meal.slot.label} · $amount',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${meal.result.caloriesKcal}',
                          style: const TextStyle(
                            color: textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 3),
                        const Text(
                          'kcal',
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _formatTime(meal.loggedAt),
                      style: const TextStyle(
                        color: textMuted,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
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

/// Lokale Wanduhr-Zeit `HH:mm` einer Mahlzeit fuer die Verlaufszeile.
String _formatTime(DateTime dt) {
  final local = dt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _formatThousands(int n) {
  final negative = n < 0;
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final fromEnd = s.length - i;
    buf.write(s[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buf.write('.');
  }
  return negative ? '-${buf.toString()}' : buf.toString();
}
