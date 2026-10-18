// E5 + FOOD-6 through the real shell: a barcode the product database does not
// know is entered by hand and remembered under its GTIN-13; the next scan,
// in either spelling and from either barcode button, finds it first without
// asking the database. After a network error the entry stays a one-off.

import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/services/open_food_facts_product_service.dart';

import '../flows/flow_test_helpers.dart';
import '../support/design_capture.dart';
import '../support/harness.dart';

const _androidUpcA = '036000291452';
const _gtin13 = '0036000291452';

final DateTime _now = DateTime(2026, 10, 18, 19, 30);

/// Scanner platform without a camera; [emit] delivers a scanned code.
class _FakeScanner extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  void emit(String code, BarcodeFormat format) => _barcodes.add(
    BarcodeCapture(
      barcodes: <Barcode>[Barcode(rawValue: code, format: format)],
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

/// The product database: knows no barcode, or is unreachable.
class _Products implements ProductLookupService {
  _Products({this.offline = false});

  final bool offline;
  final List<String> lookups = <String>[];

  @override
  Future<MealAnalysisResult> lookupBarcode(String barcode) async {
    lookups.add(barcode);
    if (offline) throw const SocketException('offline');
    throw ProductNotFoundException(barcode);
  }

  @override
  Future<List<ProductSearchResult>> searchProducts(String query) async =>
      const <ProductSearchResult>[];
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<_FakeScanner> _pumpShell(WidgetTester tester, _Products products) async {
  final prior = MobileScannerPlatform.instance;
  final scanner = _FakeScanner();
  MobileScannerPlatform.instance = scanner;
  addTearDown(() => MobileScannerPlatform.instance = prior);
  pinDesignViewport(tester);
  // The sheets' own snack hosts lay out off screen at the iPhone insets in
  // the headless test font (pre-existing, not this flow).
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
  await tester.pumpWidget(
    localizedApp(
      EatovaHomePage(
        productService: products,
        mealAnalyzer: FakeMealAnalyzer(),
        mealCameraLauncher: FakeMealCameraLauncher(),
      ),
      safeArea: false,
      scaffold: false,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(_key('nav-Food'));
  await tester.pumpAndSettle();
  return scanner;
}

/// Unknown scan from the Food dock, entered by hand.
Future<void> _scanUnknownAndEnter(
  WidgetTester tester,
  _FakeScanner scanner,
) async {
  await tester.tap(_key('food-action-barcode'));
  await tester.pumpAndSettle();
  // Android delivers UPC-A with 12 digits.
  scanner.emit(_androidUpcA, BarcodeFormat.upcA);
  await tester.pumpAndSettle();
  expect(_key('analyse-error'), findsOneWidget);
  await _tapVisible(tester, _key('analyse-manual-entry'));
  expect(_key('manual-meal-sheet'), findsOneWidget);
}

void main() {
  testWidgets('unbekannter Barcode: von Hand eingetragen, beim naechsten Scan '
      'zuerst gefunden', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      final products = _Products();
      final scanner = await _pumpShell(tester, products);

      await _scanUnknownAndEnter(tester, scanner);
      expect(products.lookups, <String>[
        _gtin13,
      ], reason: 'die Datenbank bekommt die GTIN-13 (FOOD-6)');
      expect(
        find.text(deL10n.foodOwnProductBarcodeNote(_gtin13)),
        findsOneWidget,
      );
      await tester.enterText(_key('manual-meal-name'), 'Hofmilch');
      await tester.enterText(_key('manual-meal-kcal100'), '64');
      await tester.enterText(_key('manual-meal-grams'), '250');
      await tester.pump();
      await _tapVisible(tester, _key('manual-meal-save'));

      final store = storeOf(tester);
      final own = store.favorites.single;
      expect(own.id, 'barcode:$_gtin13');
      expect(own.pinned, isTrue);
      expect(own.result.isOwnProduct, isTrue);
      expect(store.loggedMeals.single.result.barcode, _gtin13);

      // Second scan, this time from the add sheet and in the iOS form.
      await _tapVisible(tester, _key('food-slot-add-snack'));
      await _tapVisible(tester, _key('analyse-barcode-button'));
      scanner.emit(_gtin13, BarcodeFormat.ean13);
      await tester.pumpAndSettle();

      expect(products.lookups, hasLength(1), reason: 'kein zweiter Abruf');
      expect(_key('analyse-error'), findsNothing);
      expect(tester.widget<Text>(_key('analyse-meal-name')).data, 'Hofmilch');
      expect(find.text('Eigenes Produkt'), findsOneWidget);

      // The stored values can be changed from there; the save logs and
      // rewrites the remembered product.
      await _tapVisible(tester, _key('analyse-edit-values'));
      expect(
        tester.widget<TextField>(_key('manual-meal-kcal100')).controller!.text,
        '64',
      );
      await tester.enterText(_key('manual-meal-kcal100'), '70');
      await tester.pump();
      await _tapVisible(tester, _key('manual-meal-save'));

      expect(store.favorites.single.id, 'barcode:$_gtin13');
      expect(store.favorites.single.pinned, isTrue);
      expect(store.favorites.single.result.kcalPer100G, 70);
      expect(store.loggedMeals, hasLength(2));
      expect(products.lookups, hasLength(1));
    });
  });

  testWidgets('nach einem Netzfehler bleibt der Eintrag ohne Barcode', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final products = _Products(offline: true);
      final scanner = await _pumpShell(tester, products);

      await _scanUnknownAndEnter(tester, scanner);
      expect(_key('manual-meal-barcode-note'), findsNothing);
      await tester.enterText(_key('manual-meal-name'), 'Hofmilch');
      await tester.enterText(_key('manual-meal-kcal100'), '64');
      await tester.pump();
      await _tapVisible(tester, _key('manual-meal-save'));

      final store = storeOf(tester);
      expect(store.loggedMeals.single.result.barcode, isNull);
      expect(store.favorites.single.pinned, isFalse);
    });
  });
}
