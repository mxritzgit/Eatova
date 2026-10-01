// The motion vocabulary of the tabs (lively.dart, 2026-10-01): counting
// numbers, press feedback, first-view stagger and row insertion. Every
// animated case runs with reducedMotion: false and walks real 16 ms frames;
// the reduced-motion cases pin that the end state shows at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/common/lively.dart';
import 'package:eatova/src/widgets/common/motion.dart';

import '../../support/harness.dart';

const _frame = Duration(milliseconds: 16);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(_frame);
  }
}

String _count(WidgetTester tester) {
  final text = tester.widget<Text>(find.byKey(const ValueKey('count')));
  return text.data ?? text.textSpan!.toPlainText();
}

Widget _counter(double value) => CountingText(
  value: value,
  format: (v) => v.round().toString(),
  textKey: const ValueKey('count'),
);

double _scaleOf(WidgetTester tester) => tester
    .widget<Transform>(
      find.descendant(
        of: find.byType(PressScale),
        matching: find.byType(Transform),
      ),
    )
    .transform
    .storage[0];

double _opacityOf(WidgetTester tester, Key key) => tester
    .widget<FadeTransition>(
      find
          .ancestor(of: find.byKey(key), matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

void main() {
  group('CountingText', () {
    testWidgets('zaehlt beim ersten Zeigen von 0 hoch und endet exakt', (
      tester,
    ) async {
      await pumpLocalized(tester, _counter(902), reducedMotion: false);
      expect(_count(tester), '0');

      await _frames(tester, 8);
      final mid = int.parse(_count(tester));
      expect(mid, inExclusiveRange(0, 902));

      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.byKey(const ValueKey('count')));
      // At rest a plain Text: `data` as before, no spans, no label override.
      expect(text.data, '902');
      expect(text.textSpan, isNull);
      expect(text.semanticsLabel, isNull);
    });

    testWidgets('zaehlt bei neuem Wert vom angezeigten Wert aus weiter', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        _counter(902),
        settle: true,
        reducedMotion: false,
      );
      await pumpLocalized(tester, _counter(500), reducedMotion: false);
      // One frame in: still near the old value, not restarted from 0.
      await tester.pump(_frame);
      final early = int.parse(_count(tester));
      expect(early, inInclusiveRange(800, 902));

      await _frames(tester, 10);
      expect(int.parse(_count(tester)), inExclusiveRange(500, early));

      await tester.pumpAndSettle();
      expect(_count(tester), '500');
    });

    testWidgets('liest im Flug den Endwert vor', (tester) async {
      await pumpLocalized(tester, _counter(1200), reducedMotion: false);
      await _frames(tester, 5);
      final text = tester.widget<Text>(find.byKey(const ValueKey('count')));
      expect(text.data, isNull, reason: 'in flight the text is rich');
      expect(text.semanticsLabel, '1200');
      await tester.pumpAndSettle();
    });

    testWidgets('reduzierte Bewegung zeigt den Endwert sofort', (tester) async {
      await pumpLocalized(tester, _counter(902));
      expect(_count(tester), '902');
      await pumpLocalized(tester, _counter(10));
      expect(_count(tester), '10');
    });

    test('nur noch wechselnde Ziffern bekommen Tabellenziffern', () {
      const style = TextStyle(fontSize: 20);
      bool tabular(TextSpan span) =>
          span.style?.fontFeatures?.contains(
            const FontFeature.tabularFigures(),
          ) ??
          false;

      // "9" settled, "0" settled, "1" still changing.
      final late = countingSpans('901', '902', style);
      expect(late.map((s) => s.text), ['90', '1']);
      expect(late.map(tabular), [false, true]);

      // Different length: every digit still changes, separators stay plain.
      final early = countingSpans('87,5', '1,221', style);
      expect(early.map((s) => s.text), ['87', ',', '5']);
      expect(early.map(tabular), [true, false, true]);

      // The final frame is one plain run.
      final done = countingSpans('902 kcal', '902 kcal', style);
      expect(done.single.text, '902 kcal');
      expect(tabular(done.single), isFalse);
    });
  });

  group('PressScale', () {
    Widget button(VoidCallback onTap, {bool enabled = true}) => Center(
      child: PressScale(
        enabled: enabled,
        child: InkWell(
          key: const ValueKey('target'),
          onTap: enabled ? onTap : null,
          child: const SizedBox(width: 120, height: 48),
        ),
      ),
    );

    testWidgets('ein Tipp taucht kurz ein, federt zurueck und feuert einmal', (
      tester,
    ) async {
      var taps = 0;
      await pumpLocalized(tester, button(() => taps++), reducedMotion: false);
      final size = tester.getSize(find.byKey(const ValueKey('target')));

      await tester.tap(find.byKey(const ValueKey('target')));
      await _frames(tester, 4);
      expect(_scaleOf(tester), lessThan(1));
      expect(_scaleOf(tester), greaterThanOrEqualTo(kPressScale - 1e-9));

      await tester.pumpAndSettle();
      expect(_scaleOf(tester), 1);
      expect(taps, 1);
      // Layout never changed; only the paint transform did.
      expect(tester.getSize(find.byKey(const ValueKey('target'))), size);
    });

    testWidgets('gehalten bleibt es eingetaucht bis zum Loslassen', (
      tester,
    ) async {
      var taps = 0;
      await pumpLocalized(tester, button(() => taps++), reducedMotion: false);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('target'))),
      );
      // The dip waits for the press timeout, like the ink ripple.
      await tester.pump(const Duration(milliseconds: 50));
      expect(_scaleOf(tester), 1);
      await _frames(tester, 14);
      expect(_scaleOf(tester), closeTo(kPressScale, 1e-6));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), 1);
      expect(taps, 1);
    });

    testWidgets('ein Scroll-Zug ueber das Element loest die Delle', (
      tester,
    ) async {
      var taps = 0;
      await pumpLocalized(tester, button(() => taps++), reducedMotion: false);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('target'))),
      );
      await _frames(tester, 12);
      expect(_scaleOf(tester), lessThan(1));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 6));
        await tester.pump(_frame);
      }
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scaleOf(tester), 1);
      expect(taps, 0, reason: 'a drag is not a tap');
    });

    testWidgets('reduzierte Bewegung und deaktiviert: keine Delle', (
      tester,
    ) async {
      var taps = 0;
      await pumpLocalized(tester, button(() => taps++));
      await tester.tap(find.byKey(const ValueKey('target')));
      await tester.pump(_frame);
      expect(_scaleOf(tester), 1);
      expect(taps, 1);

      await pumpLocalized(
        tester,
        button(() => taps++, enabled: false),
        reducedMotion: false,
      );
      await tester.tap(find.byKey(const ValueKey('target')));
      await _frames(tester, 4);
      expect(_scaleOf(tester), 1);
      expect(taps, 1);
    });
  });

  group('LivelyStaggerScope', () {
    const a = ValueKey('a');
    const b = ValueKey('b');

    Widget page({bool late = false}) => LivelyStaggerScope(
      child: Column(
        children: [
          const LivelyStaggerItem(
            index: 0,
            child: SizedBox(key: a, height: 20),
          ),
          const LivelyStaggerItem(
            index: 3,
            child: SizedBox(key: b, height: 20),
          ),
          if (late)
            const LivelyStaggerItem(
              index: 1,
              child: SizedBox(key: ValueKey('late'), height: 20),
            ),
        ],
      ),
    );

    testWidgets('Abschnitte kommen nacheinander, zusammen in 300 ms', (
      tester,
    ) async {
      await pumpLocalized(tester, page(), reducedMotion: false);
      expect(_opacityOf(tester, a), 0);
      expect(_opacityOf(tester, b), 0);
      expect(tester.getTopLeft(find.byKey(a)).dy, greaterThan(0));

      await _frames(tester, 4);
      expect(_opacityOf(tester, a), greaterThan(_opacityOf(tester, b)));

      // 19 frames = 304 ms: everything is at rest.
      await _frames(tester, 15);
      expect(_opacityOf(tester, a), 1);
      expect(_opacityOf(tester, b), 1);
      expect(LivelyStaggerScope.total, const Duration(milliseconds: 300));
    });

    testWidgets('spielt nur einmal: spaetere Abschnitte stehen sofort da', (
      tester,
    ) async {
      await pumpLocalized(tester, page(), reducedMotion: false, settle: true);
      final restTop = tester.getTopLeft(find.byKey(a)).dy;

      // Returning to the tab rebuilds the same tree: no replay.
      await pumpLocalized(tester, page(), reducedMotion: false);
      expect(_opacityOf(tester, a), 1);
      expect(tester.getTopLeft(find.byKey(a)).dy, restTop);

      // A section that mounts later appears as it is.
      await pumpLocalized(tester, page(late: true), reducedMotion: false);
      expect(_opacityOf(tester, const ValueKey('late')), 1);
    });

    testWidgets('reduzierte Bewegung: alles sofort sichtbar', (tester) async {
      await pumpLocalized(tester, page());
      expect(_opacityOf(tester, a), 1);
      expect(_opacityOf(tester, b), 1);
    });
  });

  group('LivelyInsert', () {
    Widget list({required bool animate}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LivelyInsert(
          animate: animate,
          child: Container(key: const ValueKey('row'), height: 40),
        ),
        const SizedBox(key: ValueKey('below'), height: 10),
      ],
    );

    testWidgets('eine neue Zeile waechst herein, am Ende volle Hoehe', (
      tester,
    ) async {
      await pumpLocalized(tester, list(animate: true), reducedMotion: false);
      double belowTop() =>
          tester.getTopLeft(find.byKey(const ValueKey('below'))).dy;
      final start = belowTop();
      await _frames(tester, 6);
      final mid = belowTop();
      expect(mid, greaterThan(start));
      await tester.pumpAndSettle();
      expect(belowTop(), start + 40);
      expect(mid, lessThan(start + 40));
    });

    testWidgets('bestehende Zeilen und reduzierte Bewegung: sofort da', (
      tester,
    ) async {
      await pumpLocalized(tester, list(animate: false), reducedMotion: false);
      expect(tester.getSize(find.byKey(const ValueKey('row'))).height, 40);

      await pumpLocalized(tester, const SizedBox());
      await pumpLocalized(tester, list(animate: true));
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('below'))).dy -
            tester.getTopLeft(find.byKey(const ValueKey('row'))).dy,
        40,
      );
    });

    testWidgets('keine Aenderung der Breite in einer gestreckten Spalte', (
      tester,
    ) async {
      // SizeTransition's Align would loosen the width to the content.
      await pumpLocalized(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LivelyInsert(
              animate: false,
              child: ColoredBox(
                color: Color(0xFF000000),
                child: Text('x', key: ValueKey('narrow')),
              ),
            ),
          ],
        ),
      );
      expect(
        tester.getSize(find.byType(ColoredBox).first).width,
        tester.getSize(find.byType(Column)).width,
      );
    });
  });

  test('ein Satz Zeiten fuer die ganze Sprache', () {
    expect(kMotionCurve, Curves.easeOutCubic);
    expect(kMotionPressIn < kMotionPressOut, isTrue);
    expect(kMotionEnter < kMotionValue, isTrue);
  });
}
