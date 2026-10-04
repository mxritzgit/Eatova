import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/l10n/l10n.dart';

// The start-failure screen comes up before the app shell, so it never had the
// localization delegates and spoke German on every device. It is the one
// screen a user reads when nothing else works, in release builds included.
void main() {
  Future<void> pumpBootError(
    WidgetTester tester,
    List<Locale> deviceLocales, {
    required bool showDetails,
  }) async {
    tester.platformDispatcher.localesTestValue = deviceLocales;
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(
      buildBootErrorApp(StateError('boot'), showDetails: showDetails),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('englisches Geraet: Titel und Release-Text englisch',
      (tester) async {
    await pumpBootError(
      tester,
      const [Locale('en', 'US')],
      showDetails: false,
    );

    expect(find.text(enL10n.bootErrorTitle), findsOneWidget);
    expect(find.text(enL10n.bootErrorBody), findsOneWidget);
    expect(find.text(deL10n.bootErrorTitle), findsNothing);
  });

  testWidgets('deutsches Geraet bleibt deutsch', (tester) async {
    await pumpBootError(
      tester,
      const [Locale('de', 'DE')],
      showDetails: false,
    );

    expect(find.text(deL10n.bootErrorTitle), findsOneWidget);
    expect(find.text(deL10n.bootErrorBody), findsOneWidget);
  });

  testWidgets('andere Sprache faellt wie die App auf Englisch',
      (tester) async {
    await pumpBootError(
      tester,
      const [Locale('fr', 'FR')],
      showDetails: true,
    );

    expect(find.text(enL10n.bootErrorTitle), findsOneWidget);
    // Debug builds keep the raw error for the developer.
    expect(find.text('Bad state: boot'), findsOneWidget);
  });
}
