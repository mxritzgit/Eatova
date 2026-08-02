import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/logged_meal.dart';
import '../models/meal_analysis_request.dart';
import '../services/meal_camera_launcher.dart';
import '../theme/app_colors.dart';
import '../theme/meal_slot_style.dart';

/// In-App-Kamera fuer den KI-Scan: Live-Vorschau, Slot-Auswahl (Fruehstueck/
/// Mittag/…) als Chips oben, Ausloeser + Galerie + Abbrechen unten. Gibt beim
/// Pop ein [MealCameraCapture] (Bild + gewaehlter Slot) zurueck, oder null bei
/// Abbruch.
///
/// Nutzt das `camera`-Package (echte In-App-Vorschau, konsistent mit dem
/// Barcode-Scanner). Laesst sich per [MealCameraLauncher] fuer Widget-Tests
/// austauschen — die echte Kamera laeuft nur auf dem Geraet.
class MealCameraScreen extends StatefulWidget {
  const MealCameraScreen({super.key, required this.initialSlot});

  final MealSlot initialSlot;

  @override
  State<MealCameraScreen> createState() => _MealCameraScreenState();
}

class _MealCameraScreenState extends State<MealCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  late MealSlot _slot;
  bool _busy = false;
  bool _cameraFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slot = widget.initialSlot;
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // Kamera beim Backgrounding freigeben und beim Zurueckkehren neu
    // initialisieren — sonst haelt die App die Kamera oder crasht auf iOS.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _cameraFailed = true);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraFailed = false;
      });
    } catch (_) {
      // Kein Kamerazugriff (Berechtigung/Hardware) — Galerie bleibt als Weg.
      if (mounted) setState(() => _cameraFailed = true);
    }
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
    try {
      HapticFeedback.mediumImpact();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _returnCapture(path: file.path, bytes: bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Foto konnte nicht aufgenommen werden. Versuch es nochmal.');
    }
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1400,
      );
      if (image == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final bytes = await image.readAsBytes();
      _returnCapture(path: image.path, bytes: bytes);
    } on PlatformException catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Galerie konnte nicht geöffnet werden. Prüfe die Berechtigung.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Das Bild konnte nicht geladen werden.');
    }
  }

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
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return Scaffold(
      key: const ValueKey('meal-camera-screen'),
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            _CameraPreviewLayer(controller: controller)
          else if (_cameraFailed)
            const _CameraFailedLayer()
          else
            const _CameraLoadingLayer(),
          // Dunkle Vignette oben/unten, damit Chips + Bedienleiste auf hellen
          // Kamerabildern lesbar bleiben.
          const _ScrimGradient(),
          SafeArea(
            child: Column(
              children: [
                _TopBar(onClose: () => Navigator.of(context).pop()),
                const SizedBox(height: 4),
                _SlotChips(selected: _slot, onSelected: _selectSlot),
                const Spacer(),
                _CaptureBar(
                  canCapture: ready && !_busy,
                  busy: _busy,
                  onCapture: _capture,
                  onGallery: _pickFromGallery,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraPreviewLayer extends StatelessWidget {
  const _CameraPreviewLayer({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    // Vorschau formatfuellend zuschneiden (BoxFit.cover), damit kein
    // schwarzer Rand bleibt und das Bild den Bildschirm ausfuellt.
    final size = MediaQuery.of(context).size;
    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.width / controller.value.aspectRatio,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}

class _CameraLoadingLayer extends StatelessWidget {
  const _CameraLoadingLayer();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2, color: forgeLime),
      ),
    );
  }
}

class _CameraFailedLayer extends StatelessWidget {
  const _CameraFailedLayer();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined, color: textMuted, size: 34),
            SizedBox(height: 12),
            Text(
              'Kamera nicht verfügbar. Prüfe die Berechtigung in den '
              'Einstellungen oder wähle ein Foto aus der Galerie.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textPrimary,
                fontSize: 14,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrimGradient extends StatelessWidget {
  const _ScrimGradient();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.45),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.55),
            ],
            stops: const [0.0, 0.22, 0.7, 1.0],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('meal-camera-close'),
            onPressed: onClose,
            tooltip: 'Abbrechen',
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
          const Expanded(
            child: Text(
              'Mahlzeit scannen',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          // Symmetrischer Platzhalter, damit der Titel mittig bleibt.
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// Slot-Auswahl als Chip-Reihe oben. Der aktive Chip traegt die Slot-Akzent-
/// farbe; die Wahl bestimmt, in welchen Slot die analysierte Mahlzeit wandert.
class _SlotChips extends StatelessWidget {
  const _SlotChips({required this.selected, required this.onSelected});

  final MealSlot selected;
  final ValueChanged<MealSlot> onSelected;

  static const List<MealSlot> _slots = <MealSlot>[
    MealSlot.breakfast,
    MealSlot.lunch,
    MealSlot.dinner,
    MealSlot.snack,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final slot in _slots) ...[
            _SlotChip(
              slot: slot,
              selected: slot == selected,
              onTap: () => onSelected(slot),
            ),
            if (slot != _slots.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SlotChip extends StatelessWidget {
  const _SlotChip({
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  final MealSlot slot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = slot.accent;
    return InkWell(
      key: ValueKey('meal-camera-slot-${slot.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(rPill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.9)
              : Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(rPill),
          border: Border.all(
            color: selected ? accent : Colors.white.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              slot.icon,
              size: 15,
              color: selected ? Colors.black : Colors.white,
            ),
            const SizedBox(width: 5),
            Text(
              slot.shortLabel,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Untere Bedienleiste: Galerie (links), grosser Ausloeser (Mitte), Platzhalter
/// (rechts) fuer eine symmetrische Anordnung.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _RoundButton(
            keyValue: const ValueKey('meal-camera-gallery'),
            icon: Icons.photo_library_outlined,
            onTap: busy ? null : onGallery,
          ),
          _Shutter(enabled: canCapture, busy: busy, onTap: onCapture),
          // Platzhalter in Groesse des Galerie-Buttons: haelt den Ausloeser
          // exakt mittig.
          const SizedBox(width: 52, height: 52),
        ],
      ),
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
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, color: Colors.white, size: 22),
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
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: enabled ? 0.9 : 0.4),
            width: 4,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? forgeLime : Colors.white.withValues(alpha: 0.4),
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(18),
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
