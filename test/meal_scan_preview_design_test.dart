import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_request.dart';
import 'package:eatova/src/widgets/kcal/meal_scan_preview_sheet.dart';

import 'support/harness.dart';

Finder key(String value) => find.byKey(ValueKey(value));

void viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
  addTearDown(tester.view.reset);
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_SCAN_PREVIEW')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(key('capture'));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/scan-preview/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late Uint8List photo;
  setUpAll(() async {
    photo = File('assets/recipes/lachs_poke_bowl.jpg').readAsBytesSync();
    for (final family in ['Archivo', 'BricolageGrotesque']) {
      final loader = FontLoader(family);
      for (final file in Directory(
        'assets/fonts',
      ).listSync().whereType<File>()) {
        if (file.uri.pathSegments.last.startsWith('$family-')) {
          loader.addFont(file.readAsBytes().then(ByteData.sublistView));
        }
      }
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<BuildContext> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    Locale locale = const Locale('en'),
    double scale = 1,
  }) async {
    late BuildContext launchContext;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: localizedApp(
          const SizedBox.expand(),
          brightness: brightness,
          locale: locale,
          textScale: scale,
          onContext: (context) => launchContext = context,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return launchContext;
  }

  Future<void> loadPhoto(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final finder = find.descendant(
      of: find.byType(MealScanPreviewSheet),
      matching: find.byType(Image),
    );
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(finder).image,
        tester.element(finder),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final locale in [const Locale('de'), const Locale('en')]) {
      for (final scale in [1.0, 2.0]) {
        final name = '${brightness.name}-${locale.languageCode}-$scale';
        testWidgets('photo review and confirmation with real fonts: $name', (
          tester,
        ) async {
          viewport(
            tester,
            scale == 1 ? const Size(390, 844) : const Size(320, 568),
          );
          final context = await mount(
            tester,
            brightness: brightness,
            locale: locale,
            scale: scale,
          );
          final request = MealAnalysisRequest(
            imageId: 'fixture-photo',
            imageBytes: photo,
          );
          final result = showMealScanPreviewSheet(
            context,
            request: request,
            previewBytes: photo,
          );
          await loadPhoto(tester);
          if (scale == 2 && locale.languageCode == 'de') {
            final title = tester.renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(deL10n.foodScanPreviewTitle),
                matching: find.byType(RichText),
              ),
            );
            final word = title.getBoxesForSelection(
              const TextSelection(baseOffset: 5, extentOffset: 16),
            );
            expect(
              word,
              hasLength(1),
              reason: 'Do not split analysieren mid-word',
            );
          }
          if (scale == 1) {
            expect(key('meal-scan-start').hitTestable(), findsOneWidget);
            expect(key('meal-scan-context').hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await capture(tester, name);

          await tester.ensureVisible(key('meal-scan-context'));
          await tester.enterText(key('meal-scan-context'), '  Ohne Sauce  ');
          if (scale == 2) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          }
          await tester.pumpAndSettle();
          await tester.ensureVisible(key('meal-scan-start'));
          if (scale == 2) {
            expect(
              tester.getRect(key('meal-scan-start')).bottom,
              lessThanOrEqualTo(568 - 260),
            );
          }
          await tester.tap(key('meal-scan-start'));
          await tester.pumpAndSettle();
          final confirmed = await result;
          expect(confirmed!.imageId, request.imageId);
          expect(confirmed.imageBytes, same(photo));
          expect(confirmed.freeTextHint, 'Ohne Sauce');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('keyboard reflow preserves the focused draft and selection', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final context = await mount(tester);
    final result = showMealScanPreviewSheet(
      context,
      request: const MealAnalysisRequest(imageId: 'photo'),
      previewBytes: photo,
    );
    await loadPhoto(tester);
    await tester.enterText(key('meal-scan-context'), 'Rice with olive oil');
    final field = tester.widget<TextField>(key('meal-scan-context'));
    field.controller!.selection = const TextSelection(
      baseOffset: 10,
      extentOffset: 15,
    );
    final node = field.focusNode!;
    expect(node.hasFocus, isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(field.controller!.text, 'Rice with olive oil');
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 10, extentOffset: 15),
    );
    await tester.ensureVisible(key('meal-scan-start'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(key('meal-scan-start')).bottom,
      lessThanOrEqualTo(844 - 336),
    );
    expect(key('meal-scan-start').hitTestable(), findsOneWidget);
    await capture(tester, 'keyboard');
    await tester.tap(key('meal-scan-start'));
    await tester.pumpAndSettle();
    expect((await result)!.freeTextHint, 'Rice with olive oil');
    expect(tester.takeException(), isNull);
  });

  for (final missing in [true, false]) {
    testWidgets(
      'unavailable preview has honest fallback and can close: missing=$missing',
      (tester) async {
        viewport(tester, const Size(390, 844));
        final context = await mount(tester);
        final result = showMealScanPreviewSheet(
          context,
          request: const MealAnalysisRequest(imageId: 'photo'),
          previewBytes: missing ? null : Uint8List.fromList([0, 1, 2]),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(find.text(enL10n.foodScanPhotoUnavailable), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(key('meal-scan-cancel'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
    );
  }
}
