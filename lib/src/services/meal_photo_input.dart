import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image_picker/image_picker.dart';

import '../models/meal_analysis_request.dart';
import 'meal_photo_compressor.dart';

class MealPhotoSelection {
  const MealPhotoSelection({
    required this.request,
    required this.previewBytes,
  });

  final MealAnalysisRequest request;
  final Uint8List? previewBytes;
}

abstract class MealPhotoInput {
  Future<MealPhotoSelection?> pick(ImageSource source);
}

class DeviceMealPhotoInput implements MealPhotoInput {
  DeviceMealPhotoInput({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<MealPhotoSelection?> pick(ImageSource source) async {
    // imageQuality/maxWidth sind NICHT optional: ohne sie reicht iOS die
    // HEIC-Originaldatei durch, die package:image nicht dekodieren kann —
    // compressMealPhoto gaebe sie dann ungescrubbt zurueck (Review C4).
    final image = await _picker.pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1400,
    );
    if (image == null) {
      return null;
    }

    Uint8List? previewBytes;
    try {
      previewBytes = await _scrub(await image.readAsBytes());
    } catch (_) {
      previewBytes = null;
    }

    return MealPhotoSelection(
      request: MealAnalysisRequest(
        imageId: image.path,
        imageBytes: previewBytes,
      ),
      previewBytes: previewBytes,
    );
  }

  /// EXIF leeren, bevor die Bytes das Geraet verlassen — Review C4.
  ///
  /// Dieser Pfad ist der dritte von vieren (Kamera-Sheet und Coach-Chat
  /// scrubben bereits). Er speist `MealAnalysisRequest.imageBytes`, geht also
  /// direkt an die Edge Function und von dort an das Drittanbieter-Modell in
  /// den USA. Ohne den Scrub reisen Breitengrad, Laengengrad, Hoehe,
  /// Aufnahmezeit, Geraetemodell und Seriennummer mit.
  ///
  /// `compute()` wie im Kamera-Sheet: Dekodieren + Re-Encoden blockiert sonst
  /// den UI-Isolate. Scheitert der Isolate-Start, wird synchron komprimiert —
  /// lieber ein kurzer Ruckler als ein Upload mit Koordinaten.
  Future<Uint8List> _scrub(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }
}
