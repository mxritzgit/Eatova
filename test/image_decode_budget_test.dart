import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/meal/meal_widgets.dart';

import 'support/harness.dart';

// Perf round 2026-08-31, finding 5: three photo spots decoded their bytes at
// full size — the scan preview shows the scrubbed UPLOAD image (up to
// 1600 px), so a 170-px card paid a ~7 MB RGBA texture where ~2 MB suffice.
// `cacheWidth` (the pattern every other image site already uses) turns the
// provider into a [ResizeImage]; that provider type is the pin.

/// 1x1 PNG, as in the coach recipe flow tests.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('MealPreviewCard decodiert auf Kartenbreite (ResizeImage)',
      (tester) async {
    await pumpLocalized(tester, MealPreviewCard(imageBytes: _pngBytes));

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-image-preview')),
        matching: find.byType(Image),
      ),
    );
    expect(image.image, isA<ResizeImage>(),
        reason: 'Ohne cacheWidth decodiert die 170-px-Vorschau das bis zu '
            '1600 px grosse Upload-Bild in voller Groesse.');
    expect(image.gaplessPlayback, isTrue,
        reason: 'gaplessPlayback muss den Umbau ueberleben (Flacker-Schutz '
            'beim Byte-Wechsel).');
  });
}
