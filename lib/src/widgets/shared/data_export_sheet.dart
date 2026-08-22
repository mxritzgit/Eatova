import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/data_export.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// DATA ACCESS REQUEST (GDPR Art. 15/20) as a bottom sheet.
//
// Shared version of the former private `_ExportSheet` in
// `profile_screen.dart`, because the settings need exactly the same sheet.
//
// TODO(settings): let `profile_screen.dart` replace its private copy with
// [showDataExportSheet]. The test key `profile-export-copy` is kept unchanged
// on purpose (DESIGN_REFACTOR 6: a key stays a key).
// ---------------------------------------------------------------------------

/// Hands the FULL export out as a file (system share sheet, mail attachment,
/// storage). [inhalt] is the complete export, not the shortened preview.
typedef ExportDateiTeiler = Future<void> Function(
  String inhalt,
  String dateiname,
);

/// Opens the data export sheet.
///
/// [snapshot] is a FACTORY, not a ready future: it is called inside the
/// sheet's builder, exactly where the `FutureBuilder` subscribes to it. An
/// already running future would have no error listener between the call and
/// the first sheet frame, so a failed server export would surface as an
/// unhandled zone error instead of falling back to the session snapshot.
///
/// [fallbackSnapshot] is shown when [snapshot] fails; without it the card
/// stays empty and the subtitle says so.
Future<void> showDataExportSheet(
  BuildContext context, {
  required Future<String> Function() snapshot,
  required bool vollstaendig,
  String fallbackSnapshot = '',
  ExportDateiTeiler? dateiTeilen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.t.bg,
    // The theme sets `false` globally, but the handle belongs on the route
    // here: this sheet is a DraggableScrollableSheet with no header of its
    // own.
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DataExportSheet(
      snapshot: snapshot(),
      fallbackSnapshot: fallbackSnapshot,
      vollstaendig: vollstaendig,
      dateiTeilen: dateiTeilen,
    ),
  );
}

/// The sheet's content: title, provenance line, JSON preview and the output
/// paths (clipboard, file).
class DataExportSheet extends StatefulWidget {
  const DataExportSheet({
    super.key,
    required this.snapshot,
    required this.fallbackSnapshot,
    required this.vollstaendig,
    this.dateiTeilen,
  });

  /// The asynchronously loaded export; with sync, the full server copy.
  final Future<String> snapshot;

  /// Shown when [snapshot] fails (offline), together with a hint that this is
  /// not the complete copy.
  final String fallbackSnapshot;

  final bool vollstaendig;

  /// Passes the full export on as a file. `null` while the app has no share
  /// plugin; the button then disappears instead of offering a dead path.
  final ExportDateiTeiler? dateiTeilen;

  /// Above how many characters the card shows a preview only.
  ///
  /// A year of use is several megabytes of JSON, and a `SelectableText` is ONE
  /// paragraph whose `TextPainter.layout` runs on the UI isolate — the sheet
  /// froze until the layout finished. The full data leaves through copy or
  /// [dateiTeilen], never through the text view.
  static const int vorschauMaxZeichen = 20 * 1024;

  @override
  State<DataExportSheet> createState() => _DataExportSheetState();
}

class _DataExportSheetState extends State<DataExportSheet> {
  late Future<_Auskunft> _auskunft;

  @override
  void initState() {
    super.initState();
    _auskunft = _aufbereiten();
  }

  @override
  void didUpdateWidget(covariant DataExportSheet alt) {
    super.didUpdateWidget(alt);
    if (alt.snapshot != widget.snapshot ||
        alt.fallbackSnapshot != widget.fallbackSnapshot) {
      _auskunft = _aufbereiten();
    }
  }

  /// Shortening and scope detection run over the WHOLE text. In `build` that
  /// would be megabytes of work per frame; here it happens once, while the
  /// spinner is still up.
  Future<_Auskunft> _aufbereiten() async {
    try {
      return _Auskunft.aus(await widget.snapshot);
    } catch (e, st) {
      dev.log('DataExport: Auskunft nicht ladbar',
          error: e, stackTrace: st, name: 'data_export_sheet');
      return _Auskunft.aus(widget.fallbackSnapshot, fehler: true);
    }
  }

  /// Dated file name, so several exports in the downloads folder stay
  /// distinguishable.
  String _dateiname() {
    final jetzt = DateTime.now();
    String zwei(int n) => n.toString().padLeft(2, '0');
    return 'eatova-export-${jetzt.year}-${zwei(jetzt.month)}-'
        '${zwei(jetzt.day)}.json';
  }

  Future<void> _kopieren(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e, st) {
      // The clipboard is a platform channel and can fail (no focus,
      // restrictive OS, huge payload). Without this catch it becomes an
      // unhandled zone error while the snack still claims success.
      dev.log('DataExport: Kopieren fehlgeschlagen',
          error: e, stackTrace: st, name: 'data_export_sheet');
      return;
    }
    if (!mounted) return;
    showAppSnack(
      context,
      context.l10n.exportSheetCopiedSnack,
      icon: Icons.content_copy_rounded,
    );
  }

  Future<void> _teilen(String text) async {
    final teiler = widget.dateiTeilen;
    if (teiler == null) return;
    try {
      await teiler(text, _dateiname());
    } catch (e, st) {
      // A cancelled or failed share dialog is no reason to tear down the
      // sheet; the export is still there.
      dev.log('DataExport: Teilen fehlgeschlagen',
          error: e, stackTrace: st, name: 'data_export_sheet');
    }
  }

  String _untertitel(AppLocalizations l10n, bool laedt, _Auskunft? auskunft) {
    if (laedt || auskunft == null) return l10n.exportSheetLoadingSubtitle;
    if (auskunft.fehler) return l10n.exportSheetErrorSubtitle;
    if (!widget.vollstaendig) return l10n.exportSheetSessionSubtitle;
    return switch (auskunft.umfang) {
      // The fetch did not throw but loaded nothing; without this case the
      // sheet would claim a complete export over an empty file.
      ExportUmfang.nichtsGeladen => l10n.exportNothingLoaded,
      // No separate sentence for "partial": the error sentence is the closest
      // one that claims no completeness and advises retrying online.
      ExportUmfang.teilweise => l10n.exportSheetErrorSubtitle,
      _ => l10n.exportSheetFullSubtitle,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return FutureBuilder<_Auskunft>(
          future: _auskunft,
          builder: (context, snap) {
            final l10n = context.l10n;
            final laedt = snap.connectionState != ConnectionState.done;
            final auskunft = snap.data;
            final text = auskunft?.voll ?? '';
            final untertitel = _untertitel(l10n, laedt, auskunft);
            // ONE scroller for the whole sheet (header + JSON), driven by the
            // DraggableScrollableSheet controller: at double system font the
            // header alone would overflow the sheet height.
            return SingleChildScrollView(
              controller: controller,
              // AlwaysScrollable: a short snapshot does not fill the sheet,
              // and without this physics the scroller rejects the drag gesture
              // the DraggableScrollableSheet depends on.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          widget.vollstaendig
                              ? l10n.exportSheetTitleFull
                              : l10n.exportSheetTitleSession,
                          style: AppType.display(20, color: t.ink),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _CopyButton(
                        enabled: !laedt && text.isNotEmpty,
                        onCopy: () => _kopieren(text),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    untertitel,
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w500,
                      color: t.ink2,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    color: t.surf2,
                    child: laedt || auskunft == null
                        // Fixed height while loading: without the JSON the
                        // card would collapse onto the spinner and the sheet
                        // would look broken.
                        ? const SizedBox(
                            height: 180,
                            child: Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                          )
                        : SelectableText(
                            auskunft.vorschau,
                            style: AppType.display(
                              11.5,
                              weight: FontWeight.w400,
                              color: t.ink,
                              height: 1.45,
                            ),
                          ),
                  ),
                  if (auskunft?.gekuerzt ?? false) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      l10n.exportPreviewShortened,
                      key: const ValueKey('profile-export-shortened'),
                      style: AppType.ui(
                        11.5,
                        weight: FontWeight.w500,
                        color: t.ink2,
                        height: 1.4,
                      ),
                    ),
                  ],
                  if (widget.dateiTeilen != null) ...<Widget>[
                    const SizedBox(height: 14),
                    _ShareFileButton(
                      enabled: !laedt && text.isNotEmpty,
                      onShare: () => _teilen(text),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// The prepared export: full text for the output paths, shortened text for
/// display, plus the verdict on its scope.
@immutable
class _Auskunft {
  const _Auskunft({
    required this.voll,
    required this.vorschau,
    required this.gekuerzt,
    required this.umfang,
    required this.fehler,
  });

  factory _Auskunft.aus(String text, {bool fehler = false}) {
    const grenze = DataExportSheet.vorschauMaxZeichen;
    final umfang = fehler ? null : exportUmfangAus(text);
    if (text.length <= grenze) {
      return _Auskunft(
        voll: text,
        vorschau: text,
        gekuerzt: false,
        umfang: umfang,
        fehler: fehler,
      );
    }
    // Cut at the last line break: a half-truncated JSON line looks like
    // broken data.
    final roh = text.substring(0, grenze);
    final letzterUmbruch = roh.lastIndexOf('\n');
    return _Auskunft(
      voll: text,
      vorschau: letzterUmbruch > 0 ? roh.substring(0, letzterUmbruch) : roh,
      gekuerzt: true,
      umfang: umfang,
      fehler: fehler,
    );
  }

  /// The complete export: what gets copied or written to a file.
  final String voll;

  /// What the card paints: at most [DataExportSheet.vorschauMaxZeichen]
  /// characters.
  final String vorschau;

  final bool gekuerzt;

  /// `null` when [voll] is not an export-formatted document at all.
  final ExportUmfang? umfang;

  final bool fehler;
}

/// The copy button. Disabled while the export loads, or the placeholder would
/// end up on the clipboard.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.enabled, required this.onCopy});

  final bool enabled;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // `enabled` explicitly on the semantics: disabled means dimmed AND
    // announced as disabled, not a button that silently does nothing.
    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          key: const ValueKey('profile-export-copy'),
          color: t.forest,
          borderRadius: BorderRadius.circular(rChip),
          child: InkWell(
            onTap: enabled ? onCopy : null,
            borderRadius: BorderRadius.circular(rChip),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.copy_rounded, size: 14, color: t.onForest),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.exportSheetCopyButton,
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w700,
                      color: t.onForest,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The path for the FULL data: a file instead of a text area. Sits below the
/// card, because the preview above is explicitly not everything.
class _ShareFileButton extends StatelessWidget {
  const _ShareFileButton({required this.enabled, required this.onShare});

  final bool enabled;
  final Future<void> Function() onShare;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          key: const ValueKey('profile-export-share'),
          color: t.tile,
          borderRadius: BorderRadius.circular(rChip),
          child: InkWell(
            onTap: enabled ? onShare : null,
            borderRadius: BorderRadius.circular(rChip),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.ios_share_rounded, size: 15, color: t.ink),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.exportShareFile,
                    style: AppType.ui(12, weight: FontWeight.w700, color: t.ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
