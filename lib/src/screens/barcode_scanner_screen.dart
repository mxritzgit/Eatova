import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/app_colors.dart';

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
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
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: textPrimary,
        elevation: 0,
        title: const Text(
          'Barcode scannen',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: handleDetect,
            // Formatfuellend + verzerrungsfrei (croppt statt zu stauchen).
            fit: BoxFit.cover,
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              key: const ValueKey('barcode-scanner-hint'),
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: surface.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(rControl),
                border: Border.all(color: hairline),
              ),
              child: const Text(
                'Barcode in den Rahmen halten.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                  letterSpacing: -0.1,
                  color: textPrimary,
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 150,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(rCard),
                border: Border.all(color: cyan, width: 2),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                key: const ValueKey('barcode-close-button'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 17),
                label: const Text(
                  'Abbrechen',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: surfaceSoft,
                  foregroundColor: textPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
