import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_theme.dart';

// Gemeinsamer Unterbau fuer alle Tests der Design-Bibliothek.
//
// Die Widgets lesen ihre Farben ueber `context.t` aus der ThemeExtension —
// ohne echtes Eatova-Theme wirft `AppTokens.of` bewusst. Jeder Test haengt sein
// Pruefobjekt deshalb in [designHarness], nie in ein nacktes MaterialApp.

/// iPhone 14 (393x852 logisch). Der Default-Testviewport (800x600) ist
/// breiter als jedes Telefon und wuerde Ueberlauf-Fehler verstecken.
void pinPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// [child] im vollstaendigen Eatova-Theme, mit dem Seitenrand, den die
/// Screens spaeter auch setzen (20 px).
Widget designHarness(
  Widget child, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  bool scrollable = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEatovaTheme(brightness),
    home: Builder(
      builder: (context) {
        final Widget body = Padding(
          padding: const EdgeInsets.all(20),
          child: child,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: SafeArea(
              child: scrollable ? SingleChildScrollView(child: body) : body,
            ),
          ),
        );
      },
    ),
  );
}

/// Pumpt [build] in Hell UND Dunkel und besteht darauf, dass beide Durchgaenge
/// ohne Exception (inkl. Overflow) durchlaufen.
Future<void> expectRendersInBothBrightnesses(
  WidgetTester tester,
  Widget Function() build, {
  bool scrollable = false,
}) async {
  for (final brightness in Brightness.values) {
    await tester.pumpWidget(
      designHarness(build(), brightness: brightness, scrollable: scrollable),
    );
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'Rendering unter $brightness ist fehlgeschlagen',
    );
  }
}

/// Pumpt [child] bei doppelter Systemschrift — der Deckel, den EatovaApp
/// setzt. Ein RenderFlex-Ueberlauf schlaegt hier als Exception durch.
Future<void> expectSurvivesTextScale(
  WidgetTester tester,
  Widget child, {
  double scale = 2.0,
  bool scrollable = true,
}) async {
  await tester.pumpWidget(
    designHarness(
      child,
      textScaler: TextScaler.linear(scale),
      scrollable: scrollable,
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'Ueberlauf bei textScaler $scale',
  );
}

/// Die BoxDecoration des ersten Containers unterhalb von [of].
BoxDecoration decorationOf(WidgetTester tester, Finder of) {
  final container = tester.widget<Container>(
    find.descendant(of: of, matching: find.byType(Container)).first,
  );
  return container.decoration! as BoxDecoration;
}
