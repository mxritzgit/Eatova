import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/number_input.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/decimal_text.dart';
import '../../widgets/design/design.dart';

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
