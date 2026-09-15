import 'dart:convert';
import 'dart:typed_data';

import 'package:eatova/src/services/meal_photo_compressor.dart';
import 'package:eatova/src/services/photo_container.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _jpegSize(int width, int height) {
  final bytes = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 8, height: 8)),
  );
  for (var i = 0; i < bytes.length - 8; i++) {
    if (bytes[i] == 0xff && bytes[i + 1] == 0xc0) {
      final data = ByteData.sublistView(bytes);
      data.setUint16(i + 5, height);
      data.setUint16(i + 7, width);
      return bytes;
    }
  }
  throw StateError('Fixture has no SOF');
}

// A header fixture only. The one-byte IDAT cannot start any zlib decoder;
// CRCs are immaterial to the structural preflight being tested here.
Uint8List _pngHeaderWithInvalidPixels(int width, int height, int depth) {
  final bytes = Uint8List(58);
  bytes.setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(8, 13);
  bytes.setRange(12, 16, ascii.encode('IHDR'));
  data.setUint32(16, width);
  data.setUint32(20, height);
  bytes[24] = depth;
  bytes[25] = 6; // RGBA, valid with either 8 or 16 bits per channel.
  data.setUint32(33, 1);
  bytes.setRange(37, 41, ascii.encode('IDAT'));
  bytes.setRange(50, 54, ascii.encode('IEND'));
  return bytes;
}

void main() {
  for (final depth in [8, 16]) {
    test('PNG uint32 raster overflow is rejected before zlib ($depth-bit)', () {
      final input = _pngHeaderWithInvalidPixels(0xffffffff, 0x80000001, depth);
      expect(
        () => inspectPhotoContainer(input),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'rejects the raster before examining compressed pixels',
            'Unsupported or oversized photo container.',
          ),
        ),
      );
    });
  }
  test(
    'PNG raster budget counts 16-bit channels twice before pixel parsing',
    () {
      for (final (width, depth, expected) in [
        (4096, 16, 'Invalid or oversized compressed photo data.'),
        (4097, 16, 'Unsupported or oversized photo container.'),
        (4097, 8, 'Invalid or oversized compressed photo data.'),
      ]) {
        // At/below budget the header reaches the one-byte IDAT's safe rejection;
        // above budget it must fail earlier. None of these fixtures is decoded.
        expect(
          () => inspectPhotoContainer(
            _pngHeaderWithInvalidPixels(width, 2048, depth),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'validation stage for $width x 2048 at $depth bits',
              expected,
            ),
          ),
        );
      }
    },
  );
  test('progressive JPEG and lossy/lossless/alpha WebP remain decodable', () {
    for (final encoded in _realSmallImages) {
      final bytes = base64Decode(encoded);
      final decoded = img.decodeJpg(compressMealPhoto(bytes))!;
      expect((decoded.width, decoded.height), (8, 8));
    }
  });

  test(
    'camera and exact raster-budget headers are accepted without decoding',
    () {
      // Header-only checks: never decode these dimension-mutated tiny fixtures.
      final camera = inspectPhotoContainer(_jpegSize(4000, 3000));
      expect((camera.width, camera.height), (4000, 3000));
      expect(inspectPhotoContainer(_jpegSize(4096, 4096)).width, 4096);
    },
  );
  test('oversized raster and zero dimensions fail before the decoder', () {
    expect(
      () => inspectPhotoContainer(_jpegSize(4097, 4096)),
      throwsFormatException,
    );
    expect(() => inspectPhotoContainer(_jpegSize(0, 8)), throwsFormatException);
    // Safe because preflight rejects this header; the test never calls a codec.
  });
  test('magic-only and unsupported containers are rejected', () {
    for (final raw in [
      [0xff, 0xd8, 0xff, 0xd9],
      ascii.encode('RIFF0000WEBPVP8X'),
      img.encodeGif(img.Image(width: 1, height: 1)),
    ]) {
      expect(
        () => inspectPhotoContainer(Uint8List.fromList(raw)),
        throwsFormatException,
      );
    }
  });
  test('RGB, grayscale and 16-bit RGBA PNG photos still normalize', () {
    for (final image in [
      img.Image(width: 9, height: 5, numChannels: 3),
      img.Image(width: 9, height: 5, numChannels: 1),
      img.Image(width: 9, height: 5, numChannels: 4, format: img.Format.uint16),
    ]) {
      final png = Uint8List.fromList(img.encodePng(image));
      final output = img.decodeJpg(compressMealPhoto(png))!;
      expect((output.width, output.height), (9, 5));
    }
  });
}

const _realSmallImages = <String>[
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAAIAAgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAT/xAAUAQEAAAAAAAAAAAAAAAAAAAAF/9oADAMBAAIQAxAAAAGQOC//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAn//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AX//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AX//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/An//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IX//2gAMAwEAAgADAAAAEPv/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==',
  'UklGRowAAABXRUJQVlA4IIAAAABQAwCdASoIAAgAAUAmJbACdDKbvYa/WAmTX0AdDsW/PEgSwADxGlXPxoEaU0WyNYzkYvUjPxZ6BT3vWJGiQs4HeQkh+yvn+xEI5oOiD+hE3+8w/QYFIQxJHoLMTihLLtj4Idben375ioNK8Jh/cf5y/8Cj/5UWBerm1+ZyJ8dgAA==',
  'UklGRi4BAABXRUJQVlA4TCIBAAAvB8ABAP/hNAAApMG9ujtE502uIhOdbc3dfW84DQBAiQ53SJrcEiOQWIExGcerO+8ujgMAIKJs28azRWrn/s2As23f/McGAcoOJcGenjWBnknfFEWjNLR3oI7MXRD+qVCBVPv4YOYn8MBrrqgd+7c73L3Cue3/bSPBjl1KuOAmVIYiIp/6D9cKIQDJ3RQBHkgN8PdP5sNPAI5qb4gMUL/vAfG7wNQGLCP4aoLdA7m4Rp5b9/jvwJcAIXcuIPenBdkIS5y2o6/OrwRpkaY5p2TuSLvySDR7AhffaoXQ+J86xvlrFr2AQQAARKPZtm3biOh/JALgmbwYRieuMNxyBXQLd+icf+SG/ZJ8xw41pE1h1ZDaPyVi6ITLguvxZpWtTfvoAw==',
  'UklGRrwAAABXRUJQVlA4WAoAAAAQAAAABwAABwAAQUxQSBgAAAABuYzof0BNAAKMFUT/nD4FIiZgAjB23QBWUDggfgAAAPABAJ0BKggACAABQCYlkAJ0MEYBZ7hPeAD+hRuzEd24TJJVzZ+ZTY1fPdGLYd505D1Jj/2STD/6R/0J/n/Prifyd9BZxrUXvPW1L/LvUqbxL/lXKve5c/6YBD/2/L/WOH/BFb/xfuIT7f/geMf5LXv55Vzm005fwQiGpScAAA==',
];
