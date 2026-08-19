// TEMP-FOTO-AUFRAEUMEN — Komplettreview 2026-08-19.
//
// Kamera und Galerie liefern ihr Bild als DATEI: `takePicture()` schreibt ein
// JPEG in ein Temp-Verzeichnis, `ImagePicker.pickImage` legt wegen der
// gesetzten `imageQuality`/`maxWidth` eine skalierte Kopie im App-Cache ab.
// Die App braucht davon nur die Bytes — geloescht hat die Dateien bisher
// niemand. Sie ueberdauerten den Scan, die Abmeldung und auch die
// Kontoloeschung; das Betriebssystem raeumt den Cache erst unter
// Speicherdruck. Es geht nicht um Speicherplatz, sondern um Essensfotos.
//
// Geprueft wird deshalb das DATEISYSTEM, nicht ein Aufruf: nach jedem der drei
// Wege (Kamera-Sheet, Galerie im Sheet, `DeviceMealPhotoInput`) darf die
// Quelldatei nicht mehr existieren — und zwar erst NACHDEM ihre Bytes gelesen
// sind. Jeder Test sichert beides zugleich ab: waere zu frueh geloescht
// worden, kaeme kein (bzw. kein gescrubbtes) Bild mehr heraus.
//
// Die Fehler- und Abbruchpfade haben eigene Faelle: dort ist das Aufraeumen am
// leichtesten zu vergessen und die Datei bliebe dauerhaft liegen.

import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_camera_sheet.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/meal_photo_temp_file.dart';
import 'package:eatova/src/theme/app_theme.dart';

const List<LocalizationsDelegate<Object?>> _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Ein JPEG mit GPS-Sub-IFD — so schreibt es die Systemkamera. Der Scrub muss
/// es dekodieren koennen, sonst prueft der Erfolgspfad nichts.
Uint8List _jpegMitGps({int width = 480, int height = 360}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(180, 120, 60));
  final gps = image.exif.gpsIfd;
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0004] = img.IfdValueRational(13, 1);
  image.exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// Ersetzt die Geraete-Kamera und verhaelt sich wie das echte Plugin: die
/// Aufnahme wird als DATEI abgelegt, zurueck kommt nur ihr Pfad. Genau darum
/// geht es hier — ein `XFile.fromData` haette nie eine Datei zu loeschen.
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

/// Liefert dem Galerie-Knopf eine echte Datei im Cache-Verzeichnis — so wie
/// `image_picker` seine skalierte Kopie zurueckgibt.
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

/// Laesst echte Datei-IO und den `compute()`-Isolate laufen: beides braucht die
/// reale Event-Loop ([WidgetTester.runAsync]), die Fortsetzungen laufen erst im
/// darauffolgenden `pump()`. Bricht ab, sobald [fertig] zutrifft — ohne den Fix
/// laeuft die Schleife durch und die Zusicherung darunter faellt.
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

Widget _sheetApp(void Function(MealCameraCapture?) merken) {
  return MaterialApp(
    // MealCameraSheet liest Farben ueber `context.t` und Texte ueber
    // `context.l10n` — ohne beides wird der Ausloeser gar nicht gebaut.
    theme: buildEatovaTheme(Brightness.dark),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: _l10nDelegates,
    home: Scaffold(
      body: Builder(
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
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cache;

  setUp(() {
    // Steht stellvertretend fuer das Cache-/Temp-Verzeichnis der App, in das
    // Kamera und Picker ihre Dateien schreiben.
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
      // Zweiter Aufruf auf demselben Pfad, abgebrochene Aufnahme, fremder
      // Aufraeumer: der Aufrufer darf davon nichts merken.
      await expectLater(
        deleteMealPhotoTempFile('${cache.path}${Platform.pathSeparator}weg.jpg'),
        completes,
      );
    });

    test('leerer Pfad (In-Memory-XFile) wirft nicht', () async {
      // `XFile.fromData` ohne Pfad liefert '' — daran haengt keine Datei.
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

      // Reihenfolge-Wache: waere die Datei vor dem Lesen geloescht worden,
      // stuende hier null und der Scan haette gar kein Bild.
      expect(auswahl?.previewBytes, isNotNull,
          reason: 'geloescht werden darf erst nach dem Lesen und Scrubben');
      expect(kopie.existsSync(), isFalse,
          reason: 'das Essensfoto bliebe sonst dauerhaft im App-Cache liegen '
              '— auch nach der Kontoloeschung');
    });

    test('auch wenn der Scrub scheitert, bleibt keine Datei liegen', () async {
      // Nicht dekodierbar: `compressMealPhoto` wirft (fail-closed), die
      // Auswahl kommt ohne Bytes zurueck — die Datei muss trotzdem weg.
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
        // Nicht dekodierbar -> das Sheet bleibt offen und meldet den Fehler.
        // Genau dieser Pfad vergisst das Aufraeumen am leichtesten.
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

        // Der Fehler-Snack haelt einen Auto-Dismiss-Timer: ohne Abraeumen
        // meldet die Test-Binding am Testende eine offene Uhr.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );
  });
}
