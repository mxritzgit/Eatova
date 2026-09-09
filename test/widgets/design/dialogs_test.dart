import 'dart:io';
import 'dart:ui' as ui;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/meal_component.dart';
import 'package:eatova/src/widgets/meal/meal_widgets.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';

const _confirm = ValueKey('dialog-confirm');
const _cancel = ValueKey('dialog-cancel');
final _captureKey = GlobalKey();

Future<void> _loadFonts() async {
  for (final family in {
    'Archivo': [
      'Archivo-Regular.ttf',
      'Archivo-SemiBold.ttf',
      'Archivo-Bold.ttf',
    ],
    'BricolageGrotesque': ['BricolageGrotesque-Bold.ttf'],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  }.entries) {
    final loader = FontLoader(family.key);
    for (final file in family.value) {
      loader.addFont(
        rootBundle.load(
          family.key == 'MaterialIcons' ? 'fonts/$file' : 'assets/fonts/$file',
        ),
      );
    }
    await loader.load();
  }
}

Future<void> _host(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double scale = 1,
  Size size = const Size(393, 852),
  double keyboard = 0,
  bool destructive = false,
  bool busy = false,
  ValueChanged<bool?>? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final l = context.l10n;
              final result = await showEatovaDialog<bool>(
                context: context,
                builder: (dialogContext) => EatovaConfirmDialog(
                  title: destructive
                      ? l.trainingTimerDiscardTitle
                      : l.trainingTimerLeaveTitle,
                  body: destructive
                      ? l.trainingTimerDiscardBody
                      : l.trainingTimerLeaveBody,
                  icon: destructive
                      ? Icons.delete_outline_rounded
                      : Icons.pause_rounded,
                  destructive: destructive,
                  busy: busy,
                  busyLabel: l.trainingTimerSaving,
                  confirmKey: _confirm,
                  cancelKey: _cancel,
                  confirmLabel: destructive
                      ? l.trainingTimerDiscard
                      : l.trainingTimerSaveLeave,
                  cancelLabel: l.trainingTimerStay,
                  onConfirm: () => Navigator.pop(dialogContext, true),
                  onCancel: () => Navigator.pop(dialogContext, false),
                ),
              );
              onResult?.call(result);
            },
            child: const Text('Open dialog'),
          ),
        ),
        locale: locale,
        brightness: brightness,
        textScale: scale,
      ),
    ),
  );
  await tester.tap(find.text('Open dialog'));
  if (busy) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DIALOG_CAPTURE')) return;
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/dialog-review').create(recursive: true);
    await File(
      'build/dialog-review/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  for (final dismiss in ['confirm', 'cancel', 'barrier', 'back']) {
    testWidgets('$dismiss returns the original explicit or dismiss result', (
      tester,
    ) async {
      final results = <bool?>[];
      await _host(tester, onResult: results.add, destructive: true);
      expect(results, isEmpty);
      switch (dismiss) {
        case 'confirm':
          await tester.tap(find.byKey(_confirm));
        case 'cancel':
          await tester.tap(find.byKey(_cancel));
        case 'barrier':
          await tester.tapAt(const Offset(4, 100));
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(results, [
        dismiss == 'confirm'
            ? true
            : dismiss == 'cancel'
            ? false
            : null,
      ]);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('keyboard focus starts on the safe choice and Enter cancels', (
    tester,
  ) async {
    final results = <bool?>[];
    await _host(tester, onResult: results.add, destructive: true);
    final cancelFocus = Focus.of(tester.element(find.text('Stay here')));
    expect(cancelFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  testWidgets(
    'busy state announces its label and blocks duplicate and dismiss actions',
    (tester) async {
      final semantics = tester.ensureSemantics();

      final results = <bool?>[];
      await _host(tester, busy: true, onResult: results.add);
      expect(
        tester.widget<FilledButton>(find.byKey(_confirm)).onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(_cancel)).onPressed,
        isNull,
      );
      expect(find.text('Saving your place…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tapAt(const Offset(4, 100));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(results, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(_confirm)).label,
        contains('Saving your place'),
      );
      semantics.dispose();
    },
  );

  for (final locale in ['de', 'en']) {
    for (final brightness in Brightness.values) {
      for (final large in [false, true]) {
        for (final destructive in [false, true]) {
          testWidgets(
            '$locale ${brightness.name} ${large ? '320px 2x' : '393px'} ${destructive ? 'discard' : 'pause'} stays reachable',
            (tester) async {
              await _host(
                tester,
                locale: Locale(locale),
                brightness: brightness,
                scale: large ? 2 : 1,
                size: large ? const Size(320, 568) : const Size(393, 852),
                destructive: destructive,
              );
              expect(tester.takeException(), isNull);
              final rect = tester.getRect(
                find
                    .descendant(
                      of: find.byType(Dialog),
                      matching: find.byType(Material),
                    )
                    .first,
              );
              expect(rect.left, greaterThanOrEqualTo(20));
              expect(rect.right, lessThanOrEqualTo(large ? 300 : 373));
              await _capture(
                tester,
                '$locale-${brightness.name}-${large ? '320-2x' : '393'}-${destructive ? 'discard' : 'pause'}',
              );
              if (large) {
                await tester.drag(
                  find.byType(SingleChildScrollView),
                  const Offset(0, -600),
                );
                await tester.pumpAndSettle();
                final dialog = tester.widget<EatovaConfirmDialog>(
                  find.byType(EatovaConfirmDialog),
                );
                expect(
                  tester.getBottomLeft(find.text(dialog.body)).dy,
                  lessThanOrEqualTo(
                    tester.getTopLeft(find.byKey(_confirm)).dy - 24,
                  ),
                );
                await _capture(
                  tester,
                  '$locale-${brightness.name}-320-2x-${destructive ? 'discard' : 'pause'}-message-scrolled',
                );
              }
              for (final key in [_confirm, _cancel]) {
                await tester.ensureVisible(find.byKey(key));
                await tester.pump();
                final buttonRect = tester.getRect(find.byKey(key));
                expect(
                  buttonRect.height,
                  greaterThanOrEqualTo(kButtonMinHeight),
                );
                expect(buttonRect.left, greaterThanOrEqualTo(20));
                expect(buttonRect.right, lessThanOrEqualTo(large ? 300 : 373));
                expect(buttonRect.top, greaterThanOrEqualTo(24));
                expect(buttonRect.bottom, lessThanOrEqualTo(large ? 544 : 828));
              }
              await _capture(
                tester,
                '$locale-${brightness.name}-${large ? '320-2x' : '393'}-${destructive ? 'discard' : 'pause'}-actions',
              );
              await tester.tap(find.byKey(_cancel));
              await tester.pumpAndSettle();
              expect(find.byType(AlertDialog), findsNothing);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
      testWidgets(
        '$locale ${brightness.name} keyboard and 2x type keep the actions reachable',
        (tester) async {
          final results = <bool?>[];
          await _host(
            tester,
            locale: Locale(locale),
            brightness: brightness,
            scale: 2,
            size: const Size(320, 568),
            keyboard: 240,
            onResult: results.add,
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byKey(_cancel));
          await tester.pump();
          expect(
            tester.getBottomLeft(find.byKey(_cancel)).dy,
            lessThanOrEqualTo(328),
          );
          await _capture(tester, '$locale-${brightness.name}-keyboard-320-2x');
          await tester.tap(find.byKey(_cancel));
          await tester.pumpAndSettle();
          expect(results, [false]);
        },
      );
    }
  }
  testWidgets(
    'focused actions show a keyboard outline without adding a touch outline',
    (tester) async {
      final original = FocusManager.instance.highlightStrategy;
      addTearDown(() => FocusManager.instance.highlightStrategy = original);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await _host(tester);
      var cancel = tester.widget<FilledButton>(find.byKey(_cancel));
      expect(
        cancel.style!.side!.resolve({WidgetState.focused})!.color,
        Colors.transparent,
      );
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.pump();
      cancel = tester.widget<FilledButton>(find.byKey(_cancel));
      expect(
        cancel.style!.side!.resolve({WidgetState.focused})!.color,
        AppTokens.light.ink,
      );
      expect(cancel.style!.side!.resolve({WidgetState.focused})!.width, 2);
    },
  );

  for (final locale in ['de', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$locale ${brightness.name} guarded input keeps validation and fits 320px 2x with keyboard',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final scale = ValueNotifier(1.0);
          addTearDown(scale.dispose);
          await tester.pumpWidget(
            RepaintBoundary(
              key: _captureKey,
              child: ValueListenableBuilder<double>(
                valueListenable: scale,
                builder: (context, textScale, _) => localizedApp(
                  Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showWeightAdjustmentSheet(
                        context,
                        const MealAnalysisResult(
                          mealName: 'Bowl',
                          caloriesKcal: 100,
                          estimatedGrams: 100,
                          kcalPer100G: 100,
                          protein: '5 g',
                          carbs: '10 g',
                          fat: '2 g',
                          confidence: '',
                          portionNotes: '',
                          items: [
                            MealComponent(
                              name: 'Rice',
                              grams: 100,
                              caloriesKcal: 100,
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Open input'),
                    ),
                  ),
                  locale: Locale(locale),
                  brightness: brightness,
                  textScale: textScale,
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open input'));
          await tester.pumpAndSettle();
          final add = find.byKey(const ValueKey('analyse-item-add-button'));
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          tester.view.viewInsets = const FakeViewPadding(bottom: 240);
          scale.value = 2;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          Finder field(String name) =>
              find.byKey(ValueKey('analyse-add-item-$name'));
          final save = field('save');
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          await tester.enterText(field('name'), 'Apple');
          await tester.enterText(field('grams'), '0');
          await tester.enterText(field('kcal'), '52');
          await tester.pump();
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          await tester.enterText(field('grams'), '100');
          await tester.pump();
          expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
          await tester.ensureVisible(field('macros-toggle'));
          await tester.tap(field('macros-toggle'));
          await tester.pumpAndSettle();
          for (final name in [
            'name',
            'grams',
            'kcal',
            'protein',
            'carbs',
            'fat',
          ]) {
            final input = field(name);
            await tester.ensureVisible(input);
            await tester.pump();
            final rect = tester.getRect(input);
            expect(rect.left, greaterThanOrEqualTo(20));
            expect(rect.right, lessThanOrEqualTo(300));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(328));
            expect(input.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          await _capture(
            tester,
            '$locale-${brightness.name}-input-keyboard-320-2x',
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          final keep = find.byKey(const ValueKey('discard-changes-cancel'));
          await tester.ensureVisible(keep);
          await tester.tap(keep);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field('name')).controller!.text,
            'Apple',
          );
          await tester.ensureVisible(save);
          await tester.pump();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(find.byType(EatovaDialog), findsNothing);
          expect(find.text('Apple'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
