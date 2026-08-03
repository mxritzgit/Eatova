import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/app_colors.dart';

/// Oeffnet den Barcode-Scanner als animiertes Bottom-Panel (~60% Hoehe) im
/// gleichen Rahmen wie die KI-Scan-Kamera ([MealCameraSheet]) — gleitet von
/// unten ein statt Vollbild-Wechsel. Liefert den gescannten Code, oder null
/// bei Abbruch (X, Barrier-Tap oder Runterwischen).
Future<String?> showBarcodeScannerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const BarcodeScannerSheet(),
  );
}

class BarcodeScannerSheet extends StatefulWidget {
  const BarcodeScannerSheet({super.key});

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

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void handleDetect(BarcodeCapture capture) {
    if (hasReturned) {
      return;
    }

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        hasReturned = true;
        Navigator.of(context).pop(rawValue.trim());
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

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: SizedBox(
        height: panelHeight,
        child: Container(
          decoration: const BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const _SheetHandle(),
              _HeaderRow(onClose: () => Navigator.of(context).pop()),
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
                          // Formatfuellend + verzerrungsfrei (croppt statt zu
                          // stauchen) — wie die Kamera-Vorschau im KI-Scan.
                          fit: BoxFit.cover,
                          placeholderBuilder: (_) => const _ScannerLoadingLayer(),
                          errorBuilder: (_, __) => const _ScannerFailedLayer(),
                        ),
                        // Overlays nur solange die Kamera nicht im Fehler-
                        // Zustand ist — sonst laegen Rahmen + Hinweis mitten
                        // auf der Fehlermeldung (z.B. Simulator/Berechtigung).
                        ValueListenableBuilder<MobileScannerState>(
                          valueListenable: controller,
                          builder: (context, state, child) => state.error == null
                              ? child!
                              : const SizedBox.shrink(),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              const _EdgeScrim(),
                              const Center(child: _ScanFrame()),
                              Positioned(
                                top: 10,
                                left: 10,
                                right: 10,
                                child: Center(
                                  child: Container(
                                    key: const ValueKey('barcode-scanner-hint'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.42),
                                      borderRadius: BorderRadius.circular(rPill),
                                      border: Border.all(
                                        color:
                                            Colors.white.withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: const Text(
                                      'Barcode in den Rahmen halten',
                                      style: TextStyle(
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
        border: Border.all(color: forgeLime.withValues(alpha: 0.9), width: 2),
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
              ? forgeLime.withValues(alpha: 0.92)
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
    return const ColoredBox(
      color: bg,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: forgeLime),
        ),
      ),
    );
  }
}

class _ScannerFailedLayer extends StatelessWidget {
  const _ScannerFailedLayer();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: bg,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: textMuted, size: 32),
              SizedBox(height: 12),
              Text(
                'Kamera nicht verfügbar. Prüfe die Kamera-Berechtigung in den '
                'Einstellungen.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
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
          color: hairline,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 6, 2),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Barcode scannen',
              style: TextStyle(
                color: textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('barcode-close-button'),
            onPressed: onClose,
            tooltip: 'Schließen',
            icon: const Icon(Icons.close_rounded, color: textMuted),
          ),
        ],
      ),
    );
  }
}
