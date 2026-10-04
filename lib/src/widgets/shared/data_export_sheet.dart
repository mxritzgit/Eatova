import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/export_document.dart';
import '../../services/data_export.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../design/design.dart';
import 'export_sections.dart';

// ---------------------------------------------------------------------------
// DATA ACCESS REQUEST (GDPR Art. 15/20) as a bottom sheet.
//
// Shared version of the former private `_ExportSheet` in
// `profile_screen.dart`, because the settings need exactly the same sheet.
//
// The output actions operate on the complete export, independently of paging.
// ---------------------------------------------------------------------------

/// Hands the FULL export out as a file (system share sheet, mail attachment,
/// storage). [inhalt] is the complete export, not the shortened preview.
typedef ExportDateiTeiler =
    Future<void> Function(String inhalt, String dateiname);

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
  // Material's handle stays on: this is a DraggableScrollableSheet and the
  // handle is its grip. The Builder defers [snapshot] to the sheet's first
  // build, where the FutureBuilder subscribes.
  return showEatovaSheet<void>(
    context,
    Builder(
      builder: (_) => DataExportSheet(
        snapshot: snapshot(),
        fallbackSnapshot: fallbackSnapshot,
        vollstaendig: vollstaendig,
        dateiTeilen: dateiTeilen,
      ),
    ),
  );
}

/// Grouped, paged data with full report/JSON and per-section CSV output.
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

  /// Large exports are prepared off the UI isolate and carry a preview hint.
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
  bool _jsonOutput = false;

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

  /// Parse and order once; large documents are prepared off the UI isolate.
  Future<_Auskunft> _aufbereiten() async {
    try {
      final text = await widget.snapshot;
      return text.length > DataExportSheet.vorschauMaxZeichen
          ? await compute(_Auskunft.aus, text)
          : _Auskunft.aus(text);
    } catch (e, st) {
      dev.log(
        'DataExport: Auskunft nicht ladbar',
        error: e,
        stackTrace: st,
        name: 'data_export_sheet',
      );
      return _Auskunft.aus(widget.fallbackSnapshot, fehler: true);
    }
  }

  /// Dated file name, so several exports in the downloads folder stay
  /// distinguishable.
  String _dateiname() {
    final jetzt = clock.now();
    String zwei(int n) => n.toString().padLeft(2, '0');
    return 'eatova-export-${jetzt.year}-${zwei(jetzt.month)}-'
        '${zwei(jetzt.day)}.${_jsonOutput ? 'json' : 'txt'}';
  }

  Future<void> _kopieren(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e, st) {
      // The clipboard is a platform channel and can fail (no focus,
      // restrictive OS, huge payload). Without this catch it becomes an
      // unhandled zone error while the snack still claims success.
      dev.log(
        'DataExport: Kopieren fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'data_export_sheet',
      );
      // Copying is the only way out of the export; a silent failure (e.g. a
      // multi-megabyte text over the Android clipboard limit) looked like a
      // dead button.
      if (mounted) {
        showAppSnack(
          context,
          context.l10n.exportSheetCopyFailedSnack,
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
          duration: kSnackError,
        );
      }
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
      dev.log(
        'DataExport: Teilen fehlgeschlagen',
        error: e,
        stackTrace: st,
        name: 'data_export_sheet',
      );
    }
  }

  String _untertitel(AppLocalizations l10n, bool laedt, _Auskunft? auskunft) {
    if (laedt || auskunft == null) return l10n.exportSheetLoadingSubtitle;
    if (auskunft.fehler) return l10n.exportSheetErrorSubtitle;
    if (!widget.vollstaendig) return l10n.exportSheetSessionSubtitle;
    if (auskunft.document == null || auskunft.umfang == null) {
      return l10n.exportUnverified;
    }
    return switch (auskunft.umfang) {
      // The fetch did not throw but loaded nothing; without this case the
      // sheet would claim a complete export over an empty file.
      ExportUmfang.nichtsGeladen => l10n.exportNothingLoaded,
      // Covers missing rows as well as an unavailable server count.
      ExportUmfang.teilweise => l10n.exportSheetErrorSubtitle,
      _ => l10n.exportSheetFullSubtitle,
    };
  }

  String _output(_Auskunft data, AppLocalizations l10n) =>
      _jsonOutput || data.document == null
      ? data.document?.json ?? data.voll
      : data.document!.report(
          widget.vollstaendig
              ? l10n.exportSheetTitleFull
              : l10n.exportSheetTitleSession,
          (key) => exportLabel(key, l10n),
          value: (fields, path, value) =>
              exportReadableValue(fields, path, value, l10n),
        );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) => FutureBuilder<_Auskunft>(
        future: _auskunft,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final data = loading ? null : snap.data;
          final document = data?.document;
          final enabled = data != null && data.voll.isNotEmpty;
          return SnackHost(
            measureToast: true,
            child: ListView(
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                _ExportHeader(full: widget.vollstaendig),
                const SizedBox(height: 12),
                AppCard(
                  color: t.brandSurface,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.folder_copy_outlined, color: t.ink, size: 28),
                      const SizedBox(height: 12),
                      Text(
                        document == null
                            ? l10n.exportOverview
                            : l10n.exportSummary(
                                document.sections.length,
                                document.recordCount,
                              ),
                        style: AppType.display(20, color: t.ink),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _untertitel(l10n, loading, data),
                        style: AppType.ui(13, color: t.ink2, height: 1.45),
                      ),
                      if (document?.data['exportedAt']
                          case final String at) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.exportCreatedAt(exportDisplayDate(context, at)),
                          style: AppType.ui(11, color: t.ink2),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChipPill(
                      key: const ValueKey('export-format-text'),
                      label: l10n.exportReadable,
                      selected: !_jsonOutput,
                      onTap: () => setState(() => _jsonOutput = false),
                    ),
                    FilterChipPill(
                      key: const ValueKey('export-format-json'),
                      label: l10n.exportJson,
                      selected: _jsonOutput,
                      onTap: () => setState(() => _jsonOutput = true),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CopyButton(
                      enabled: enabled,
                      onCopy: () => _kopieren(_output(data!, l10n)),
                    ),
                    if (widget.dateiTeilen != null)
                      _ShareFileButton(
                        enabled: enabled,
                        onShare: () => _teilen(_output(data!, l10n)),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.exportOutputHint,
                  style: AppType.ui(12, color: t.ink2, height: 1.4),
                ),
                const SizedBox(height: 22),
                if (loading)
                  const SizedBox(
                    height: 160,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (document != null) ...[
                  for (final section in document.sections)
                    ExportSectionView(
                      key: ValueKey('export-section-${section.key}'),
                      section: section,
                      onCopy: _kopieren,
                    ),
                ] else
                  AppCard(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l10n.exportNothingLoaded,
                      style: AppType.ui(13, color: t.ink2),
                    ),
                  ),
                if (data?.gekuerzt ?? false) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.exportPreviewShortened,
                    key: const ValueKey('profile-export-shortened'),
                    style: AppType.ui(12, color: t.ink2, height: 1.4),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Prepared data and provenance; preview limits never affect output.
@immutable
class _Auskunft {
  const _Auskunft({
    required this.voll,
    required this.gekuerzt,
    required this.umfang,
    required this.fehler,
    this.document,
  });

  factory _Auskunft.aus(String text, {bool fehler = false}) {
    ExportDocument? document;
    try {
      document = ExportDocument.parse(text);
    } on FormatException {
      // Keep the original downloadable if a legacy snapshot cannot be read.
    }
    return _Auskunft(
      document: document,
      voll: text,
      gekuerzt: text.length > DataExportSheet.vorschauMaxZeichen,
      umfang: fehler ? null : exportUmfangAus(text),
      fehler: fehler,
    );
  }

  /// The complete export: what gets copied or written to a file.
  final String voll;

  final bool gekuerzt;

  /// `null` when [voll] is not an export-formatted document at all.
  final ExportUmfang? umfang;

  final bool fehler;
  final ExportDocument? document;
}

/// The copy button. Disabled while the export loads, or the placeholder would
/// end up on the clipboard.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.enabled, required this.onCopy});

  final bool enabled;
  final Future<void> Function() onCopy;

  // A null onTap is the pill's disabled state: dimmed AND announced as
  // disabled, not a button that silently does nothing.
  @override
  Widget build(BuildContext context) => SoftPillButton(
    key: const ValueKey('profile-export-copy'),
    label: context.l10n.exportSheetCopyButton,
    icon: Icons.copy_rounded,
    onTap: enabled ? onCopy : null,
  );
}

/// The path for the FULL data: a file instead of a text area. Sits below the
/// card, because the preview above is explicitly not everything.
class _ShareFileButton extends StatelessWidget {
  const _ShareFileButton({required this.enabled, required this.onShare});

  final bool enabled;
  final Future<void> Function() onShare;

  @override
  Widget build(BuildContext context) => SoftPillButton(
    key: const ValueKey('profile-export-share'),
    label: context.l10n.exportShareFile,
    icon: Icons.ios_share_rounded,
    tone: SoftPillTone.neutral,
    onTap: enabled ? onShare : null,
  );
}

class _ExportHeader extends StatelessWidget {
  const _ExportHeader({required this.full});
  final bool full;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
    final title = HeadingSemantics(
      level: 1,
      child: Text(
        full
            ? (largeText
                  ? context.l10n.settingsExportDataTitle
                  : context.l10n.exportSheetTitleFull)
            : context.l10n.exportSheetTitleSession,
        style: AppType.display(largeText ? 22 : 26, color: context.t.ink),
      ),
    );
    final t = context.t;
    final close = IconButton(
      tooltip: context.l10n.commonClose,
      onPressed: () => Navigator.of(context).pop(),
      style: IconButton.styleFrom(backgroundColor: t.surf2),
      icon: Icon(Icons.close_rounded, color: t.ink2, size: 21),
    );
    return largeText
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(alignment: Alignment.centerRight, child: close),
              title,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: title),
              close,
            ],
          );
  }
}
