import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/meal_analysis_result.dart';
import '../../theme/app_colors.dart';

/// Gemeinsames Item-Widget fuer Suchtreffer, Favoriten und letzte
/// Mahlzeiten im AddMealSheet.
///
/// Collapsed = schlanke Zeile (Avatar + Titel + Subtitle + Chevron).
/// Tap → expandiert in einen Stepper-Body mit Gramm-Anpassung und einem
/// einzigen "Hinzufuegen"-Button. Nach dem Hinzufuegen collapsed das Item
/// und zeigt einen gruenen Check als Trailing.
class MealSuggestionItem extends StatefulWidget {
  const MealSuggestionItem({
    super.key,
    required this.result,
    required this.expanded,
    required this.onTap,
    required this.onAdd,
    this.imageUrl,
    this.fallbackIcon = Icons.fastfood_outlined,
    this.accent = lime,
    this.justAdded = false,
    this.onRemove,
    this.addButtonKey,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final bool expanded;
  final VoidCallback onTap;
  final ValueChanged<MealAnalysisResult> onAdd;
  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;
  final bool justAdded;
  final VoidCallback? onRemove;
  final Key? addButtonKey;

  /// Ob dieses Item aktuell favorisiert ist (Herz gefüllt, lime).
  final bool isFavorite;

  /// Optionaler Favoriten-Toggle im Header. Null → kein Herz-Button
  /// (bestehende Aufrufer bleiben unverändert).
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  State<MealSuggestionItem> createState() => _MealSuggestionItemState();
}

class _MealSuggestionItemState extends State<MealSuggestionItem> {
  static const int _minGrams = 5;
  static const int _maxGrams = 1000;
  static const int _step = 10;

  late int _grams;
  late TextEditingController _gramsController;
  bool _isUserTyping = false;

  @override
  void initState() {
    super.initState();
    _grams = widget.result.estimatedGrams.clamp(_minGrams, _maxGrams);
    _gramsController = TextEditingController(text: _grams.toString());
  }

  @override
  void didUpdateWidget(covariant MealSuggestionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.estimatedGrams != widget.result.estimatedGrams) {
      _grams = widget.result.estimatedGrams.clamp(_minGrams, _maxGrams);
      _syncControllerText();
    }
  }

  @override
  void dispose() {
    _gramsController.dispose();
    super.dispose();
  }

  void _syncControllerText() {
    if (_isUserTyping) return;
    final next = _grams.toString();
    if (_gramsController.text != next) {
      _gramsController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  void _setGrams(int value) {
    final clamped = value.clamp(_minGrams, _maxGrams);
    if (clamped == _grams) return;
    setState(() => _grams = clamped);
    _syncControllerText();
  }

  void _bumpGrams(int delta) => _setGrams(_grams + delta);

  void _onGramsTextChanged(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) return;
    _isUserTyping = true;
    setState(() => _grams = parsed.clamp(_minGrams, _maxGrams));
    _isUserTyping = false;
  }

  int get _liveKcal {
    final per100 = widget.result.kcalPer100G;
    if (per100 <= 0) {
      final ref = widget.result.estimatedGrams <= 0
          ? 100
          : widget.result.estimatedGrams;
      return (widget.result.caloriesKcal * _grams / ref).round();
    }
    return (per100 * _grams / 100).round();
  }

  MealAnalysisResult _resultForCurrentGrams() {
    if (_grams == widget.result.estimatedGrams) {
      return widget.result;
    }
    return widget.result.adjustedToGrams(_grams);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: widget.expanded ? surface : surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(
          color: widget.expanded
              ? widget.accent.withValues(alpha: 0.55)
              : Colors.transparent,
          width: widget.expanded ? 1.2 : 0,
        ),
        boxShadow: widget.expanded
            ? [
                BoxShadow(
                  color: widget.accent.withValues(alpha: 0.08),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            result: widget.result,
            imageUrl: widget.imageUrl,
            fallbackIcon: widget.fallbackIcon,
            accent: widget.accent,
            expanded: widget.expanded,
            justAdded: widget.justAdded,
            onTap: widget.onTap,
            onRemove: widget.onRemove,
            isFavorite: widget.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
            favoriteButtonKey: widget.favoriteButtonKey,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: widget.expanded
                ? _ExpandedBody(
                    accent: widget.accent,
                    grams: _grams,
                    gramsController: _gramsController,
                    liveKcal: _liveKcal,
                    minGrams: _minGrams,
                    maxGrams: _maxGrams,
                    step: _step,
                    protein: widget.result.protein,
                    carbs: widget.result.carbs,
                    fat: widget.result.fat,
                    addButtonKey: widget.addButtonKey,
                    onBump: _bumpGrams,
                    onTextChanged: _onGramsTextChanged,
                    onSliderChanged: (v) => _setGrams(v.round()),
                    onAdd: () => widget.onAdd(_resultForCurrentGrams()),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.result,
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.onRemove,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;
  final bool expanded;
  final bool justAdded;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool isFavorite;
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  Widget build(BuildContext context) {
    final per100 = result.kcalPer100G;
    final subtitle = per100 > 0
        ? '${per100.round()} kcal / 100 g'
        : '${result.caloriesKcal} kcal · ${result.estimatedGrams} g';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
        child: Row(
          children: [
            _Avatar(
              imageUrl: imageUrl,
              fallbackIcon: fallbackIcon,
              accent: accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.mealName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (onToggleFavorite != null)
              IconButton(
                key: favoriteButtonKey,
                onPressed: () => onToggleFavorite!(result),
                tooltip: isFavorite
                    ? 'Aus Favoriten entfernen'
                    : 'Als Favorit speichern',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  // lime ist die reservierte Aktionsfarbe — bewusst NICHT der
                  // (oft orange) Item-Akzent.
                  color: isFavorite ? lime : textMuted,
                  size: 18,
                ),
              ),
            _Trailing(
              expanded: expanded,
              justAdded: justAdded,
              accent: accent,
              onRemove: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
  });

  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // 42px-Avatar: Remote-Produktbilder kommen voll aufgelöst von OpenFoodFacts
    // — Decode auf die Avatar-Größe begrenzen (spart Speicher pro Suchtreffer).
    final cachePx = (42 * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      width: 42,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: imageUrl == null
          ? Icon(fallbackIcon, color: accent, size: 19)
          : Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              cacheWidth: cachePx,
              cacheHeight: cachePx,
              errorBuilder: (_, __, ___) =>
                  Icon(fallbackIcon, color: accent, size: 19),
            ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.expanded,
    required this.justAdded,
    required this.accent,
    required this.onRemove,
  });

  final bool expanded;
  final bool justAdded;
  final Color accent;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    if (justAdded) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle_rounded, color: accent, size: 22),
      );
    }
    final chevron = AnimatedRotation(
      duration: const Duration(milliseconds: 180),
      turns: expanded ? 0.5 : 0,
      child: const Icon(
        Icons.keyboard_arrow_down_rounded,
        color: textMuted,
        size: 22,
      ),
    );
    if (onRemove == null) {
      return Padding(padding: const EdgeInsets.only(right: 8), child: chevron);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onRemove,
          tooltip: 'Entfernen',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, color: textMuted, size: 15),
        ),
        chevron,
        const SizedBox(width: 4),
      ],
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  const _ExpandedBody({
    required this.accent,
    required this.grams,
    required this.gramsController,
    required this.liveKcal,
    required this.minGrams,
    required this.maxGrams,
    required this.step,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.addButtonKey,
    required this.onBump,
    required this.onTextChanged,
    required this.onSliderChanged,
    required this.onAdd,
  });

  final Color accent;
  final int grams;
  final TextEditingController gramsController;
  final int liveKcal;
  final int minGrams;
  final int maxGrams;
  final int step;
  final String protein;
  final String carbs;
  final String fat;
  final Key? addButtonKey;
  final ValueChanged<int> onBump;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<double> onSliderChanged;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: hairline, height: 12),
          Row(
            children: [
              _StepperButton(
                icon: Icons.remove_rounded,
                semanticLabel: 'Menge verringern',
                onTap: () => onBump(-step),
                onLongPress: () => onBump(-step * 5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _GramsField(
                  controller: gramsController,
                  onChanged: onTextChanged,
                ),
              ),
              const SizedBox(width: 10),
              _StepperButton(
                icon: Icons.add_rounded,
                semanticLabel: 'Menge erhöhen',
                onTap: () => onBump(step),
                onLongPress: () => onBump(step * 5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent,
              inactiveTrackColor: hairline,
              thumbColor: accent,
              overlayColor: accent.withValues(alpha: 0.15),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              min: minGrams.toDouble(),
              max: maxGrams.toDouble(),
              value: grams.clamp(minGrams, maxGrams).toDouble(),
              onChanged: onSliderChanged,
            ),
          ),
          const SizedBox(height: 6),
          _LivePreview(
            kcal: liveKcal,
            protein: protein,
            carbs: carbs,
            fat: fat,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: addButtonKey,
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text(
                'Hinzufügen',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: bg,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;

  /// A11y: das +/-Icon allein sagt einem Screenreader nichts.
  final String semanticLabel;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: surfaceSoft,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(color: hairline),
          ),
          child: Icon(icon, size: 20, color: textPrimary),
        ),
      ),
    );
  }
}

class _GramsField extends StatelessWidget {
  const _GramsField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: hairline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 56,
            child: TextField(
              cursorOpacityAnimates: false,
              controller: controller,
              onChanged: onChanged,
              keyboardType: const TextInputType.numberWithOptions(
                signed: false,
                decimal: false,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 2),
          const Text(
            'g',
            style: TextStyle(
              color: textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final int kcal;
  final String protein;
  final String carbs;
  final String fat;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text(
          '=',
          style: TextStyle(
            color: textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$kcal kcal',
          style: const TextStyle(
            color: textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            height: 1.0,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _macroLine(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  String _macroLine() {
    final parts = <String>[];
    if (protein != '-') parts.add('P $protein');
    if (carbs != '-') parts.add('KH $carbs');
    if (fat != '-') parts.add('F $fat');
    return parts.join(' · ');
  }
}
