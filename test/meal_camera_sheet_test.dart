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
import 'package:eatova/src/widgets/common/app_snack.dart';

/// MealCameraSheet reads `context.l10n`; a constant because several
/// `MaterialApp` setups in this file need the same delegates.
const List<LocalizationsDelegate<Object?>> _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Replaces the real device camera: one back camera, immediate init success,
/// logged lockCaptureOrientation calls. Streams stay open.
///
/// Also counts setup/teardown ([createCalls]/[disposeCalls]) and can stall init
/// via [initGate], making the D3 lifecycle races (pause during a running init)
/// deterministic.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  final List<DeviceOrientation> lockCalls = <DeviceOrientation>[];
  int createCalls = 0;
  int disposeCalls = 0;

  /// While set, `initializeCamera` blocks until the completer completes.
  Completer<void>? initGate;

  /// Simulates a camera permission revoked mid-flight.
  bool denyCamera = false;

  /// Simulates a plugin error that is NOT a permission problem.
  bool failGeneric = false;

  final StreamController<DeviceOrientationChangedEvent> _orientationEvents =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  final StreamController<CameraErrorEvent> _errorEvents =
      StreamController<CameraErrorEvent>.broadcast();

  /// How many cameras are currently open — after each test 0 or 1, never 2
  /// (two parallel controllers = D3 regression).
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
    if (failGeneric) {
      throw CameraException('cameraNotFound', 'No camera');
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
    // A controller that was never created (kUninitializedCameraId = -1) has
    // nothing to release, same as the real platform.
    if (cameraId > 0) disposeCalls += 1;
  }
}

/// Gives the gallery button a fixed image, without a platform channel.
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

/// A JPEG with a GPS sub-IFD, as the system camera writes with location
/// tagging enabled.
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

/// Searches the raw byte stream for the APP1 Exif signature ("Exif\x00\x00").
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

/// Runs frames AND pending futures without waiting for quiescence.
/// `pumpAndSettle` is unusable once the loading state shows: its
/// [CircularProgressIndicator] animates forever.
Future<void> _flush(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The sequence Android/iOS fire when a picker opens or a notification banner
/// appears.
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

  // Review I-2: capture and gallery errors toast while the sheet stays open,
  // so the sheet needs its own host above the scrim. The error paths are not
  // triggerable here (takePicture has no fake), so pin the host in the tree —
  // around the controls, inside the panel.
  testWidgets('das Kamera-Sheet traegt einen SnackHost um seine Bedienelemente',
      (tester) async {
    final fake = _FakeCameraPlatform();
    CameraPlatform.instance = fake;

    await _pumpSheet(tester);

    expect(find.byType(SnackHost), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('meal-camera-shutter')),
        matching: find.byType(SnackHost),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byType(SnackHost),
        matching: find.byType(MealCameraSheet),
      ),
      findsOneWidget,
      reason: 'der Host gehoert INS Sheet, nicht um es herum',
    );
    // The host must not swallow the controls: the close button still works.
    expect(find.byKey(const ValueKey('meal-camera-close')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('meal-camera-gallery')).hitTestable(),
        findsOneWidget);
  });

  group('D3 · Kamera nach Unterbrechung', () {
    testWidgets(
      'nach Pause und Resume laeuft die Vorschau wieder, statt im '
      'Dauer-Spinner zu haengen',
      (tester) async {
        final fake = _FakeCameraPlatform();
        CameraPlatform.instance = fake;

        await _pumpSheet(tester);
        expect(find.byType(CameraPreview), findsOneWidget);

        // User taps the gallery icon: the picker pauses the activity.
        _sendToBackground(tester);
        await _flush(tester);
        expect(fake.disposeCalls, 1);

        // User cancels the picker and is back in the sheet.
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
        // `inactive` only: the engine keeps producing frames, so the rebuild is
        // observable. Setting `_controller = null` without setState used to
        // leave the disposed controller's texture on screen here.
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await _flush(tester);

        expect(fake.disposeCalls, 1);
        expect(find.byType(CameraPreview), findsNothing);
        // No live controller -> loading state, not the stale preview.
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

        // The picker opens before initialize() returns.
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

        // F4-04: `CameraAccessDenied` is named as such, with the way out.
        expect(find.textContaining('Kein Zugriff auf die Kamera'),
            findsOneWidget);
        expect(find.byKey(const ValueKey('meal-camera-open-settings')),
            findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets(
      '"Einstellungen oeffnen" ruft app_settings auf, ein sonstiger '
      'Kamerafehler zeigt den Button nicht',
      (tester) async {
        final settingsCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.spencerccf.app_settings/methods'),
          (call) async {
            settingsCalls.add(call.method);
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('com.spencerccf.app_settings/methods'),
                null));

        final fake = _FakeCameraPlatform();
        fake.denyCamera = true;
        CameraPlatform.instance = fake;

        await _pumpSheet(tester);
        await tester.tap(
            find.byKey(const ValueKey('meal-camera-open-settings')));
        await _flush(tester);
        expect(settingsCalls, isNotEmpty);

        // A non-permission failure: generic message, no Settings button.
        fake.denyCamera = false;
        fake.failGeneric = true;
        _sendToBackground(tester);
        await _flush(tester);
        _bringToForeground(tester);
        await _flush(tester);

        expect(find.textContaining('Kamera nicht verfügbar'), findsOneWidget);
        expect(find.byKey(const ValueKey('meal-camera-open-settings')),
            findsNothing);
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
      // Recompression runs through compute() in a real isolate, which needs the
      // real event loop — pump()'s fake time is not enough.
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

      // Picker opens ...
      await tester.tap(find.byKey(const ValueKey('meal-camera-gallery')));
      _sendToBackground(tester);
      await _flush(tester);
      // ... and closes again, without a selection.
      _bringToForeground(tester);
      await tester.pumpAndSettle();

      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
