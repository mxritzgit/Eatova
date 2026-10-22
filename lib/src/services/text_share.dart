import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// How [shareText] handed a text on.
enum TextShareOutcome {
  /// The system share sheet opened (and may have been dismissed).
  shared,

  /// The sheet could not open; the text is on the clipboard instead.
  copied,
}

/// The share sheet call. Tests replace it and restore it afterwards.
@visibleForTesting
Future<ShareResult> Function(ShareParams params) shareSheet = _platformShare;

Future<ShareResult> _platformShare(ShareParams params) =>
    SharePlus.instance.share(params);

/// Hands [text] to the system share sheet: messengers, notes, mail, and
/// "Copy" on both platforms. [subject] titles a mail; [origin] anchors the
/// iPad popover ([shareOriginOf]). Where the sheet cannot open (no plugin, a
/// platform error), the text goes to the clipboard and the caller confirms
/// that. Nothing about the text is logged.
Future<TextShareOutcome> shareText(
  String text, {
  String? subject,
  Rect? origin,
}) async {
  try {
    await shareSheet(
      ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
    );
    return TextShareOutcome.shared;
  } on Exception {
    await Clipboard.setData(ClipboardData(text: text));
    return TextShareOutcome.copied;
  }
}

/// [context]'s box in global coordinates, where the iPad share popover
/// points; null before layout.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
