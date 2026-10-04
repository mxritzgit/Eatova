import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/lively.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';

// ---------------------------------------------------------------------------
// The onboarding's answer controls: option cards, the three-up choice tiles,
// the number picker and the small marks inside them.
//
// Selection language = the settings picker sheets (polish 2026-10-02): the
// chosen card takes the accent tint, an accent outline and a filled accent
// radio with a check; the others keep the card surface and an empty ring.
// The radio and the outline carry the state at 3:1 or more (WCAG 1.4.11);
// the tint alone would not, and the text stays `ink` in both states.
// ---------------------------------------------------------------------------

/// A selection change on cards, tiles and the radio.
const Duration _kSelect = Duration(milliseconds: 180);

/// Outline width, the same in both states so selecting never shifts layout.
const double _kEdge = 1.5;

/// Card fill: `surf` at rest, the accent tint over it when chosen.
Color _cardFill(AppTokens t, bool selected) =>
    selected ? Color.alphaBlend(t.accentTint, t.surf) : t.surf;

/// Card outline: the faint card edge at rest, the accent when chosen.
Color _cardEdge(AppTokens t, bool selected) => selected ? t.accent : t.line;

/// 24 px radio mark: a filled accent disc with a check, or an empty ring.
class OnboardingRadio extends StatelessWidget {
  const OnboardingRadio({super.key, required this.selected, this.size = 24});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: motionDuration(context, _kSelect),
        curve: kMotionCurve,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? t.selectedFill : Colors.transparent,
          border: Border.all(
            color: selected ? t.selectedFill : t.ink3,
            width: _kEdge,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded, size: size * 0.66, color: t.onSelected)
            : null,
      ),
    );
  }
}

/// A rounded tile behind a glyph, leading an option card.
class OnboardingGlyphTile extends StatelessWidget {
  const OnboardingGlyphTile({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Icon(icon, size: 22, color: t.accentText),
    );
  }
}

/// [level] of [of] rising bars: how demanding an activity level or how
/// brisk a pace is, readable before the words.
class OnboardingIntensityMark extends StatelessWidget {
  const OnboardingIntensityMark({
    super.key,
    required this.level,
    required this.of,
  });

  final int level;
  final int of;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: 44,
      height: 44,
      padding: const EdgeInsets.fromLTRB(10, 11, 10, 11),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (var i = 0; i < of; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 2.5),
            Flexible(
              child: Container(
                height: 6 + 16 * (i + 1) / of,
                decoration: BoxDecoration(
                  color: i < level
                      ? t.accentText
                      : t.ink3.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One answer of a single-choice question: a full-width card with an
/// optional leading mark, title, one-line consequence and the radio.
///
/// [actionKey] sits on the tap target; its semantics node is the whole card
/// (button, selected, in a mutually exclusive group).
class OnboardingOptionCard extends StatelessWidget {
  const OnboardingOptionCard({
    super.key,
    required this.actionKey,
    required this.selected,
    required this.onTap,
    required this.title,
    this.subtitle,
    this.leading,
    this.badge,
  });

  final Key actionKey;
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Short value next to the title, e.g. the PAL factor "×1,45".
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final radius = BorderRadius.circular(rCard);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: PressScale(
          scale: kPressScaleCard,
          child: AnimatedContainer(
            duration: motionDuration(context, _kSelect),
            curve: kMotionCurve,
            decoration: BoxDecoration(
              color: _cardFill(t, selected),
              borderRadius: radius,
              border: Border.all(color: _cardEdge(t, selected), width: _kEdge),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: actionKey,
                onTap: onTap,
                borderRadius: radius,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 68),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          _layout(context, t, constraints.maxWidth),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mark, texts and radio in one row; once the text column would drop below
  /// ~150 px of 1.0 text (2x text on a 320 px phone left 110 px and broke
  /// "Kaloriendefizit" mid-word), the mark and radio move above the texts.
  Widget _layout(BuildContext context, AppTokens t, double width) {
    final radio = OnboardingRadio(selected: selected);
    final textWidth = width - (leading == null ? 0 : 58) - 36;
    final stacked =
        leading != null &&
        textWidth < MediaQuery.textScalerOf(context).scale(150);
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ExcludeSemantics(child: leading!),
              const Spacer(),
              radio,
            ],
          ),
          const SizedBox(height: 12),
          _texts(t),
        ],
      );
    }
    return Row(
      children: <Widget>[
        if (leading != null) ...<Widget>[
          ExcludeSemantics(child: leading!),
          const SizedBox(width: 14),
        ],
        Expanded(child: _texts(t)),
        const SizedBox(width: 12),
        radio,
      ],
    );
  }

  Widget _texts(AppTokens t) {
    final heading = Text(
      title,
      style: AppType.ui(
        16,
        weight: FontWeight.w700,
        color: t.ink,
        letterSpacing: -0.2,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (badge == null)
          heading
        else
          // Wrap, not Row: at 2x text the badge moves under the title instead
          // of squeezing it.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              heading,
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: t.tile,
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: Text(
                  badge!,
                  style: AppType.display(
                    12.5,
                    weight: FontWeight.w700,
                    color: t.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: AppType.ui(13.5, color: t.ink2, height: 1.35),
          ),
        ],
      ],
    );
  }
}

/// A short single choice ([values] fit three across): tiles with a glyph and
/// a label. When the label would not fit a third of the row at the current
/// text size, the tiles become [OnboardingOptionCard] rows instead of
/// shrinking their text (F8-09).
class OnboardingChoiceTiles<T> extends StatelessWidget {
  const OnboardingChoiceTiles({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.labelOf,
    required this.iconOf,
    required this.keyOf,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;
  final Key Function(T) keyOf;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final perTile =
            (constraints.maxWidth - _gap * (values.length - 1)) / values.length;
        final stacked = MediaQuery.textScalerOf(context).scale(84) > perTile;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final value in values) ...<Widget>[
                if (value != values.first) const SizedBox(height: _gap),
                OnboardingOptionCard(
                  actionKey: keyOf(value),
                  selected: value == selected,
                  onTap: () => onChanged(value),
                  title: labelOf(value),
                  leading: OnboardingGlyphTile(icon: iconOf(value)),
                ),
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final value in values) ...<Widget>[
                if (value != values.first) const SizedBox(width: _gap),
                Expanded(
                  child: _ChoiceTile(
                    actionKey: keyOf(value),
                    selected: value == selected,
                    onTap: () => onChanged(value),
                    label: labelOf(value),
                    icon: iconOf(value),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.actionKey,
    required this.selected,
    required this.onTap,
    required this.label,
    required this.icon,
  });

  final Key actionKey;
  final bool selected;
  final VoidCallback onTap;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final radius = BorderRadius.circular(rCard);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: PressScale(
          child: AnimatedContainer(
            duration: motionDuration(context, _kSelect),
            curve: kMotionCurve,
            decoration: BoxDecoration(
              color: _cardFill(t, selected),
              borderRadius: radius,
              border: Border.all(color: _cardEdge(t, selected), width: _kEdge),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: actionKey,
                onTap: onTap,
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 18, 8, 16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          ExcludeSemantics(
                            child: Container(
                              width: 44,
                              height: 44,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: t.tile,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(icon, size: 22, color: t.accentText),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            label,
                            textAlign: TextAlign.center,
                            style: AppType.ui(
                              14,
                              weight: FontWeight.w700,
                              color: t.ink,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: OnboardingRadio(selected: selected, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Number picker: the big value, steppers and a slider
// ---------------------------------------------------------------------------

/// Picks a whole number in [min] .. [max] without a keyboard: a big value,
/// two steppers (hold to repeat) and a slider. Always yields a value inside
/// the window, so the DB constraints cannot be hit.
///
/// [min] .. [max] must be a real window. A picker used to fold an inverted one
/// up onto [min] — a SECOND clamping rule next to the caller's, and the two
/// disagreed: the target step drew 301 while footnote, BMI hint and the saved
/// plan said 300 / "0 kg", and the steppers wrote a value the caller clamped
/// straight back away (J1). An empty window has nothing to pick, so the caller
/// drops the step instead of asking for controls that cannot move.
///
/// The capsule is the app's soft input surface (`field`, no outline) and
/// lightens to `fieldFocus` while a stepper or the slider holds focus.
class OnboardingNumberPicker extends StatefulWidget {
  const OnboardingNumberPicker({
    super.key,
    required this.field,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.footnote,
  }) : assert(min <= max, 'inverted window: nothing to pick');

  /// Key stem: `onboarding-<field>-value|-dec|-inc|-slider`.
  final String field;
  final int value;
  final int min;
  final int max;
  final String unit;
  final ValueChanged<int> onChanged;

  /// Consequence of the value, e.g. "5 kg abnehmen".
  final String? footnote;

  @override
  State<OnboardingNumberPicker> createState() => _OnboardingNumberPickerState();
}

class _OnboardingNumberPickerState extends State<OnboardingNumberPicker> {
  bool _focused = false;

  /// The value this picker reported last, until the parent rebuilds with it.
  /// A held stepper can tick twice before the next frame; stepping from the
  /// stale [OnboardingNumberPicker.value] would lose every second step.
  int? _reported;

  /// The value in play, narrowed to the window. Steps start from it, or a raw
  /// value above the window would make "minus" write a number that clamps
  /// straight back.
  int get _value =>
      (_reported ?? widget.value).clamp(widget.min, widget.max).toInt();

  @override
  void didUpdateWidget(OnboardingNumberPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent rebuilt: its value is the truth again.
    _reported = null;
  }

  void _set(int v) {
    final value = v.clamp(widget.min, widget.max).toInt();
    _reported = value;
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final min = widget.min;
    final max = widget.max;
    final field = widget.field;
    final value = _value;
    String spoken(double v) => '${v.round()} ${widget.unit}';
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: AnimatedContainer(
        duration: motionDuration(context, _kSelect),
        curve: kMotionCurve,
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
        decoration: BoxDecoration(
          color: _focused ? t.fieldFocus : t.field,
          borderRadius: BorderRadius.circular(rCard),
        ),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                _StepperButton(
                  actionKey: ValueKey('onboarding-$field-dec'),
                  icon: Icons.remove_rounded,
                  semanticLabel: l10n.onboardingStepDownSemanticLabel,
                  enabled: value > min,
                  onStep: () => _set(_value - 1),
                ),
                const SizedBox(width: 12),
                // The column takes the remaining space; only the number may
                // shrink (F8-09), the unit scales like any label.
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$value',
                          key: ValueKey('onboarding-$field-value'),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          // 54 px is large text already; at 2.0 it would
                          // fill the capsule without reading any better.
                          textScaler: MediaQuery.textScalerOf(
                            context,
                          ).clamp(maxScaleFactor: 1.4),
                          style: AppType.display(54, color: t.ink, height: 1),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.unit,
                        textAlign: TextAlign.center,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _StepperButton(
                  actionKey: ValueKey('onboarding-$field-inc'),
                  icon: Icons.add_rounded,
                  semanticLabel: l10n.onboardingStepUpSemanticLabel,
                  enabled: value < max,
                  onStep: () => _set(_value + 1),
                ),
              ],
            ),
            // A single-value window (gaining at 299 kg) has nothing to slide.
            if (max > min) ...<Widget>[
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: t.accent,
                  inactiveTrackColor: t.ink3.withValues(alpha: 0.3),
                  thumbColor: t.accent,
                  overlayColor: t.accentTint,
                  trackHeight: 4,
                  trackShape: const RoundedRectSliderTrackShape(),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 11,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 22,
                  ),
                ),
                child: Slider(
                  key: ValueKey('onboarding-$field-slider'),
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  // A screen reader hears "75 kg", not a percentage.
                  label: spoken(value.toDouble()),
                  semanticFormatterCallback: spoken,
                  onChanged: (v) => _set(v.round()),
                ),
              ),
            ],
            if (widget.footnote != null) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: t.accentTint,
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: Text(
                  widget.footnote!,
                  textAlign: TextAlign.center,
                  style: AppType.display(
                    13.5,
                    weight: FontWeight.w700,
                    color: t.accentText,
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }
}

/// Round stepper: a tap moves one unit, holding repeats.
class _StepperButton extends StatefulWidget {
  const _StepperButton({
    required this.actionKey,
    required this.icon,
    required this.semanticLabel,
    required this.enabled,
    required this.onStep,
  });

  final Key actionKey;
  final IconData icon;

  /// Spoken name; the glyph alone says nothing to a screen reader.
  final String semanticLabel;
  final bool enabled;
  final VoidCallback onStep;

  @override
  State<_StepperButton> createState() => _StepperButtonState();
}

class _StepperButtonState extends State<_StepperButton> {
  static const Duration _repeatEvery = Duration(milliseconds: 90);

  Timer? _repeat;

  // Reads `widget` on every tick: each step rebuilds the picker with the new
  // value, and only the latest callback knows it.
  void _startRepeat() {
    if (!widget.enabled) return;
    widget.onStep();
    _repeat?.cancel();
    _repeat = Timer.periodic(_repeatEvery, (_) {
      if (mounted && widget.enabled) {
        widget.onStep();
      } else {
        _stopRepeat();
      }
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void didUpdateWidget(_StepperButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stopRepeat();
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        onLongPressStart: (_) => _startRepeat(),
        onLongPressEnd: (_) => _stopRepeat(),
        onLongPressCancel: _stopRepeat,
        child: PressScale(
          enabled: enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Material(
              color: t.accentTint,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: widget.actionKey,
                onTap: enabled ? widget.onStep : null,
                customBorder: const CircleBorder(),
                child: SizedBox.square(
                  dimension: 48,
                  child: Icon(widget.icon, size: 24, color: t.accentText),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
