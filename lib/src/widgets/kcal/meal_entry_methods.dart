import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import 'food_glyphs.dart';

/// The add sheet's capture choices: the AI photo scan as the hero, with the
/// violet camera button of the Food tab's dock, and the other ways in as rows
/// of one quiet card beneath it (gallery, barcode and, when [onManual] is
/// given, manual entry).
class MealEntryMethods extends StatelessWidget {
  const MealEntryMethods({
    super.key,
    required this.onCamera,
    required this.onGallery,
    required this.onBarcode,
    this.onManual,
  });

  final VoidCallback onCamera, onGallery, onBarcode;

  /// Adds the manual-entry row (key `manual-entry-button`) to the card. Null
  /// while the host still renders its own manual row.
  final VoidCallback? onManual;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final rows = <Widget>[
      _MethodRow(
        actionKey: const ValueKey('analyse-gallery-button'),
        glyph: const Icon(Icons.photo_library_outlined),
        label: l10n.foodFromGalleryTooltip,
        hint: l10n.foodGalleryEntryHint,
        onTap: onGallery,
      ),
      _MethodRow(
        actionKey: const ValueKey('analyse-barcode-button'),
        glyph: const FoodGlyphIcon(FoodGlyph.barcode),
        label: l10n.foodScanBarcodeTooltip,
        hint: l10n.foodBarcodeEntryHint,
        onTap: onBarcode,
      ),
      if (onManual != null)
        _MethodRow(
          actionKey: const ValueKey('manual-entry-button'),
          glyph: const Icon(Icons.edit_outlined),
          label: l10n.foodManualEntryCta,
          hint: l10n.foodManualEntryHint,
          onTap: onManual!,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Pressable(
          actionKey: const ValueKey('analyse-camera-button'),
          onTap: onCamera,
          shape: BorderRadius.circular(rCard),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [t.accentTint, t.accentTint.withValues(alpha: 0)],
            ),
          ),
          child: const _HeroContent(),
        ),
        const SizedBox(height: 10),
        // One card, hairline dividers between the rows (Food diary card).
        Material(
          color: t.surf,
          borderRadius: BorderRadius.circular(rCard),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: _MethodRow.textInset,
                    endIndent: 16,
                    color: t.line,
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroContent extends StatelessWidget {
  const _HeroContent();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final eyebrow = l10n.foodEntryAiEyebrow;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          semanticsLabel: eyebrow,
          style: AppType.ui(
            11.5,
            weight: FontWeight.w700,
            color: t.accentText,
            letterSpacing: 11.5 * 0.08,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.foodTakePhotoTooltip,
          style: AppType.display(21, color: t.ink),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.foodPhotoEntryHint,
          style: AppType.ui(13, color: t.ink2, height: 1.4),
        ),
      ],
    );
    // The dock's camera button: accent disc, on-accent glyph, violet glow.
    final mark = ExcludeSemantics(
      child: Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.accentFill,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: t.accentGlow,
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: FoodGlyphIcon(FoodGlyph.camera, size: 24, color: t.onAccentFill),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 18, 16),
      child: MediaQuery.textScalerOf(context).scale(14) > 18
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [mark, const SizedBox(height: 14), copy],
            )
          : Row(
              children: [
                Expanded(child: copy),
                const SizedBox(width: 16),
                mark,
              ],
            ),
    );
  }
}

/// Icon tile, title with a one-line hint, chevron — a Food diary row.
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.actionKey,
    required this.glyph,
    required this.label,
    required this.hint,
    required this.onTap,
  });

  static const double _tile = 36;
  static const double _pad = 16;

  /// Where the title starts; the dividers begin there.
  static const double textInset = _pad + _tile + 14;

  final Key actionKey;
  final Widget glyph;
  final String label, hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return _Pressable(
      actionKey: actionKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_pad, 10, 12, 10),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Container(
                width: _tile,
                height: _tile,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.tile,
                  borderRadius: BorderRadius.circular(rChip),
                ),
                child: IconTheme(
                  data: IconThemeData(color: t.accentText, size: 20),
                  child: glyph,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: AppType.ui(12.5, color: t.ink2, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ExcludeSemantics(
              child: Icon(Icons.chevron_right_rounded, size: 22, color: t.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ink handles keyboard/focus feedback; scale only acknowledges a touch press.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.actionKey,
    required this.onTap,
    required this.child,
    this.shape,
    this.decoration,
  });

  final Key actionKey;
  final VoidCallback onTap;
  final Widget child;

  /// A standalone card ([shape] set) paints its own `surf` fill; a row
  /// inside a card stays transparent.
  final BorderRadius? shape;
  final Decoration? decoration;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final shape = widget.shape;
    Widget ink = InkWell(
      key: widget.actionKey,
      onTap: widget.onTap,
      onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
      borderRadius: shape,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kButtonMinHeight),
        child: widget.child,
      ),
    );
    if (widget.decoration != null) {
      ink = Ink(decoration: widget.decoration, child: ink);
    }
    return Semantics(
      button: true,
      child: AnimatedScale(
        scale: _pressed && !reducedMotion(context) ? 0.985 : 1,
        duration: motionDuration(context, const Duration(milliseconds: 120)),
        curve: Curves.easeOutCubic,
        child: shape == null
            ? Material(type: MaterialType.transparency, child: ink)
            : Material(
                color: context.t.surf,
                borderRadius: shape,
                clipBehavior: Clip.antiAlias,
                child: ink,
              ),
      ),
    );
  }
}
