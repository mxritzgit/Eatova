// AppNavBar motion (polish 2026-10-01): the selected-item pill slides to the
// new item instead of jumping, icon/label colours cross-fade, the tapped icon
// dips, and a real change clicks once. Reduced motion makes all of it instant.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/app_icon.dart';
import 'package:eatova/src/widgets/design/controls.dart';

import 'design_harness.dart';

const List<AppNavItem> _items = <AppNavItem>[
  AppNavItem(icon: AppSymbol.today, label: 'Heute'),
  AppNavItem(icon: AppSymbol.food, label: 'Food'),
  AppNavItem(icon: AppSymbol.recipes, label: 'Rezepte'),
  AppNavItem(icon: AppSymbol.training, label: 'Training'),
  AppNavItem(icon: AppSymbol.coach, label: 'Coach'),
];

/// The bar as the shell drives it: a tap sets the index. [changes] records
/// every onChanged call, re-taps included.
Future<void> _pumpBar(
  WidgetTester tester, {
  required List<int> changes,
  ValueNotifier<int>? index,
  bool reducedMotion = false,
}) async {
  pinIphone14Pro(tester);
  final selected = index ?? ValueNotifier<int>(0);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: Scaffold(
        extendBody: true,
        body: const SizedBox.expand(),
        bottomNavigationBar: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (context, value, _) => AppNavBar(
            index: value,
            onChanged: (i) {
              changes.add(i);
              selected.value = i;
            },
            items: _items,
          ),
        ),
      ),
    ),
  );
}

Rect _pill(WidgetTester tester) => AppNavBar.debugPillRect(
  tester.renderObject(find.byKey(const ValueKey<String>('nav-pill'))),
)!;

Offset _icon(WidgetTester tester, AppSymbol symbol) => tester.getCenter(
  find.byWidgetPredicate((w) => w is AppIcon && w.symbol == symbol),
);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Records `HapticFeedback.selectionClick` calls.
List<Object?> _recordHaptics(WidgetTester tester) {
  final calls = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

double _scaleOf(WidgetTester tester, String keyId) => tester
    .widget<ScaleTransition>(
      find.descendant(
        of: find.byKey(ValueKey<String>('nav-$keyId')),
        matching: find.byType(ScaleTransition),
      ),
    )
    .scale
    .value;

void main() {
  group('AppNavBar-Bewegung', () {
    testWidgets('die Kapsel gleitet zum neuen Item, streckt sich unterwegs '
        'und endet genau darunter', (tester) async {
      await _pumpBar(tester, changes: <int>[]);
      final start = _icon(tester, AppSymbol.today);
      final end = _icon(tester, AppSymbol.recipes);
      expect(_pill(tester).center.dx, moreOrLessEquals(start.dx));

      await tester.tap(find.byKey(const ValueKey<String>('nav-Rezepte')));
      await tester.pump();
      await _frames(tester, 3);

      final mid = _pill(tester);
      expect(mid.center.dx, greaterThan(start.dx + 1),
          reason: 'die Kapsel springt nicht, sie ist unterwegs');
      expect(mid.center.dx, lessThan(end.dx - 1));
      expect(mid.width, greaterThan(48), reason: 'leichte Streckung');
      expect(mid.height, 28);

      await _frames(tester, 20);
      final rest = _pill(tester);
      expect(rest.center, offsetMoreOrLessEquals(end));
      expect(rest.size, const Size(48, 28));
    });

    testWidgets('schnelles Umentscheiden: die Kapsel zieht von ihrer '
        'aktuellen Position weiter und endet auf dem letzten Item',
        (tester) async {
      final index = ValueNotifier<int>(0);
      await _pumpBar(tester, changes: <int>[], index: index);

      index.value = 4;
      await tester.pump();
      await _frames(tester, 3);
      final before = _pill(tester).center.dx;

      index.value = 1;
      await tester.pump();
      expect(_pill(tester).center.dx, moreOrLessEquals(before),
          reason: 'kein Sprung beim Umlenken');

      await _frames(tester, 20);
      expect(_pill(tester).center,
          offsetMoreOrLessEquals(_icon(tester, AppSymbol.food)));
    });

    testWidgets('Icon- und Labelfarbe blenden ueber, statt umzuspringen',
        (tester) async {
      await _pumpBar(tester, changes: <int>[]);
      const t = AppTokens.dark;
      Color label(String text) => tester.widget<Text>(find.text(text)).style!.color!;

      await tester.tap(find.byKey(const ValueKey<String>('nav-Food')));
      await tester.pump();
      await _frames(tester, 3);
      expect(label('Food'), isNot(t.ink3));
      expect(label('Food'), isNot(t.accentText));
      expect(label('Heute'), isNot(t.accentText));

      await _frames(tester, 20);
      expect(label('Food'), t.accentText);
      expect(label('Heute'), t.ink3);
    });

    testWidgets('das getippte Icon gibt kurz nach und federt zurueck',
        (tester) async {
      await _pumpBar(tester, changes: <int>[]);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('nav-Training'))),
      );
      // Past the tap-down deadline, pressed and held.
      await tester.pump(const Duration(milliseconds: 150));
      await _frames(tester, 6);
      expect(_scaleOf(tester, 'Training'), closeTo(0.9, 1e-6));

      await gesture.up();
      await _frames(tester, 25);
      expect(_scaleOf(tester, 'Training'), 1);
    });

    testWidgets('ein kurzer Tipp taucht das Icon trotzdem sichtbar ein',
        (tester) async {
      await _pumpBar(tester, changes: <int>[]);
      await tester.tap(find.byKey(const ValueKey<String>('nav-Coach')));
      var deepest = 1.0;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final scale = _scaleOf(tester, 'Coach');
        if (scale < deepest) deepest = scale;
      }
      expect(deepest, lessThan(0.95));
      expect(_scaleOf(tester, 'Coach'), 1);
    });

    testWidgets('Haptik nur bei einem echten Wechsel; erneutes Tippen meldet '
        'weiter, bleibt aber still', (tester) async {
      final haptics = _recordHaptics(tester);
      final changes = <int>[];
      await _pumpBar(tester, changes: changes);

      await tester.tap(find.byKey(const ValueKey<String>('nav-Food')));
      await tester.pump();
      expect(haptics, <Object?>['HapticFeedbackType.selectionClick']);

      // Re-tapping the active item: reported as before (the shell unfocuses
      // and re-selects), but no second click.
      await tester.tap(find.byKey(const ValueKey<String>('nav-Food')));
      await tester.pump();
      expect(changes, <int>[1, 1]);
      expect(haptics, hasLength(1));

      await tester.tap(find.byKey(const ValueKey<String>('nav-Coach')));
      await tester.pump();
      expect(haptics, hasLength(2));
    });

    testWidgets('reduzierte Bewegung: Kapsel, Farbe und Icon sofort am Ziel',
        (tester) async {
      await _pumpBar(tester, changes: <int>[], reducedMotion: true);
      await tester.tap(find.byKey(const ValueKey<String>('nav-Coach')));
      await tester.pump();

      expect(_pill(tester).center,
          offsetMoreOrLessEquals(_icon(tester, AppSymbol.coach)));
      expect(_pill(tester).size, const Size(48, 28));
      expect(tester.widget<Text>(find.text('Coach')).style!.color,
          AppTokens.dark.accentText);
      expect(_scaleOf(tester, 'Coach'), 1);
      // (The ink ripple is Material's own and still runs.)
    });
  });
}
