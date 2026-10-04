// Visual evidence for the 2026-10-03 sweep of leftover Material defaults:
// the data export sheet (format pills, soft copy/share actions, section
// pills), the onboarding review rows, the camera and scanner fallback layers,
// the analysis error card and the workout finish sheet.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/misc-*.png; without it the suite still checks that
// every surface renders with the design-system controls and without an
// exception or overflow, at 390 px and at 320 px with 2x text.

import 'dart:async';
import 'dart:convert';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';
import 'package:eatova/src/screens/onboarding_screen.dart';
import 'package:eatova/src/screens/training/player/player_finish_sheet.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/services/meal_camera_launcher.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/shared/data_export_sheet.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';
import '../support/onboarding_harness.dart';

String _export() => jsonEncode({
  'format': DataExportService.formatKennung,
  'exportedAt': '2026-10-03T09:30:00Z',
  'userId': 'demo-account',
  for (final table in DataExportService.alleExportTabellen) table: <dynamic>[],
  'profiles': [
    {'display_name': 'Alex', 'daily_kcal_goal': 2200},
  ],
  'logged_meals': List.generate(
    5,
    (i) => {
      'id': 'meal-$i',
      'logged_at': '2026-09-${20 + i}T12:00:00Z',
      'payload': {'mealName': 'Bowl $i', 'kcal': 500 + i},
    },
  ),
});

/// Every scanner start ends in a denied permission.
class _DeniedScanner extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
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
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
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

/// A back camera whose access is denied.
class _DeniedCamera extends CameraPlatform with MockPlatformInterfaceMixin {
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
  ) async => throw CameraException('CameraAccessDenied', 'denied');
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();
  @override
  Future<void> dispose(int cameraId) async {}
}

/// The reference phone, optionally narrowed to [width].
void _viewport(WidgetTester tester, double width) {
  pinDesignViewport(tester);
  tester.view.physicalSize =
      Size(width, kDesignViewport.height) * kDesignPixelRatio;
}

/// Pumps a launcher button and taps it.
Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  double width = 390,
  double textScale = 1,
}) async {
  _viewport(tester, width);
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
        locale: const Locale('en'),
        textScale: textScale,
        safeArea: false,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Builds and centres [key] in the sheet's lazy list.
Future<void> _reveal(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(finder, 120);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

/// Whether [key] sits on a design-system pill of type [T].
void _expectPill<T extends Widget>(String key) {
  expect(
    find.byWidgetPredicate((w) => w is T && w.key == ValueKey(key)),
    findsOneWidget,
    reason: key,
  );
}

void main() {
  setUpAll(loadDesignFonts);

  const sizes = <(String, double, double)>[
    ('', 390, 1),
    ('-320-x2', 320, 2),
  ];

  for (final (suffix, width, scale) in sizes) {
    testWidgets('export sheet$suffix', (tester) async {
      await _host(
        tester,
        (context) => showDataExportSheet(
          context,
          snapshot: () async => _export(),
          dateiTeilen: (_, _) async {},
        ),
        width: width,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'misc-export$suffix');

      // At 2x text the actions sit below the fold of the lazy list.
      await _reveal(tester, 'export-format-text');
      _expectPill<FilterChipPill>('export-format-text');
      _expectPill<FilterChipPill>('export-format-json');
      expect(find.byType(ChoiceChip), findsNothing);
      await _reveal(tester, 'profile-export-share');
      _expectPill<SoftPillButton>('profile-export-copy');
      _expectPill<SoftPillButton>('profile-export-share');
      if (scale > 1) {
        await captureDesignShot(tester, 'misc-export-actions$suffix');
      }

      // JSON selected, then one section opened with its copy pills.
      await tester.tap(find.byKey(const ValueKey('export-format-json')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChipPill>(
              find.byKey(const ValueKey('export-format-json')),
            )
            .selected,
        isTrue,
      );
      final section = find.byKey(const ValueKey('export-expand-logged_meals'));
      await tester.scrollUntilVisible(section, 200);
      await tester.pumpAndSettle();
      await tester.tap(section);
      await tester.pumpAndSettle();
      final csv = find.byKey(const ValueKey('export-csv-logged_meals'));
      await tester.ensureVisible(csv);
      await tester.pumpAndSettle();
      _expectPill<SoftPillButton>('export-copy-logged_meals');
      _expectPill<SoftPillButton>('export-csv-logged_meals');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'misc-export-section$suffix');
    });

    testWidgets('onboarding review$suffix', (tester) async {
      _viewport(tester, width);
      await tester.pumpWidget(
        designCaptureBoundary(
          localizedApp(
            OnboardingScreen(
              firstName: 'Alex',
              initialProfile: const UserProfile(
                weightGoal: WeightGoal.lose05kg,
              ),
              onComplete: (_) {},
            ),
            locale: const Locale('en'),
            textScale: scale,
            safeArea: false,
            scaffold: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await goToOnboarding(tester, 'summary');
      final diet = find.byKey(const ValueKey('onboarding-edit-diet'));
      await tester.ensureVisible(diet);
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNothing);
      for (final step in ['basics', 'body', 'activity', 'goal', 'diet']) {
        _expectPill<SettingsRow>('onboarding-edit-$step');
      }
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'misc-onboarding-review$suffix');
    });

    group('camera fallbacks$suffix', () {
      late _DeniedScanner scanner;
      setUp(() {
        MobileScannerController.resetPlatformSessionOwner();
        scanner = _DeniedScanner();
        MobileScannerPlatform.instance = scanner;
        CameraPlatform.instance = _DeniedCamera();
      });
      tearDown(() => scanner.close());

      testWidgets('barcode permission denied', (tester) async {
        await _host(
          tester,
          (context) =>
              showBarcodeScannerSheet(context, initialSlot: MealSlot.lunch),
          width: width,
          textScale: scale,
        );
        expect(
          find.byKey(const ValueKey('barcode-scanner-failed')),
          findsOneWidget,
        );
        _expectPill<SoftPillButton>('barcode-open-settings');
        _expectPill<SoftPillButton>('barcode-type-in');
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'misc-barcode-denied$suffix');

        final typeIn = find.byKey(const ValueKey('barcode-type-in'));
        await tester.ensureVisible(typeIn);
        await tester.pumpAndSettle();
        await tester.tap(typeIn);
        await tester.pumpAndSettle();
        _expectPill<PrimaryActionButton>('barcode-manual-submit');
        _expectPill<SoftPillButton>('barcode-manual-back');
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'misc-barcode-manual$suffix');
      });

      testWidgets('meal camera permission denied', (tester) async {
        await _host(
          tester,
          (context) => const InAppMealCameraLauncher().launch(
            context,
            initialSlot: MealSlot.breakfast,
          ),
          width: width,
          textScale: scale,
        );
        expect(find.byKey(const ValueKey('meal-camera-failed')), findsOneWidget);
        _expectPill<SoftPillButton>('meal-camera-open-settings');
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'misc-camera-denied$suffix');
      });
    });

    testWidgets('analysis error card$suffix', (tester) async {
      final failing = Completer<MealAnalysisResult>();
      await _host(
        tester,
        (context) => showMealAnalysisSheet(
          context,
          slot: MealSlot.dinner,
          resultFuture: failing.future,
          previewImage: null,
          onAdd: (_, _) => 'id',
          onUpdateMeal: (_, _) {},
          failureMessage: 'The analysis is unavailable right now.',
          retry: () => Completer<MealAnalysisResult>().future,
        ),
        width: width,
        textScale: scale,
      );
      failing.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('analyse-error')), findsOneWidget);
      _expectPill<PrimaryActionButton>('analyse-retry');
      _expectPill<SoftPillButton>('analyse-manual-entry');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'misc-analysis-error$suffix');
    });

    for (final (state, completed, open) in [
      ('open-sets', 4, 2),
      ('nothing-done', 0, 6),
    ]) {
      testWidgets('finish sheet $state$suffix', (tester) async {
        final note = TextEditingController();
        addTearDown(note.dispose);
        await _host(
          tester,
          (context) => showPlayerFinishSheet(
            context,
            completed: completed,
            skipped: 0,
            open: open,
            total: completed + open,
            valuesValid: true,
            note: note,
            onNoteChanged: () {},
          ),
          width: width,
          textScale: scale,
        );
        _expectPill<SoftPillButton>('training-finish-keep');
        if (completed == 0) {
          _expectPill<SoftPillButton>('training-finish-discard');
          expect(
            tester
                .widget<SoftPillButton>(
                  find.byKey(const ValueKey('training-finish-discard')),
                )
                .tone,
            SoftPillTone.danger,
          );
        } else {
          _expectPill<SoftPillButton>('training-finish-log-rest');
        }
        expect(find.byType(TextButton), findsOneWidget, reason: 'launcher');
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, 'misc-finish-$state$suffix');
      });
    }
  }
}
