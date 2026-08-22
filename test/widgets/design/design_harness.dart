import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Shared scaffolding for all design-library tests.
//
// The widgets read their colors from the ThemeExtension via `context.t`, and
// `AppTokens.of` throws without a real Eatova theme. Every test therefore
// mounts its subject in [designHarness], never in a bare MaterialApp.

/// iPhone 14 (393x852 logical). The default 800x600 test viewport is wider
/// than any phone and would hide overflow errors.
void pinPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// iPhone 14 Pro: 390x844 logical, 59 pt Dynamic Island, 34 pt home bar,
/// optionally with the keyboard open (336 pt). Unlike [pinPhoneViewport] this
/// also sets safe area and keyboard on the [FlutterView] so sheets compute
/// their height against real device insets.
void pinIphone14Pro(WidgetTester tester, {bool keyboard = false}) {
  const dpr = 3.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = const Size(390 * dpr, 844 * dpr);
  tester.view.viewPadding =
      const FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
  // With the keyboard up it covers the home bar: `padding.bottom` drops to 0
  // while `viewPadding.bottom` stays, exactly as the engine reports it.
  tester.view.padding = keyboard
      ? const FakeViewPadding(top: 59 * dpr)
      : const FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
  tester.view.viewInsets =
      keyboard ? const FakeViewPadding(bottom: 336 * dpr) : FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

/// [child] in the full Eatova theme, with the 20 px side padding the screens
/// use as well.
Widget designHarness(
  Widget child, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  bool scrollable = false,
  Locale locale = const Locale('de'),
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEatovaTheme(brightness),
    locale: locale,
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
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

/// Pumps [build] in light AND dark and requires both passes to run without an
/// exception, overflow included.
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

/// Pumps [child] at double system font size — the cap EatovaApp sets. A
/// RenderFlex overflow surfaces here as an exception.
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

/// The BoxDecoration of the first Container below [of].
BoxDecoration decorationOf(WidgetTester tester, Finder of) {
  final container = tester.widget<Container>(
    find.descendant(of: of, matching: find.byType(Container)).first,
  );
  return container.decoration! as BoxDecoration;
}
