import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';

import 'support/harness.dart';

// Fix run 2026-08-27, F4-03 / F4-04: the barcode sheet observes the app
// lifecycle (stop on inactive/paused, start on resumed with permission guard)
// and names a denied permission with "open Settings" + typed-barcode fallback.

const MethodChannel _settingsChannel =
    MethodChannel('com.spencerccf.app_settings/methods');

class _FakeScannerPlatform extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;

  /// While true every `start` ends in `permissionDenied`.
  bool denyPermission = false;

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
    if (denyPermission) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
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

class _Ergebnis {
  BarcodeScan? scan;
  bool geschlossen = false;
}

Future<void> _oeffneScanner(
  WidgetTester tester,
  _FakeScannerPlatform platform,
  _Ergebnis ergebnis,
) async {
  MobileScannerPlatform.instance = platform;
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          ergebnis.scan = await showBarcodeScannerSheet(
            context,
            initialSlot: MealSlot.lunch,
          );
          ergebnis.geschlossen = true;
        },
        child: const Text('scannen'),
      ),
    ),
  );
  await tester.tap(find.text('scannen'));
  await tester.pumpAndSettle();
}

Future<void> _flush(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late _FakeScannerPlatform platform;

  setUp(() {
    platform = _FakeScannerPlatform();
  });

  tearDown(() async {
    await platform.schliessen();
  });

  group('D3 · Lifecycle', () {
    testWidgets('inactive/paused stoppt die Kamera, resumed startet sie neu',
        (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScanner(tester, platform, ergebnis);
      expect(platform.startCalls, 1);
      expect(platform.stopCalls, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(platform.stopCalls, 1,
          reason: 'die Vorschau darf im Hintergrund nicht weiterlaufen');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(platform.startCalls, 2,
          reason: 'ohne Neustart bliebe die Vorschau schwarz');

      // Close cleanly; the sheet must not react to lifecycle events any more.
      await tester.tap(find.byKey(const ValueKey('barcode-close-button')));
      await tester.pumpAndSettle();
      final startsBefore = platform.startCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(platform.startCalls, startsBefore);
      expect(ergebnis.geschlossen, isTrue);
    });

    testWidgets('ohne Berechtigung kein Neustart bei resumed', (tester) async {
      platform.denyPermission = true;
      await _oeffneScanner(tester, platform, _Ergebnis());
      expect(platform.startCalls, 1);
      expect(find.byKey(const ValueKey('barcode-scanner-failed')),
          findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);

      expect(platform.startCalls, 1,
          reason: 'sonst poppt bei jedem App-Wechsel der Berechtigungsdialog');
    });
  });

  group('F4-04 · Berechtigung verweigert', () {
    testWidgets('Fehlerlayer nennt die Berechtigung und bietet Einstellungen '
        'sowie Eintippen; nach Einstellungen startet resumed neu',
        (tester) async {
      final settingsCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _settingsChannel,
        (call) async {
          settingsCalls.add(call.method);
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_settingsChannel, null));

      platform.denyPermission = true;
      await _oeffneScanner(tester, platform, _Ergebnis());

      expect(find.textContaining('Kein Zugriff auf die Kamera'), findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-open-settings')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('barcode-type-in')), findsOneWidget);
      // Chips/hint/torch overlay is hidden in the error state.
      expect(find.byKey(const ValueKey('barcode-scanner-hint')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('barcode-open-settings')));
      await _flush(tester);
      expect(settingsCalls, isNotEmpty);

      // The user granted the permission in Settings and comes back.
      platform.denyPermission = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);

      expect(platform.startCalls, 2);
      expect(find.byKey(const ValueKey('barcode-scanner-failed')), findsNothing);
      expect(find.byKey(const ValueKey('barcode-scanner-hint')),
          findsOneWidget);
    });

    testWidgets('Barcode eintippen -> Rueckgabe wie ein Scan (lookup-Pfad)',
        (tester) async {
      platform.denyPermission = true;
      final ergebnis = _Ergebnis();
      await _oeffneScanner(tester, platform, ergebnis);

      await tester.tap(find.byKey(const ValueKey('barcode-type-in')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('barcode-manual-layer')), findsOneWidget);

      // Too short: stays open, names the rule.
      await tester.enterText(
          find.byKey(const ValueKey('barcode-manual-field')), '1234');
      await tester.tap(find.byKey(const ValueKey('barcode-manual-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Bitte 8, 12 oder 13 Ziffern eingeben.'),
          findsOneWidget);
      expect(ergebnis.geschlossen, isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('barcode-manual-field')), '4001724012345');
      await tester.pumpAndSettle();
      expect(find.text('Bitte 8, 12 oder 13 Ziffern eingeben.'), findsNothing,
          reason: 'Tippen loescht den Fehler');
      await tester.tap(find.byKey(const ValueKey('barcode-manual-submit')));
      await tester.pumpAndSettle();

      expect(ergebnis.geschlossen, isTrue);
      expect(ergebnis.scan?.code, '4001724012345');
      expect(ergebnis.scan?.slot, MealSlot.lunch);
    });

    testWidgets('Abbrechen im Eingabelayer fuehrt zurueck zum Fehlerlayer',
        (tester) async {
      platform.denyPermission = true;
      await _oeffneScanner(tester, platform, _Ergebnis());
      await tester.tap(find.byKey(const ValueKey('barcode-type-in')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('barcode-manual-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('barcode-manual-layer')), findsNothing);
      expect(find.byKey(const ValueKey('barcode-type-in')), findsOneWidget);
    });
  });

  test('isValidTypedBarcode: 8/12/13 Ziffern, sonst nichts', () {
    expect(isValidTypedBarcode('12345678'), isTrue);
    expect(isValidTypedBarcode('123456789012'), isTrue);
    expect(isValidTypedBarcode('4001724012345'), isTrue);
    expect(isValidTypedBarcode('1234567'), isFalse);
    expect(isValidTypedBarcode('12345678901234'), isFalse);
    expect(isValidTypedBarcode('40017240a2345'), isFalse);
    expect(isValidTypedBarcode(''), isFalse);
  });
}
