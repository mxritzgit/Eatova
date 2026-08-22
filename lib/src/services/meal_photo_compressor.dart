import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Recompresses AI-scan photos: longest edge <= [maxDimension] px, JPEG
/// q[quality]. The in-app camera delivers raw JPEGs without the downscale the
/// gallery path already gets from `image_picker`, and analyze-meal caps at
/// 5 MB (base64 = +33 %).
///
/// EXIF scrubbing (C4): neither `image_picker` nor package:image strips
/// metadata — both copy the container back, GPS sub-IFD included, so a gallery
/// photo would carry the restaurant's coordinates to the third-party model.
/// The container is therefore emptied completely (ICC profile stays: colours,
/// not a person). Order is mandatory bake -> resize -> clear, because
/// [img.bakeOrientation] reads the orientation from `image.exif`.
///
/// Purely functional (no plugins, no IO) — runs via `compute()` in an isolate.
///
/// FAIL-CLOSED (S2): undecodable bytes THROW a [FormatException] instead of
/// going out unscrubbed. Rare in practice: the camera path yields JPEG and the
/// gallery path converts via `imageQuality`/`maxWidth` — which is why those
/// options must not be dropped, or iOS passes through HEIC that package:image
/// cannot decode. All callers handle the throw.
Uint8List compressMealPhoto(
  Uint8List original, {
  int maxDimension = 1600,
  int quality = 85,
}) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(original);
  } catch (e) {
    throw FormatException('Bild nicht dekodierbar — kein ungescrubbter '
        'Upload (fail-closed): $e');
  }
  if (decoded == null) {
    throw const FormatException(
        'Bild nicht dekodierbar — kein ungescrubbter Upload (fail-closed).');
  }

  // JPEGs come back from decodeImage already baked: the decoder applies the
  // EXIF orientation and zeroes the tag. bakeOrientation is the safety net for
  // other formats and is skipped when no tag remains, saving a full buffer
  // copy.
  final hadOrientation = decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1;
  // Note before clearing: does the source carry metadata at all? Only then is
  // the recompression below unavoidable.
  final hadExif = !decoded.exif.isEmpty;
  var image = hadOrientation ? img.bakeOrientation(decoded) : decoded;

  final longestSide =
      image.width >= image.height ? image.width : image.height;
  final resized = longestSide > maxDimension;
  if (resized) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxDimension : null,
      height: image.width >= image.height ? null : maxDimension,
      interpolation: img.Interpolation.linear,
    );
  }

  // Now — after baking the orientation and after resizing — the whole metadata
  // container goes. The encoder skips the APP1 segment for an empty container,
  // so the output carries no EXIF at all.
  image.exif = img.ExifData();

  final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  // Resized, rotated OR carrying metadata: the re-encoded image is the correct
  // one and is kept even when larger. The byte-saving branch must not be a
  // loophole for GPS — it only applies when the original had no metadata.
  if (resized || hadOrientation || hadExif) return encoded;
  return encoded.lengthInBytes < original.lengthInBytes ? encoded : original;
}
