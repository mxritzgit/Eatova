// WIRING GUARD C4 — the fifth image path.
//
// `compressMealPhoto` (the app's EXIF scrubber) is well tested as a FUNCTION;
// its call sites are not. Of the five, only `meal_camera_sheet._capture` — the
// in-app camera — was unguarded, even though it sits in the same file as the
// covered gallery path and calls the same `_compress`.
//
// The `camera` plugin writes device model and capture timestamp into the
// JPEG; GPS only with a location permission Eatova does not declare. The test
// still carries a GPS sub-IFD so it stays red if that ever changes.
//
// Asserts on the bytes leaving the sheet, not on source text, so it survives
// renames and refactors.

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_camera_sheet.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Longest edge [compressMealPhoto] scales down to. The test source is larger
/// on purpose, so recompression shows in two independent ways: metadata gone
/// AND edge capped.
const int _maxKante = 1600;

/// Replaces the device camera and returns a real JPEG from [takePicture] —
/// the seam the camera branch of `_capture()` enters.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  _FakeCameraPlatform(this.rohesFoto);

  /// What the platform returns as the captured image.
  final Uint8List rohesFoto;

  int takeCalls = 0;

  final StreamController<DeviceOrientationChangedEvent> _orientationEvents =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  final StreamController<CameraErrorEvent> _errorEvents =
      StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const <CameraDescription>[
        CameraDescription(
          name: 'back',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings? mediaSettings,
  ) async =>
      1;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      _orientationEvents.stream;

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(
        CameraInitializedEvent(
          cameraId,
          1280,
          720,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errorEvents.stream;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {}

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();

  @override
  Future<XFile> takePicture(int cameraId) async {
    takeCalls += 1;
    // As the real plugin does: a cache file holding the raw sensor JPEG.
    return XFile.fromData(
      rohesFoto,
      path: 'CAP_20260808_120000.jpg',
      name: 'CAP_20260808_120000.jpg',
      mimeType: 'image/jpeg',
    );
  }

  @override
  Future<void> dispose(int cameraId) async {}
}

/// A JPEG like a location-tagging system camera writes: larger than
/// [_maxKante], with a GPS sub-IFD and device model in the APP1 segment.
Uint8List _fotoMitMetadaten({int width = 2048, int height = 1536}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(90, 160, 210));
  final gps = image.exif.gpsIfd;
  gps[0x0001] = img.IfdValueAscii('N');
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0003] = img.IfdValueAscii('E');
  gps[0x0004] = img.IfdValueRational(13, 1);
  gps[0x0006] = img.IfdValueRational(3417, 100);
  image.exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  image.exif.imageIfd['DateTime'] = '2026:08:08 12:00:00';
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Finds the APP1 Exif signature in the raw bytes. A byte scan, not a decoder
/// query, so it also sees metadata a lenient decoder would silently drop.
bool _hatExifSegment(Uint8List bytes) {
  const signature = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  for (var i = 0; i + signature.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  testWidgets(
    'C4-Verdrahtung: das mit der IN-APP-KAMERA aufgenommene Foto verlaesst '
    'das Sheet ohne EXIF/GPS und auf 1600 px gekappt',
    (tester) async {
      final roh = _fotoMitMetadaten();
      // Without these preconditions the test asserts nothing.
      expect(_hatExifSegment(roh), isTrue,
          reason: 'die Testquelle muss selbst Metadaten tragen');
      expect(img.decodeImage(roh)!.width, greaterThan(_maxKante),
          reason: 'die Testquelle muss ueber der Kappungsgrenze liegen');

      final camera = _FakeCameraPlatform(roh);
      CameraPlatform.instance = camera;

      MealCameraCapture? captured;
      await tester.pumpWidget(
        MaterialApp(
          // MealCameraSheet reads colors via `context.t`; `AppTokens.of`
          // throws without the ThemeExtension, so without `theme:` the
          // shutter button is never built.
          theme: buildEatovaTheme(Brightness.dark),
          // MealCameraSheet reads context.l10n.
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  captured = await showModalBottomSheet<MealCameraCapture>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        const MealCameraSheet(initialSlot: MealSlot.lunch),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('meal-camera-shutter')));
      // Recompression runs in a real isolate via compute(), which needs the
      // real event loop; pump()'s fake time is not enough.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();

      expect(camera.takeCalls, 1, reason: 'der Ausloeser muss ausgeloest haben');

      final bytes = captured?.request.imageBytes;
      expect(bytes, isNotNull,
          reason: 'das Sheet muss ein Capture zurueckgegeben haben');

      // 1) No metadata container left in the byte stream.
      expect(_hatExifSegment(bytes!), isFalse,
          reason: 'Geraetemodell, Aufnahmezeit und (falls je eine '
              'Standortberechtigung dazukommt) Koordinaten duerfen den '
              'Kamera-Pfad nicht verlassen — genauso wenig wie den '
              'Galerie-Pfad daneben');
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.exif.gpsIfd.keys, isEmpty);
      expect(decoded.exif.isEmpty, isTrue);

      // 2) Second, independent signal: raw is 2048 px, compressed 1600 px.
      expect(
        decoded.width >= decoded.height ? decoded.width : decoded.height,
        _maxKante,
        reason: 'ohne Re-Kompression ginge das rohe Sensor-JPEG in voller '
            'Groesse an die Edge Function (5-MB-Cap, Base64 +33%)',
      );

      // 3) Preview and upload must be the same scrubbed bytes, else the app
      //    would show the clean image and upload the raw one.
      expect(identical(captured!.previewBytes, bytes), isTrue);
    },
  );
}
