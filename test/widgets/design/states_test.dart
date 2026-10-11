// Feedback states (design pass 2026-10-11): toasts always carry their tone
// glyph and sit on the 20 px gutter without a clipped shadow, the busy
// primary button, the shared signal note and calm state, and the emptied
// favorites sheet that hands back to the search.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/favorite_meal.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/favorites_sheet.dart';

import '../../support/harness.dart';

Future<BuildContext> _host(WidgetTester tester) async {
  pinPhoneViewport(tester);
  late BuildContext captured;
  await tester.pumpWidget(
    localizedApp(
      Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.expand();
        },
      ),
      locale: const Locale('en'),
    ),
  );
  return captured;
}

Future<void> _settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  group('toasts', () {
    const glyphs = <SnackTone, IconData>{
      SnackTone.positive: Icons.check_circle_outline_rounded,
      SnackTone.neutral: Icons.info_outline_rounded,
      SnackTone.warning: Icons.warning_amber_rounded,
      SnackTone.error: Icons.error_outline_rounded,
    };

    for (final MapEntry(key: tone, value: glyph) in glyphs.entries) {
      testWidgets('a ${tone.name} toast without an icon shows its tone glyph', (
        tester,
      ) async {
        final context = await _host(tester);
        showAppSnack(context, 'Message', tone: tone);
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byIcon(glyph),
          ),
          findsOneWidget,
        );
        await _settleToast(tester);
      });
    }

    testWidgets('an explicit icon still wins over the tone glyph', (
      tester,
    ) async {
      final context = await _host(tester);
      showAppSnack(
        context,
        'Removed',
        icon: Icons.delete_outline_rounded,
        tone: SnackTone.error,
      );
      await tester.pump();
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      await _settleToast(tester);
    });

    testWidgets('the toast sits on the 20 px gutter, flat, with a hairline', (
      tester,
    ) async {
      final context = await _host(tester);
      showAppSnack(context, 'Added 105 kcal to Dinner.');
      await tester.pumpAndSettle();
      final material = find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first;
      final rect = tester.getRect(material);
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(rect.left, 20);
      expect(rect.right, width - 20);
      final widget = tester.widget<Material>(material);
      expect(
        widget.elevation,
        0,
        reason: 'a shadow is cut off by a SnackHost strip in light mode',
      );
      final shape = widget.shape! as RoundedRectangleBorder;
      expect(shape.side.color, AppTokens.dark.lineStrong);
      await _settleToast(tester);
    });
  });

  testWidgets('a busy primary button shows the spinner and takes no tap', (
    tester,
  ) async {
    var taps = 0;
    final semantics = tester.ensureSemantics();
    await pumpLocalized(
      tester,
      Center(
        child: PrimaryActionButton(
          key: const ValueKey('save'),
          label: 'Saving…',
          busy: true,
          onTap: () => taps++,
        ),
      ),
      locale: const Locale('en'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('save')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('save')));
    await tester.pump();
    expect(taps, 0);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('save'))),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );
    semantics.dispose();
  });

  testWidgets('a boxed signal note writes in ink and announces itself', (
    tester,
  ) async {
    late AppTokens t;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) {
          t = context.t;
          return SignalNote(
            'Could not save.',
            tone: t.danger,
            icon: Icons.error_outline_rounded,
            boxed: true,
            liveRegion: true,
            action: SoftPillButton(label: 'Retry', onTap: () {}),
          );
        },
      ),
      locale: const Locale('en'),
    );
    final text = tester.widget<Text>(find.text('Could not save.'));
    expect(text.style!.color, t.ink);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.error_outline_rounded)).color,
      t.danger,
    );
    // Only the text is the live region; the pill keeps its own button node.
    final live = find.byWidgetPredicate(
      (w) => w is Semantics && (w.properties.liveRegion ?? false),
    );
    expect(live, findsOneWidget);
    expect(
      find.descendant(of: live, matching: find.text('Could not save.')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: live, matching: find.byType(SoftPillButton)),
      findsNothing,
    );
    // The action starts under the text, not under the glyph.
    expect(
      tester.getTopLeft(find.byType(SoftPillButton)).dx,
      tester.getTopLeft(find.text('Could not save.')).dx,
    );
  });

  testWidgets('a calm state card has a jump-mark title and soft actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLocalized(
      tester,
      CalmState(
        card: true,
        icon: Icons.history_rounded,
        title: 'Nothing to restore yet',
        text: 'Earlier versions show up here.',
        actions: [SoftPillButton(label: 'Try again', onTap: () {})],
      ),
      locale: const Locale('en'),
    );
    expect(
      tester.getSemantics(find.text('Nothing to restore yet')),
      isSemantics(isHeader: true),
    );
    expect(find.byType(SoftPillButton), findsOneWidget);
    expect(find.byType(AppCard), findsOneWidget);
    semantics.dispose();
  });

  for (final (label, width, scale, stacked) in const [
    ('side by side while they fit', 390.0, 1.0, false),
    ('stacked at one width when they do not', 320.0, 2.0, true),
  ]) {
    testWidgets('calm state actions: $label', (tester) async {
      pinPhoneViewport(tester);
      tester.view.physicalSize =
          Size(width, 844) * tester.view.devicePixelRatio;
      // Short labels: the test font sets every glyph 1 em wide.
      await pumpLocalized(
        tester,
        CalmState(
          icon: Icons.cloud_off_rounded,
          text: 'OpenFoodFacts is currently unreachable.',
          actions: [
            SoftPillButton(
              key: const ValueKey('a'),
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onTap: () {},
            ),
            SoftPillButton(
              key: const ValueKey('b'),
              label: 'Edit',
              icon: Icons.edit_rounded,
              onTap: () {},
            ),
          ],
        ),
        locale: const Locale('en'),
        textScale: scale,
        scrollable: true,
      );
      expect(tester.takeException(), isNull);
      final a = tester.getRect(find.byKey(const ValueKey('a')));
      final b = tester.getRect(find.byKey(const ValueKey('b')));
      if (stacked) {
        expect(b.top, greaterThan(a.bottom));
        expect(a.width, b.width);
        expect(a.center.dx, closeTo(b.center.dx, 0.01));
      } else {
        expect(a.center.dy, closeTo(b.center.dy, 0.01));
        expect(b.left, greaterThan(a.right));
      }
      expect(a.height, greaterThanOrEqualTo(48));
    });
  }

  testWidgets('the emptied favorites sheet hands back to the search', (
    tester,
  ) async {
    pinPhoneViewport(tester);
    bool? result;
    // Only an auto recent, no pinned favorite: the sheet opens empty.
    final recent = FavoriteMeal(
      id: 'skyr',
      result: const MealAnalysisResult(
        mealName: 'Skyr',
        caloriesKcal: 90,
        estimatedGrams: 150,
        kcalPer100G: 60,
        protein: '-',
        carbs: '-',
        fat: '-',
        confidence: 'database',
        portionNotes: '',
      ),
      addedAt: DateTime(2026, 9, 1),
      pinned: false,
    );
    await tester.pumpWidget(
      localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showFavoritesSheet(
                context,
                favorites: [recent],
                slot: MealSlot.lunch,
                onAdd: (_, _) => 'id',
                onUnpin: (_) {},
              );
            },
            child: const Text('open'),
          ),
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet-empty')), findsOneWidget);
    // No "Close" next to the X: the way forward is the search.
    expect(find.text('Close'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('favorites-sheet-empty-search')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorites-sheet')), findsNothing);
    expect(result, isTrue);
  });

  test('progress bars are rounded pills on the tile track', () {
    for (final brightness in Brightness.values) {
      final theme = buildEatovaTheme(brightness).progressIndicatorTheme;
      expect(theme.borderRadius, BorderRadius.circular(rPill));
      expect(theme.linearMinHeight, 4);
      expect(theme.strokeCap, StrokeCap.round);
    }
  });

  testWidgets('the skeleton card is one spoken label, not its bars', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLocalized(
      tester,
      const SkeletonCard(rows: 3, semanticLabel: 'Loading day…'),
      locale: const Locale('en'),
    );
    expect(find.bySemanticsLabel('Loading day…'), findsOneWidget);
    expect(
      tester.renderObject<RenderBox>(find.byType(SkeletonCard)).size.height,
      greaterThan(3 * 64),
    );
    semantics.dispose();
  });
}
