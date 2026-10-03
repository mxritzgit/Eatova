import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/design/design.dart';

/// Borderless set inputs shared by the active set and completion review.
class TrainingActualFields extends StatefulWidget {
  const TrainingActualFields({
    super.key,
    required this.timed,
    this.reps,
    this.weightKg,
    required this.onChanged,
    required this.onValidityChanged,
    this.enabled = true,
  });
  final bool timed;
  final int? reps;
  final double? weightKg;
  final bool enabled;
  final void Function(int? reps, double? weightKg) onChanged;
  final ValueChanged<bool> onValidityChanged;

  @override
  State<TrainingActualFields> createState() => _TrainingActualFieldsState();
}

class _TrainingActualFieldsState extends State<TrainingActualFields> {
  late final _reps = TextEditingController(text: widget.reps?.toString() ?? '');
  final _weight = TextEditingController();
  bool _weightFilled = false;
  bool _showErrors = false;
  int? get _repsValue => NumberInput.parse(_reps.text).wholeValue;
  double? get _weightValue => NumberInput.parse(_weight.text).value;
  bool get _repsValid =>
      widget.timed ||
      (_repsValue != null && _repsValue! >= 0 && _repsValue! <= 1000);
  bool get _weightValid =>
      _weight.text.trim().isEmpty ||
      (_weightValue != null && _weightValue! >= 0 && _weightValue! <= 2000);

  void _changed() {
    final valid = _repsValid && _weightValid;
    widget.onValidityChanged(valid);
    if (valid) widget.onChanged(widget.timed ? null : _repsValue, _weightValue);
    if (_showErrors) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "62,5" under de: the prefill needs the locale, unreadable in initState.
    final kg = widget.weightKg;
    if (!_weightFilled && kg != null) {
      _weight.text = formatTrainingWeight(kg, context.l10n);
    }
    _weightFilled = true;
  }

  @override
  void dispose() {
    _reps.dispose();
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    Widget field(
      String label,
      TextEditingController controller,
      bool valid,
      bool decimal,
    ) => Focus(
      canRequestFocus: false,
      onFocusChange: (focused) {
        if (!focused) setState(() => _showErrors = true);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: AppType.ui(13, color: context.t.ink2)),
          const SizedBox(height: 8),
          SheetField(
            controller: controller,
            label: null,
            semanticLabel: label,
            fieldKey: ValueKey(
              decimal ? 'training-actual-weight' : 'training-actual-reps',
            ),
            hint: decimal ? l.trainingActualOptional : l.trainingActualReps,
            enabled: widget.enabled,
            keyboardType: TextInputType.numberWithOptions(decimal: decimal),
            errorText: _showErrors && !valid
                ? numberInputHint(
                        NumberInput.parse(controller.text),
                        l,
                        wholeNumber: !decimal,
                      ) ??
                      l.trainingActualInvalid
                : null,
            onChanged: (_) => _changed(),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.timed) ...[
          field(l.trainingActualReps, _reps, _repsValid, false),
          const SizedBox(height: 12),
        ],
        field(l.trainingActualWeight, _weight, _weightValid, true),
      ],
    );
  }
}

/// One compact number cell of a player set row (spec A3): borderless soft
/// fill, focus = fill change, Done closes the keyboard. Shows [value] unless
/// the user is typing; reports only valid values. Weight ([decimal]) may be
/// blank, repetitions may not.
class TrainingSetValueField extends StatefulWidget {
  const TrainingSetValueField({
    super.key,
    required this.value,
    required this.decimal,
    required this.semanticLabel,
    required this.onChanged,
    required this.onValidityChanged,
    this.fieldKey,
    this.enabled = true,
    this.muted = false,
  });

  final num? value;
  final bool decimal;
  final String semanticLabel;
  final ValueChanged<num?> onChanged;

  /// Called when validity flips, and with true when an invalid field
  /// unmounts. That last call comes from dispose, while the tree is locked:
  /// the caller must defer any rebuild.
  final ValueChanged<bool> onValidityChanged;
  final Key? fieldKey;
  final bool enabled;

  /// Prefilled, not yet confirmed by the set's ✓.
  final bool muted;

  @override
  State<TrainingSetValueField> createState() => _TrainingSetValueFieldState();
}

class _TrainingSetValueFieldState extends State<TrainingSetValueField> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _filled = false;
  bool _valid = true;

  num? get _parsed {
    final input = NumberInput.parse(_text.text);
    return widget.decimal ? input.value : input.wholeValue;
  }

  bool get _isValid {
    if (widget.decimal && _text.text.trim().isEmpty) return true;
    final value = _parsed;
    return value != null &&
        value >= 0 &&
        value <= (widget.decimal ? 2000 : 1000);
  }

  String _format(num? value) => value == null
      ? ''
      : widget.decimal
      ? formatTrainingWeight(value.toDouble(), context.l10n)
      : '${value.toInt()}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "62,5" under de: the text needs the locale, unreadable in initState.
    if (!_filled) _text.text = _format(widget.value);
    _filled = true;
  }

  @override
  void didUpdateWidget(TrainingSetValueField old) {
    super.didUpdateWidget(old);
    // A carried prefill, an undo or a copied Last time replaces the text,
    // but never under the user's fingers.
    if (!_focus.hasFocus && _valid && widget.value != _parsed) {
      _text.text = _format(widget.value);
    }
  }

  void _changed(String _) {
    final valid = _isValid;
    if (valid != _valid) {
      setState(() => _valid = valid);
      widget.onValidityChanged(valid);
    }
    if (valid) widget.onChanged(_text.text.trim().isEmpty ? null : _parsed);
  }

  @override
  void dispose() {
    // Invalid text never reached the caller and goes with the field, so its
    // report must not outlive it.
    if (!_valid) widget.onValidityChanged(true);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return FieldCapsule(
      focusNode: _focus,
      error: !_valid,
      enabled: widget.enabled,
      shadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(minHeight: 48),
      alignment: Alignment.center,
      child: Semantics(
        label: widget.semanticLabel,
        child: TextField(
          key: widget.fieldKey,
          controller: _text,
          focusNode: _focus,
          enabled: widget.enabled,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.numberWithOptions(
            decimal: widget.decimal,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _focus.unfocus(),
          onChanged: _changed,
          cursorColor: t.accent,
          style: AppType.ui(
            15,
            weight: FontWeight.w700,
            color: widget.muted ? t.ink2 : t.ink,
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 13),
            hintText: widget.decimal ? '–' : null,
            hintStyle: AppType.ui(15, color: t.ink3),
          ),
        ),
      ),
    );
  }
}

/// A set's weight for labels and prefills: "62,5" under de, "60" not "60.0".
String formatTrainingWeight(double kg, AppLocalizations l10n) =>
    formatDecimal(kg, l10n);
