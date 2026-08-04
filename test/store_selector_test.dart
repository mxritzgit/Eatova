import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/widgets/common/store_selector.dart';

/// Minimaler Store mit zwei unabhaengigen Slices.
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
          // Selektiert NUR a — Aenderungen an b duerfen keinen Rebuild ausloesen.
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

    // Unabhaengige Slice b aendern -> KEIN Rebuild (Kern der PERF-2-Scoping-Idee).
    store.bumpB();
    await tester.pump();
    expect(builds, 1, reason: 'b-Aenderung darf den a-Selektor nicht rebuilden');

    // Selektierte Slice a aendern -> genau EIN Rebuild.
    store.bumpA();
    await tester.pump();
    expect(builds, 2, reason: 'a-Aenderung rebuildet den Selektor');

    // Erneute b-Aenderung -> weiterhin kein zusaetzlicher Rebuild.
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
          // Record-Slice: strukturelle Gleichheit -> identische Werte = kein Rebuild.
          selector: () => (store.a, store.b),
          builder: (context) {
            builds++;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(builds, 1);

    // notifyListeners ohne Wertaenderung -> kein Rebuild.
    store.notifyListeners();
    await tester.pump();
    expect(builds, 1, reason: 'gleiche (a,b) -> Record gleich -> kein Rebuild');

    store.bumpA();
    await tester.pump();
    expect(builds, 2);
  });
}
