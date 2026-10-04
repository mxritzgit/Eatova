// ---------------------------------------------------------------------------
// Capture harness for the dark redesign (2026-09-28).
//
// Renders a tree at the design's reference geometry — 390x844 logical at
// DPR 2 with the iPhone safe areas (top 47, bottom 34) — using the real
// bundled fonts, so a shot can be compared 1:1 with the design's
// `shots/<tab>-NN.png` (also 780x1688 px).
//
// PNGs are written ONLY with `--dart-define=DARK_REDESIGN_CAPTURE=true`, to
// `build/dark-redesign/<name>.png`. Without the define every shot is a no-op,
// so the capture suites run in the normal test pass and write nothing.
//
// LIGHT MODE: `--dart-define=DESIGN_CAPTURE_BRIGHTNESS=light` renders every
// suite that mounts through `localizedApp` (test/support/harness.dart) in the
// light theme — whatever brightness the suite asks for — and writes the shots
// to `build/light-redesign/<name>.png`; it switches capturing on by itself.
// `=dark` forces the dark theme the same way. Without the define nothing
// changes.
//
//   setUpAll(loadDesignFonts);
//   testWidgets('today', (tester) async {
//     pinDesignViewport(tester);
//     await tester.pumpWidget(designCaptureBoundary(localizedApp(...)));
//     await tester.pumpAndSettle();
//     await captureDesignShot(tester, 'today-00');
//     await scrollDesignTabBy(tester, 631);
//     await captureDesignShot(tester, 'today-01');
//   });
// ---------------------------------------------------------------------------

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';

/// `light`, `dark` or empty, from `--dart-define=DESIGN_CAPTURE_BRIGHTNESS`.
const String _kCaptureBrightness = String.fromEnvironment(
  'DESIGN_CAPTURE_BRIGHTNESS',
);

/// True when the run was started with `DARK_REDESIGN_CAPTURE=true` or with
/// a `DESIGN_CAPTURE_BRIGHTNESS`.
const bool kDesignCapture =
    bool.fromEnvironment('DARK_REDESIGN_CAPTURE') || _kCaptureBrightness != '';

/// Output directory of the shots, relative to the project root.
const String kDesignCaptureDir = _kCaptureBrightness == 'light'
    ? 'build/light-redesign'
    : 'build/dark-redesign';

/// The brightness a capture run forces onto every `localizedApp`, or null
/// (the normal test pass, and plain `DARK_REDESIGN_CAPTURE` runs).
Brightness? get designCaptureBrightness => switch (_kCaptureBrightness) {
  'light' => Brightness.light,
  'dark' => Brightness.dark,
  '' => null,
  _ => throw ArgumentError.value(
    _kCaptureBrightness,
    'DESIGN_CAPTURE_BRIGHTNESS',
    'expected light or dark',
  ),
};

/// The palette the capture suites render with: dark (the harness default)
/// unless the run forces a brightness.
AppTokens get designCaptureTokens =>
    designCaptureBrightness == Brightness.light
        ? AppTokens.light
        : AppTokens.dark;

/// The design's reference viewport in logical pixels.
const Size kDesignViewport = Size(390, 844);

/// Device pixel ratio of the reference shots (780x1688 px).
const double kDesignPixelRatio = 2;

/// Safe areas of the reference phone in logical pixels.
const EdgeInsets kDesignSafeArea = EdgeInsets.only(top: 47, bottom: 34);

/// Key of the [RepaintBoundary] that [captureDesignShot] reads.
final GlobalKey designCaptureKey = GlobalKey(debugLabel: 'design-capture');

/// Loads every family bundled under `assets/fonts` plus Material Icons.
///
/// Files follow `<Family>-<Weight>.ttf`; each family gets all its cuts, so a
/// new weight or family is picked up without touching this harness. Call it
/// from `setUpAll` — fonts load once per test file.
Future<void> loadDesignFonts() async {
  final families = <String, List<File>>{};
  for (final file in Directory('assets/fonts').listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.ttf') || !name.contains('-')) continue;
    families.putIfAbsent(name.split('-').first, () => <File>[]).add(file);
  }
  for (final MapEntry(key: family, value: files) in families.entries) {
    final loader = FontLoader(family);
    for (final file in files) {
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

/// Pins the test view to the reference phone; reset on teardown.
void pinDesignViewport(WidgetTester tester) {
  final view = tester.view;
  view.devicePixelRatio = kDesignPixelRatio;
  view.physicalSize = kDesignViewport * kDesignPixelRatio;
  final padding = FakeViewPadding(
    top: kDesignSafeArea.top * kDesignPixelRatio,
    bottom: kDesignSafeArea.bottom * kDesignPixelRatio,
  );
  view.padding = padding;
  view.viewPadding = padding;
  addTearDown(view.reset);
}

/// Wraps [child] in the boundary the shots are read from.
Widget designCaptureBoundary(Widget child) =>
    RepaintBoundary(key: designCaptureKey, child: child);

/// Writes the current frame as `<kDesignCaptureDir>/<name>.png` when
/// capturing is on; otherwise does nothing.
///
/// flutter_test paints every shadow as a solid block ([debugDisableShadows]),
/// which would turn the design's floating and glow shadows into hard bands.
/// The shot is therefore repainted with real shadows, and the flag restored
/// before returning — the binding checks it right after the test body.
Future<void> captureDesignShot(WidgetTester tester, String name) async {
  if (!kDesignCapture) return;
  final boundary =
      designCaptureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  debugDisableShadows = false;
  try {
    _repaintSubtree(boundary);
    await tester.pump();
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: kDesignPixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$kDesignCaptureDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  } finally {
    debugDisableShadows = true;
    _repaintSubtree(boundary);
    await tester.pump();
  }
}

/// Repaint boundaries cache their layers; a paint flag only reaches pixels
/// once every render object below [root] paints again.
void _repaintSubtree(RenderObject root) {
  root.markNeedsPaint();
  root.visitChildren(_repaintSubtree);
}

/// Decodes every on-screen [Image] for real, then settles.
///
/// Image decoding runs outside the fake-async test clock, so without this a
/// shot shows empty frames where the design has photos. Call it before
/// [captureDesignShot] on screens with pictures.
Future<void> precacheDesignImages(WidgetTester tester) async {
  final images = find.byType(Image).evaluate().toList();
  await tester.runAsync(() async {
    for (final element in images) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pumpAndSettle();
}

/// The outermost vertical scrollable on screen — a tab's main scroll view.
///
/// Hidden tabs of the shell's IndexedStack are offstage and not matched.
Finder designMainScrollable() => find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable &&
          axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
    )
    .first;

/// Scrolls [scrollable] (default: [designMainScrollable]) by [pixels],
/// clamped to its extent, and settles — for follow-up shots `<tab>-01…`.
///
/// Returns the new offset, so a caller can check it reached the design's
/// `scrollTop`.
Future<double> scrollDesignTabBy(
  WidgetTester tester,
  double pixels, {
  Finder? scrollable,
}) async {
  final position = tester
      .state<ScrollableState>(scrollable ?? designMainScrollable())
      .position;
  final target = math.min(
    math.max(position.pixels + pixels, position.minScrollExtent),
    position.maxScrollExtent,
  );
  position.jumpTo(target);
  await tester.pumpAndSettle();
  return position.pixels;
}
