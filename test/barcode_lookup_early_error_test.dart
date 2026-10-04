// A barcode lookup that fails before the result sheet listens (offline, the
// DNS lookup fails within the frame that builds the sheet) must still be a
// handled error: the sheet shows it, and nothing reaches the zone as an
// unhandled async error, which the crash reporter records as a crash.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:image_picker/image_picker.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';
import 'package:eatova/src/widgets/kcal/add_meal_sheet.dart';

import 'support/harness.dart';

/// Scanner platform without a camera; [emit] delivers a scanned code.
class _FakeScanner extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  void emit(String code) => _barcodes.add(
    BarcodeCapture(
      barcodes: <Barcode>[Barcode(rawValue: code, format: BarcodeFormat.ean13)],
    ),
  );

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
}

/// Offline: the lookup fails in the same event-loop turn, as a failed DNS
/// lookup does on a phone without a network.
class _OfflineProducts implements ProductLookupService {
  final List<String> lookups = <String>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    lookups.add(barcode);
    throw const SocketException('Failed host lookup');
  }

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

class _UnusedAnalyzer implements MealAnalyzer {
  @override
  Future<MealAnalysisResult> analyze(MealAnalysisRequest request) =>
      throw UnimplementedError();
}

class _NoPhotos implements MealPhotoInput {
  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async => null;
}

void main() {
  testWidgets(
    'ein sofort scheiternder Barcode-Lookup landet im Sheet, nicht als '
    'unbehandelter Fehler',
    (tester) async {
      final prior = MobileScannerPlatform.instance;
      final scanner = _FakeScanner();
      MobileScannerPlatform.instance = scanner;
      addTearDown(() => MobileScannerPlatform.instance = prior);
      final products = _OfflineProducts();

      await tester.pumpWidget(
        localizedApp(
          MealAnalysisScreen(dailyConsumedKcal: 0, productService: products),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('food-action-barcode')));
      await tester.pumpAndSettle();

      scanner.emit('4001724012345');
      await tester.pumpAndSettle();

      expect(products.lookups, <String>['4001724012345']);
      expect(
        find.text(enL10n.foodAnalysisOfflineMessage),
        findsOneWidget,
        reason: 'the sheet still reports the error it received',
      );
    },
  );

  testWidgets(
    'im Hinzufuegen-Sheet landet ein sofort scheiternder Barcode-Lookup '
    'ebenso im Sheet, nicht als unbehandelter Fehler',
    (tester) async {
      final prior = MobileScannerPlatform.instance;
      final scanner = _FakeScanner();
      MobileScannerPlatform.instance = scanner;
      addTearDown(() => MobileScannerPlatform.instance = prior);
      final products = _OfflineProducts();
      pinPhoneViewport(tester);

      await tester.pumpWidget(
        localizedApp(
          AddMealSheet(
            slot: MealSlot.lunch,
            analyzer: _UnusedAnalyzer(),
            productService: products,
            photoInput: _NoPhotos(),
            favorites: const [],
            onAdd: (_, _) => 'id-1',
            onUpdateMeal: (_, _) {},
            onRemoveFavorite: (_) {},
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      final barcode = find.byKey(const ValueKey('analyse-barcode-button'));
      await tester.ensureVisible(barcode);
      await tester.tap(barcode);
      await tester.pumpAndSettle();

      scanner.emit('4001724012345');
      await tester.pumpAndSettle();

      expect(products.lookups, <String>['4001724012345']);
      expect(
        find.text(enL10n.foodAnalysisOfflineMessage),
        findsOneWidget,
        reason: 'the sheet still reports the error it received',
      );
    },
  );
}
