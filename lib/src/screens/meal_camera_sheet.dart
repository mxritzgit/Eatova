import 'dart:developer' as dev;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/logged_meal.dart';
import '../models/meal_analysis_request.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_compressor.dart';
import '../theme/app_tokens.dart';
import '../theme/meal_slot_style.dart';
import '../widgets/common/motion.dart';

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

  /// Serialisiert Auf- und Abbau der Kamera. Lifecycle-Events feuern schneller
  /// als `initialize()` laeuft (Galerie-Picker auf/zu, iOS-Benachrichtigungs-
  /// banner): ohne diese Kette entstuenden zwei Controller nebeneinander, oder
  /// ein Pause-Event wuerde von einer noch laufenden Initialisierung ueberholt
  /// und liesse die Kamera im Hintergrund offen.
  Future<void> _cameraQueue = Future<void>.value();

  void _enqueueCameraOp(Future<void> Function() op) {
    _cameraQueue = _cameraQueue
        .then((_) => op())
        // Ein gescheiterter Auf-/Abbau darf die Kette nicht abreissen lassen,
        // sonst kaeme die Kamera nach dem naechsten Resume nie wieder.
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
    // Erst abhaengen, dann freigeben: eine noch laufende Queue-Operation soll
    // den entsorgten Controller nicht mehr finden.
    _controller = null;
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Bewusst OHNE den frueheren `_controller == null`-Guard (Review D3): der
    // Pause-Zweig nullte genau das Feld, auf das der Guard prueft — damit war
    // der resumed-Zweig ab der ersten Unterbrechung unerreichbar und die
    // Vorschau blieb bis zum Neu-Oeffnen des Sheets ein Dauer-Spinner.
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

  /// Gibt die Kamera frei. Das Feld wird VOR dem `dispose()` und innerhalb von
  /// `setState` genullt: sonst rendert `build` weiter die Texture eines
  /// entsorgten Controllers, der Ausloeser sieht aktiv aus, und ein Tap darauf
  /// laeuft still in den Null-Check von [_capture].
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
      // Ein bereits gestorbener Controller ist kein Fehlerfall fuer die UI.
    }
  }

  Future<void> _initCamera() async {
    if (!mounted) return;
    // Es laeuft bereits eine Kamera: ein zweites `initialize()` erzeugte einen
    // zweiten Controller und liesse den ersten unentsorgt liegen.
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
      // veryHigh (1080p): scharfes Analyse-Foto, aber klein genug fuer das
      // 5-MB-Bildlimit der Edge Function. high (720p) wirkte unscharf.
      controller = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      // Sheet zwischenzeitlich geschlossen: der frisch gebaute Controller darf
      // nicht als Leiche zurueckbleiben.
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // iOS rotiert sonst Vorschau- und Foto-Buffer bei jeder physischen
      // Drehung mit: camera_avfoundation hoert auf UIDevice-Orientation-
      // Notifications, die trotz Portrait-Lock der UI feuern, und setzt
      // connection.videoOrientation um — das Bild dreht sich dann sichtbar
      // im starren Portrait-Layout. Der Lock pinnt beide Outputs auf
      // portraitUp; die Vorschau verhaelt sich damit wie der Barcode-Scanner
      // (Fenster-Verhalten) und das Foto ist deckungsgleich mit der Vorschau.
      // Android feuert unter dem Portrait-Lock keine Orientation-Events —
      // dort aendert der Lock nichts.
      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } on CameraException {
        // Ohne Lock laeuft die Kamera weiter — schlimmstenfalls mit dem
        // alten Dreh-Verhalten. Kein Grund, sie als ausgefallen zu melden.
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
      // Berechtigung waehrenddessen entzogen, keine Kamera, Plugin-Fehler:
      // sauber in der Fehlerflaeche landen statt im Dauer-Spinner haengen.
      final partial = controller;
      if (partial != null && !identical(_controller, partial)) {
        try {
          await partial.dispose();
        } catch (_) {
          // Ein nie fertig aufgebauter Controller hat nichts freizugeben.
        }
      }
      if (mounted) setState(() => _cameraFailed = true);
    }
  }

  /// Einziger Ausgang fuer Bild-Bytes aus diesem Sheet: Kamera **und** Galerie
  /// laufen hier durch. [compressMealPhoto] verkleinert (Base64 macht +33%,
  /// der Server kappt bei 5 MB) und leert den EXIF-Container (Review C4).
  ///
  /// `compute()`: Dekodieren + Re-Encoden blockiert sonst den UI-Isolate.
  /// Scheitert der Isolate-Start, wird im UI-Isolate komprimiert — lieber ein
  /// kurzer Ruckler als ein Upload mit Koordinaten.
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
    try {
      HapticFeedback.mediumImpact();
      final file = await controller.takePicture();
      final raw = await file.readAsBytes();
      // Rohes Kamera-JPEG vor dem Versand auf Galerie-Niveau bringen
      // (laengste Kante 1600 px, q85) und die Metadaten strippen.
      final bytes = await _compress(raw);
      if (!mounted) return;
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
      final raw = await image.readAsBytes();
      // Review C4: `image_picker` skaliert zwar, kopiert danach aber ueber
      // ImageResizer.copyExif() die Metadaten inklusive GPS-Sub-IFD zurueck.
      // Ein aus der Galerie gewaehltes Systemkamera-Foto traegt damit die
      // Koordinaten des Restaurants. compressMealPhoto leert den Container —
      // derselbe Weg wie beim Kamera-Pfad, deshalb hier ebenfalls zwingend.
      final bytes = await _compress(raw);
      if (!mounted) return;
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
    final t = context.t;
    // GENAU EIN CircularProgressIndicator: die Zaehlung pro Zustand ist in
    // meal_camera_sheet_test festgenagelt.
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
    // KEIN Spinner in dieser Schicht — der Fehlerzustand zeigt eine Erklaerung,
    // kein Warten (meal_camera_sheet_test zaehlt beides).
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
                'Kamera nicht verfügbar. Prüfe die Berechtigung oder wähle ein '
                'Foto aus der Galerie.',
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

/// Sanfte dunkle Verlaeufe oben/unten, damit Chips + Bedienleiste auf hellen
/// Kamerabildern lesbar bleiben.
///
/// Die harten `Colors.black`/`Colors.white` dieser und der folgenden
/// Overlay-Klassen bleiben bewusst stehen und sind KEIN vergessener Token: sie
/// liegen auf einem LIVE-Kamerabild, nicht auf einer Theme-Flaeche. Ein
/// token-gefaerbter Scrim wuerde im Hell-Modus zu einem hellen Schleier auf
/// einem beliebig hellen Bild — genau die Lesbarkeit, die er herstellen soll,
/// waere dahin.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 6, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Mahlzeit scannen',
              style: AppType.display(17, color: t.ink),
            ),
          ),
          IconButton(
            key: const ValueKey('meal-camera-close'),
            onPressed: onClose,
            tooltip: 'Schließen',
            icon: Icon(Icons.close_rounded, color: t.ink2),
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
    // Der Chip liegt AUF dem Live-Kamerabild, zusammen mit den harten
    // schwarz/weissen Scrims und Beschriftungen dieser Datei — deshalb die
    // DUNKEL-Palette in beiden Anzeige-Modi, nicht `accentIn(context)`.
    // Dasselbe Argument wie beim Scanrahmen und beim Ausloeser: die hellen
    // Slot-Toene tragen auf einem beliebig hellen Bild, die dunklen des
    // Hell-Modus (Mittag = tiefes Blau) haetten das schwarze Chip-Label auf
    // 3,6:1 gedrueckt. Kein Brightness-Abzweig, sondern eine feste Palette
    // fuer eine Flaeche, die immer dunkel ist.
    final accent = slot.accentOn(AppTokens.dark);
    return InkWell(
      key: ValueKey('meal-camera-slot-${slot.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(rPill),
      child: AnimatedContainer(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
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
