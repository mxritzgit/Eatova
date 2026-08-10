// VERDRAHTUNGS-WAECHTER C4 — der fuenfte Bildpfad.
//
// `compressMealPhoto` ist der EXIF-Scrubber der App und selbst gruendlich
// getestet (test/services/meal_photo_compressor_test.dart,
// meal_photo_exif_scrub_test.dart). Getestet ist aber die FUNKTION, nicht ihre
// Anbindung. Es gibt fuenf Aufrufstellen:
//
//   1. meal_photo_compressor.dart          — Funktion selbst      (abgedeckt)
//   2. meal_photo_input.dart               — Galerie im Formular  (abgedeckt)
//   3. meal_camera_sheet._pickFromGallery  — Galerie im Sheet     (abgedeckt)
//   4. meal_camera_sheet._capture          — KAMERA im Sheet      (BIS HIER OFFEN)
//   5. coach                               — Chat-Bild            (abgedeckt)
//
// Der Kontrast ist der Punkt: Pfad 3 und Pfad 4 stehen in DERSELBEN Datei und
// rufen DIESELBE Methode `_compress`. Wer in `_capture()`
//
//     final bytes = await _compress(raw);   ->   final bytes = raw;
//
// schreibt, bekam vor dieser Datei eine vollstaendig gruene Suite und ein
// sauberes `flutter analyze` — waehrend derselbe Griff eine Zeile weiter unten
// (`_pickFromGallery`) sofort rot wird.
//
// Schadensbild: das `camera`-Plugin schreibt Geraetemodell und Aufnahme-
// zeitstempel ins JPEG; GPS nur bei Standortberechtigung, die Eatova nicht
// deklariert. Geringer als beim Galerie-Pfad — aber der Fix ist derselbe und
// er war ungeschuetzt. Der Test faehrt trotzdem ein GPS-Sub-IFD mit: er soll
// auch dann rot bleiben, wenn spaeter jemand eine Standortberechtigung
// deklariert oder das Plugin tauscht.
//
// EINSTUFUNG: stark — geprueft wird das Byte-Ergebnis am Ausgang des Sheets
// (das Objekt, das der Analyse-Aufruf hochlaedt), nicht der Quelltext. Der
// Waechter ueberlebt Umbenennung von `_compress`, Umformatierung und jeden
// Umbau, solange die Bytes sauber und verkleinert herauskommen.

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_camera_sheet.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Laengste Kante, auf die [compressMealPhoto] herunterrechnet. Die Testquelle
/// liegt bewusst DARUEBER, damit die Re-Kompression an zwei unabhaengigen
/// Merkmalen nachweisbar ist: Metadaten weg UND Kantenlaenge gekappt.
const int _maxKante = 1600;

/// Ersetzt die Geraete-Kamera. Anders als der Fake in
/// `test/meal_camera_sheet_test.dart` liefert dieser ein echtes JPEG aus
/// [takePicture] — genau die Naht, die der Kamera-Zweig von `_capture()`
/// betritt.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  _FakeCameraPlatform(this.rohesFoto);

  /// Was die Plattform als aufgenommenes Bild zurueckgibt.
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
    // So liefert das echte Plugin: eine Datei im Cache-Verzeichnis der App,
    // deren Bytes das ungefilterte Sensor-JPEG sind.
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

/// Ein JPEG, wie es eine Systemkamera mit Standort-Tagging schreibt: groesser
/// als [_maxKante] und mit GPS-Sub-IFD plus Geraetemodell im APP1-Segment.
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

/// Sucht die APP1-Exif-Signatur ("Exif\x00\x00") im rohen Byte-Strom. Bewusst
/// eine Byte-Suche und keine Decoder-Frage: sie sieht auch Metadaten, die ein
/// nachsichtiger Decoder stillschweigend verwirft.
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
      // Ohne diese beiden Vorbedingungen prueft der Test nichts.
      expect(_hatExifSegment(roh), isTrue,
          reason: 'die Testquelle muss selbst Metadaten tragen');
      expect(img.decodeImage(roh)!.width, greaterThan(_maxKante),
          reason: 'die Testquelle muss ueber der Kappungsgrenze liegen');

      final camera = _FakeCameraPlatform(roh);
      CameraPlatform.instance = camera;

      MealCameraCapture? captured;
      await tester.pumpWidget(
        MaterialApp(
          // Design-Refactor 2026-08: MealCameraSheet liest seine Farben ueber
          // `context.t`. `AppTokens.of` wirft absichtlich ohne
          // ThemeExtension — ohne `theme:` wird der Ausloeser
          // (`meal-camera-shutter`) gar nicht erst gebaut.
          theme: buildEatovaTheme(Brightness.dark),
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
      // Die Re-Kompression laeuft ueber compute() in einem echten Isolate —
      // der braucht die reale Event-Loop, die Fake-Zeit von pump() reicht
      // nicht.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle();

      expect(camera.takeCalls, 1, reason: 'der Ausloeser muss ausgeloest haben');

      final bytes = captured?.request.imageBytes;
      expect(bytes, isNotNull,
          reason: 'das Sheet muss ein Capture zurueckgegeben haben');

      // 1) Kein Metadaten-Container mehr im Byte-Strom.
      expect(_hatExifSegment(bytes!), isFalse,
          reason: 'Geraetemodell, Aufnahmezeit und (falls je eine '
              'Standortberechtigung dazukommt) Koordinaten duerfen den '
              'Kamera-Pfad nicht verlassen — genauso wenig wie den '
              'Galerie-Pfad daneben');
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.exif.gpsIfd.keys, isEmpty);
      expect(decoded.exif.isEmpty, isTrue);

      // 2) Zweites, unabhaengiges Merkmal derselben Verdrahtung: der Rohpfad
      //    liefert 2048 px, der komprimierte 1600 px.
      expect(
        decoded.width >= decoded.height ? decoded.width : decoded.height,
        _maxKante,
        reason: 'ohne Re-Kompression ginge das rohe Sensor-JPEG in voller '
            'Groesse an die Edge Function (5-MB-Cap, Base64 +33%)',
      );

      // 3) Vorschau und Upload muessen dieselben (sauberen) Bytes sein — sonst
      //    zeigte die App das gescrubbte Bild und luede das rohe hoch.
      expect(identical(captured!.previewBytes, bytes), isTrue);
    },
  );
}
