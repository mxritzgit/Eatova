import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'bounded_zlib.dart';
import 'photo_container.dart';

/// Recompresses AI-scan photos: longest edge <= [maxDimension] px, JPEG
/// q[quality]. The in-app camera delivers raw JPEGs without the downscale the
/// gallery path already gets from `image_picker`, and analyze-meal caps at
/// 5 MB (base64 = +33 %).
///
/// Removes camera EXIF and ancillary text/XMP metadata. ICC colour profiles
/// are preserved within the codec limits. Read bounded orientation before
/// stripping raw EXIF; then bake -> resize -> clear before encoding.
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
  final container = inspectPhotoContainer(original);
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(container.decoderBytes ?? original, frame: 0);
  } catch (_) {
    throw const FormatException(
      'Bild nicht dekodierbar — kein ungescrubbter '
      'Upload (fail-closed).',
    );
  }
  if (decoded == null) {
    throw const FormatException(
      'Bild nicht dekodierbar — kein ungescrubbter Upload (fail-closed).',
    );
  }

  // Raw EXIF is removed before decoding: arbitrary linked IFDs are irrelevant
  // to a meal photo. Apply only the preflight's bounded IFD0 orientation.
  if (container.orientation != 1) {
    decoded.exif.imageIfd.orientation = container.orientation;
  }
  final hadOrientation =
      decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1;
  // Note before clearing: does the source carry metadata at all? Only then is
  // the recompression below unavoidable.
  final hadExif = !decoded.exif.isEmpty;
  var image = hadOrientation ? img.bakeOrientation(decoded) : decoded;

  final longestSide = image.width >= image.height ? image.width : image.height;
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
  image.textData = null;

  final icc = image.iccProfile;
  if (icc != null && icc.compression == img.IccProfileCompression.deflate) {
    validateZlibOutput(icc.data, maxBytes: maxPhotoEncodedBytes);
  }
  final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  // Fail closed if the encoder cannot represent a profile in its APP2 segment.
  inspectPhotoContainer(encoded);
  // Resized, rotated OR carrying metadata: the re-encoded image is the correct
  // one and is kept even when larger. The byte-saving branch must not be a
  // loophole for GPS — it only applies when the original had no metadata.
  if (resized || hadOrientation || hadExif || !container.canRetainOriginal) {
    return encoded;
  }
  return encoded.lengthInBytes < original.lengthInBytes ? encoded : original;
}
