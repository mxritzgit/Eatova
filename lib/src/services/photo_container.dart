import 'dart:typed_data';

import 'bounded_zlib.dart';

/// Bounds the raster before package:image allocates it. 64 MiB is the RGBA
/// raster budget, not a claim about total decoder RSS (JPEG also needs working
/// buffers). It admits 16 MP / ordinary 12 MP camera JPEGs; picker output is
/// already at most 1600 px. 16-bit PNGs use twice the bytes per channel.
const maxPhotoRasterBytes = 64 * 1024 * 1024;
const maxPhotoEncodedBytes = 32 * 1024 * 1024;

class PhotoContainer {
  const PhotoContainer(
    this.mime,
    this.width,
    this.height, {
    this.canRetainOriginal = false,
    this.orientation = 1,
    this.decoderBytes,
  });

  final String mime;
  final int width;
  final int height;
  final bool canRetainOriginal;
  final int orientation;
  final Uint8List? decoderBytes;
}

/// Structural preflight only: compressed pixel data still needs the decoder.
/// Never use JpegDecoder.startDecode for this: it allocates coefficient blocks.
PhotoContainer inspectPhotoContainer(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxPhotoEncodedBytes) _invalid();
  final data = ByteData.sublistView(bytes);
  int u16(int offset, [Endian endian = Endian.big]) =>
      data.getUint16(offset, endian);
  int u32(int offset, [Endian endian = Endian.big]) =>
      data.getUint32(offset, endian);
  int u24(int offset) =>
      bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
  bool tag(int offset, String value) {
    if (offset + value.length > bytes.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (bytes.length >= 4 && u16(0) == 0xffd8) {
    var offset = 2;
    var width = 0;
    var height = 0;
    var hasScan = false;
    var canRetainOriginal = true;
    var orientation = 1;
    final privateSegments = <(int, int)>[];
    while (offset < bytes.length) {
      final markerStart = offset;
      if (bytes[offset++] != 0xff) _invalid();
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) _invalid();
      final marker = bytes[offset++];
      if (marker == 0xd9) {
        if (offset != bytes.length || width == 0 || !hasScan) _invalid();
        return PhotoContainer(
          'image/jpeg',
          width,
          height,
          canRetainOriginal: canRetainOriginal,
          orientation: orientation,
          decoderBytes: _withoutRanges(bytes, privateSegments),
        );
      }
      if (marker == 0 ||
          marker == 0xd8 ||
          marker == 1 ||
          (marker >= 0xd0 && marker <= 0xd7) ||
          offset + 2 > bytes.length) {
        _invalid();
      }
      final length = u16(offset);
      if (length < 2 || offset + length > bytes.length) _invalid();
      final start = offset + 2;
      if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
        if (width != 0 || length < 11 || bytes[start] != 8) _invalid();
        height = u16(start + 1);
        width = u16(start + 3);
        _checkRaster(width, height);
        final components = bytes[start + 5];
        if (![1, 3, 4].contains(components) || length != 8 + 3 * components) {
          _invalid();
        }
        for (var component = 0; component < components; component++) {
          final sampling = bytes[start + 7 + 3 * component];
          if (sampling >> 4 == 0 ||
              sampling >> 4 > 4 ||
              sampling & 15 == 0 ||
              sampling & 15 > 4) {
            _invalid();
          }
        }
      } else if (marker >= 0xc0 &&
          marker <= 0xcf &&
          ![0xc4, 0xc8, 0xcc].contains(marker)) {
        _invalid(); // Unsupported JPEG coding process.
      }
      // Only an exact, thumbnail-free JFIF APP0 is safe for the size-saving
      // original-byte path. EXIF, XMP, comments and unknown APP data re-encode.
      if (marker == 0xfe || marker >= 0xe0 && marker <= 0xef) {
        final plainJfif =
            marker == 0xe0 &&
            length == 16 &&
            tag(start, 'JFIF\x00') &&
            bytes[start + 12] == 0 &&
            bytes[start + 13] == 0;
        if (!plainJfif) canRetainOriginal = false;
      }
      if (marker == 0xe1) {
        if (length >= 8 && tag(start, 'Exif\x00\x00')) {
          orientation = _exifOrientation(
            Uint8List.sublistView(bytes, start + 6, offset + length),
          );
        }
        privateSegments.add((markerStart, offset + length));
      }
      offset += length;
      if (marker == 0xda) {
        if (width == 0 || length < 8 || length != 6 + 2 * bytes[start]) {
          _invalid();
        }
        hasScan = true;
        // Skip entropy-coded bytes without decoding, including stuffed FF and
        // restart markers. Continue parsing subsequent scans/metadata segments.
        while (offset < bytes.length) {
          if (bytes[offset] != 0xff) {
            offset++;
            continue;
          }
          var nextOffset = offset + 1;
          while (nextOffset < bytes.length && bytes[nextOffset] == 0xff) {
            nextOffset++;
          }
          if (nextOffset >= bytes.length) _invalid();
          final next = bytes[nextOffset];
          if (next == 0 || next >= 0xd0 && next <= 0xd7) {
            offset = nextOffset + 1;
            continue;
          }
          break;
        }
      }
    }
    _invalid();
  }

  if (tag(0, '\x89PNG\r\n\x1a\n')) {
    var offset = 8;
    var width = 0;
    var height = 0;
    var hasPixels = false;
    Uint8List? exif;
    var inflatedBytes = 0;
    final pixelData = BytesBuilder(copy: false);
    while (offset + 12 <= bytes.length) {
      final length = u32(offset);
      if (length > bytes.length - offset - 12) _invalid();
      final start = offset + 8;
      if (offset == 8) {
        if (length != 13 || !tag(offset + 4, 'IHDR')) _invalid();
        width = u32(start);
        height = u32(start + 4);
        final depth = bytes[start + 8];
        final color = bytes[start + 9];
        final depths = {
          0: [1, 2, 4, 8, 16],
          2: [8, 16],
          3: [1, 2, 4, 8],
          4: [8, 16],
          6: [8, 16],
        };
        if (!(depths[color]?.contains(depth) ?? false) ||
            bytes[start + 10] != 0 ||
            bytes[start + 11] != 0 ||
            bytes[start + 12] > 1) {
          _invalid();
        }
        _checkRaster(width, height, bytesPerPixel: depth == 16 ? 8 : 4);
        final channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]!;
        final passes = bytes[start + 12] == 0
            ? [
                [0, 0, 1, 1],
              ]
            : [
                [0, 0, 8, 8],
                [4, 0, 8, 8],
                [0, 4, 4, 8],
                [2, 0, 4, 4],
                [0, 2, 2, 4],
                [1, 0, 2, 2],
                [0, 1, 1, 2],
              ];
        for (final pass in passes) {
          if (width <= pass[0] || height <= pass[1]) continue;
          final columns = (width - pass[0] + pass[2] - 1) ~/ pass[2];
          final rows = (height - pass[1] + pass[3] - 1) ~/ pass[3];
          inflatedBytes += rows * (1 + (columns * channels * depth + 7) ~/ 8);
        }
      } else if (tag(offset + 4, 'IHDR') || tag(offset + 4, 'acTL')) {
        _invalid(); // Uploads are still photos, not unbounded frame collections.
      } else if (tag(offset + 4, 'eXIf')) {
        if (exif != null) _invalid();
        exif = Uint8List.sublistView(bytes, start, start + length);
      } else if (tag(offset + 4, 'IDAT')) {
        hasPixels = hasPixels || length > 0;
        pixelData.add(Uint8List.sublistView(bytes, start, start + length));
      } else if (tag(offset + 4, 'IEND')) {
        if (length != 0 || !hasPixels || offset + 12 != bytes.length) {
          _invalid();
        }
        validateZlibOutput(
          pixelData.takeBytes(),
          maxBytes: inflatedBytes,
          expectedBytes: inflatedBytes,
        );
        return PhotoContainer(
          'image/png',
          width,
          height,
          orientation: exif == null ? 1 : _exifOrientation(exif),
        );
      }
      offset += length + 12;
    }
    _invalid();
  }

  if (bytes.length >= 20 && tag(0, 'RIFF') && tag(8, 'WEBP')) {
    if (u32(4, Endian.little) != bytes.length - 8) _invalid();
    var offset = 12;
    var width = 0;
    var height = 0;
    var canvasWidth = 0;
    var canvasHeight = 0;
    var orientation = 1;
    final privateChunks = <(int, int)>[];
    while (offset + 8 <= bytes.length) {
      final length = u32(offset + 4, Endian.little);
      final start = offset + 8;
      if (length > bytes.length - start ||
          length + (length & 1) > bytes.length - start) {
        _invalid();
      }
      if (tag(offset, 'VP8X')) {
        if (offset != 12 || length != 10 || bytes[start] & 2 != 0) _invalid();
        canvasWidth = u24(start + 4) + 1;
        canvasHeight = u24(start + 7) + 1;
        _checkRaster(canvasWidth, canvasHeight);
      } else if (tag(offset, 'ANIM') || tag(offset, 'ANMF')) {
        _invalid();
      } else if (tag(offset, 'VP8 ') || tag(offset, 'VP8L')) {
        if (width != 0) _invalid();
        if (tag(offset, 'VP8 ')) {
          if (length < 10 ||
              bytes[start] & 1 != 0 ||
              !tag(start + 3, '\x9d\x01\x2a')) {
            _invalid();
          }
          width = u16(start + 6, Endian.little) & 0x3fff;
          height = u16(start + 8, Endian.little) & 0x3fff;
        } else {
          if (length < 5 ||
              bytes[start] != 0x2f ||
              bytes[start + 4] >> 5 != 0) {
            _invalid();
          }
          final bits = u32(start + 1, Endian.little);
          width = (bits & 0x3fff) + 1;
          height = (bits >> 14 & 0x3fff) + 1;
        }
        _checkRaster(width, height);
      }
      if (tag(offset, 'EXIF') || tag(offset, 'XMP ')) {
        if (tag(offset, 'EXIF')) {
          final exifStart = length >= 6 && tag(start, 'Exif\x00\x00')
              ? start + 6
              : start;
          orientation = _exifOrientation(
            Uint8List.sublistView(bytes, exifStart, start + length),
          );
        }
        privateChunks.add((offset, start + length + (length & 1)));
      }
      offset = start + length + (length & 1);
    }
    if (offset != bytes.length ||
        width == 0 ||
        canvasWidth != 0 && (width != canvasWidth || height != canvasHeight)) {
      _invalid();
    }
    final normalized = _withoutRanges(bytes, privateChunks);
    if (normalized != null) {
      ByteData.sublistView(
        normalized,
      ).setUint32(4, normalized.length - 8, Endian.little);
      if (canvasWidth != 0) normalized[20] &= ~12; // EXIF/XMP feature flags.
    }
    return PhotoContainer(
      'image/webp',
      width,
      height,
      orientation: orientation,
      decoderBytes: normalized,
    );
  }
  _invalid();
}

void _checkRaster(int width, int height, {int bytesPerPixel = 4}) {
  if (width <= 0 ||
      height <= 0 ||
      width * height > maxPhotoRasterBytes ~/ bytesPerPixel) {
    _invalid();
  }
}

Never _invalid() =>
    throw const FormatException('Unsupported or oversized photo container.');

// Drop opaque EXIF/XMP before a dependency traverses attacker-controlled IFD
// chains. Keep pixel segments and colour profiles byte-for-byte.
Uint8List? _withoutRanges(Uint8List bytes, List<(int, int)> ranges) {
  if (ranges.isEmpty) return null;
  final out = BytesBuilder(copy: false);
  var offset = 0;
  for (final (start, end) in ranges) {
    out.add(Uint8List.sublistView(bytes, offset, start));
    offset = end;
  }
  out.add(Uint8List.sublistView(bytes, offset));
  return out.takeBytes();
}

// TIFF IFD0 orientation is one inline SHORT. Do not parse linked EXIF/GPS IFDs
// or allocate arrays from metadata-supplied counts merely to retain orientation.
int _exifOrientation(Uint8List exif) {
  if (exif.length < 8) return 1;
  final data = ByteData.sublistView(exif);
  final order = data.getUint16(0);
  if (order != 0x4949 && order != 0x4d4d) return 1;
  final endian = order == 0x4949 ? Endian.little : Endian.big;
  if (data.getUint16(2, endian) != 42) return 1;
  final offset = data.getUint32(4, endian);
  if (offset > exif.length - 2) return 1;
  final count = data.getUint16(offset, endian);
  if (count > (exif.length - offset - 2) ~/ 12) return 1;
  for (var i = 0; i < count; i++) {
    final entry = offset + 2 + 12 * i;
    if (data.getUint16(entry, endian) == 0x112 &&
        data.getUint16(entry + 2, endian) == 3 &&
        data.getUint32(entry + 4, endian) == 1) {
      final orientation = data.getUint16(entry + 8, endian);
      return orientation >= 1 && orientation <= 8 ? orientation : 1;
    }
  }
  return 1;
}
