import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/l10n/l10n.dart';

// The start-failure screen comes up before the app shell, so it never had the
// localization delegates and spoke German on every device. It is the one
// screen a user reads when nothing else works, in release builds included.
//
// English and German devices (title and release text) are asserted by
// test/design/boot_error_capture_test.dart, which renders the same screen.
void main() {
  testWidgets('andere Sprache faellt wie die App auf Englisch',
      (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('fr', 'FR')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      buildBootErrorApp(StateError('boot'), showDetails: true),
    );
    await tester.pumpAndSettle();

    expect(find.text(enL10n.bootErrorTitle), findsOneWidget);
    expect(find.text(deL10n.bootErrorTitle), findsNothing);
    // Debug builds keep the raw error for the developer.
    expect(find.text('Bad state: boot'), findsOneWidget);
  });
}
