// The studio artwork is a 1536 x 1024 PNG shown in a 190 px band of the plan
// picker. Without a decode size it was decoded in full (6 MB of pixels) every
// time the picker opened (perf-ui, polish run 2026-10-01).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/training/training_studio_widgets.dart';

import '../support/harness.dart';

Future<ResizeImage> _decodedIn(
  WidgetTester tester, {
  required Size box,
  required double dpr,
}) async {
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    localizedApp(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: box,
          child: const TrainingStudioArtwork(),
        ),
      ),
      scaffold: false,
      safeArea: false,
    ),
  );
  final image = tester.widget<Image>(find.byType(Image)).image;
  expect(image, isA<ResizeImage>(), reason: 'decoded at the painted size');
  return image as ResizeImage;
}

void main() {
  testWidgets('die Studio-Grafik wird in Bandbreite dekodiert', (tester) async {
    final image = await _decodedIn(tester, box: const Size(350, 190), dpr: 3);

    // Cover over a wide band is width-driven: 350 px at 3x.
    expect(image.width, 1050);
    expect(image.height, isNull, reason: 'the aspect ratio stays the image\'s');
  });

  testWidgets('ein schmales Band dekodiert so breit, dass die Hoehe deckt', (
    tester,
  ) async {
    final image = await _decodedIn(tester, box: const Size(200, 190), dpr: 3);

    // 190 px tall at 3:2 needs 285 px of width, or cover would upscale.
    expect(image.width, 855);
  });

  testWidgets('nie groesser als das Original', (tester) async {
    final image = await _decodedIn(tester, box: const Size(700, 190), dpr: 3);

    expect(image.width, 1536);
  });
}
