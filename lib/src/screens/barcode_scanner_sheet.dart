import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/l10n.dart';
import '../models/logged_meal.dart';
import '../services/crash_reporter.dart';
import '../theme/app_tokens.dart';
import '../widgets/kcal/scan_slot_chips.dart';

/// Ergebnis des Barcode-Scanners: der getrimmte Code und der Slot, den der
/// Nutzer ueber die Chips auf dem Kamerabild gewaehlt hat.
class BarcodeScan {
  const BarcodeScan({required this.code, required this.slot});

  final String code;
  final MealSlot slot;
}

/// Oeffnet den Barcode-Scanner als animiertes Bottom-Panel (~60% Hoehe) im
/// gleichen Rahmen wie die KI-Scan-Kamera ([MealCameraSheet]) — gleitet von
/// unten ein statt Vollbild-Wechsel. Liefert Code + gewaehlten Slot, oder
/// null bei Abbruch (X, Barrier-Tap oder Runterwischen).
///
/// [initialSlot] belegt die Slot-Chips vor (Uhrzeit-Heuristik bzw. der im
/// Add-Sheet gewaehlte Slot); die Wahl im Scanner hat das letzte Wort.
Future<BarcodeScan?> showBarcodeScannerSheet(
  BuildContext context, {
  required MealSlot initialSlot,
}) {
  return showModalBottomSheet<BarcodeScan>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Bewusst kein Token: der Scrim hinter einem Sheet dunkelt in beiden
    // Anzeige-Modi ab — ein heller Scrim wuerde nichts daempfen.
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => BarcodeScannerSheet(initialSlot: initialSlot),
  );
}

class BarcodeScannerSheet extends StatefulWidget {
  const BarcodeScannerSheet({super.key, required this.initialSlot});

  final MealSlot initialSlot;

  @override
  State<BarcodeScannerSheet> createState() => _BarcodeScannerSheetState();
}

class _BarcodeScannerSheetState extends State<BarcodeScannerSheet> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.ean8, BarcodeFormat.ean13, BarcodeFormat.upcA],
    // autoZoom holt den Barcode heran, statt ihn im weitwinkligen Sensorbild
    // klein zu lassen — behebt den „zu weit weg / Weitwinkel"-Eindruck und
    // macht das Scannen zuverlaessiger.
    autoZoom: true,
  );
  bool hasReturned = false;

  bool _analyzerHaengt = false;

  late MealSlot _slot;

  @override
  void initState() {
    super.initState();
    _slot = widget.initialSlot;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// Macht Analysefehler sichtbar, statt sie zu verschlucken.
  ///
  /// **Der ERSTE Fehler zaehlt.** Das war zunaechst anders gebaut (Schwelle 3,
  /// „ein einzelner Ausrutscher soll den Nutzer nicht behelligen") — die
  /// Annahme war falsch, und zwar in beide Richtungen:
  ///
  /// * Ein unscharfes Bild erzeugt **gar keinen Fehler**. Es laeuft ueber den
  ///   Erfolgspfad mit leerer Barcode-Liste, der den `ImageProxy` ordentlich
  ///   schliesst. `onDetectError` feuert ausschliesslich bei einem ML-Kit-
  ///   *Verarbeitungs*fehler — fehlendes Modell, Decoder-Fehler.
  /// * Genau dieser Zweig (`MobileScanner.kt:225-229`, mobile_scanner 7.4.0)
  ///   ruft **kein** `imageProxy.close()`. Mit `STRATEGY_KEEP_ONLY_LATEST`
  ///   (`:425`) reicht CameraX dann keinen weiteren Frame durch — die Zahl der
  ///   ueberhaupt zustellbaren Fehlframes ist durch die Reader-Tiefe begrenzt
  ///   und erreicht die 3 in keinem Fall garantiert.
  ///
  /// Eine Schwelle > 1 machte das Overlay also genau in dem Szenario
  /// unerreichbar, fuer das es gebaut wurde.
  ///
  /// Der Neustart ist noetig, weil der Analyzer sich aus demselben Grund nicht
  /// selbst erholt: ohne ihn bliebe das Bild live und der Scanner trotzdem tot.
  void handleDetectError(Object error, StackTrace stackTrace) {
    if (hasReturned || !mounted || _analyzerHaengt) return;
    setState(() => _analyzerHaengt = true);
    CrashReporter.capture(error, stackTrace, context: 'barcode-detect');
  }

  /// Schaltet den Analyzer ab und markiert dieses Sheet als erledigt.
  ///
  /// **Muss vor JEDEM Pop laufen.** Die Schliess-Animation dauert ~250 ms, und
  /// erst an deren Ende baut Flutter den [MobileScanner] ab. Bis dahin liefert
  /// der Analyzer weiter Treffer — frueher fielen die durch die Wache in
  /// [handleDetect] (`hasReturned` blieb beim Schliessen ungesetzt) und popten
  /// ein zweites Mal. Der zweite Pop traf dann die darunterliegende Route, also
  /// das Sheet, aus dem der Scanner geoeffnet wurde, und schloss es mit.
  ///
  /// `controller.stop()` kappt die Barcode-Subscription noch synchron; nur der
  /// Plattform-Stop dahinter ist asynchron. Deshalb wird hier angestossen und
  /// nicht gewartet — die Ausblendzeit soll nicht daran haengen.
  void _erkennungBeenden() {
    if (hasReturned) return;
    hasReturned = true;
    unawaited(_analyzerStoppen());
  }

  Future<void> _analyzerStoppen() async {
    try {
      await controller.stop();
    } catch (_) {
      // Das Sheet ist auf dem Weg nach draussen und `dispose()` raeumt danach
      // ohnehin auf — ein fehlgeschlagener Stop hat hier keine Folge mehr.
    }
  }

  void _selectSlot(MealSlot slot) {
    if (slot == _slot) return;
    HapticFeedback.selectionClick();
    setState(() => _slot = slot);
  }

  void _schliessen() {
    _erkennungBeenden();
    Navigator.of(context).pop();
  }

  Future<void> _neuStarten() async {
    setState(() {
      _analyzerHaengt = false;
    });
    try {
      await controller.stop();
      await controller.start();
    } catch (_) {
      // Scheitert der Neustart, bleibt der Hinweis das Naechste, was der
      // Nutzer sieht — ein stiller Fehlschlag waere genau der Bug von vorher.
      if (mounted) setState(() => _analyzerHaengt = true);
    }
  }

  void handleDetect(BarcodeCapture capture) {
    if (hasReturned || !mounted) {
      return;
    }
    // Zweite Wache gegen denselben Doppel-Pop: `hasReturned` deckt nur ab, was
    // ueber diese Klasse laeuft. Ist die Route nicht mehr die oberste — weil
    // gerade gepoppt wird oder etwas darueber liegt —, wuerde ein Pop hier die
    // darunterliegende Route treffen.
    if (ModalRoute.of(context)?.isCurrent != true) {
      return;
    }

    // Ein guter Frame heisst: der Analyzer laeuft wieder.
    if (_analyzerHaengt) setState(() => _analyzerHaengt = false);

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        final code = rawValue.trim();
        _erkennungBeenden();
        Navigator.of(context).pop(BarcodeScan(code: code, slot: _slot));
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // ~60% der Bildschirmhoehe — deckungsgleich mit dem KI-Scan-Panel, damit
    // beide Scan-Wege als dasselbe In-App-Muster gelesen werden.
    final panelHeight = mediaQuery.size.height * 0.6;

    return PopScope<Object?>(
      // Reiner Horchposten, kein Veto: `canPop` bleibt true. Wischen,
      // Barrier-Tap und System-Zurueck poppen an [_schliessen] vorbei — ueber
      // `onPopInvokedWithResult` erfaehrt das Sheet trotzdem von jedem dieser
      // Wege und kann den Analyzer abschalten, bevor die Ausblendzeit laeuft
      // (Begruendung in [_erkennungBeenden]).
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _erkennungBeenden();
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: SizedBox(
          height: panelHeight,
          child: Container(
            decoration: BoxDecoration(
              color: context.t.bg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(rSheet),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const _SheetHandle(),
                _HeaderRow(onClose: _schliessen),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(rCard),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MobileScanner(
                            controller: controller,
                            onDetect: handleDetect,
                            // Ohne diesen Handler ist der Default laut
                            // mobile_scanner.dart:157-160 woertlich
                            // `// Do nothing.` — jeder Analysefehler wurde also
                            // ERSATZLOS verschluckt. `errorBuilder` haengt an
                            // `controller.value.error`, und Analysefehler
                            // setzen das nie; der rote Zweig erschien deshalb
                            // nie.
                            //
                            // Erschwerend: `MobileScanner.kt:225-229` ruft im
                            // Fehlerpfad kein `imageProxy.close()`. Mit
                            // STRATEGY_KEEP_ONLY_LATEST liefert CameraX dann
                            // keinen weiteren Frame — der Analyzer steht nach
                            // dem ERSTEN Fehlframe still und erholt sich nicht
                            // von selbst. Der Nutzer sah: Live-Bild,
                            // Scanrahmen, nie ein Treffer, nie eine Meldung.
                            onDetectError: handleDetectError,
                            // Formatfuellend + verzerrungsfrei (croppt statt zu
                            // stauchen) — wie die Kamera-Vorschau im KI-Scan.
                            fit: BoxFit.cover,
                            placeholderBuilder: (_) =>
                                const _ScannerLoadingLayer(),
                            errorBuilder: (_, __) =>
                                const _ScannerFailedLayer(),
                          ),
                          // Overlays nur solange die Kamera nicht im
                          // Fehler-Zustand ist — sonst laegen Rahmen + Hinweis
                          // mitten auf der Fehlermeldung
                          // (z.B. Simulator/Berechtigung).
                          ValueListenableBuilder<MobileScannerState>(
                            valueListenable: controller,
                            builder: (context, state, child) =>
                                state.error == null
                                    ? child!
                                    : const SizedBox.shrink(),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const _EdgeScrim(),
                                const Center(child: _ScanFrame()),
                                // Slot-Chips oben auf dem Kamerabild —
                                // dieselbe Reihe wie im KI-Scan. Bis
                                // 2026-08-22 fehlte sie hier: der
                                // Barcode-Weg aus dem Food-Tab landete
                                // stumm im Uhrzeit-Slot.
                                Positioned(
                                  top: 10,
                                  left: 10,
                                  right: 10,
                                  child: ScanSlotChips(
                                    selected: _slot,
                                    onSelected: _selectSlot,
                                    keyPrefix: 'barcode-slot',
                                  ),
                                ),
                                // Der Hinweis rueckt unter die Chips;
                                // der Scanrahmen in der Mitte bleibt frei.
                                Positioned(
                                  top: 50,
                                  left: 10,
                                  right: 10,
                                  child: Center(
                                    child: Container(
                                      key: const ValueKey(
                                        'barcode-scanner-hint',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.42,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          rPill,
                                        ),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.35,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        context.l10n.foodBarcodeHintText,
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.1,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Torch-Toggle unten mittig — beim Scannen im
                                // Dunkeln oft der Unterschied zwischen Treffer
                                // und Frust.
                                Positioned(
                                  bottom: 14,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: _TorchButton(controller: controller),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_analyzerHaengt)
                            _AnalyzerStalledLayer(onRetry: _neuStarten),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: mediaQuery.viewPadding.bottom + 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Zielrahmen in Barcode-Proportion; forgeLime = Food-Tab-Akzent (der alte
/// Cyan-Rahmen war eine Makro-Datenfarbe und damit Palette-fremd).
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 132,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rCard),
        // Der Rahmen liegt AUF dem Kamerabild: `lime` traegt dort in beiden
        // Anzeige-Modi, `accent` waere im Hell-Modus dunkelgruen auf dunklem
        // Bild.
        border: Border.all(
          color: context.t.lime.withValues(alpha: 0.9),
          width: 2,
        ),
      ),
    );
  }
}

class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.torchState == TorchState.unavailable) {
          return const SizedBox.shrink();
        }
        final on = state.torchState == TorchState.on;
        return Material(
          key: const ValueKey('barcode-torch'),
          color: on
              ? context.t.lime.withValues(alpha: 0.92)
              : Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: controller.toggleTorch,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                on ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: on ? Colors.black : Colors.white,
                size: 21,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScannerLoadingLayer extends StatelessWidget {
  const _ScannerLoadingLayer();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ColoredBox(
      color: t.bg,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
        ),
      ),
    );
  }
}

class _ScannerFailedLayer extends StatelessWidget {
  const _ScannerFailedLayer();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ColoredBox(
      color: t.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: t.ink2, size: 32),
              const SizedBox(height: 12),
              Text(
                context.l10n.foodCameraUnavailableMessage,
                textAlign: TextAlign.center,
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w500,
                  color: t.ink,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sanfte dunkle Verlaeufe oben/unten, damit Hinweis-Pill + Torch-Button auf
/// hellen Kamerabildern lesbar bleiben (deckungsgleich mit MealCameraSheet).
///
/// Die harten `Colors.black`/`Colors.white` in diesem Overlay bleiben bewusst
/// stehen und sind KEIN vergessener Token: sie liegen auf einem LIVE-Kamerabild
/// und nicht auf einer Theme-Flaeche. Ein token-gefaerbter Scrim wuerde im
/// Hell-Modus zu einem hellen Schleier auf einem beliebig hellen Bild — genau
/// die Lesbarkeit, die er herstellen soll, waere dahin.
class _EdgeScrim extends StatelessWidget {
  const _EdgeScrim();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.4),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.5),
            ],
            stops: const [0.0, 0.2, 0.68, 1.0],
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.foodScanBarcodeTooltip,
              style: AppType.display(17, color: t.ink),
            ),
          ),
          IconButton(
            key: const ValueKey('barcode-close-button'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// Der Analyzer liefert keine Frames mehr — sichtbar statt still.
///
/// Nicht `_ScannerFailedLayer` wiederverwendet: der beschreibt einen toten
/// Kamerazugriff (Berechtigung, Simulator) und bietet keinen Ausweg. Hier ist
/// die Kamera in Ordnung, nur die Erkennung haengt, und ein Neustart hilft.
///
/// Liegt wie [_EdgeScrim] ueber dem LIVE-Kamerabild — die harten
/// Schwarz/Weiss-Werte sind bewusst kein Token (Begruendung dort).
class _AnalyzerStalledLayer extends StatelessWidget {
  const _AnalyzerStalledLayer({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('barcode-analyzer-stalled'),
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.refresh_rounded, size: 30, color: Colors.white),
          const SizedBox(height: 10),
          Text(
            l10n.foodDetectionStalledTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.foodDetectionStalledBody,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12, height: 1.35, color: Colors.white70),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('barcode-analyzer-restart'),
            onPressed: onRetry,
            child: Text(l10n.foodRestartScannerButton),
          ),
        ],
      ),
    );
  }
}
