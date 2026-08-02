import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/logged_meal.dart';
import '../models/meal_analysis_request.dart';
import '../services/meal_camera_launcher.dart';
import '../theme/app_colors.dart';
import '../theme/meal_slot_style.dart';

/// In-App-Kamera als animiertes Bottom-Panel (~60% Hoehe) statt Vollbild-
/// Wechsel: Live-Vorschau (verzerrungsfrei cover-gecroppt), Slot-Chips oben,
/// Ausloeser + Galerie unten. Gibt beim Pop ein [MealCameraCapture]
/// (Bild + gewaehlter Slot) zurueck, oder null bei Abbruch.
///
/// Nutzt das `camera`-Package. Ueber [MealCameraLauncher] fuer Widget-Tests
/// austauschbar — die echte Kamera laeuft nur auf dem Geraet.
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
      // veryHigh (1080p): scharfes Analyse-Foto, aber klein genug fuer das
      // 5-MB-Bildlimit der Edge Function. high (720p) wirkte unscharf.
      final controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
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
        imageQuality: 85,
        maxWidth: 1600,
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
    final mediaQuery = MediaQuery.of(context);
    // ~60% der Bildschirmhoehe — genug fuer eine grosse Vorschau, aber klar ein
    // Panel „in der App", kein Vollbild-Wechsel.
    final panelHeight = mediaQuery.size.height * 0.6;
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: SizedBox(
        height: panelHeight,
        child: Container(
          decoration: const BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
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
                        // Slot-Chips oben auf der Vorschau.
                        Positioned(
                          top: 10,
                          left: 10,
                          right: 10,
                          child: _SlotChips(
                            selected: _slot,
                            onSelected: _selectSlot,
                          ),
                        ),
                        // Ausloeser + Galerie unten auf der Vorschau.
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

/// Verzerrungsfreie Cover-Darstellung der Kamera-Vorschau in einer beliebigen
/// Box: [CameraPreview] traegt seine Aspect-Ratio selbst — deshalb bekommt es
/// hier eine [SizedBox] mit exakt dieser Ratio, die so gross skaliert wird,
/// dass sie die Box fuellt (Ueberstand wird vom ClipRRect gecroppt).
class _CoveredCameraPreview extends StatelessWidget {
  const _CoveredCameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxAspect = constraints.maxWidth / constraints.maxHeight;
        // Portrait-Seitenverhaeltnis (Breite/Hoehe) der Vorschau. aspectRatio
        // ist im Querformat definiert -> fuer Hochkant invertieren.
        final previewAspect = 1 / controller.value.aspectRatio;
        double w;
        double h;
        if (previewAspect < boxAspect) {
          // Vorschau schmaler als die Box -> Breite anlegen, Hoehe ueberstehen.
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
    return const ColoredBox(
      color: bg,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: forgeLime),
        ),
      ),
    );
  }
}

class _CameraFailedLayer extends StatelessWidget {
  const _CameraFailedLayer();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: bg,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: textMuted, size: 32),
              SizedBox(height: 12),
              Text(
                'Kamera nicht verfügbar. Prüfe die Berechtigung oder wähle ein '
                'Foto aus der Galerie.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sanfte dunkle Verlaeufe oben/unten, damit Chips + Bedienleiste auf hellen
/// Kamerabildern lesbar bleiben.
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
          color: hairline,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 6, 2),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Mahlzeit scannen',
              style: TextStyle(
                color: textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('meal-camera-close'),
            onPressed: onClose,
            tooltip: 'Schließen',
            icon: const Icon(Icons.close_rounded, color: textMuted),
          ),
        ],
      ),
    );
  }
}

/// Slot-Auswahl als Chip-Reihe. Aktiver Chip traegt die Slot-Akzentfarbe; die
/// Wahl bestimmt, in welchen Slot die analysierte Mahlzeit wandert.
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final slot in _slots) ...[
          Flexible(
            child: _SlotChip(
              slot: slot,
              selected: slot == selected,
              onTap: () => onSelected(slot),
            ),
          ),
          if (slot != _slots.last) const SizedBox(width: 6),
        ],
      ],
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.92)
              : Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(rPill),
          border: Border.all(
            color: selected ? accent : Colors.white.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              slot.icon,
              size: 13,
              color: selected ? Colors.black : Colors.white,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                slot.shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Untere Bedienleiste: Galerie (links), grosser Ausloeser (Mitte),
/// symmetrischer Platzhalter (rechts).
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
              color: enabled ? forgeLime : Colors.white.withValues(alpha: 0.4),
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
