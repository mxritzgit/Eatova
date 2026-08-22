import 'dart:typed_data';

import 'package:eatova/src/services/meal_photo_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// C4, third image path. This one is the most dangerous of the three: its bytes
/// go into `MealAnalysisRequest.imageBytes`, hence to the edge function and on
/// to the third-party model. Used by `add_meal_sheet.dart` (camera and gallery)
/// and `meal_analysis_screen.dart`.
///
/// Asserts the **output at byte level**, not that a function was called:
/// `Exif\x00\x00` is the APP1 signature that actually leaves the device.

/// A JPEG with a GPS sub-IFD, as the system camera writes with location
/// tagging enabled.
Uint8List _geotaggedJpeg({int width = 480, int height = 360}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(180, 120, 60));
  final gps = image.exif.gpsIfd;
  gps[0x0001] = img.IfdValueAscii('N');
  gps[0x0002] = img.IfdValueRational(52, 1);
  gps[0x0003] = img.IfdValueAscii('E');
  gps[0x0004] = img.IfdValueRational(13, 1);
  gps[0x0006] = img.IfdValueRational(3417, 100);
  gps[0x001d] = img.IfdValueAscii('2026:08:08');
  final ifd0 = image.exif.imageIfd;
  ifd0['Make'] = img.IfdValueAscii('ACME');
  ifd0['Model'] = img.IfdValueAscii('Phone X');
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// Searches the raw byte stream for the APP1 signature.
bool _hasExifSegment(Uint8List bytes) {
  const marker = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
  for (var i = 0; i + marker.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

class _FakePickerPlatform extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakePickerPlatform(this.result);

  final XFile? result;
  ImagePickerOptions? lastOptions;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    lastOptions = options;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List original;

  setUp(() {
    original = _geotaggedJpeg();
  });

  test('Vorbedingung: das Fixture traegt GPS wirklich im Byte-Strom', () {
    // Without this guard the scrub test would be vacuously green.
    expect(_hasExifSegment(original), isTrue);
    final decoded = img.decodeJpg(original)!;
    expect(decoded.exif.gpsIfd.keys, isNotEmpty);
    expect(decoded.exif.gpsIfd[0x0002]!.toDouble(), closeTo(52, 0.01));
  });

  test(
      'C4: das gewaehlte Foto verlaesst DeviceMealPhotoInput ohne EXIF — '
      'sonst reisen Koordinaten an die Edge Function und weiter in die USA',
      () async {
    ImagePickerPlatform.instance = _FakePickerPlatform(
      XFile.fromData(original, name: 'meal.jpg', mimeType: 'image/jpeg'),
    );

    final selection = await DeviceMealPhotoInput().pick(ImageSource.gallery);

    expect(selection, isNotNull);
    final gesendet = selection!.request.imageBytes!;
    expect(_hasExifSegment(gesendet), isFalse,
        reason: 'Breitengrad, Laengengrad, Hoehe und Aufnahmezeit duerfen das '
            'Geraet nicht verlassen');
    final decoded = img.decodeJpg(gesendet)!;
    expect(decoded.exif.gpsIfd.keys, isEmpty);
    expect(decoded.exif.isEmpty, isTrue,
        reason: 'auch Geraetemodell und Seriennummer gehoeren nicht mit');
  });

  test('C4: Vorschau und Upload tragen dieselben gescrubbten Bytes', () async {
    ImagePickerPlatform.instance = _FakePickerPlatform(
      XFile.fromData(original, name: 'meal.jpg', mimeType: 'image/jpeg'),
    );

    final selection = await DeviceMealPhotoInput().pick(ImageSource.camera);

    expect(selection!.previewBytes, same(selection.request.imageBytes),
        reason: 'zwei Kopien wuerden auseinanderlaufen, sobald jemand nur '
            'eine davon scrubbt');
    expect(_hasExifSegment(selection.previewBytes!), isFalse);
  });

  test('das Motiv ueberlebt den Scrub', () async {
    ImagePickerPlatform.instance = _FakePickerPlatform(
      XFile.fromData(original, name: 'meal.jpg', mimeType: 'image/jpeg'),
    );

    final selection = await DeviceMealPhotoInput().pick(ImageSource.gallery);
    final decoded = img.decodeJpg(selection!.previewBytes!)!;

    expect(decoded.width, greaterThan(0));
    expect(decoded.height, greaterThan(0));
    final pixel = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
    expect(pixel.r, closeTo(180, 12));
    expect(pixel.g, closeTo(120, 12));
  });

  test(
      'imageQuality/maxWidth bleiben gesetzt — ohne sie reicht iOS HEIC durch, '
      'das package:image nicht dekodieren kann', () async {
    final picker = _FakePickerPlatform(
      XFile.fromData(original, name: 'meal.jpg', mimeType: 'image/jpeg'),
    );
    ImagePickerPlatform.instance = picker;

    await DeviceMealPhotoInput().pick(ImageSource.gallery);

    expect(picker.lastOptions!.imageQuality, isNotNull);
    expect(picker.lastOptions!.maxWidth, isNotNull);
  });

  test('abgebrochene Auswahl liefert null, ohne zu werfen', () async {
    ImagePickerPlatform.instance = _FakePickerPlatform(null);

    expect(await DeviceMealPhotoInput().pick(ImageSource.gallery), isNull);
  });
}
