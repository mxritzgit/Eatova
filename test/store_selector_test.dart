import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/widgets/common/store_selector.dart';

/// Minimal store with two independent slices.
class _TwoSliceStore extends ChangeNotifier {
  int a = 0;
  int b = 0;
  void bumpA() {
    a++;
    notifyListeners();
  }

  void bumpB() {
    b++;
    notifyListeners();
  }
}

void main() {
  testWidgets(
      'StoreSelector rebuildet nur, wenn sich die selektierte Slice aendert',
      (tester) async {
    final store = _TwoSliceStore();
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StoreSelector(
          store: store,
          // Selects ONLY a — changes to b must not trigger a rebuild.
          selector: () => store.a,
          builder: (context) {
            builds++;
            return Text('a=${store.a} b=${store.b}',
                textDirection: TextDirection.ltr);
          },
        ),
      ),
    );

    expect(builds, 1, reason: 'erster Build');

    // Change the independent slice b -> NO rebuild (the point of PERF-2).
    store.bumpB();
    await tester.pump();
    expect(builds, 1, reason: 'b-Aenderung darf den a-Selektor nicht rebuilden');

    // Change the selected slice a -> exactly ONE rebuild.
    store.bumpA();
    await tester.pump();
    expect(builds, 2, reason: 'a-Aenderung rebuildet den Selektor');

    // Another b change -> still no extra rebuild.
    store.bumpB();
    await tester.pump();
    expect(builds, 2, reason: 'b bleibt irrelevant fuer den a-Selektor');
  });

  testWidgets('StoreSelector mit Record-Slice vergleicht strukturell',
      (tester) async {
    final store = _TwoSliceStore();
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StoreSelector(
          store: store,
          // Record slice: structural equality, so equal values = no rebuild.
          selector: () => (store.a, store.b),
          builder: (context) {
            builds++;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(builds, 1);

    // notifyListeners without a value change -> no rebuild.
    store.notifyListeners();
    await tester.pump();
    expect(builds, 1, reason: 'gleiche (a,b) -> Record gleich -> kein Rebuild');

    store.bumpA();
    await tester.pump();
    expect(builds, 2);
  });
}
