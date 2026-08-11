import 'dart:async';

import 'package:camera/camera.dart';
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
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';

/// MealCameraSheet liest seit der i18n-Migration `context.l10n` — dasselbe
/// Delegates-Buendel wie test/home_page_tabs_test.dart, hier als Konstante,
/// weil mehrere `MaterialApp`-Aufbauten in dieser Datei es brauchen.
const List<LocalizationsDelegate<Object?>> _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Ersetzt die echte Geraete-Kamera: liefert eine Back-Kamera, laesst die
/// Initialisierung sofort gelingen und protokolliert lockCaptureOrientation-
/// Aufrufe. Streams bleiben offen (kein .first-Fehler auf leeren Streams).
///
/// Zaehlt zusaetzlich Auf- und Abbauten ([createCalls]/[disposeCalls]) und
/// kann die Initialisierung ueber [initGate] anhalten — damit sind die
/// Lifecycle-Rennen aus D3 (Pause waehrend laufender Initialisierung)
/// deterministisch nachstellbar.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  final List<DeviceOrientation> lockCalls = <DeviceOrientation>[];
  int createCalls = 0;
  int disposeCalls = 0;

  /// Solange gesetzt, blockiert `initializeCamera` bis der Completer laeuft.
  Completer<void>? initGate;

  /// Simuliert eine waehrenddessen entzogene Kamera-Berechtigung.
  bool denyCamera = false;

  final StreamController<DeviceOrientationChangedEvent> _orientationEvents =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  final StreamController<CameraErrorEvent> _errorEvents =
      StreamController<CameraErrorEvent>.broadcast();

  /// Wie viele Kameras aktuell offen sind — nach jedem Test muss das 0 oder 1
  /// sein, nie 2 (zwei parallele Controller = D3-Regression).
  int get openCameras => createCalls - disposeCalls;

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
  ) async {
    if (denyCamera) {
      throw CameraException('CameraAccessDenied', 'Permission revoked');
    }
    createCalls += 1;
    return createCalls;
  }

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
  }) async {
    final gate = initGate;
    if (gate != null) await gate.future;
  }

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
  Future<void> dispose(int cameraId) async {
    // Ein nie erzeugter Controller (kUninitializedCameraId = -1) hat auf der
    // Plattform nichts freizugeben — so verhaelt sich auch die echte.
    if (cameraId > 0) disposeCalls += 1;
  }
}

/// Liefert dem Galerie-Knopf ein festes Bild, ohne Plattform-Kanal.
class _FakeImagePickerPlatform extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakeImagePickerPlatform(this.result);

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

/// Ein JPEG mit GPS-Sub-IFD — wie es die Systemkamera mit Standort-Tagging in
/// die Galerie schreibt.
Uint8List _geotaggedJpeg({int width = 480, int height = 360}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(180, 120, 60));
  final gps = image.exif.gpsIfd;
  gps[0x0001] = img.IfdValueAscii('N');
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0003] = img.IfdValueAscii('E');
  gps[0x0004] = img.IfdValueRational(13, 1);
  gps[0x0006] = img.IfdValueRational(3417, 100);
  image.exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Sucht die APP1-Exif-Signatur ("Exif\x00\x00") im rohen Byte-Strom.
bool _hasExifSegment(Uint8List bytes) {
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

Future<void> _pumpSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: _l10nDelegates,
      home: const Scaffold(
        body: MealCameraSheet(initialSlot: MealSlot.lunch),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Laesst Frames UND anhaengige Futures durchlaufen, ohne auf Ruhe zu warten.
/// `pumpAndSettle` ist hier nicht benutzbar, sobald der Ladezustand sichtbar
/// ist: dessen [CircularProgressIndicator] animiert endlos.
Future<void> _flush(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Die Sequenz, die Android/iOS beim Oeffnen eines Pickers bzw. beim
/// Einblenden eines Benachrichtigungsbanners feuern.
void _sendToBackground(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _bringToForeground(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'KI-Scan-Kamera lockt die Capture-Orientierung auf portraitUp, '
    'damit die Vorschau bei Geraete-Rotation nicht mitdreht',
    (tester) async {
      final fake = _FakeCameraPlatform();
      CameraPlatform.instance = fake;

      await _pumpSheet(tester);

      expect(fake.lockCalls, const [DeviceOrientation.portraitUp]);
    },
  );

  group('D3 · Kamera nach Unterbrechung', () {
    testWidgets(
      'nach Pause und Resume laeuft die Vorschau wieder, statt im '
      'Dauer-Spinner zu haengen',
      (tester) async {
        final fake = _FakeCameraPlatform();
        CameraPlatform.instance = fake;

        await _pumpSheet(tester);
        expect(find.byType(CameraPreview), findsOneWidget);

        // Nutzer tippt das Galerie-Icon: der Picker pausiert die Activity.
        _sendToBackground(tester);
        await _flush(tester);
        expect(fake.disposeCalls, 1);

        // Nutzer bricht den Picker ab und ist wieder im Sheet.
        _bringToForeground(tester);
        await tester.pumpAndSettle();

        expect(find.byType(CameraPreview), findsOneWidget,
            reason: 'ohne Neu-Initialisierung bliebe hier der Spinner stehen');
        expect(fake.createCalls, 2);
        expect(fake.openCameras, 1);
      },
    );

    testWidgets(
      'ein Benachrichtigungsbanner (inactive) raeumt die tote Vorschau sofort '
      'ab, statt einen wirkungslosen Ausloeser stehenzulassen',
      (tester) async {
        final fake = _FakeCameraPlatform();
        CameraPlatform.instance = fake;

        await _pumpSheet(tester);
        // Nur `inactive`: die Engine produziert weiter Frames, der Rebuild ist
        // also beobachtbar. Genau hier zeigte die alte Fassung noch die
        // Texture des bereits entsorgten Controllers, weil `_controller = null`
        // ohne setState lief.
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await _flush(tester);

        expect(fake.disposeCalls, 1);
        expect(find.byType(CameraPreview), findsNothing);
        // Kein lebender Controller -> Ladezustand, nicht die alte Vorschau.
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );

    testWidgets(
      'eine Pause waehrend der Initialisierung laesst die Kamera nicht im '
      'Hintergrund offen',
      (tester) async {
        final fake = _FakeCameraPlatform();
        fake.initGate = Completer<void>();
        CameraPlatform.instance = fake;

        await tester.pumpWidget(
          MaterialApp(
            theme: buildEatovaTheme(Brightness.dark),
            locale: const Locale('de'),
            supportedLocales: const [Locale('de'), Locale('en')],
            localizationsDelegates: _l10nDelegates,
            home: const Scaffold(
              body: MealCameraSheet(initialSlot: MealSlot.lunch),
            ),
          ),
        );
        await tester.pump();

        // Der Picker geht auf, bevor initialize() zurueck ist.
        _sendToBackground(tester);
        await tester.pump();

        fake.initGate!.complete();
        await _flush(tester);

        expect(fake.openCameras, 0,
            reason: 'die Kamera darf im Hintergrund nicht weiterlaufen');
        expect(find.byType(CameraPreview), findsNothing);
      },
    );

    testWidgets(
      'ein Resume waehrend laufender Initialisierung erzeugt keinen zweiten '
      'Controller',
      (tester) async {
        final fake = _FakeCameraPlatform();
        fake.initGate = Completer<void>();
        CameraPlatform.instance = fake;

        await tester.pumpWidget(
          MaterialApp(
            theme: buildEatovaTheme(Brightness.dark),
            locale: const Locale('de'),
            supportedLocales: const [Locale('de'), Locale('en')],
            localizationsDelegates: _l10nDelegates,
            home: const Scaffold(
              body: MealCameraSheet(initialSlot: MealSlot.lunch),
            ),
          ),
        );
        await tester.pump();

        _bringToForeground(tester);
        await tester.pump();

        fake.initGate!.complete();
        await tester.pumpAndSettle();

        expect(fake.openCameras, 1);
        expect(find.byType(CameraPreview), findsOneWidget);
      },
    );

    testWidgets(
      'wird die Berechtigung waehrend der Unterbrechung entzogen, erscheint '
      'die Fehlerflaeche statt eines haengenden Spinners',
      (tester) async {
        final fake = _FakeCameraPlatform();
        CameraPlatform.instance = fake;

        await _pumpSheet(tester);
        expect(find.byType(CameraPreview), findsOneWidget);

        fake.denyCamera = true;
        _sendToBackground(tester);
        await _flush(tester);
        _bringToForeground(tester);
        await _flush(tester);

        expect(find.textContaining('Kamera nicht verfügbar'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('das Schliessen des Sheets laesst keine Kamera offen',
        (tester) async {
      final fake = _FakeCameraPlatform();
      CameraPlatform.instance = fake;

      await _pumpSheet(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();

      expect(fake.openCameras, 0);
    });
  });

  group('C4 · Galerie-Pfad im Kamera-Sheet', () {
    testWidgets('gewaehltes Galerie-Foto verlaesst das Sheet ohne GPS/EXIF',
        (tester) async {
      final camera = _FakeCameraPlatform();
      CameraPlatform.instance = camera;

      final raw = _geotaggedJpeg();
      expect(_hasExifSegment(raw), isTrue,
          reason: 'sonst prueft der Test nichts');
      final picker = _FakeImagePickerPlatform(
        XFile.fromData(raw, name: 'meal.jpg', mimeType: 'image/jpeg'),
      );
      ImagePickerPlatform.instance = picker;

      MealCameraCapture? captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de'), Locale('en')],
          localizationsDelegates: _l10nDelegates,
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

      await tester.tap(find.byKey(const ValueKey('meal-camera-gallery')));
      // Die Re-Kompression laeuft ueber compute() in einem echten Isolate —
      // der braucht die reale Event-Loop, die Fake-Zeit von pump() reicht
      // nicht.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      final bytes = captured?.request.imageBytes;
      expect(bytes, isNotNull);
      expect(_hasExifSegment(bytes!), isFalse,
          reason: 'Standort und Geraetedaten duerfen nicht mitgehen');
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.exif.gpsIfd.keys, isEmpty);
    });

    testWidgets('abgebrochener Galerie-Pick friert das Sheet nicht ein',
        (tester) async {
      final camera = _FakeCameraPlatform();
      CameraPlatform.instance = camera;
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(null);

      await _pumpSheet(tester);

      // Picker auf ...
      await tester.tap(find.byKey(const ValueKey('meal-camera-gallery')));
      _sendToBackground(tester);
      await _flush(tester);
      // ... und wieder zu, ohne Auswahl.
      _bringToForeground(tester);
      await tester.pumpAndSettle();

      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
