import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
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
  late final _weight = TextEditingController(
    text: widget.weightKg?.toString() ?? '',
  );
  bool _showErrors = false;
  int? get _repsValue => int.tryParse(_reps.text.trim());
  double? get _weightValue =>
      double.tryParse(_weight.text.trim().replaceAll(',', '.'));
  bool get _repsValid =>
      widget.timed ||
      (_repsValue != null && _repsValue! >= 0 && _repsValue! <= 1000);
  bool get _weightValid =>
      _weight.text.trim().isEmpty ||
      (_weightValue != null &&
          _weightValue!.isFinite &&
          _weightValue! >= 0 &&
          _weightValue! <= 2000);

  void _changed() {
    final valid = _repsValid && _weightValid;
    widget.onValidityChanged(valid);
    if (valid) widget.onChanged(widget.timed ? null : _repsValue, _weightValue);
    if (_showErrors) setState(() {});
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
            errorText: _showErrors && !valid ? l.trainingActualInvalid : null,
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
