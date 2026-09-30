// HomeTabSwitcher — the shell's tab stack with a fade-through switch
// (polish 2026-10-01, "switching tabs feels dead").
//
// The switch must animate, but keep the IndexedStack contract of D6: tabs
// stay mounted and keep their state (scroll offset), are not rebuilt by a
// switch, and only the selected tab is hit-tested, in the semantics tree and
// onstage. Rapid switching must end cleanly on the last tab; reduced motion
// switches instantly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_tab_switcher.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import '../support/harness.dart';

const _stackKey = ValueKey<String>('switcher');

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int index = 0;
  final List<int> taps = <int>[0, 0, 0];
  final List<int> builds = <int>[0, 0, 0];
  final List<ScrollController> scrolls = List<ScrollController>.generate(
    3,
    (_) => ScrollController(),
  );

  // Cached instances, like the shell's `_tabViews`: a switch must not
  // rebuild them.
  late final List<Widget> tabs = List<Widget>.generate(3, (i) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => taps[i]++,
      child: Builder(
        builder: (context) {
          builds[i]++;
          return ListView(
            controller: scrolls[i],
            children: <Widget>[
              for (var j = 0; j < 40; j++)
                SizedBox(height: 60, child: Text('Tab $i · $j')),
            ],
          );
        },
      ),
    );
  });

  void show(int next) => setState(() => index = next);

  @override
  void dispose() {
    for (final c in scrolls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      HomeTabSwitcher(key: _stackKey, index: index, children: tabs);
}

final _host = GlobalKey<_HostState>();

Future<_HostState> _pump(WidgetTester tester, {bool reducedMotion = false}) async {
  await pumpLocalized(
    tester,
    _Host(key: _host),
    reducedMotion: reducedMotion,
    safeArea: false,
  );
  return _host.currentState!;
}

HomeTabSwitcherState _switcher(WidgetTester tester) =>
    tester.state<HomeTabSwitcherState>(find.byKey(_stackKey));

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _show(WidgetTester tester, _HostState host, int index) async {
  host.show(index);
  await tester.pump();
}

/// A translucent background-coloured rect: the fade scrim.
PaintPattern _scrim() => paints..something((method, arguments) {
  if (method != #drawRect) return false;
  final color = (arguments[1] as Paint).color;
  final bg = AppTokens.dark.bg;
  // Paint stores float32 channels.
  bool same(double a, double b) => (a - b).abs() < 1e-4;
  return same(color.r, bg.r) &&
      same(color.g, bg.g) &&
      same(color.b, bg.b) &&
      color.a > 0.01 &&
      color.a < 0.99;
});

void main() {
  group('HomeTabSwitcher', () {
    testWidgets('Wechsel blendet durch: im Zwischenframe sind beide Tabs zu '
        'sehen, am Ende nur der neue', (tester) async {
      final host = await _pump(tester);
      await _show(tester, host, 1);
      await _frames(tester, 4);

      final s = _switcher(tester);
      expect(s.visibilityOf(0), inExclusiveRange(0, 1), reason: 'blendet aus');
      expect(s.visibilityOf(1), inExclusiveRange(0, 1), reason: 'blendet ein');
      expect(s.visibilityOf(2), 0, reason: 'unbeteiligt');
      // Moving right in the bar: the new tab drifts in from the right.
      expect(s.driftOf(1), inExclusiveRange(0, HomeTabSwitcher.drift));
      expect(tester.renderObject(find.byKey(_stackKey)), _scrim());

      await _frames(tester, 20);
      expect(s.visibilityOf(0), 0);
      expect(s.visibilityOf(1), 1);
      expect(s.driftOf(1), 0);
      expect(
        tester.renderObject(find.byKey(_stackKey)),
        isNot(_scrim()),
        reason: 'im Ruhezustand kein Schleier: der Look bleibt unveraendert',
      );
      expect(find.text('Tab 1 · 0'), findsOneWidget);
      expect(find.text('Tab 0 · 0'), findsNothing);
      expect(find.text('Tab 0 · 0', skipOffstage: false), findsOneWidget,
          reason: 'der alte Tab bleibt gemountet (D6)');
      expect(host.builds, <int>[1, 1, 1],
          reason: 'ein Wechsel baut keinen Tab-Inhalt neu');
    });

    testWidgets('der kommende Tab liegt oben und kommt von links, wenn er '
        'links vom gehenden steht', (tester) async {
      final host = await _pump(tester);
      await _show(tester, host, 2);
      await _frames(tester, 20);
      await _show(tester, host, 0);
      await _frames(tester, 3);

      final drift = _switcher(tester).driftOf(0);
      expect(drift, lessThan(0), reason: 'Richtung aus der Tab-Reihenfolge');
      final rect = Offset.zero & tester.getSize(find.byKey(_stackKey));
      // Outgoing scrim (no drift) first, then the incoming one, which spans
      // the drift: the incoming tab paints on top.
      expect(
        tester.renderObject(find.byKey(_stackKey)),
        paints
          ..rect(rect: rect)
          ..rect(
            rect: Rect.fromLTRB(
              rect.left + drift,
              rect.top,
              rect.right - drift,
              rect.bottom,
            ),
          ),
      );
    });

    testWidgets('waehrend des Wechsels nimmt nur der neue Tab Eingaben an',
        (tester) async {
      final host = await _pump(tester);
      await _show(tester, host, 1);
      await _frames(tester, 3);
      expect(_switcher(tester).visibilityOf(0), greaterThan(0));

      await tester.tapAt(tester.getCenter(find.byKey(_stackKey)));
      expect(host.taps, <int>[0, 1, 0]);
    });

    testWidgets('nur der neue Tab steht im Semantikbaum, auch mitten im '
        'Wechsel', (tester) async {
      final handle = tester.ensureSemantics();
      final host = await _pump(tester);
      await _show(tester, host, 1);
      await _frames(tester, 3);

      expect(find.bySemanticsLabel('Tab 1 · 0'), findsOneWidget);
      expect(find.bySemanticsLabel('Tab 0 · 0'), findsNothing);
      handle.dispose();
    });

    testWidgets('Scrollposition und Zustand ueberleben Hin- und Rueckweg',
        (tester) async {
      final host = await _pump(tester);
      host.scrolls[0].jumpTo(300);
      await tester.pump();
      final position = host.scrolls[0].position;

      await _show(tester, host, 1);
      await _frames(tester, 20);
      await _show(tester, host, 0);
      await _frames(tester, 20);

      expect(host.scrolls[0].offset, 300);
      expect(identical(host.scrolls[0].position, position), isTrue);
      expect(host.builds, <int>[1, 1, 1]);
    });

    testWidgets('Zuruecktippen mitten im Wechsel setzt dort fort, wo die Tabs '
        'gerade sind', (tester) async {
      final host = await _pump(tester);
      await _show(tester, host, 1);
      await _frames(tester, 3);
      final s = _switcher(tester);
      final leaving = s.visibilityOf(0);
      final arriving = s.visibilityOf(1);
      final drift = s.driftOf(1);

      await _show(tester, host, 0);
      expect(s.visibilityOf(0), closeTo(leaving, 1e-9),
          reason: 'kein Aufblitzen und kein Sprung auf 0');
      expect(s.visibilityOf(1), closeTo(arriving, 1e-9));
      expect(s.driftOf(1), closeTo(drift, 1e-9));

      await _frames(tester, 20);
      expect(s.visibilityOf(0), 1);
      expect(s.visibilityOf(1), 0);
    });

    testWidgets('schnelles Tippen ueber mehrere Tabs endet sauber auf dem '
        'zuletzt gewaehlten', (tester) async {
      final host = await _pump(tester);
      for (final next in <int>[1, 2, 1, 2, 0, 2]) {
        await _show(tester, host, next);
        await _frames(tester, 1);
      }
      await _frames(tester, 20);

      final s = _switcher(tester);
      expect(<double>[s.visibilityOf(0), s.visibilityOf(1), s.visibilityOf(2)],
          <double>[0, 0, 1],
          reason: 'kein halb ausgeblendeter Tab bleibt stehen');
      expect(s.driftOf(2), 0);
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.renderObject(find.byKey(_stackKey)), isNot(_scrim()));

      await tester.tapAt(tester.getCenter(find.byKey(_stackKey)));
      expect(host.taps, <int>[0, 0, 1]);
    });

    testWidgets('reduzierte Bewegung wechselt sofort', (tester) async {
      final host = await _pump(tester, reducedMotion: true);
      await _show(tester, host, 2);

      final s = _switcher(tester);
      expect(s.visibilityOf(2), 1);
      expect(s.visibilityOf(0), 0);
      expect(s.driftOf(2), 0);
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.text('Tab 2 · 0'), findsOneWidget);
      expect(tester.renderObject(find.byKey(_stackKey)), isNot(_scrim()));
    });
  });
}
