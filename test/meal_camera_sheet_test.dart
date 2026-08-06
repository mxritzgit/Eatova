import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_camera_sheet.dart';

/// Ersetzt die echte Geraete-Kamera: liefert eine Back-Kamera, laesst die
/// Initialisierung sofort gelingen und protokolliert lockCaptureOrientation-
/// Aufrufe. Streams bleiben offen (kein .first-Fehler auf leeren Streams).
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  final List<DeviceOrientation> lockCalls = <DeviceOrientation>[];

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
        const CameraInitializedEvent(
          1,
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
  ) async {
    lockCalls.add(orientation);
  }

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();

  @override
  Future<void> dispose(int cameraId) async {}
}

void main() {
  testWidgets(
    'KI-Scan-Kamera lockt die Capture-Orientierung auf portraitUp, '
    'damit die Vorschau bei Geraete-Rotation nicht mitdreht',
    (tester) async {
      final fake = _FakeCameraPlatform();
      CameraPlatform.instance = fake;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MealCameraSheet(initialSlot: MealSlot.lunch),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fake.lockCalls, const [DeviceOrientation.portraitUp]);
    },
  );
}
