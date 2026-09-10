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
    final l10n = context.l10n;
    final media = MediaQuery.of(context);
    final valid = MealAnalysisRequest.isValidHint(_hint.text);
    final bytes = widget.previewBytes;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        key: const ValueKey('meal-scan-preview'),
        constraints: BoxConstraints(maxHeight: sheetMaxHeightOf(context)),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            18 + media.viewPadding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.line,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _ScanPreviewHeader(
                title: l10n.foodScanPreviewTitle,
                eyebrow: l10n.foodScanPreviewEyebrow,
                description: l10n.foodScanPreviewDescription,
                photoReady: l10n.foodScanPhotoReady,
              ),
              const SizedBox(height: 18),
              _ScanPhotoCard(
                bytes: bytes,
                height: media.viewInsets.bottom > 0 ? 116 : 176,
                photoLabel: l10n.foodScanPhotoLabel,
              ),
              const SizedBox(height: 18),
              _ScanContextCard(
                hint: _hint,
                valid: valid,
                l10n: l10n,
                onChanged: (_) => setState(() {}),
                onSuggestion: _applySuggestion,
              ),
              const SizedBox(height: 20),
              PrimaryActionButton(
                key: const ValueKey('meal-scan-start'),
                label: l10n.foodScanStart,
                onTap: valid ? _start : null,
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  key: const ValueKey('meal-scan-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applySuggestion(String suggestion) {
    final current = _hint.text.trim();
    final next = current.isEmpty ? suggestion : '$current · $suggestion';
    if (next.length > MealAnalysisRequest.maxHintLength) return;
    _hint
      ..text = next
      ..selection = TextSelection.collapsed(offset: next.length);
    setState(() {});
  }
}

class _ScanPreviewHeader extends StatelessWidget {
  const _ScanPreviewHeader({
    required this.title,
    required this.eyebrow,
    required this.description,
    required this.photoReady,
  });

  final String title;
  final String eyebrow;
  final String description;
  final String photoReady;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: t.forest,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Icon(Icons.auto_awesome_rounded, color: t.lime, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(eyebrow, style: AppType.eyebrow(t.accent, size: 10)),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    style: AppType.display(24, color: t.ink, height: 1.15),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ScanStatusPill(label: photoReady),
          ],
        ),
        const SizedBox(height: 10),
        Text(description, style: AppType.ui(14, color: t.ink2, height: 1.45)),
      ],
    );
  }
}

class _ScanStatusPill extends StatelessWidget {
  const _ScanStatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: t.lime,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, color: t.onLime, size: 15),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppType.ui(11.5, color: t.onLime, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _ScanPhotoCard extends StatelessWidget {
  const _ScanPhotoCard({
    required this.bytes,
    required this.height,
    required this.photoLabel,
  });

  final Uint8List? bytes;
  final double height;
  final String photoLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(rCard),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: t.surf2,
              child: bytes == null
                  ? Icon(Icons.photo_outlined, color: t.ink2, size: 32)
                  : Image.memory(
                      bytes!,
                      fit: BoxFit.cover,
                      semanticLabel: photoLabel,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        color: t.ink2,
                        size: 32,
                      ),
                    ),
            ),
            if (bytes != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, t.ink.withValues(alpha: 0.72)],
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Row(
                children: [
                  Icon(Icons.photo_camera_rounded, color: t.bg, size: 17),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      photoLabel,
                      style: AppType.ui(
                        12.5,
                        color: t.bg,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanContextCard extends StatelessWidget {
  const _ScanContextCard({
    required this.hint,
    required this.valid,
    required this.l10n,
    required this.onChanged,
    required this.onSuggestion,
  });

  final TextEditingController hint;
  final bool valid;
  final AppLocalizations l10n;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final progress = (hint.text.length / MealAnalysisRequest.maxHintLength)
        .clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.edit_note_rounded, color: t.accent, size: 21),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.foodScanContextPrompt,
                      style: AppType.ui(
                        15,
                        color: t.ink,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.foodScanContextLabel,
                      style: AppType.eyebrow(t.ink2, size: 9.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.tune_rounded, color: t.ink2, size: 17),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.foodScanContextAssist,
            style: AppType.ui(12.5, color: t.ink2, height: 1.4),
          ),
          const SizedBox(height: 12),
          SheetField(
            fieldKey: const ValueKey('meal-scan-context'),
            controller: hint,
            semanticLabel: l10n.foodScanContextLabel,
            hint: l10n.foodScanContextExample,
            maxLines: 3,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            prefix: Icon(Icons.notes_rounded, color: t.ink2, size: 19),
            onChanged: onChanged,
            errorText: valid ? null : l10n.foodScanContextInvalid,
            bottomGap: 6,
          ),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(rPill),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: t.tile,
                    color: valid ? t.accent : t.danger,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${hint.text.length}/${MealAnalysisRequest.maxHintLength}',
                key: const ValueKey('meal-scan-context-count'),
                style: AppType.ui(12, color: valid ? t.ink2 : t.danger),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            l10n.foodScanContextHelp,
            style: AppType.ui(12.5, color: t.ink2, height: 1.4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _ScanSuggestion(
                label: l10n.foodScanContextSuggestionNoSauce,
                enabled: !_hasSuggestion(l10n.foodScanContextSuggestionNoSauce),
                onPressed: () =>
                    onSuggestion(l10n.foodScanContextSuggestionNoSauce),
              ),
              _ScanSuggestion(
                label: l10n.foodScanContextSuggestionHomemade,
                enabled: !_hasSuggestion(
                  l10n.foodScanContextSuggestionHomemade,
                ),
                onPressed: () =>
                    onSuggestion(l10n.foodScanContextSuggestionHomemade),
              ),
              _ScanSuggestion(
                label: l10n.foodScanContextSuggestionPortion,
                enabled: !_hasSuggestion(l10n.foodScanContextSuggestionPortion),
                onPressed: () =>
                    onSuggestion(l10n.foodScanContextSuggestionPortion),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _hasSuggestion(String suggestion) => hint.text
      .split(' · ')
      .any((part) => part.trim().toLowerCase() == suggestion.toLowerCase());
}

class _ScanSuggestion extends StatelessWidget {
  const _ScanSuggestion({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: enabled ? onPressed : null,
    style: TextButton.styleFrom(
      foregroundColor: context.t.ink,
      disabledForegroundColor: context.t.ink2,
      backgroundColor: context.t.tile,
      minimumSize: const Size(0, kButtonMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rPill)),
    ),
    icon: Icon(enabled ? Icons.add_rounded : Icons.check_rounded, size: 15),
    label: Text(label, style: AppType.ui(12, weight: FontWeight.w600)),
  );
}
