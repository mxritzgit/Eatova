import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// Regression: with system animations disabled the snackbar entrance finishes
// synchronously and Flutter's auto-dismiss timer sometimes never fires, so
// toasts stayed on screen. showAppSnack has a safety net for that.

// showAppSnack reads the toast tone via `context.t`, and `AppTokens.of` throws
// without the theme extension, so the host must build the real theme.
Widget _host(VoidCallback onTap) => MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
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
      theme: buildEatovaTheme(Brightness.dark),
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

    // Past duration (300ms) plus safety-net buffer (350ms): must be gone.
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
    await tester.tap(find.text('go')); // builds ctx via overlay
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

  testWidgets('Undo-Toast steht 4 s, lang genug fuer das Rueckgaengig',
      (tester) async {
    await tester.pumpWidget(_host(() {}));
    final ctx = tester.element(find.text('go'));
    showAppSnack(ctx, 'Rezept gelöscht',
        action: SnackBarAction(label: 'Rückgängig', onPressed: () {}));
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 3900));
    expect(find.text('Rückgängig'), findsOneWidget,
        reason: 'the undo stays within reach for 4 s');

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Rezept gelöscht'), findsNothing);
  });

  testWidgets('Mit Screenreader bleibt nur der Toast mit Aktion stehen',
      (tester) async {
    // Flutter's own SnackBar does the same: with TalkBack or VoiceOver the
    // undo must stay reachable until it is used or the toast is dismissed.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_host(() {}));
    final ctx = tester.element(find.text('go'));

    for (final (label, action, stays) in <(String, SnackBarAction?, bool)>[
      ('Rezept gelöscht', SnackBarAction(label: 'Rückgängig', onPressed: () {}),
          true),
      ('Gespeichert', null, false),
    ]) {
      showAppSnack(ctx, label, action: action);
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text(label), stays ? findsOneWidget : findsNothing,
          reason: label);
    }
  });
}
