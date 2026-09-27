import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/design/readable_width.dart';

// ReadableWidth bounds phone-first pages on large windows. Its contract has
// two halves and both are pinned here: below the breakpoint the child gets
// EXACTLY the incoming constraints (phone layouts unchanged), above it the
// child is a centred column of kReadableContentWidth.

/// Records the constraints and state of whatever sits below [ReadableWidth].
class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.onLayout});

  final ValueChanged<BoxConstraints> onLayout;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      widget.onLayout(constraints);
      return const SizedBox.expand();
    },
  );
}

/// [child] in a window of [size] logical pixels, laid out with tight
/// constraints like a Scaffold body.
Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

void main() {
  group('insetFor', () {
    test('ist bis einschliesslich zur Spaltenbreite null', () {
      for (final width in const [0.0, 320.0, 390.0, 639.9, 640.0]) {
        expect(ReadableWidth.insetFor(width), 0, reason: 'bei $width');
      }
    });

    test('teilt den Ueberschuss auf beide Seiten', () {
      expect(ReadableWidth.insetFor(641), 0.5);
      expect(ReadableWidth.insetFor(1024), 192);
      expect(ReadableWidth.insetFor(1366), 363);
      expect(ReadableWidth.insetFor(900, maxWidth: 500), 200);
    });

    test('bleibt bei unbeschraenkter Breite null', () {
      expect(ReadableWidth.insetFor(double.infinity), 0);
    });
  });

  group('Telefonbreiten', () {
    for (final size in const [Size(320, 568), Size(390, 844), Size(640, 960)]) {
      testWidgets('reicht die Constraints unveraendert durch '
          '(${size.width.toInt()} px)', (tester) async {
        BoxConstraints? outer;
        BoxConstraints? inner;
        await _pump(
          tester,
          size,
          LayoutBuilder(
            builder: (context, constraints) {
              outer = constraints;
              return ReadableWidth(child: _Probe(onLayout: (c) => inner = c));
            },
          ),
        );
        expect(outer, BoxConstraints.tight(size));
        expect(inner, outer, reason: 'eng bleibt eng, nichts wird abgezogen');
        expect(tester.getRect(find.byType(_Probe)), Offset.zero & size);
      });
    }

    testWidgets('lose Constraints bleiben lose', (tester) async {
      BoxConstraints? inner;
      await _pump(
        tester,
        const Size(390, 844),
        Align(
          alignment: Alignment.topLeft,
          child: ReadableWidth(child: _Probe(onLayout: (c) => inner = c)),
        ),
      );
      expect(inner, BoxConstraints.loose(const Size(390, 844)));
    });
  });

  group('Grosse Fenster', () {
    for (final size in const [Size(1024, 768), Size(1366, 1024), Size(844, 390)]) {
      testWidgets('zentriert eine Spalte von $kReadableContentWidth px '
          '(${size.width.toInt()} px)', (tester) async {
        BoxConstraints? inner;
        await _pump(
          tester,
          size,
          ReadableWidth(child: _Probe(onLayout: (c) => inner = c)),
        );
        expect(
          inner,
          BoxConstraints.tight(Size(kReadableContentWidth, size.height)),
          reason: 'die Hoehe bleibt eng, nur die Breite wird begrenzt',
        );
        final rect = tester.getRect(find.byType(_Probe));
        expect(rect.width, kReadableContentWidth);
        expect(rect.center.dx, size.width / 2);
      });
    }

    testWidgets('eigene maxWidth wird respektiert', (tester) async {
      await _pump(
        tester,
        const Size(1024, 768),
        ReadableWidth(maxWidth: 480, child: _Probe(onLayout: (_) {})),
      );
      expect(tester.getRect(find.byType(_Probe)).width, 480);
    });
  });

  testWidgets('Zustand ueberlebt das Ueberschreiten der Grenze', (
    tester,
  ) async {
    // Rotating or resizing a window must not rebuild the page from scratch:
    // the element tree is the same on both sides of the breakpoint.
    final key = GlobalKey<_ProbeState>();
    final probe = ReadableWidth(child: _Probe(key: key, onLayout: (_) {}));
    await _pump(tester, const Size(390, 844), probe);
    final before = key.currentState;
    expect(before, isNotNull);

    tester.view.physicalSize = const Size(1024, 768);
    await tester.pump();
    expect(key.currentState, same(before));
    expect(tester.getRect(find.byType(_Probe)).width, kReadableContentWidth);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    expect(key.currentState, same(before));
    expect(tester.getRect(find.byType(_Probe)).width, 390);
  });

  testWidgets('unbeschraenkte Breite (horizontale Liste) wirft nicht', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(390, 844),
      const SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ReadableWidth(child: SizedBox(width: 800, height: 100)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(ReadableWidth)).width, 800);
  });
}
