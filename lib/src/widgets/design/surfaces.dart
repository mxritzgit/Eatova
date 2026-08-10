import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';

// ---------------------------------------------------------------------------
// FLAECHEN — Karte, Seitentitel, Abschnittszeile, Bild-Platzhalter, Add-Slot.
//
// Geometrie, Radien und Abstaende stammen 1:1 aus der Design-Vorlage
// (newScreen/nutrition_app(1).dart); Farben ausschliesslich aus [AppTokens],
// Schrift ausschliesslich aus [AppType].
// ---------------------------------------------------------------------------

/// Die Grundflaeche der neuen Sprache: ruhige Karte, 1-px-Rand, kein Schatten.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.color,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;

  /// Schneidet den Inhalt am Radius ab und nimmt dafuer die Innenpolsterung
  /// weg — fuer Karten, deren Kinder (Listenzeilen, Bilder) bis an die Kante
  /// laufen sollen.
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: color ?? t.surf,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: t.line),
      ),
      padding: clip ? EdgeInsets.zero : padding,
      child: child,
    );
  }
}

/// Der grosse Seitentitel oben auf einem Screen.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: AppType.display(30, color: t.ink, height: 1.1)),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style:
                      AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Die Abschnittszeile ueber einer Gruppe („Makros" / „Tagesziele").
class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.title, this.trailing});

  final String title;

  /// Gedaempfter Zusatz rechts (Zeitraum, Ziel, „Verwalten").
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style:
                AppType.display(17, weight: FontWeight.w700, color: t.ink),
          ),
        ),
        // Abweichung von der Vorlage: dort steht rechts ein freier Text. Bei
        // textScaler 2.0 sprengt der die Zeile, deshalb Flexible statt starr.
        if (trailing != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                trailing!,
                textAlign: TextAlign.right,
                style: AppType.ui(
                  11.5,
                  weight: FontWeight.w600,
                  color: t.ink2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Diagonal gestreifte Flaeche als Platzhalter fuer fehlende Fotografie.
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, this.radius = 16, this.label = 'BILD'});

  final double radius;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(
        painter: _StripePainter(base: t.surf2, stripe: t.tile),
        child: Center(
          child: Text(label, style: AppType.eyebrow(t.ink2, size: 9)),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.base, required this.stripe});

  final Color base, stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final stripePaint = Paint()
      ..color = stripe
      ..strokeWidth = 10;
    for (double x = -size.height; x < size.width + size.height; x += 20) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0),
          stripePaint);
    }
  }

  // Das Streifenmuster haengt allein an den beiden Toenen; die Groesse
  // steuert Flutter ueber die neue Leinwand.
  @override
  bool shouldRepaint(_StripePainter old) =>
      old.base != base || old.stripe != stripe;
}

/// Gestrichelter „Hier etwas hinzufuegen"-Slot am Ende einer Liste.
class DottedAddSlot extends StatelessWidget {
  const DottedAddSlot({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: t.line, radius: 14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = (d + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
