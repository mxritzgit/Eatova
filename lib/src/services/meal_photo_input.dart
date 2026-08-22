import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image_picker/image_picker.dart';

import '../models/meal_analysis_request.dart';
import 'meal_photo_compressor.dart';
import 'meal_photo_temp_file.dart';

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
    // imageQuality/maxWidth are NOT optional: without them iOS passes through
    // the original HEIC, which package:image cannot decode (C4).
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
    } finally {
      // Privacy: the bytes are in memory, the picker's cache copy is never
      // read again — also on the scrub error path. Without the delete, meal
      // photos in the app cache outlived account deletion. The gallery
      // original is untouched, see [deleteMealPhotoTempFile].
      await deleteMealPhotoTempFile(image.path);
    }

    return MealPhotoSelection(
      request: MealAnalysisRequest(
        // Just a label for the request: nobody reads the path, and the file
        // behind it is already deleted above.
        imageId: image.path,
        imageBytes: previewBytes,
      ),
      previewBytes: previewBytes,
    );
  }

  /// Clears EXIF before the bytes leave the device (C4). These bytes feed
  /// `MealAnalysisRequest.imageBytes` and reach the third-party model, so
  /// without the scrub GPS, capture time and device id travel along.
  ///
  /// `compute()` keeps decode + re-encode off the UI isolate; if the isolate
  /// fails to start it compresses synchronously — a stutter beats an upload
  /// with coordinates.
  Future<Uint8List> _scrub(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }
}
