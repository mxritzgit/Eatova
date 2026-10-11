import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_request.dart';
import '../../theme/app_tokens.dart';
import '../design/controls.dart';
import '../design/sheets.dart';

/// A local preview. Nothing is uploaded until the user starts analysis.
Future<MealAnalysisRequest?> showMealScanPreviewSheet(
  BuildContext context, {
  required MealAnalysisRequest request,
  required Uint8List? previewBytes,
}) => showModalBottomSheet<MealAnalysisRequest>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: context.t.scrim,
  builder: (_) =>
      MealScanPreviewSheet(request: request, previewBytes: previewBytes),
);

class MealScanPreviewSheet extends StatefulWidget {
  const MealScanPreviewSheet({
    super.key,
    required this.request,
    required this.previewBytes,
  });

  final MealAnalysisRequest request;
  final Uint8List? previewBytes;

  @override
  State<MealScanPreviewSheet> createState() => _MealScanPreviewSheetState();
}

class _MealScanPreviewSheetState extends State<MealScanPreviewSheet> {
  late final TextEditingController _hint = TextEditingController(
    text: widget.request.freeTextHint ?? '',
  );
  bool _started = false;

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  void _start() {
    if (_started || !MealAnalysisRequest.isValidHint(_hint.text)) return;
    _started = true;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(widget.request.withHint(_hint.text));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final media = MediaQuery.of(context);
    final valid = MealAnalysisRequest.isValidHint(_hint.text);
    final maxHeight = sheetMaxHeightOf(context);
    final pinnedAction = maxHeight >= 620 && media.textScaler.scale(14) <= 21;
    final footer = _ScanFooter(onStart: valid ? _start : null);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        key: const ValueKey('meal-scan-preview'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        // The page ground plus the 1 px edge of every Eatova sheet.
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        foregroundDecoration: sheetEdgeDecoration(t),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              // Keep the field in the same subtree when the keyboard changes
              // the footer layout, so focus, selection and draft survive.
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SheetHandle(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 4, 18, 16),
                      child: _ScanHeader(),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ScanPhoto(
                            bytes: widget.previewBytes,
                            compact: media.viewInsets.bottom > 0,
                          ),
                          const SizedBox(height: 24),
                          _ScanContext(
                            hint: _hint,
                            valid: valid,
                            onChanged: (_) => setState(() {}),
                            onSuggestion: _toggleSuggestion,
                          ),
                        ],
                      ),
                    ),
                    if (!pinnedAction) footer,
                  ],
                ),
              ),
            ),
            if (pinnedAction) footer,
          ],
        ),
      ),
    );
  }

  /// Adds [suggestion] as a ' · ' part of the note, or takes it out again
  /// when the note already holds it.
  void _toggleSuggestion(String suggestion) {
    final parts = _hint.text
        .split(_suggestionSeparator)
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    final picked = _matchesSuggestion(suggestion);
    final String next;
    if (parts.any(picked)) {
      next = parts.where((part) => !picked(part)).join(_suggestionSeparator);
    } else {
      final current = _hint.text.trim();
      next = current.isEmpty
          ? suggestion
          : '$current$_suggestionSeparator$suggestion';
      if (next.length > MealAnalysisRequest.maxHintLength) return;
    }
    _hint
      ..text = next
      ..selection = TextSelection.collapsed(offset: next.length);
    setState(() {});
  }
}

/// Joins the suggestion parts of the note.
const String _suggestionSeparator = ' · ';

/// Whether a note part is [suggestion], ignoring case and padding.
bool Function(String part) _matchesSuggestion(String suggestion) {
  final wanted = suggestion.toLowerCase();
  return (part) => part.trim().toLowerCase() == wanted;
}

class _ScanHeader extends StatelessWidget {
  const _ScanHeader();

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
    final title = SheetTitle(context.l10n.foodScanPreviewTitle);
    final close = SheetCloseButton(
      buttonKey: const ValueKey('meal-scan-cancel'),
      tooltip: context.l10n.commonClose,
      onTap: () => Navigator.of(context).pop(),
    );
    return largeText
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerRight, child: close),
              title,
            ],
          )
        : Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 8),
              close,
            ],
          );
  }
}

class _ScanPhoto extends StatelessWidget {
  const _ScanPhoto({required this.bytes, required this.compact});

  final Uint8List? bytes;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final unavailable = Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          l10n.foodScanPhotoUnavailable,
          textAlign: TextAlign.center,
          style: AppType.ui(13, color: t.ink2),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        key: const ValueKey('meal-scan-photo'),
        height: compact ? 100 : (constraints.maxWidth * 0.6).clamp(160, 240),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: t.surf2,
          borderRadius: BorderRadius.circular(rCard),
        ),
        child: bytes == null
            ? unavailable
            : Image.memory(
                bytes!,
                fit: BoxFit.cover,
                semanticLabel: l10n.foodScanPhotoLabel,
                gaplessPlayback: true,
                cacheWidth:
                    (constraints.maxWidth *
                            MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(1, 1600),
                errorBuilder: (_, _, _) => unavailable,
              ),
      ),
    );
  }
}

class _ScanContext extends StatelessWidget {
  const _ScanContext({
    required this.hint,
    required this.valid,
    required this.onChanged,
    required this.onSuggestion,
  });

  final TextEditingController hint;
  final bool valid;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final suggestions = [
      l10n.foodScanContextSuggestionNoSauce,
      l10n.foodScanContextSuggestionHomemade,
      l10n.foodScanContextSuggestionPortion,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                l10n.foodScanContextLabel,
                style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${hint.text.length}/${MealAnalysisRequest.maxHintLength}',
              key: const ValueKey('meal-scan-context-count'),
              style: AppType.ui(11, color: valid ? t.ink2 : t.danger),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SheetField(
          fieldKey: const ValueKey('meal-scan-context'),
          controller: hint,
          semanticLabel: l10n.foodScanContextLabel,
          hint: l10n.foodScanContextExample,
          maxLines: 3,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          onChanged: onChanged,
          errorText: valid ? null : l10n.foodScanContextInvalid,
          bottomGap: 10,
        ),
        // The app's chip language: a picked suggestion is the accent pill
        // with a check and taps off again; the others offer a "+".
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, suggestion) in suggestions.indexed)
              FilterChipPill(
                key: ValueKey('meal-scan-suggestion-$i'),
                label: suggestion,
                selected: _hasSuggestion(suggestion),
                icon: _hasSuggestion(suggestion)
                    ? Icons.check_rounded
                    : Icons.add_rounded,
                onTap: () => onSuggestion(suggestion),
              ),
          ],
        ),
      ],
    );
  }

  bool _hasSuggestion(String suggestion) =>
      hint.text.split(_suggestionSeparator).any(_matchesSuggestion(suggestion));
}

class _ScanFooter extends StatelessWidget {
  const _ScanFooter({required this.onStart});

  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        18 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.foodScanContextHelp,
            style: AppType.ui(12, color: context.t.ink2, height: 1.4),
          ),
          const SizedBox(height: 14),
          PrimaryActionButton(
            key: const ValueKey('meal-scan-start'),
            label: l10n.foodScanStart,
            onTap: onStart,
          ),
        ],
      ),
    );
  }
}
