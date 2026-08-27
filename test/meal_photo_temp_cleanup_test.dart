// TEMP PHOTO CLEANUP (review 2026-08-19).
//
// Camera and gallery hand over their image as a FILE (a temp JPEG, or the
// picker's scaled cache copy). The app only needs the bytes, but nobody deleted
// the files: they outlived the scan, sign-out and even account deletion, since
// the OS clears the cache only under memory pressure. This is about food
// photos, not disk space.
//
// So the FILESYSTEM is checked, not a call: after each of the three paths the
// source file must be gone, but only AFTER its bytes were read. Every test
// asserts both at once — deleting too early would yield no image.
// The error and cancel paths have their own cases; that is where cleanup is
// easiest to forget.

import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_camera_sheet.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/meal_photo_temp_file.dart';

import 'support/harness.dart';

/// A JPEG with a GPS sub-IFD, as the system camera writes it. The scrub must be
/// able to decode it, otherwise the success path checks nothing.
Uint8List _jpegMitGps({int width = 480, int height = 360}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(180, 120, 60));
  final gps = image.exif.gpsIfd;
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0004] = img.IfdValueRational(13, 1);
  image.exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// Replaces the device camera and behaves like the real plugin: the shot is
/// written as a FILE and only its path comes back. That is the point here — an
/// `XFile.fromData` would never have a file to delete.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  _FakeCameraPlatform({required this.aufnahmePfad, required this.inhalt});

  final String aufnahmePfad;
  final Uint8List inhalt;
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
    File(aufnahmePfad).writeAsBytesSync(inhalt);
    return XFile(aufnahmePfad);
  }

  @override
  Future<void> dispose(int cameraId) async {}
}

/// Gives the gallery button a real file in the cache directory, the way
/// `image_picker` returns its scaled copy.
class _FakePickerPlatform extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakePickerPlatform(this.result);

  final XFile? result;
  int calls = 0;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls += 1;
    return result;
  }
}

/// Lets real file IO and the `compute()` isolate run: both need the real event
/// loop ([WidgetTester.runAsync]), and continuations only run in the following
/// `pump()`. Stops once [fertig] holds; without the fix the loop runs out and
/// the assertion below fails.
Future<void> _durchlaufen(
  WidgetTester tester, {
  required bool Function() fertig,
  int runden = 40,
}) async {
  for (var i = 0; i < runden; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (fertig()) return;
  }
}

/// `localizedApp` instead of `pumpLocalized`: the suite pumps this widget
/// itself, inside `tester.runAsync` bookkeeping.
Widget _sheetApp(void Function(MealCameraCapture?) merken) {
  return localizedApp(
    Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          merken(
            await showModalBottomSheet<MealCameraCapture>(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  const MealCameraSheet(initialSlot: MealSlot.lunch),
            ),
          );
        },
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;

  setUp(() {
    // Stands in for the app cache/temp directory camera and picker write to.
    cache = Directory.systemTemp.createTempSync('eatova_fotocache');
  });

  tearDown(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  group('Aufraeum-Helfer', () {
    test('loescht die uebergebene Cache-Datei', () async {
      final datei = File('${cache.path}${Platform.pathSeparator}foto.jpg')
        ..writeAsBytesSync(_jpegMitGps());
      expect(datei.existsSync(), isTrue, reason: 'sonst prueft der Test nichts');

      await deleteMealPhotoTempFile(datei.path);

      expect(datei.existsSync(), isFalse);
    });

    test('eine fehlende Datei ist kein Fehlerfall', () async {
      // Second call on the same path, aborted capture, foreign cleaner: the
      // caller must not notice.
      await expectLater(
        deleteMealPhotoTempFile('${cache.path}${Platform.pathSeparator}weg.jpg'),
        completes,
      );
    });

    test('leerer Pfad (In-Memory-XFile) wirft nicht', () async {
      // `XFile.fromData` without a path yields '' — no file behind it.
      await expectLater(deleteMealPhotoTempFile(''), completes);
    });
  });

  group('DeviceMealPhotoInput', () {
    test(
        'die Picker-Kopie ist nach pick() geloescht — die gescrubbten Bytes '
        'sind trotzdem da', () async {
      final kopie = File('${cache.path}${Platform.pathSeparator}pick.jpg')
        ..writeAsBytesSync(_jpegMitGps());
      ImagePickerPlatform.instance = _FakePickerPlatform(XFile(kopie.path));

      final auswahl = await DeviceMealPhotoInput().pick(ImageSource.gallery);

      // Ordering guard: deleting before reading would leave null here and the
      // scan would have no image at all.
      expect(auswahl?.previewBytes, isNotNull,
          reason: 'geloescht werden darf erst nach dem Lesen und Scrubben');
      expect(kopie.existsSync(), isFalse,
          reason: 'das Essensfoto bliebe sonst dauerhaft im App-Cache liegen '
              '— auch nach der Kontoloeschung');
    });

    test('auch wenn der Scrub scheitert, bleibt keine Datei liegen', () async {
      // Undecodable: `compressMealPhoto` throws (fail-closed) and the pick
      // returns without bytes — the file must still be gone.
      final kopie = File('${cache.path}${Platform.pathSeparator}kaputt.jpg')
        ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4, 5]));
      ImagePickerPlatform.instance = _FakePickerPlatform(XFile(kopie.path));

      final auswahl = await DeviceMealPhotoInput().pick(ImageSource.camera);

      expect(auswahl?.previewBytes, isNull);
      expect(kopie.existsSync(), isFalse);
    });
  });

  group('MealCameraSheet', () {
    testWidgets(
      'die Kamera-Aufnahme ist nach dem Ausloeser aus dem Cache verschwunden, '
      'das Capture traegt die Bytes',
      (tester) async {
        final pfad = '${cache.path}${Platform.pathSeparator}CAP_0001.jpg';
        final aufnahme = File(pfad);
        final camera = _FakeCameraPlatform(
          aufnahmePfad: pfad,
          inhalt: _jpegMitGps(width: 1200, height: 900),
        );
        CameraPlatform.instance = camera;

        MealCameraCapture? captured;
        await tester.pumpWidget(_sheetApp((c) => captured = c));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('meal-camera-shutter')));
        await _durchlaufen(
          tester,
          fertig: () => camera.takeCalls == 1 && !aufnahme.existsSync(),
        );
        await tester.pumpAndSettle();

        expect(camera.takeCalls, 1, reason: 'der Ausloeser muss ausgeloest haben');
        expect(captured?.request.imageBytes, isNotNull,
            reason: 'zu frueh geloescht: das Sheet haette kein Bild mehr');
        expect(aufnahme.existsSync(), isFalse,
            reason: 'das Kamera-JPEG ueberdauerte sonst unbegrenzt im Cache');
      },
    );

    testWidgets(
      'das aus der Galerie gewaehlte Foto ist nach dem Pop aus dem Cache weg',
      (tester) async {
        CameraPlatform.instance = _FakeCameraPlatform(
          aufnahmePfad: '${cache.path}${Platform.pathSeparator}unused.jpg',
          inhalt: _jpegMitGps(),
        );
        final kopie = File('${cache.path}${Platform.pathSeparator}galerie.jpg')
          ..writeAsBytesSync(_jpegMitGps());
        final picker = _FakePickerPlatform(XFile(kopie.path));
        ImagePickerPlatform.instance = picker;

        MealCameraCapture? captured;
        await tester.pumpWidget(_sheetApp((c) => captured = c));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('meal-camera-gallery')));
        await _durchlaufen(tester, fertig: () => !kopie.existsSync());
        await tester.pumpAndSettle();

        expect(picker.calls, 1);
        expect(captured?.request.imageBytes, isNotNull,
            reason: 'zu frueh geloescht: das Sheet haette kein Bild mehr');
        expect(kopie.existsSync(), isFalse,
            reason: 'geloescht wird die Cache-Kopie des Pickers — das Original '
                'in der Galerie ist eine andere Datei');
      },
    );

    testWidgets(
      'scheitert der Scrub, bleibt die Datei trotzdem nicht liegen',
      (tester) async {
        CameraPlatform.instance = _FakeCameraPlatform(
          aufnahmePfad: '${cache.path}${Platform.pathSeparator}unused.jpg',
          inhalt: _jpegMitGps(),
        );
        // Undecodable -> the sheet stays open and reports the error. This is
        // the path that most easily forgets to clean up.
        final kopie = File('${cache.path}${Platform.pathSeparator}kaputt.jpg')
          ..writeAsBytesSync(Uint8List.fromList(<int>[9, 9, 9, 9]));
        ImagePickerPlatform.instance = _FakePickerPlatform(XFile(kopie.path));

        MealCameraCapture? captured;
        await tester.pumpWidget(_sheetApp((c) => captured = c));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('meal-camera-gallery')));
        await _durchlaufen(tester, fertig: () => !kopie.existsSync());

        expect(captured, isNull, reason: 'das Sheet bleibt bei Fehler offen');
        expect(
          find.byKey(const ValueKey('meal-camera-shutter')),
          findsOneWidget,
        );
        expect(kopie.existsSync(), isFalse);

        // The error snack holds an auto-dismiss timer; without draining it the
        // test binding reports a pending timer at the end.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );
  });
}
