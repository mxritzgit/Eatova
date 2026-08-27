import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';

import 'support/harness.dart';

/// Replaces the real scanner platform: the camera starts at once and [emit]
/// pushes a hit into the same stream the real analyzer feeds, which is the
/// only way to reproduce the close-animation race.
///
/// [stopCalls] counts platform stops — the proof that the analyzer is turned
/// off ON close, not only at the end of the fade via `dispose`.
class _FakeScannerPlatform extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;

  void emit(String rawValue) {
    _barcodes.add(
      BarcodeCapture(
        barcodes: <Barcode>[
          Barcode(rawValue: rawValue, format: BarcodeFormat.ean13),
        ],
      ),
    );
  }

  Future<void> schliessen() async {
    await _barcodes.close();
    await _torch.close();
    await _zoom.close();
  }

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;

  @override
  Stream<TorchState> get torchStateStream => _torch.stream;

  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    startCalls += 1;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      numberOfCameras: 1,
      size: Size(1280, 720),
      initialDeviceOrientation: DeviceOrientation.portraitUp,
    );
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> toggleTorch() async {}

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> dispose() async {}
}

/// Collects what the caller gets back from [showBarcodeScannerSheet].
class _Ergebnis {
  BarcodeScan? scan;
  bool geschlossen = false;

  String? get code => scan?.code;
}

/// Rebuilds the real flow's nesting: the scanner always sits above another
/// sheet, and that lower sheet is what a second pop used to tear down.
Future<void> _oeffneScannerUeberSheet(
  WidgetTester tester,
  _FakeScannerPlatform platform,
  _Ergebnis ergebnis,
) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (sheetContext) => SizedBox(
            height: 260,
            child: Center(
              child: TextButton(
                onPressed: () async {
                  ergebnis.scan = await showBarcodeScannerSheet(
                    sheetContext,
                    initialSlot: MealSlot.lunch,
                  );
                  ergebnis.geschlossen = true;
                },
                child: const Text('scannen'),
              ),
            ),
          ),
        ),
        child: const Text('add-sheet'),
      ),
    ),
    reducedMotion: false,
    safeArea: false,
  );

  await tester.tap(find.text('add-sheet'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('scannen'));
  await tester.pumpAndSettle();

  expect(find.byType(BarcodeScannerSheet), findsOneWidget);
  expect(
    platform.startCalls,
    1,
    reason: 'ohne laufenden Analyzer prueft der Rest dieser Datei nichts',
  );
}

void main() {
  late _FakeScannerPlatform platform;

  setUp(() {
    // The session owner is static and would otherwise leak between tests.
    MobileScannerController.resetPlatformSessionOwner();
    platform = _FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.schliessen();
  });

  testWidgets(
    'ein Treffer waehrend der Schliess-Animation schliesst nicht auch das '
    'darunterliegende Sheet',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);

      await tester.tap(find.byKey(const ValueKey('barcode-close-button')));
      // Exactly one frame: the fade is running and the sheet is still in the
      // tree — the window in which the analyzer used to keep running.
      await tester.pump();
      expect(find.byType(BarcodeScannerSheet), findsOneWidget);

      platform.emit('4001234567890');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(
        find.text('scannen'),
        findsOneWidget,
        reason: 'der zweite Pop haette das darunterliegende Sheet mitgerissen',
      );
      expect(ergebnis.geschlossen, isTrue);
      expect(ergebnis.code, isNull);
    },
  );

  testWidgets(
    'Barrier-Tap schaltet den Analyzer sofort ab, nicht erst am Ende der '
    'Ausblendzeit',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);
      final stopsVorher = platform.stopCalls;

      // Top edge: that is the sheet's scrim, not the ~60%-tall panel.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();

      expect(
        platform.stopCalls,
        greaterThan(stopsVorher),
        reason: 'Wisch- und Barrier-Dismiss laufen an der Schliess-Methode '
            'vorbei; ohne den PopScope-Haken bliebe der Analyzer an',
      );

      platform.emit('4001234567890');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(find.text('scannen'), findsOneWidget);
      expect(ergebnis.code, isNull);
    },
  );

  testWidgets(
    'ein Treffer im offenen Sheet liefert den getrimmten Code und laesst das '
    'darunterliegende Sheet stehen',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);

      platform.emit('  4001234567890  ');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(ergebnis.code, '4001234567890');
      // Without reselection the hit carries the preset slot.
      expect(ergebnis.scan?.slot, MealSlot.lunch);
      expect(find.byType(BarcodeScannerSheet), findsNothing);
      expect(
        find.text('scannen'),
        findsOneWidget,
        reason: 'die neue Routen-Wache darf den Normalfall nicht abwuergen',
      );
    },
  );

  testWidgets(
    'die Slot-Chips auf dem Kamerabild entscheiden, wohin der Treffer wandert',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);

      // All four chips sit on top of the image (finding 2026-08-22: from the
      // Food tab button the slot was not selectable at all), with the hint
      // moved below them instead of colliding.
      for (final slot in MealSlot.values) {
        expect(
          find.byKey(ValueKey('barcode-slot-${slot.name}')),
          findsOneWidget,
          reason: slot.name,
        );
      }
      final chips =
          tester.getRect(find.byKey(const ValueKey('barcode-slot-lunch')));
      final hinweis =
          tester.getRect(find.byKey(const ValueKey('barcode-scanner-hint')));
      expect(hinweis.top, greaterThanOrEqualTo(chips.bottom));

      await tester.tap(find.byKey(const ValueKey('barcode-slot-dinner')));
      await tester.pump();

      platform.emit('4001234567890');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(ergebnis.scan?.code, '4001234567890');
      expect(ergebnis.scan?.slot, MealSlot.dinner);
      expect(find.byType(BarcodeScannerSheet), findsNothing);
    },
  );
}
