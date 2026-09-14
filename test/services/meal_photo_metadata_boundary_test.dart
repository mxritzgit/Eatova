import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/services/meal_photo_compressor.dart';
import 'package:eatova/src/services/photo_container.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _marker = 'SYNTHETIC_PRIVATE_LOCATION';

Uint8List _chunk(String type, List<int> payload) {
  final bytes = Uint8List(payload.length + 12);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, payload.length);
  bytes.setRange(4, 8, ascii.encode(type));
  bytes.setRange(8, 8 + payload.length, payload);
  var crc = 0xffffffff;
  for (final byte in bytes.sublist(4, bytes.length - 4)) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  data.setUint32(bytes.length - 4, crc ^ 0xffffffff);
  return bytes;
}

Uint8List _pngWith(String type, List<int> payload) {
  final png = img.encodePng(img.Image(width: 1, height: 1));
  return Uint8List.fromList([
    ...png.sublist(0, png.length - 12),
    ..._chunk(type, payload),
    ...png.sublist(png.length - 12),
  ]);
}

void main() {
  test('rejects PNG pixel-stream overrun even with a tiny valid IHDR', () {
    final png = img.encodePng(img.Image(width: 1, height: 1, numChannels: 4));
    final input = Uint8List.fromList([
      ...png.sublist(0, 33),
      ..._chunk('IDAT', zlib.encode(List<int>.filled(64, 0))),
      ...png.sublist(png.length - 12),
    ]);
    // A harmless 64-byte stream, not a decompression bomb. The decoder ignores
    // the bytes past the one scanline, so header validation alone is not enough.
    expect(img.decodePng(input), isNotNull);
    expect(() => compressMealPhoto(input), throwsFormatException);
  });

  test('JPEG EXIF is removed before the dependency parses linked IFDs', () {
    final pixels = img.Image(width: 8, height: 4);
    pixels.exif.imageIfd.orientation = 6;
    pixels.exif.gpsIfd[1] = img.IfdValueAscii('N');
    final input = Uint8List.fromList(img.encodeJpg(pixels));
    final preflight = inspectPhotoContainer(input);
    expect(preflight.orientation, 6);
    expect(preflight.decoderBytes, isNotNull);
    expect(latin1.decode(preflight.decoderBytes!).contains('Exif'), isFalse);
    expect(img.decodeJpg(preflight.decoderBytes!)!.exif.isEmpty, isTrue);
    final output = img.decodeJpg(compressMealPhoto(input))!;
    expect((output.width, output.height), (4, 8));
  });

  test('PNG eXIf orientation is baked before the metadata is discarded', () {
    final png = img.encodePng(img.Image(width: 8, height: 4));
    final metadata = img.ExifData()..imageIfd.orientation = 6;
    final buffer = img.OutputBuffer();
    metadata.write(buffer);
    final input = Uint8List.fromList([
      ...png.sublist(0, png.length - 12),
      ..._chunk('eXIf', buffer.getBytes()),
      ...png.sublist(png.length - 12),
    ]);
    final output = img.decodeJpg(compressMealPhoto(input))!;
    expect((output.width, output.height), (4, 8));
    expect(output.exif.isEmpty, isTrue);
  });

  test('Adam7 PNG remains supported', () {
    final png = img.encodePng(img.Image(width: 8, height: 8, numChannels: 4));
    final header = Uint8List.fromList(png.sublist(16, 29))..[12] = 1;
    // Seven standard Adam7 passes of an 8x8 RGBA image: 5+5+9+18+34+68+132
    // bytes, including each scanline's zero filter. All pixels transparent.
    final input = Uint8List.fromList([
      ...png.sublist(0, 8),
      ..._chunk('IHDR', header),
      ..._chunk('IDAT', zlib.encode(List<int>.filled(271, 0))),
      ...png.sublist(png.length - 12),
    ]);
    expect(img.decodePng(input), isNotNull);
    expect(img.decodeJpg(compressMealPhoto(input))!.width, 8);
  });

  test(
    'oversized ICC APP2 output fails closed instead of persisting malformed JPEG',
    () {
      final pixels = img.Image(width: 8, height: 8);
      pixels.iccProfile = img.IccProfile(
        'synthetic',
        img.IccProfileCompression.none,
        Uint8List.fromList(List.generate(66000, (i) => (i * 31) & 255)),
      );
      final input = Uint8List.fromList(img.encodePng(pixels));
      // The pinned JPEG encoder uses one uint16 APP2 block rather than splitting
      // large profiles. The fixture is only 66 KiB inflated, never a large raster.
      expect(() => compressMealPhoto(input), throwsFormatException);
    },
  );

  test('ordinary-size colour profiles are retained', () {
    final pixels = img.Image(width: 8, height: 8);
    pixels.iccProfile = img.IccProfile(
      'synthetic',
      img.IccProfileCompression.none,
      Uint8List.fromList(List.generate(512, (i) => (i * 31) & 255)),
    );
    final input = Uint8List.fromList(img.encodePng(pixels));
    final output = compressMealPhoto(input);
    expect(latin1.decode(output).contains('ICC_PROFILE'), isTrue);
    expect(inspectPhotoContainer(output).mime, 'image/jpeg');
  });

  for (final type in ['tEXt', 'iTXt']) {
    test('scrub removes $type even when JPEG recompression is larger', () {
      final input = _pngWith(
        type,
        ascii.encode(
          type == 'tEXt'
              ? 'Location\x00$_marker'
              : 'XML:com.adobe.xmp\x00\x00\x00\x00\x00$_marker',
        ),
      );
      expect(latin1.decode(input), contains(_marker));
      expect(img.decodePng(input), isNotNull);
      final output = compressMealPhoto(input);
      expect(latin1.decode(output).contains(_marker), isFalse);
      expect(img.decodeImage(output), isNotNull);
    });
  }

  test('scrub removes PNG eXIf GPS/device metadata ignored by decoder', () {
    final metadata = img.ExifData();
    metadata.imageIfd['Model'] = _marker;
    metadata.gpsIfd[1] = img.IfdValueAscii('N');
    metadata.gpsIfd[2] = img.IfdValueRational(52, 1);
    final buffer = img.OutputBuffer();
    metadata.write(buffer);
    final input = _pngWith('eXIf', buffer.getBytes());
    expect(latin1.decode(input), contains(_marker));
    expect(
      img.decodePng(input)!.exif.isEmpty,
      isTrue,
      reason: 'Pinned decoder ignores eXIf; its metadata flag is insufficient.',
    );
    final output = compressMealPhoto(input);
    expect(latin1.decode(output).contains(_marker), isFalse);
  });

  test('scrub removes JPEG XMP despite empty decoded EXIF', () {
    final pixels = img.Image(width: 64, height: 64);
    var seed = 17;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        pixels.setPixelRgb(x, y, seed & 255, seed >> 8 & 255, seed >> 16 & 255);
      }
    }
    final jpeg = img.encodeJpg(pixels, quality: 20);
    final xmp = ascii.encode('http://ns.adobe.com/xap/1.0/\x00$_marker');
    final length = xmp.length + 2;
    final input = Uint8List.fromList([
      ...jpeg.sublist(0, 2),
      0xff,
      0xe1,
      length >> 8,
      length & 255,
      ...xmp,
      ...jpeg.sublist(2),
    ]);
    final decoded = img.decodeJpg(input)!;
    expect(decoded.exif.isEmpty, isTrue);
    expect(
      img.encodeJpg(decoded, quality: 85).length,
      greaterThan(input.length),
    );
    expect(latin1.decode(compressMealPhoto(input)).contains(_marker), isFalse);
  });
}
