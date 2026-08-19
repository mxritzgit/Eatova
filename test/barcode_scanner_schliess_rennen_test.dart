import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/barcode_scanner_sheet.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Das Sheet liest `context.l10n` — dasselbe Delegates-Buendel wie
/// test/meal_camera_sheet_test.dart.
const List<LocalizationsDelegate<Object?>> _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Ersetzt die echte Scanner-Plattform: die Kamera startet sofort, und
/// [emit] schiebt einen Treffer in denselben Stream, aus dem der echte
/// Analyzer liefert. Nur so ist das Rennen zwischen Schliess-Animation und
/// nachlaufendem Treffer ueberhaupt nachstellbar.
///
/// [stopCalls] zaehlt die Plattform-Stops — daran haengt der Nachweis, dass
/// der Analyzer BEIM Schliessen abgeschaltet wird und nicht erst am Ende der
/// Ausblendzeit durch `dispose`.
class _FakeScannerPlatform extends MobileScannerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<BarcodeCapture?> _barcodes =
      StreamController<BarcodeCapture?>.broadcast();
  final StreamController<TorchState> _torch =
      StreamController<TorchState>.broadcast();
  final StreamController<double> _zoom = StreamController<double>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;

  void emit(String rawValue) {
    _barcodes.add(
      BarcodeCapture(
        barcodes: <Barcode>[
          Barcode(rawValue: rawValue, format: BarcodeFormat.ean13),
        ],
      ),
    );
  }

  Future<void> schliessen() async {
    await _barcodes.close();
    await _torch.close();
    await _zoom.close();
  }

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;

  @override
  Stream<TorchState> get torchStateStream => _torch.stream;

  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;

  @override
  Widget buildCameraView() => const SizedBox.expand();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    startCalls += 1;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      numberOfCameras: 1,
      size: Size(1280, 720),
      initialDeviceOrientation: DeviceOrientation.portraitUp,
    );
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> toggleTorch() async {}

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> dispose() async {}
}

/// Sammelt, was der Aufrufer aus [showBarcodeScannerSheet] zurueckbekommt.
class _Ergebnis {
  String? code;
  bool geschlossen = false;
}

/// Baut die Schachtelung des echten Flows nach: der Scanner haengt IMMER
/// ueber einem anderen Sheet (Add-Sheet bzw. Analyse-Screen). Genau dieses
/// darunterliegende Sheet riss der zweite Pop frueher mit.
Future<void> _oeffneScannerUeberSheet(
  WidgetTester tester,
  _FakeScannerPlatform platform,
  _Ergebnis ergebnis,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: _l10nDelegates,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (sheetContext) => SizedBox(
                height: 260,
                child: Center(
                  child: TextButton(
                    onPressed: () async {
                      ergebnis.code = await showBarcodeScannerSheet(
                        sheetContext,
                      );
                      ergebnis.geschlossen = true;
                    },
                    child: const Text('scannen'),
                  ),
                ),
              ),
            ),
            child: const Text('add-sheet'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('add-sheet'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('scannen'));
  await tester.pumpAndSettle();

  expect(find.byType(BarcodeScannerSheet), findsOneWidget);
  expect(
    platform.startCalls,
    1,
    reason: 'ohne laufenden Analyzer prueft der Rest dieser Datei nichts',
  );
}

void main() {
  late _FakeScannerPlatform platform;

  setUp(() {
    // Der Session-Besitzer ist statisch und wuerde sonst zwischen den Tests
    // durchschlagen.
    MobileScannerController.resetPlatformSessionOwner();
    platform = _FakeScannerPlatform();
    MobileScannerPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.schliessen();
  });

  testWidgets(
    'ein Treffer waehrend der Schliess-Animation schliesst nicht auch das '
    'darunterliegende Sheet',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);

      await tester.tap(find.byKey(const ValueKey('barcode-close-button')));
      // Genau ein Frame: die Ausblendzeit laeuft, das Sheet steht noch im
      // Baum — das ist das Fenster, in dem der Analyzer frueher weiterlief.
      await tester.pump();
      expect(find.byType(BarcodeScannerSheet), findsOneWidget);

      platform.emit('4001234567890');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(
        find.text('scannen'),
        findsOneWidget,
        reason: 'der zweite Pop haette das darunterliegende Sheet mitgerissen',
      );
      expect(ergebnis.geschlossen, isTrue);
      expect(ergebnis.code, isNull);
    },
  );

  testWidgets(
    'Barrier-Tap schaltet den Analyzer sofort ab, nicht erst am Ende der '
    'Ausblendzeit',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);
      final stopsVorher = platform.stopCalls;

      // Oberer Bildschirmrand: dort liegt der Scrim des Scanner-Sheets, nicht
      // das ~60% hohe Panel selbst.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();

      expect(
        platform.stopCalls,
        greaterThan(stopsVorher),
        reason: 'Wisch- und Barrier-Dismiss laufen an der Schliess-Methode '
            'vorbei; ohne den PopScope-Haken bliebe der Analyzer an',
      );

      platform.emit('4001234567890');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(find.text('scannen'), findsOneWidget);
      expect(ergebnis.code, isNull);
    },
  );

  testWidgets(
    'ein Treffer im offenen Sheet liefert den getrimmten Code und laesst das '
    'darunterliegende Sheet stehen',
    (tester) async {
      final ergebnis = _Ergebnis();
      await _oeffneScannerUeberSheet(tester, platform, ergebnis);

      platform.emit('  4001234567890  ');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(ergebnis.code, '4001234567890');
      expect(find.byType(BarcodeScannerSheet), findsNothing);
      expect(
        find.text('scannen'),
        findsOneWidget,
        reason: 'die neue Routen-Wache darf den Normalfall nicht abwuergen',
      );
    },
  );
}
