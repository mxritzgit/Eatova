import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/common/app_snack.dart';

// Regression: Snackbars (z. B. "Mahlzeit gelöscht / Rückgängig") blieben auf
// dem Gerät stehen und mussten manuell weggewischt werden. Ursache: bei
// deaktivierter System-Animation ("Bewegung reduzieren") schließt die
// Snackbar-Entrance synchron ab und Flutters eingebauter Auto-Dismiss-Timer
// feuert teils nicht. showAppSnack hat dafür ein Safety-Net.

Widget _host(VoidCallback onTap) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onTap.call(),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('Toast verschwindet automatisch — auch mit "Animationen aus"',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox.shrink();
        }),
      ),
    ));

    showAppSnack(ctx, 'Auto-weg-Test',
        duration: const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('Auto-weg-Test'), findsOneWidget);

    // Über Dauer (300ms) + Safety-Net-Puffer (350ms) hinaus -> muss weg sein.
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.text('Auto-weg-Test'), findsNothing);
  });

  testWidgets('Undo-Toast mit Aktion verschwindet ebenfalls automatisch',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(_host(() {}));
    await tester.tap(find.text('go')); // baut ctx via overlay
    await tester.pump();

    final ctx = tester.element(find.text('go'));
    showAppSnack(ctx, 'Mahlzeit gelöscht',
        duration: const Duration(milliseconds: 300),
        action: SnackBarAction(label: 'Rückgängig', onPressed: () {}));
    await tester.pump();
    expect(find.text('Mahlzeit gelöscht'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(find.text('Mahlzeit gelöscht'), findsNothing);
  });
}
