// Visual evidence for the meal-slot choice and the entry methods (design
// polish 2026-10-02, agent "slots").
//
// Mounts every host of MealSlotPicker / SlotSelector / MealEntryMethods at the
// design's reference geometry: the add-meal sheet, the barcode scanner sheet,
// the meal camera sheet, the manual entry sheet and the edit sheet, plus a
// gallery with every slot selected once. With
// --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/slots-*.png; without it the suite still checks that
// every host renders the controls without an exception or overflow.

import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/edit_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/manual_meal_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_entry_methods.dart';
import 'package:eatova/src/widgets/kcal/meal_slot_picker.dart';
import 'package:eatova/src/widgets/kcal/slot_selector.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

class _Photos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

class _Analyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) async =>
      throw StateError('not used in captures');
}

class _Products implements ProductLookupService {
  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async =>
      throw UnimplementedError();
  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async => [];
}

/// The scanner starts at once and shows an empty preview.
class _Scanner extends MobileScannerPlatform with MockPlatformInterfaceMixin {
  final _barcodes = StreamController<BarcodeCapture?>.broadcast();
  final _torch = StreamController<TorchState>.broadcast();
  final _zoom = StreamController<double>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;
  @override
  Stream<TorchState> get torchStateStream => _torch.stream;
  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;
  @override
  Widget buildCameraView() => const ColoredBox(color: Color(0xFF2A2730));
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        numberOfCameras: 1,
        size: Size(1280, 720),
        initialDeviceOrientation: DeviceOrientation.portraitUp,
      );
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> toggleTorch() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}

  Future<void> close() async {
    await _barcodes.close();
    await _torch.close();
    await _zoom.close();
  }
}

/// One back camera that initializes at once.
class _Camera extends CameraPlatform with MockPlatformInterfaceMixin {
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  final _orientation =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
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
  ) async => 1;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      _orientation.stream;
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
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
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;
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
  Widget buildPreview(int cameraId) =>
      const ColoredBox(color: Color(0xFF2A2730));
  @override
  Future<void> dispose(int cameraId) async {}
}

MealAnalysisResult _meal(String name) => MealAnalysisResult(
  mealName: name,
  caloriesKcal: 158,
  estimatedGrams: 250,
  kcalPer100G: 63,
  protein: '28 g',
  carbs: '10 g',
  fat: '0.5 g',
  confidence: '',
  portionNotes: '',
);

final _skyr = _meal('Skyr, natural');

final _day = DateTime(2026, 9, 28, 12, 30);

LoggedMeal _logged() => LoggedMeal(
  id: 'meal-1',
  result: _skyr,
  loggedAt: _day,
  forcedSlot: MealSlot.breakfast,
);

/// Pumps a launcher button at the reference geometry and taps it.
Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
        locale: locale,
        textScale: textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _openAdd(BuildContext context) => showAddMealSheet(
  context,
  slot: MealSlot.lunch,
  foodDate: _day,
  analyzer: _Analyzer(),
  photoInput: _Photos(),
  productService: _Products(),
  favorites: [
    for (final name in ['Skyr, natural', 'Oat flakes', 'Banana'])
      FavoriteMeal(
        id: name,
        result: _meal(name),
        addedAt: _day,
        pinned: true,
      ),
  ],
  onAdd: (_, _) => 'id',
  onUpdateMeal: (_, _) {},
  onRemoveFavorite: (_) {},
);

void _expectClean(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

/// The edit sheet's day strip reads the clock: frozen on the meal's day.
Future<void> _edit(
  WidgetTester tester,
  String shot, {
  Locale locale = const Locale('en'),
  double textScale = 1,
}) => withClock(Clock.fixed(_day), () async {
  await _host(
    tester,
    (context) => showEditMealSheet(
      context,
      meal: _logged(),
      onUpdateMeal: (id, {result, slot, day}) => null,
    ),
    locale: locale,
    textScale: textScale,
  );
  final selector = find.byType(SlotSelector);
  expect(selector, findsOneWidget);
  await tester.ensureVisible(selector);
  await tester.pumpAndSettle();
  // Moving the meal to another slot selects that segment.
  await tester.tap(find.byKey(const ValueKey('edit-slot-select-dinner')));
  await tester.pumpAndSettle();
  expect(tester.widget<SlotSelector>(selector).selected, MealSlot.dinner);
  _expectClean(tester);
  await captureDesignShot(tester, shot);
});

void main() {
  setUpAll(loadDesignFonts);

  final scales = <String, double>{'': 1, '-x2': 2};
  for (final MapEntry(key: suffix, value: scale) in scales.entries) {
    testWidgets('add sheet$suffix', (tester) async {
      await _host(tester, _openAdd, textScale: scale);
      expect(find.byType(MealSlotPicker), findsOneWidget);
      expect(find.byType(MealEntryMethods), findsOneWidget);
      _expectClean(tester);
      await captureDesignShot(tester, 'slots-add-sheet$suffix');
    });
  }

  testWidgets('add sheet, German', (tester) async {
    await _host(tester, _openAdd, locale: const Locale('de'));
    expect(find.byType(MealSlotPicker), findsOneWidget);
    _expectClean(tester);
    await captureDesignShot(tester, 'slots-add-sheet-de');
  });

  testWidgets('add sheet, slot choice', (tester) async {
    await _host(tester, _openAdd);
    final snack = find.byKey(const ValueKey('slot-select-snack'));
    expect(snack.hitTestable(), findsOneWidget);
    await tester.tap(snack);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MealSlotPicker>(find.byType(MealSlotPicker)).selected,
      MealSlot.snack,
    );
    _expectClean(tester);
    await captureDesignShot(tester, 'slots-add-sheet-snack');
  });

  group('scanner hosts', () {
    late _Scanner scanner;
    setUp(() {
      MobileScannerController.resetPlatformSessionOwner();
      scanner = _Scanner();
      MobileScannerPlatform.instance = scanner;
      CameraPlatform.instance = _Camera();
    });
    tearDown(() => scanner.close());

    for (final MapEntry(key: suffix, value: scale) in scales.entries) {
      testWidgets('barcode sheet$suffix', (tester) async {
        await _host(
          tester,
          (context) =>
              showBarcodeScannerSheet(context, initialSlot: MealSlot.dinner),
          textScale: scale,
        );
        expect(find.byType(BarcodeScannerSheet), findsOneWidget);
        expect(find.byType(MealSlotPicker), findsOneWidget);
        _expectClean(tester);
        await captureDesignShot(tester, 'slots-barcode$suffix');
      });

      testWidgets('camera sheet$suffix', (tester) async {
        await _host(
          tester,
          (context) => const InAppMealCameraLauncher().launch(
            context,
            initialSlot: MealSlot.breakfast,
          ),
          textScale: scale,
        );
        expect(find.byType(MealSlotPicker), findsOneWidget);
        _expectClean(tester);
        await captureDesignShot(tester, 'slots-camera$suffix');
      });
    }
  });

  for (final MapEntry(key: suffix, value: scale) in scales.entries) {
    testWidgets('manual sheet$suffix', (tester) async {
      await _host(
        tester,
        (context) => showManualMealSheet(
          context,
          initialSlot: MealSlot.snack,
          contextLabel: 'Adds to Monday, Sep 28',
        ),
        textScale: scale,
      );
      expect(find.byType(MealSlotPicker), findsOneWidget);
      _expectClean(tester);
      await captureDesignShot(tester, 'slots-manual$suffix');
    });

    testWidgets('edit sheet$suffix', (tester) async {
      await _edit(tester, 'slots-edit$suffix', textScale: scale);
    });
  }

  testWidgets('edit sheet, German', (tester) async {
    await _edit(tester, 'slots-edit-de', locale: const Locale('de'));
  });

  // Proposed host wiring: the manual row joins the methods card.
  testWidgets('entry methods with the manual row', (tester) async {
    final taps = <String>[];
    pinDesignViewport(tester);
    await tester.pumpWidget(
      designCaptureBoundary(
        localizedApp(
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 80, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MealSlotPicker(selected: MealSlot.snack, onSelected: (_) {}),
                const SizedBox(height: 16),
                MealEntryMethods(
                  onCamera: () => taps.add('camera'),
                  onGallery: () => taps.add('gallery'),
                  onBarcode: () => taps.add('barcode'),
                  onManual: () => taps.add('manual'),
                ),
              ],
            ),
          ),
          locale: const Locale('en'),
          safeArea: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in [
      'analyse-camera-button',
      'analyse-gallery-button',
      'analyse-barcode-button',
      'manual-entry-button',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }
    expect(taps, ['camera', 'gallery', 'barcode', 'manual']);
    _expectClean(tester);
    await captureDesignShot(tester, 'slots-methods-manual');
  });

  // Every slot selected once, in both controls.
  for (final (suffix, locale, scale) in [
    ('', const Locale('en'), 1.0),
    ('-de', const Locale('de'), 1.0),
    ('-x2', const Locale('en'), 2.0),
  ]) {
    testWidgets('gallery$suffix: every slot selected once', (tester) async {
      pinDesignViewport(tester);
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final slot in MealSlot.values) ...[
                    MealSlotPicker(
                      keyPrefix: 'gallery-${slot.name}-',
                      selected: slot,
                      onSelected: (_) {},
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                  for (final slot in MealSlot.values) ...[
                    SlotSelector(
                      keyPrefix: 'gallery-edit-${slot.name}-',
                      selected: slot,
                      onSelected: (_) {},
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
            locale: locale,
            textScale: scale,
            safeArea: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MealSlotPicker), findsNWidgets(4));
      expect(find.byType(SlotSelector), findsNWidgets(4));
      _expectClean(tester);
      await captureDesignShot(tester, 'slots-gallery$suffix');
    });
  }
}
