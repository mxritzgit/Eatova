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
              Text(
                l10n.foodScanPreviewTitle,
                style: AppType.display(24, color: t.ink, height: 1.15),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.foodScanPreviewDescription,
                style: AppType.ui(14, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(rCard),
                child: SizedBox(
                  width: double.infinity,
                  height: media.viewInsets.bottom > 0 ? 120 : 180,
                  child: ColoredBox(
                    color: t.surf2,
                    child: bytes == null
                        ? Icon(Icons.photo_outlined, color: t.ink2, size: 32)
                        : Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            semanticLabel: l10n.foodScanPhotoLabel,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.broken_image_outlined,
                              color: t.ink2,
                              size: 32,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.foodScanContextLabel,
                style: AppType.ui(14, weight: FontWeight.w600, color: t.ink),
              ),
              const SizedBox(height: 8),
              SheetField(
                fieldKey: const ValueKey('meal-scan-context'),
                controller: _hint,
                semanticLabel: l10n.foodScanContextLabel,
                hint: l10n.foodScanContextExample,
                maxLines: 3,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                errorText: valid ? null : l10n.foodScanContextInvalid,
                bottomGap: 8,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${_hint.text.length}/${MealAnalysisRequest.maxHintLength}',
                  key: const ValueKey('meal-scan-context-count'),
                  style: AppType.ui(12.5, color: valid ? t.ink2 : t.danger),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.foodScanContextHelp,
                style: AppType.ui(12.5, color: t.ink2, height: 1.45),
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
}
