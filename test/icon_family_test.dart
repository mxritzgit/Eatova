import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'flows/flow_test_helpers.dart' show storeOf;
import 'support/harness.dart';

final _today = DateTime(2026, 9, 14, 12);
final _root = GlobalKey();
Finder _key(String name) => find.byKey(ValueKey(name));

class _Health extends NoopHealthService {
  @override
  HealthAuthState get authState => HealthAuthState.granted;
  @override
  Future<HealthSnapshot> readSnapshot() async =>
      HealthSnapshot(stepsToday: 7000, fetchedAt: _today);
}

Future<void> _fonts() async {
  for (final family in ['Archivo', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final weight
        in family == 'Archivo'
            ? ['Regular', 'Medium', 'SemiBold', 'Bold']
            : ['Bold', 'ExtraBold']) {
      loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
    }
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons');
  icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('ICON_CAPTURE')) return;
  final boundary =
      _root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/icon-family/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(_fonts);

  testWidgets(
    'selection and inherited opacity visibly repaint an existing icon',
    (tester) async {
      final glyph = GlobalKey();
      Future<Uint8List> render({
        bool selected = false,
        double opacity = 1,
      }) async {
        await tester.pumpWidget(
          localizedApp(
            Center(
              child: RepaintBoundary(
                key: glyph,
                child: IconTheme(
                  data: IconThemeData(size: 23, opacity: opacity),
                  child: AppIcon(AppSymbol.food, selected: selected),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return _pixels(tester, glyph);
      }

      final resting = await render();
      final active = await render(selected: true);
      expect(base64Encode(active), isNot(base64Encode(resting)));
      final dimmed = await render(selected: true, opacity: .4);
      int coverage(Uint8List pixels) {
        var sum = 0;
        for (var i = 3; i < pixels.length; i += 4) {
          sum += pixels[i];
        }
        return sum;
      }

      expect(coverage(dimmed), lessThan(coverage(active) * .7));
    },
  );

  testWidgets('a small pictogram keeps its optical size inside a meal badge', (
    tester,
  ) async {
    final glyph = GlobalKey();
    await tester.pumpWidget(
      localizedApp(
        Center(
          child: RepaintBoundary(
            key: glyph,
            child: const SizedBox.square(
              dimension: 44,
              child: AppIcon(AppSymbol.food, size: 18),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final data = await _pixels(tester, glyph);
    for (var i = 3; i < data.length; i += 4) {
      if (data[i] == 0) continue;
      expect((i ~/ 4) % 44, inInclusiveRange(13, 30));
      expect((i ~/ 4) ~/ 44, inInclusiveRange(13, 30));
    }
  });

  testWidgets('small pictograms stay distinct, unclipped and inherit opacity', (
    tester,
  ) async {
    final glyph = GlobalKey();
    final signatures = <String>{};
    for (final symbol in AppSymbol.values) {
      await tester.pumpWidget(
        localizedApp(
          Center(
            child: RepaintBoundary(
              key: glyph,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: IconTheme(
                  data: const IconThemeData(
                    size: 18,
                    color: Color(0xFF16151F),
                    opacity: .5,
                  ),
                  child: AppIcon(symbol),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final data = await _pixels(tester, glyph);
      const width = 26;
      var visible = 0;
      var maxAlpha = 0;
      for (var i = 3; i < data.length; i += 4) {
        final alpha = data[i];
        if (alpha == 0) continue;
        final x = (i ~/ 4) % width;
        final y = (i ~/ 4) ~/ width;
        expect(
          x,
          inInclusiveRange(4, 21),
          reason: '${symbol.name} horizontal contour',
        );
        expect(
          y,
          inInclusiveRange(4, 21),
          reason: '${symbol.name} vertical contour',
        );
        visible++;
        if (alpha > maxAlpha) maxAlpha = alpha;
      }
      expect(
        visible,
        greaterThan(25),
        reason: '${symbol.name} must remain visible at 18 px',
      );
      // Overlapping strokes blend, but no individual path can ignore opacity.
      expect(maxAlpha, lessThan(255));
      expect(
        signatures.add(base64Encode(data)),
        isTrue,
        reason: '${symbol.name} needs its own recognizable silhouette',
      );
    }
  });

  testWidgets('original icon family preview', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 620);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _root,
        child: localizedApp(
          Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Eatova / Icon family',
                    style: AppType.display(26, color: context.t.ink),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 18,
                    children: [
                      for (final symbol in AppSymbol.values)
                        SizedBox(
                          width: 174,
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  AppIcon(
                                    symbol,
                                    size: 40,
                                    color: context.t.ink,
                                  ),
                                  const SizedBox(width: 16),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: context.t.brandSurface,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: AppIcon(
                                      symbol,
                                      size: 24,
                                      selected: true,
                                      color: context.t.onBrandSurface,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 9),
                              Text(
                                symbol.name,
                                style: AppType.ui(12, color: context.t.ink2),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          brightness: Brightness.light,
          safeArea: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _capture(tester, 'family');
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final locale in ['de', 'en']) {
      for (final scale in [1.0, 2.0]) {
        final id = '${brightness.name}-$locale-$scale';
        testWidgets('Today, Food and all five icon tabs remain usable: $id', (
          tester,
        ) async {
          await withClock(Clock.fixed(_today), () async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = scale == 1
                ? const Size(390, 844)
                : const Size(320, 568);
            tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
            tester.view.viewPadding = tester.view.padding;
            addTearDown(tester.view.reset);
            final semantics = tester.ensureSemantics();
            try {
              await tester.pumpWidget(
                RepaintBoundary(
                  key: _root,
                  child: localizedApp(
                    EatovaHomePage(healthService: _Health()),
                    brightness: brightness,
                    locale: Locale(locale),
                    textScale: scale,
                    safeArea: false,
                    scaffold: false,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final store = storeOf(tester);
              store.lifetimeStats = LifetimeStats(
                currentStreak: 7,
                lastTrackedDate: _today,
                sessionStart: _today,
              );
              await store.refreshHealthSteps();
              await tester.pumpAndSettle();
              await _capture(tester, 'today-$id');
              for (final (key, symbol) in [
                ('Heute', AppSymbol.today),
                ('Food', AppSymbol.food),
                ('Rezepte', AppSymbol.recipes),
                ('Training', AppSymbol.training),
                ('Coach', AppSymbol.coach),
              ]) {
                final target = _key('nav-$key');
                expect(target.hitTestable(), findsOneWidget);
                expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
                await tester.tap(target);
                await tester.pumpAndSettle();
                expect(
                  tester.getSemantics(target),
                  isSemantics(isSelected: true),
                );
                final active = tester
                    .widgetList<AppIcon>(
                      find.descendant(
                        of: find.byType(AppNavBar),
                        matching: find.byType(AppIcon),
                      ),
                    )
                    .where((icon) => icon.selected)
                    .toList();
                expect(active.single.symbol, symbol);
                if (key == 'Food') await _capture(tester, 'food-$id');
                if (key == 'Training') {
                  await _capture(tester, 'training-footer-$id');
                }
              }
              await tester.tap(_key('nav-Food'));
              await tester.pumpAndSettle();
              await tester.ensureVisible(_key('food-search'));
              await tester.tap(_key('food-search'));
              await tester.pumpAndSettle();
              FocusManager.instance.primaryFocus?.unfocus();
              await tester.pumpAndSettle();
              await tester.ensureVisible(_key('slot-select-open'));
              await tester.tap(_key('slot-select-open'));
              await tester.pumpAndSettle();
              await _capture(tester, 'meal-picker-$id');
              await tester.ensureVisible(_key('slot-select-dinner'));
              await tester.tap(_key('slot-select-dinner'));
              await tester.pumpAndSettle();
              expect(
                find.byKey(const ValueKey('slot-select-sheet')),
                findsNothing,
              );
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          });
        });
      }
    }
  }
}
