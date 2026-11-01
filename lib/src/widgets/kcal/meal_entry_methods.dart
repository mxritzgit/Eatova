import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';
import '../design/design.dart';
import 'food_glyphs.dart';

/// The add sheet's capture choices: the AI photo scan as the hero, with the
/// violet camera button of the Food tab's dock, and the other ways in as rows
/// of one quiet card beneath it (gallery, a typed or spoken description when
/// [onDescribe] is given, barcode and, when [onManual] is given, manual
/// entry).
class MealEntryMethods extends StatelessWidget {
  const MealEntryMethods({
    super.key,
    required this.onCamera,
    required this.onGallery,
    required this.onBarcode,
    this.onDescribe,
    this.onManual,
  });

  final VoidCallback onCamera, onGallery, onBarcode;

  /// Adds the describe row (key `describe-entry-button`) after the gallery,
  /// next to the other AI path.
  final VoidCallback? onDescribe;

  /// Adds the manual-entry row (key `manual-entry-button`) to the card. Null
  /// while the host still renders its own manual row.
  final VoidCallback? onManual;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The list anatomy of the app (ListRow): neutral badge, title, hint
    // and the chevron, since each row opens a sheet.
    final rows = <Widget>[
      ListRow(
        key: const ValueKey('analyse-gallery-button'),
        icon: AppIcons.photoLibrary,
        title: l10n.foodFromGalleryTooltip,
        subtitle: l10n.foodGalleryEntryHint,
        trailing: ListTrailing.chevron,
        onTap: onGallery,
      ),
      if (onDescribe != null)
        ListRow(
          key: const ValueKey('describe-entry-button'),
          icon: AppIcons.mic,
          title: l10n.foodDescribeEntryTitle,
          subtitle: l10n.foodDescribeEntryHint,
          trailing: ListTrailing.chevron,
          onTap: onDescribe,
        ),
      ListRow(
        key: const ValueKey('analyse-barcode-button'),
        leading: const IconBadge(child: FoodGlyphIcon(FoodGlyph.barcode)),
        title: l10n.foodScanBarcodeTooltip,
        subtitle: l10n.foodBarcodeEntryHint,
        trailing: ListTrailing.chevron,
        onTap: onBarcode,
      ),
      if (onManual != null)
        ListRow(
          key: const ValueKey('manual-entry-button'),
          icon: AppIcons.edit,
          title: l10n.foodManualEntryCta,
          subtitle: l10n.foodManualEntryHint,
          trailing: ListTrailing.chevron,
          onTap: onManual,
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
        const SizedBox(height: kSpace12),
        ListSection(spacing: 0, children: rows),
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
          style: AppType.sectionEyebrow(t.accentText),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.foodTakePhotoTooltip,
          style: AppType.display(21, color: t.ink),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.foodPhotoEntryHint,
          style: AppType.subhead(t.ink2),
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
                shape: RoundedRectangleBorder(
                  borderRadius: shape,
                  side: BorderSide(color: context.t.cardBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: ink,
              ),
      ),
    );
  }
}
