import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../common/app_snack.dart';
import '../design/design.dart';

// ---------------------------------------------------------------------------
// DATENAUSKUNFT (DSGVO Art. 15/20) als Bottom-Sheet.
//
// Herkunft: `_ExportSheet` in `lib/src/screens/profile_screen.dart` (C7). Die
// Einstellungen brauchen exakt dasselbe Sheet — und ein zweites, eigenes waere
// genau die Sorte Doppelbedienung, die der Design-Refactor abbaut. Weil die
// Vorlage dort PRIVAT ist und `profile_screen.dart` einem anderen Paket
// gehoert, steht die gemeinsame Fassung hier (widgets/shared gehoert dem
// Einstellungs-Paket).
//
// **Nachzuziehen:** `profile_screen.dart` soll seine private Kopie durch
// [showDataExportSheet] ersetzen; der Testschluessel `profile-export-copy` ist
// deshalb bewusst uebernommen und NICHT umbenannt (DESIGN_REFACTOR §6:
// „Key bleibt Key"). Danach gibt es die Kopie nur noch einmal.
// ---------------------------------------------------------------------------

/// Oeffnet die Datenauskunft.
///
/// [snapshot] ist die (asynchron geladene) Auskunft, [fallbackSnapshot] der
/// Text, der bei einem Fehler stattdessen gezeigt wird — ohne ihn bleibt die
/// Karte im Fehlerfall leer und das Sheet sagt es im Untertitel.
/// [snapshot] ist bewusst eine FABRIK und keine fertige Future: Sie wird erst
/// im Builder des Sheets aufgerufen, also genau dort, wo der `FutureBuilder`
/// sie im selben Zug abonniert.
///
/// Eine hier uebergebene, schon laufende Future haette zwischen Aufruf und
/// erstem Sheet-Frame niemanden, der auf ihren Fehler hoert — ein
/// fehlgeschlagener Server-Export schlaegt dann als unbehandelter Zonen-Fehler
/// durch, statt im Sheet als ehrlicher Rueckfall auf den Sitzungs-Auszug zu
/// landen. Genau daran ist die Zusammenlegung der beiden Sheets zuerst
/// gescheitert.
Future<void> showDataExportSheet(
  BuildContext context, {
  required Future<String> Function() snapshot,
  required bool vollstaendig,
  String fallbackSnapshot = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.t.bg,
    // Das Theme setzt global `false`; hier steht der Griff aber an der Route
    // richtig, weil das Sheet selbst ein DraggableScrollableSheet ist und
    // keinen eigenen Kopfbereich hat.
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DataExportSheet(
      snapshot: snapshot(),
      fallbackSnapshot: fallbackSnapshot,
      vollstaendig: vollstaendig,
    ),
  );
}

/// Das Innenleben der Datenauskunft: Titel, Herkunfts-Satz, JSON-Block und der
/// Kopieren-Knopf.
class DataExportSheet extends StatelessWidget {
  const DataExportSheet({
    super.key,
    required this.snapshot,
    required this.fallbackSnapshot,
    required this.vollstaendig,
  });

  /// Die (asynchron geladene) Auskunft — mit Sync die vollstaendige
  /// Server-Kopie.
  final Future<String> snapshot;

  /// Wird gezeigt, wenn [snapshot] fehlschlaegt (offline) — zusammen mit einem
  /// Hinweis, dass es sich dann nicht um die vollstaendige Kopie handelt.
  final String fallbackSnapshot;

  final bool vollstaendig;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return FutureBuilder<String>(
          future: snapshot,
          builder: (context, snap) {
            final l10n = context.l10n;
            final laedt = snap.connectionState != ConnectionState.done;
            final fehler = snap.hasError;
            final text = snap.data ?? fallbackSnapshot;
            final untertitel = laedt
                ? l10n.exportSheetLoadingSubtitle
                : fehler
                    ? l10n.exportSheetErrorSubtitle
                    : vollstaendig
                        ? l10n.exportSheetFullSubtitle
                        : l10n.exportSheetSessionSubtitle;
            // EIN Scroller fuer das ganze Sheet (Kopf + JSON), getrieben vom
            // Controller des DraggableScrollableSheet: bei doppelter
            // Systemschrift waechst der Kopf sonst ueber die Sheet-Hoehe
            // hinaus und die Spalte laeuft ueber.
            return SingleChildScrollView(
              controller: controller,
              // AlwaysScrollable: ein kurzer Snapshot fuellt das Sheet nicht
              // aus. Ohne diese Physik nimmt der Scroller die Zieh-Geste dann
              // gar nicht erst an — und das DraggableScrollableSheet, das
              // genau daran haengt, liesse sich nicht mehr ziehen.
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
                          vollstaendig
                              ? l10n.exportSheetTitleFull
                              : l10n.exportSheetTitleSession,
                          style: AppType.display(20, color: t.ink),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _CopyButton(
                        enabled: !laedt && text.isNotEmpty,
                        onCopy: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) {
                            showAppSnack(
                              context,
                              l10n.exportSheetCopiedSnack,
                              icon: Icons.content_copy_rounded,
                            );
                          }
                        },
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
                    child: laedt
                        // Feste Hoehe waehrend des Ladens: ohne den JSON-Text
                        // schrumpfte die Karte sonst auf den Spinner zusammen
                        // und das Sheet saehe nach einem Fehler aus.
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
                            text,
                            style: AppType.display(
                              11.5,
                              weight: FontWeight.w400,
                              color: t.ink,
                              height: 1.45,
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Der „Kopieren"-Knopf. Gesperrt, solange die Auskunft laedt — sonst landete
/// der Platzhalter in der Zwischenablage.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.enabled, required this.onCopy});

  final bool enabled;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // `enabled` explizit an die Semantik: gesperrt heisst gedaempft UND fuer
    // den Screenreader hoerbar gesperrt — sonst kuendigt er einen Knopf an,
    // der waehrend des Ladens nichts tut.
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
