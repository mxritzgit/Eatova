import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/l10n.dart';
import '../models/logged_meal.dart';
import '../services/crash_reporter.dart';
import '../services/meal_camera_launcher.dart' show openAppSettingsForCamera;
import '../theme/app_tokens.dart';
import '../widgets/design/design.dart';
import '../widgets/kcal/scan_slot_chips.dart';

/// Barcode scanner result: the trimmed code and the slot picked via the chips
/// on the camera preview.
class BarcodeScan {
  const BarcodeScan({required this.code, required this.slot});

  final String code;
  final MealSlot slot;
}

/// Opens the barcode scanner as a ~60% bottom panel, same frame as the AI scan
/// camera ([MealCameraSheet]). Returns code + slot, or null on cancel.
///
/// [initialSlot] preselects the slot chips; the choice made in the scanner
/// wins.
Future<BarcodeScan?> showBarcodeScannerSheet(
  BuildContext context, {
  required MealSlot initialSlot,
}) {
  return showModalBottomSheet<BarcodeScan>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.t.scrim,
    builder: (_) => BarcodeScannerSheet(initialSlot: initialSlot),
  );
}

/// EAN-8, UPC-A (12) and EAN-13 — the formats the scanner accepts.
bool isValidTypedBarcode(String digits) =>
    RegExp(r'^\d+$').hasMatch(digits) &&
    (digits.length == 8 || digits.length == 12 || digits.length == 13);

class BarcodeScannerSheet extends StatefulWidget {
  const BarcodeScannerSheet({super.key, required this.initialSlot});

  final MealSlot initialSlot;

  @override
  State<BarcodeScannerSheet> createState() => _BarcodeScannerSheetState();
}

class _BarcodeScannerSheetState extends State<BarcodeScannerSheet>
    with WidgetsBindingObserver {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.ean8, BarcodeFormat.ean13, BarcodeFormat.upcA],
    // autoZoom pulls the barcode in instead of leaving it small in the
    // wide-angle sensor image, which makes scanning far more reliable.
    autoZoom: true,
  );
  bool hasReturned = false;

  bool _analyzerHaengt = false;

  /// Manual entry layer open (permission denied / camera dead).
  bool _manuelleEingabe = false;

  /// Set when the user was sent to Settings: the next resume retries the
  /// camera even though the last start ended in `permissionDenied`.
  bool _settingsGeoeffnet = false;

  late MealSlot _slot;

  @override
  void initState() {
    super.initState();
    // [MobileScanner] only observes the lifecycle for its OWN controller; with
    // an injected one (ours) the preview froze after an app switch (F4-03).
    WidgetsBinding.instance.addObserver(this);
    _slot = widget.initialSlot;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (hasReturned) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_analyzerStoppen());
      case AppLifecycleState.resumed:
        unawaited(_nachResumeStarten());
    }
  }

  /// Restart after an interruption. Permission guard as in mobile_scanner's
  /// own observer — except right after a Settings visit, which is the one
  /// moment a fresh start may succeed where the last one was denied.
  Future<void> _nachResumeStarten() async {
    final value = controller.value;
    if (value.isRunning || value.isStarting) return;
    final retryAfterSettings = _settingsGeoeffnet;
    _settingsGeoeffnet = false;
    if (!value.hasCameraPermission && !retryAfterSettings) return;
    try {
      await controller.start();
    } catch (_) {
      // `start()` reports permission errors via `value.error`; anything else
      // (already starting, disposed) leaves the current layer in place.
    }
  }

  /// Surfaces analysis errors instead of swallowing them.
  ///
  /// The FIRST error counts. A blurry frame produces no error at all (it takes
  /// the success path with an empty barcode list); `onDetectError` only fires
  /// on an ML Kit processing error, and that branch never calls
  /// `imageProxy.close()`. With STRATEGY_KEEP_ONLY_LATEST CameraX then
  /// delivers no further frame, so any threshold > 1 is unreachable.
  ///
  /// The restart is required because the analyzer cannot recover on its own —
  /// otherwise the preview stays live while the scanner is dead.
  void handleDetectError(Object error, StackTrace stackTrace) {
    if (hasReturned || !mounted || _analyzerHaengt) return;
    setState(() => _analyzerHaengt = true);
    CrashReporter.capture(error, stackTrace, context: 'barcode-detect');
  }

  /// Stops the analyzer and marks this sheet as done.
  ///
  /// Must run before EVERY pop: the close animation takes ~250 ms and the
  /// [MobileScanner] is only torn down at its end, so a late hit would pop a
  /// second time and take the underlying sheet with it.
  ///
  /// `controller.stop()` cuts the barcode subscription synchronously; only the
  /// platform stop behind it is async, so it is fired and not awaited.
  void _erkennungBeenden() {
    if (hasReturned) return;
    hasReturned = true;
    unawaited(_analyzerStoppen());
  }

  Future<void> _analyzerStoppen() async {
    try {
      await controller.stop();
    } catch (_) {
      // The sheet is on its way out and `dispose()` cleans up anyway, so a
      // failed stop has no consequence here.
    }
  }

  void _selectSlot(MealSlot slot) {
    if (slot == _slot) return;
    HapticFeedback.selectionClick();
    setState(() => _slot = slot);
  }

  void _schliessen() {
    _erkennungBeenden();
    Navigator.of(context).pop();
  }

  Future<void> _neuStarten() async {
    setState(() {
      _analyzerHaengt = false;
    });
    try {
      await controller.stop();
      await controller.start();
    } catch (_) {
      // If the restart fails, keep the notice up — a silent failure would be
      // exactly the previous bug.
      if (mounted) setState(() => _analyzerHaengt = true);
    }
  }

  void _einstellungenOeffnen() {
    _settingsGeoeffnet = true;
    unawaited(openAppSettingsForCamera());
  }

  void _manuellEingeben() {
    setState(() => _manuelleEingabe = true);
  }

  void _manuelleEingabeSchliessen() {
    setState(() => _manuelleEingabe = false);
  }

  /// Typed code takes the same exit as a scanned one, so the caller's
  /// `lookupBarcode` path stays the single consumer.
  void _codeAbgeben(String code) {
    if (hasReturned || !mounted) return;
    _erkennungBeenden();
    Navigator.of(context).pop(BarcodeScan(code: code, slot: _slot));
  }

  void handleDetect(BarcodeCapture capture) {
    if (hasReturned || !mounted) {
      return;
    }
    // Second guard against the same double pop: `hasReturned` only covers
    // what goes through this class. If the route is no longer topmost, a pop
    // here would hit the route below.
    if (ModalRoute.of(context)?.isCurrent != true) {
      return;
    }

    // A good frame means the analyzer is running again.
    if (_analyzerHaengt) setState(() => _analyzerHaengt = false);

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        final code = rawValue.trim();
        _codeAbgeben(code);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // ~60% of screen height, identical to the AI scan panel so both scan
    // paths read as the same in-app pattern.
    final panelHeight = mediaQuery.size.height * 0.6;

    return PopScope<Object?>(
      // Listener only, no veto: `canPop` stays true. Swipe, barrier tap and
      // system back bypass [_schliessen], so this is how the sheet learns of
      // them and can stop the analyzer before the fade-out.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _erkennungBeenden();
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: SizedBox(
          height: panelHeight,
          child: Container(
            decoration: BoxDecoration(
              color: context.t.bg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(rSheet),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const _SheetHandle(),
                _HeaderRow(onClose: _schliessen),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(rCard),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MobileScanner(
                            controller: controller,
                            onDetect: handleDetect,
                            // Without this handler the default is literally
                            // "do nothing", so analysis errors vanished:
                            // `errorBuilder` hangs off
                            // `controller.value.error`, which they never set.
                            // Worse, the error path never closes the
                            // imageProxy, so under
                            // STRATEGY_KEEP_ONLY_LATEST the analyzer stalls
                            // after the FIRST bad frame — live preview, scan
                            // frame, never a hit and never a message.
                            onDetectError: handleDetectError,
                            // Fills the frame without distortion (crops
                            // instead of squashing), like the AI scan preview.
                            fit: BoxFit.cover,
                            placeholderBuilder: (_) =>
                                const _ScannerLoadingLayer(),
                            errorBuilder: (_, error) => _ScannerFailedLayer(
                              permissionDenied: error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied,
                              onOpenSettings: _einstellungenOeffnen,
                              onTypeBarcode: _manuellEingeben,
                            ),
                          ),
                          // Overlays only while the camera is not in an error
                          // state, or frame and hint would sit on top of the
                          // error message.
                          ValueListenableBuilder<MobileScannerState>(
                            valueListenable: controller,
                            builder: (context, state, child) =>
                                state.error == null
                                    ? child!
                                    : const SizedBox.shrink(),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const _EdgeScrim(),
                                const Center(child: _ScanFrame()),
                                // Slot chips on the camera preview, same row
                                // as the AI scan. Missing until 2026-08-22,
                                // when the barcode path silently used the
                                // time-of-day slot.
                                Positioned(
                                  top: 10,
                                  left: 10,
                                  right: 10,
                                  child: ScanSlotChips(
                                    selected: _slot,
                                    onSelected: _selectSlot,
                                    keyPrefix: 'barcode-slot',
                                  ),
                                ),
                                // Hint sits below the chips; the scan frame in
                                // the centre stays clear.
                                Positioned(
                                  top: 50,
                                  left: 10,
                                  right: 10,
                                  child: Center(
                                    child: Container(
                                      key: const ValueKey(
                                        'barcode-scanner-hint',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.42,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          rPill,
                                        ),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.35,
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        context.l10n.foodBarcodeHintText,
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.1,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                // Torch toggle, bottom centre — often decisive
                                // when scanning in the dark.
                                Positioned(
                                  bottom: 14,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: _TorchButton(controller: controller),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_analyzerHaengt)
                            _AnalyzerStalledLayer(onRetry: _neuStarten),
                          if (_manuelleEingabe)
                            _ManualBarcodeLayer(
                              onSubmit: _codeAbgeben,
                              onBack: _manuelleEingabeSchliessen,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: mediaQuery.viewPadding.bottom + 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Target frame in barcode proportions; lime is the food-tab accent (cyan was
/// a macro data colour and off-palette).
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 132,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rCard),
        // The frame sits ON the camera image: `lime` carries in both modes,
        // `accent` would be dark green on a dark image in light mode.
        border: Border.all(
          color: context.t.lime.withValues(alpha: 0.9),
          width: 2,
        ),
      ),
    );
  }
}

class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        if (state.torchState == TorchState.unavailable) {
          return const SizedBox.shrink();
        }
        final on = state.torchState == TorchState.on;
        return Material(
          key: const ValueKey('barcode-torch'),
          color: on
              ? context.t.lime.withValues(alpha: 0.92)
              : Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: controller.toggleTorch,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                on ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: on ? Colors.black : Colors.white,
                size: 21,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScannerLoadingLayer extends StatelessWidget {
  const _ScannerLoadingLayer();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ColoredBox(
      color: t.bg,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
        ),
      ),
    );
  }
}

/// Camera dead or permission denied (F4-04). Both offer typing the code;
/// only the permission case sends to Settings, where the fix actually is.
class _ScannerFailedLayer extends StatelessWidget {
  const _ScannerFailedLayer({
    required this.permissionDenied,
    required this.onOpenSettings,
    required this.onTypeBarcode,
  });

  final bool permissionDenied;
  final VoidCallback onOpenSettings;
  final VoidCallback onTypeBarcode;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return ColoredBox(
      key: const ValueKey('barcode-scanner-failed'),
      color: t.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: t.ink2, size: 32),
              const SizedBox(height: 12),
              Text(
                permissionDenied
                    ? l10n.foodBarcodePermissionDeniedMessage
                    : l10n.foodCameraUnavailableMessage,
                textAlign: TextAlign.center,
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w500,
                  color: t.ink,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              // Theme-styled on purpose (F8-10): no colour copies here.
              if (permissionDenied)
                OutlinedButton.icon(
                  key: const ValueKey('barcode-open-settings'),
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: Text(l10n.foodOpenSettingsButton),
                ),
              TextButton.icon(
                key: const ValueKey('barcode-type-in'),
                onPressed: onTypeBarcode,
                icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                label: Text(l10n.foodBarcodeTypeInButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Typed barcode as a fallback for a dead camera. Borderless soft capsule
/// (no hairline, no focus ring); the error text under it is the only red.
class _ManualBarcodeLayer extends StatefulWidget {
  const _ManualBarcodeLayer({required this.onSubmit, required this.onBack});

  final ValueChanged<String> onSubmit;
  final VoidCallback onBack;

  @override
  State<_ManualBarcodeLayer> createState() => _ManualBarcodeLayerState();
}

class _ManualBarcodeLayerState extends State<_ManualBarcodeLayer> {
  final TextEditingController _controller = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final digits = _controller.text.trim();
    if (!isValidTypedBarcode(digits)) {
      setState(() => _invalid = true);
      return;
    }
    widget.onSubmit(digits);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return ColoredBox(
      key: const ValueKey('barcode-manual-layer'),
      color: t.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.foodBarcodeManualLabel.toUpperCase(),
              style: AppType.eyebrow(t.ink2, size: 9.5),
            ),
            const SizedBox(height: 7),
            // Capsule, fill states (rest/focus/error) and the error line come
            // from inputDecorationTheme — no decoration copy here.
            TextField(
              key: const ValueKey('barcode-manual-field'),
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(13),
              ],
              onChanged: (_) {
                if (_invalid) setState(() => _invalid = false);
              },
              onSubmitted: (_) => _submit(),
              style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
              decoration: InputDecoration(
                hintText: l10n.foodBarcodeManualHint,
                errorText: _invalid ? l10n.foodBarcodeManualInvalid : null,
              ),
            ),
            const SizedBox(height: 14),
            PrimaryActionButton(
              key: const ValueKey('barcode-manual-submit'),
              label: l10n.foodBarcodeManualSubmit,
              icon: Icons.search_rounded,
              onTap: _submit,
              height: 48,
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                key: const ValueKey('barcode-manual-back'),
                onPressed: widget.onBack,
                child: Text(l10n.commonCancel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft dark gradients top and bottom so hint pill and torch stay readable on
/// bright camera images (same as MealCameraSheet).
///
/// The literal `Colors.black`/`Colors.white` here are NOT forgotten tokens:
/// they sit on a live camera image, not a theme surface. A token-coloured
/// scrim would become a light veil on a light image and destroy readability.
class _EdgeScrim extends StatelessWidget {
  const _EdgeScrim();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.4),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.5),
            ],
            stops: const [0.0, 0.2, 0.68, 1.0],
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.foodScanBarcodeTooltip,
              style: AppType.display(17, color: t.ink),
            ),
          ),
          IconButton(
            key: const ValueKey('barcode-close-button'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// The analyzer stopped delivering frames — shown, not swallowed.
///
/// Not `_ScannerFailedLayer`: that describes dead camera access with no way
/// out. Here the camera is fine, only detection stalled, and a restart helps.
/// Sits over the live image, so the literal black/white is no token (see
/// [_EdgeScrim]).
class _AnalyzerStalledLayer extends StatelessWidget {
  const _AnalyzerStalledLayer({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('barcode-analyzer-stalled'),
      color: Colors.black.withValues(alpha: 0.72),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.refresh_rounded, size: 30, color: Colors.white),
          const SizedBox(height: 10),
          Text(
            l10n.foodDetectionStalledTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.foodDetectionStalledBody,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12, height: 1.35, color: Colors.white70),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('barcode-analyzer-restart'),
            onPressed: onRetry,
            child: Text(l10n.foodRestartScannerButton),
          ),
        ],
      ),
    );
  }
}
