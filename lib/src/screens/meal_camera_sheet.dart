import 'dart:developer' as dev;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/l10n.dart';
import '../models/logged_meal.dart';
import '../models/meal_analysis_request.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_compressor.dart';
import '../services/meal_photo_temp_file.dart';
import '../theme/app_tokens.dart';
import '../widgets/kcal/scan_slot_chips.dart';

/// In-app camera as an animated bottom panel. Pops a [MealCameraCapture], or
/// null on cancel. Swappable via [MealCameraLauncher] for widget tests.
class MealCameraSheet extends StatefulWidget {
  const MealCameraSheet({super.key, required this.initialSlot});

  final MealSlot initialSlot;

  @override
  State<MealCameraSheet> createState() => _MealCameraSheetState();
}

class _MealCameraSheetState extends State<MealCameraSheet>
    with WidgetsBindingObserver {
  CameraController? _controller;
  late MealSlot _slot;
  bool _busy = false;
  bool _cameraFailed = false;

  /// Serialises camera setup/teardown: lifecycle events outrun `initialize()`,
  /// so two controllers could coexist or a pause be lost.
  Future<void> _cameraQueue = Future<void>.value();

  void _enqueueCameraOp(Future<void> Function() op) {
    _cameraQueue = _cameraQueue
        .then((_) => op())
        // A failed setup/teardown must not break the chain for the next resume.
        .catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slot = widget.initialSlot;
    _enqueueCameraOp(_initCamera);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    // Detach before releasing so a pending queue op cannot find it.
    _controller = null;
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No `_controller == null` guard (Review D3): the pause branch nulls that
    // very field, making the resumed branch unreachable.
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _enqueueCameraOp(_teardownCamera);
      case AppLifecycleState.resumed:
        _enqueueCameraOp(_initCamera);
    }
  }

  /// Releases the camera. The field is nulled in `setState` BEFORE `dispose()`,
  /// or `build` keeps rendering a dead controller's texture.
  Future<void> _teardownCamera() async {
    final controller = _controller;
    if (controller == null) return;
    if (mounted) {
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    try {
      await controller.dispose();
    } catch (_) {
      // An already dead controller is not a UI error.
    }
  }

  Future<void> _initCamera() async {
    if (!mounted) return;
    // A second `initialize()` would leak the already running controller.
    if (_controller != null) return;

    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted) return;
      if (cameras.isEmpty) {
        setState(() => _cameraFailed = true);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // veryHigh (1080p): sharp enough to analyse, under the 5 MB limit.
      controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      // Sheet closed meanwhile: don't leave the fresh controller behind.
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // iOS otherwise rotates preview and photo buffers on physical turns,
      // despite the portrait lock. No-op on Android.
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } on CameraException {
        // Without the lock the camera still runs; not a failure.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraFailed = false;
      });
    } catch (_) {
      // Permission revoked, no camera, plugin error: show the error layer.
      final partial = controller;
      if (partial != null && !identical(_controller, partial)) {
        try {
          await partial.dispose();
        } catch (_) {
          // A controller that never finished setup has nothing to release.
        }
      }
      if (mounted) setState(() => _cameraFailed = true);
    }
  }

  /// Only exit for image bytes from this sheet — camera **and** gallery.
  /// [compressMealPhoto] shrinks (base64 adds 33 %, server caps at 5 MB) and
  /// wipes EXIF (Review C4).
  Future<Uint8List> _compress(Uint8List raw) async {
    Uint8List bytes;
    try {
      bytes = await compute(compressMealPhoto, raw);
    } catch (_) {
      bytes = compressMealPhoto(raw);
    }
    dev.log(
      'meal photo compressed: ${raw.lengthInBytes} -> ${bytes.lengthInBytes} bytes',
      name: 'meal_camera',
    );
    return bytes;
  }

  void _selectSlot(MealSlot slot) {
    if (slot == _slot) return;
    HapticFeedback.selectionClick();
    setState(() => _slot = slot);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_busy || controller == null || !controller.value.isInitialized) return;
    setState(() => _busy = true);
    // Outside the try so the finally always clears the cached shot.
    XFile? shot;
    try {
      HapticFeedback.mediumImpact();
      shot = await controller.takePicture();
      final raw = await shot.readAsBytes();
      // Shrink the raw camera JPEG (1600 px long edge, q85), strip metadata.
      final bytes = await _compress(raw);
      if (!mounted) return;
      _returnCapture(path: shot.path, bytes: bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError(context.l10n.foodPhotoCaptureFailedMessage);
    } finally {
      // Without [deleteMealPhotoTempFile] meal photos outlive account deletion.
      final temp = shot;
      if (temp != null) await deleteMealPhotoTempFile(temp.path);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    // As in [_capture]: the picker copy's path must reach the finally block.
    XFile? picked;
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1600,
      );
      if (image == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      picked = image;
      final raw = await image.readAsBytes();
      // Review C4: `image_picker` copies EXIF back via copyExif(), GPS
      // included — so the scrub is mandatory here too.
      final bytes = await _compress(raw);
      if (!mounted) return;
      _returnCapture(path: image.path, bytes: bytes);
    } on PlatformException catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError(context.l10n.foodGalleryPermissionError);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError(context.l10n.foodImageLoadFailedMessage);
    } finally {
      // Only image_picker's cache copy is deleted; the original stays.
      final temp = picked;
      if (temp != null) await deleteMealPhotoTempFile(temp.path);
    }
  }

  /// `imageId` is a mere label: the upload rides on [bytes], and the file
  /// behind the path is already gone.
  void _returnCapture({required String path, required Uint8List bytes}) {
    if (!mounted) return;
    Navigator.of(context).pop(
      MealCameraCapture(
        request: MealAnalysisRequest(imageId: path, imageBytes: bytes),
        previewBytes: bytes,
        slot: _slot,
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // ~60% of screen height: a large preview that still reads as a panel.
    final panelHeight = mediaQuery.size.height * 0.6;
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Padding(
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
              _HeaderRow(onClose: () => Navigator.of(context).pop()),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(rCard),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (ready)
                          _CoveredCameraPreview(controller: controller)
                        else if (_cameraFailed)
                          const _CameraFailedLayer()
                        else
                          const _CameraLoadingLayer(),
                        const _EdgeScrim(),
                        Positioned(
                          top: 10,
                          left: 10,
                          right: 10,
                          child: ScanSlotChips(
                            selected: _slot,
                            onSelected: _selectSlot,
                            keyPrefix: 'meal-camera-slot',
                          ),
                        ),
                        Positioned(
                          bottom: 14,
                          left: 20,
                          right: 20,
                          child: _CaptureBar(
                            canCapture: ready && !_busy,
                            busy: _busy,
                            onCapture: _capture,
                            onGallery: _pickFromGallery,
                          ),
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
    );
  }
}

/// Cover fit without distortion: [CameraPreview] carries its own aspect ratio,
/// so it gets a [SizedBox] with that ratio, scaled to fill.
class _CoveredCameraPreview extends StatelessWidget {
  const _CoveredCameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxAspect = constraints.maxWidth / constraints.maxHeight;
        // `aspectRatio` is landscape-defined -> invert for portrait.
        final previewAspect = 1 / controller.value.aspectRatio;
        double w;
        double h;
        if (previewAspect < boxAspect) {
          // Preview narrower than the box -> match width, overflow height.
          w = constraints.maxWidth;
          h = w / previewAspect;
        } else {
          h = constraints.maxHeight;
          w = h * previewAspect;
        }
        return OverflowBox(
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          alignment: Alignment.center,
          child: SizedBox(
            width: w,
            height: h,
            child: CameraPreview(controller),
          ),
        );
      },
    );
  }
}

class _CameraLoadingLayer extends StatelessWidget {
  const _CameraLoadingLayer();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // EXACTLY ONE spinner: meal_camera_sheet_test pins the count per state.
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

class _CameraFailedLayer extends StatelessWidget {
  const _CameraFailedLayer();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // NO spinner here: the error state explains, it does not wait.
    return ColoredBox(
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
                context.l10n.foodCameraUnavailableGalleryMessage,
                textAlign: TextAlign.center,
                style: AppType.ui(
                  13.5,
                  weight: FontWeight.w500,
                  color: t.ink,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft dark gradients so chips and controls stay readable on bright camera
/// images. The hard `Colors.black`/`Colors.white` here and below are
/// intentional: on a live image a token scrim would haze out in light mode.
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
              l10n.foodScanMealTitle,
              style: AppType.display(17, color: t.ink),
            ),
          ),
          IconButton(
            key: const ValueKey('meal-camera-close'),
            onPressed: onClose,
            tooltip: l10n.commonClose,
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

/// Bottom bar: gallery, shutter, symmetric spacer.
class _CaptureBar extends StatelessWidget {
  const _CaptureBar({
    required this.canCapture,
    required this.busy,
    required this.onCapture,
    required this.onGallery,
  });

  final bool canCapture;
  final bool busy;
  final VoidCallback onCapture;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _RoundButton(
          keyValue: const ValueKey('meal-camera-gallery'),
          icon: Icons.photo_library_outlined,
          onTap: busy ? null : onGallery,
        ),
        _Shutter(enabled: canCapture, busy: busy, onTap: onCapture),
        const SizedBox(width: 48, height: 48),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.keyValue,
    required this.icon,
    required this.onTap,
  });

  final Key keyValue;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: keyValue,
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white, size: 21),
        ),
      ),
    );
  }
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.enabled, required this.busy, required this.onTap});

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('meal-camera-shutter'),
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: enabled ? 0.95 : 0.4),
            width: 4,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled
                ? context.t.lime
                : Colors.white.withValues(alpha: 0.4),
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
