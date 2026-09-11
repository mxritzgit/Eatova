import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Capture choices share Today's soft surfaces without borrowing macro colors.
class MealEntryMethods extends StatelessWidget {
  const MealEntryMethods({
    super.key,
    required this.onCamera,
    required this.onGallery,
    required this.onBarcode,
  });

  final VoidCallback onCamera, onGallery, onBarcode;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MethodSurface(
          actionKey: const ValueKey('analyse-camera-button'),
          color: t.brandSurface,
          onTap: onCamera,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final copy = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.foodTakePhotoTooltip,
                      style: AppType.display(20, color: t.onBrandSurface),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.foodPhotoEntryHint,
                      style: AppType.ui(
                        13,
                        color: t.onBrandSurface,
                        height: 1.4,
                      ),
                    ),
                  ],
                );
                final mark = ExcludeSemantics(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: t.progressAccent, width: 3),
                    ),
                    padding: const EdgeInsets.all(5),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.surf,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.photo_camera_outlined,
                        color: t.ink,
                        size: 26,
                      ),
                    ),
                  ),
                );
                if (MediaQuery.textScalerOf(context).scale(14) > 18) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [mark, const SizedBox(height: 12), copy],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: copy),
                    const SizedBox(width: 16),
                    mark,
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 300 ||
                MediaQuery.textScalerOf(context).scale(14) > 18;
            final gallery = _SecondaryMethod(
              actionKey: const ValueKey('analyse-gallery-button'),
              icon: Icons.photo_library_outlined,
              label: l10n.foodFromGalleryTooltip,
              onTap: onGallery,
            );
            final barcode = _SecondaryMethod(
              actionKey: const ValueKey('analyse-barcode-button'),
              icon: Icons.qr_code_scanner_rounded,
              label: l10n.foodScanBarcodeTooltip,
              onTap: onBarcode,
            );
            return stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [gallery, const SizedBox(height: 10), barcode],
                  )
                : Row(
                    children: [
                      Expanded(child: gallery),
                      const SizedBox(width: 10),
                      Expanded(child: barcode),
                    ],
                  );
          },
        ),
      ],
    );
  }
}

class _SecondaryMethod extends StatelessWidget {
  const _SecondaryMethod({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return _MethodSurface(
      actionKey: actionKey,
      color: t.surf,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: t.accent, size: 23),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ink handles keyboard/focus feedback; scale only acknowledges a touch press.
class _MethodSurface extends StatefulWidget {
  const _MethodSurface({
    required this.actionKey,
    required this.color,
    required this.onTap,
    required this.child,
  });

  final Key actionKey;
  final Color color;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_MethodSurface> createState() => _MethodSurfaceState();
}

class _MethodSurfaceState extends State<_MethodSurface> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: AnimatedScale(
      scale: _pressed && !reducedMotion(context) ? 0.985 : 1,
      duration: motionDuration(context, const Duration(milliseconds: 120)),
      curve: Curves.easeOutCubic,
      child: Material(
        color: widget.color,
        borderRadius: BorderRadius.circular(rCard),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: widget.actionKey,
          onTap: widget.onTap,
          onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
          borderRadius: BorderRadius.circular(rCard),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kButtonMinHeight),
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}
