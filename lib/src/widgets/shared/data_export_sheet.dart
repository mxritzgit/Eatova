import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/data_export.dart';
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

/// Gibt die VOLLE Auskunft als Datei heraus — Teilen-Dialog des Systems,
/// E-Mail-Anhang, Ablage. [inhalt] ist der komplette Export, NICHT die
/// gekuerzte Vorschau.
typedef ExportDateiTeiler = Future<void> Function(
  String inhalt,
  String dateiname,
);

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
  ExportDateiTeiler? dateiTeilen,
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
      dateiTeilen: dateiTeilen,
    ),
  );
}

/// Das Innenleben der Datenauskunft: Titel, Herkunfts-Satz, JSON-Vorschau und
/// die Ausgabewege (Zwischenablage, Datei).
class DataExportSheet extends StatefulWidget {
  const DataExportSheet({
    super.key,
    required this.snapshot,
    required this.fallbackSnapshot,
    required this.vollstaendig,
    this.dateiTeilen,
  });

  /// Die (asynchron geladene) Auskunft — mit Sync die vollstaendige
  /// Server-Kopie.
  final Future<String> snapshot;

  /// Wird gezeigt, wenn [snapshot] fehlschlaegt (offline) — zusammen mit einem
  /// Hinweis, dass es sich dann nicht um die vollstaendige Kopie handelt.
  final String fallbackSnapshot;

  final bool vollstaendig;

  /// Reicht die volle Auskunft als Datei weiter. Bleibt `null`, solange die App
  /// kein Teilen-Plugin hat — dann entfaellt der Knopf, statt einen Ausgabeweg
  /// anzubieten, den es nicht gibt.
  final ExportDateiTeiler? dateiTeilen;

  /// Ab wieviel Zeichen die Karte nur noch eine Vorschau zeigt.
  ///
  /// Ein Jahr Nutzung sind schnell mehrere Megabyte JSON — jede Tagebuchzeile
  /// mit ihrer JSONB-Nutzlast, eingerueckt. Flutter legt aus einem
  /// `SelectableText` EINEN Paragraphen an, und `TextPainter.layout` laeuft
  /// dabei auf dem UI-Isolate: das Sheet fror ein, bis das Layout durch war.
  /// Die Vorschau ist deshalb hart begrenzt. Die vollstaendigen Daten
  /// verlassen das Sheet ueber Kopieren bzw. [dateiTeilen] — nicht ueber die
  /// Textdarstellung.
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

  /// Kuerzen und Umfang-Lesen laufen ueber den GANZEN Text. In `build` waere
  /// das eine Megabyte-Arbeit pro Frame; hier passiert es einmal, und zwar
  /// noch waehrend der Spinner steht.
  Future<_Auskunft> _aufbereiten() async {
    try {
      return _Auskunft.aus(await widget.snapshot);
    } catch (e, st) {
      dev.log('DataExport: Auskunft nicht ladbar',
          error: e, stackTrace: st, name: 'data_export_sheet');
      return _Auskunft.aus(widget.fallbackSnapshot, fehler: true);
    }
  }

  /// Datumsbehafteter Dateiname: mehrere Auskuenfte im Download-Ordner sollen
  /// sich unterscheiden lassen.
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
      // Die Zwischenablage ist ein Plattformkanal und kann fehlschlagen (kein
      // Fokus, restriktives OS, sehr grosse Nutzlast). Ohne diesen Fang wuerde
      // daraus ein unbehandelter Zonen-Fehler — und die Bestaetigung unten
      // behauptete trotzdem, es sei kopiert.
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
      // Ein abgebrochener oder fehlgeschlagener Teilen-Dialog ist kein Grund,
      // das Sheet zu reissen — die Auskunft liegt weiter davor.
      dev.log('DataExport: Teilen fehlgeschlagen',
          error: e, stackTrace: st, name: 'data_export_sheet');
    }
  }

  String _untertitel(AppLocalizations l10n, bool laedt, _Auskunft? auskunft) {
    if (laedt || auskunft == null) return l10n.exportSheetLoadingSubtitle;
    if (auskunft.fehler) return l10n.exportSheetErrorSubtitle;
    if (!widget.vollstaendig) return l10n.exportSheetSessionSubtitle;
    return switch (auskunft.umfang) {
      // Der Abruf hat nicht geworfen — geladen hat er trotzdem nichts. Ohne
      // diesen Fall behauptete das Sheet offline eine vollstaendige Auskunft
      // ueber eine leere Datei.
      ExportUmfang.nichtsGeladen => l10n.exportNothingLoaded,
      // Kein eigener Satz fuer „teilweise": der Fehler-Satz ist der
      // naechstliegende, der KEINE Vollstaendigkeit behauptet und zum erneuten
      // Oeffnen mit Netz raet — genau das hilft hier.
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

/// Die aufbereitete Auskunft: der volle Text fuer die Ausgabewege, die
/// gekuerzte Fassung fuer die Darstellung und das Urteil ueber ihren Umfang.
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
    // An der letzten Zeilengrenze schneiden: eine halb abgeschnittene
    // JSON-Zeile sieht nach kaputten Daten aus, und genau das soll die
    // Vorschau nicht suggerieren.
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

  /// Der komplette Export — was kopiert bzw. als Datei herausgegeben wird.
  final String voll;

  /// Was die Karte zeichnet: hoechstens
  /// [DataExportSheet.vorschauMaxZeichen] Zeichen.
  final String vorschau;

  final bool gekuerzt;

  /// `null`, wenn [voll] gar keine Auskunft im Export-Format ist.
  final ExportUmfang? umfang;

  final bool fehler;
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

/// Der Weg fuer die VOLLEN Daten: eine Datei statt einer Textflaeche. Steht
/// unter der Karte, weil die Vorschau darueber ausdruecklich nicht alles ist.
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
