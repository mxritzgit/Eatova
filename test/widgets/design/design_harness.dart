import 'dart:math' as math;

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

// --- LEGIBILITY --------------------------------------------------------------
//
// "Renders without an exception" says nothing about whether anything can be
// SEEN. A control label swapped from `ink2` to `onForest` renders perfectly in
// both modes — and is invisible on the light card (1.06:1). The sweep below
// closes that hole: it reads the colour a [Text] actually carries and the
// surface it actually sits on.
//
// The floor is 3:1, deliberately: this asks "did it disappear", not "does it
// meet AA". The AA numbers per token pair live in test/theme/
// hell_modus_audit_test.dart; duplicating them here would only make both files
// fail for the same reason.
//
// Known gap: a [Text] without an explicit `style.color` inherits from
// [DefaultTextStyle] and is skipped — resolving that chain would mean
// re-implementing Flutter's text style merge.

/// WCAG 2.1 contrast ratio of two OPAQUE colors (1.0 … 21.0).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The colour actually painted behind [element]: the nearest ancestor surface,
/// with translucent layers composited onto the one above them, falling back to
/// the scaffold background.
///
/// `computeLuminance()` ignores alpha, so a 5 % tile would otherwise measure as
/// full ink and a semi-transparent nav bar as opaque `surf`.
Color groundBehind(Element element, {Color? fallback}) {
  final layers = <Color>[];
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    Color? color;
    if (widget is DecoratedBox) {
      final decoration = widget.decoration;
      if (decoration is BoxDecoration) color = decoration.color;
    } else if (widget is ColoredBox) {
      color = widget.color;
    } else if (widget is Material) {
      color = widget.color;
    }
    if (color == null || color.a == 0) return true;
    layers.add(color);
    // Opaque: nothing below it can still shine through.
    return color.a < 1.0;
  });
  var ground = fallback ?? Theme.of(element).scaffoldBackgroundColor;
  for (final layer in layers.reversed) {
    ground = Color.alphaBlend(layer, ground);
  }
  return ground;
}

/// True for the app's one DISABLED look: a dimmed label inside a control whose
/// InkWell carries no handler.
///
/// WCAG 1.4.3 exempts inactive components, and `PrimaryActionButton` without
/// `onTap` deliberately lands at 2.73:1 — pinned as a deliberate difference in
/// `fixlauf_h_design_system_test.dart`. The exemption is this narrow on
/// purpose: an OPAQUE label stays measured even without a handler, so a
/// decorative-only chip is not silently excused.
bool _istGesperrt(Element element, Color farbe) {
  if (farbe.a >= 1.0) return false;
  var gesperrt = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is InkWell) {
      gesperrt = widget.onTap == null && widget.onLongPress == null;
      return false;
    }
    return true;
  });
  return gesperrt;
}

/// Fails when a [Text] with an explicit colour would be invisible on the
/// surface it is painted on (< [minRatio]:1 after compositing).
void expectTextStaysVisible(WidgetTester tester, {double minRatio = 3.0}) {
  final unlesbar = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final farbe = widget.style?.color;
    if (farbe == null) continue;
    if (_istGesperrt(element, farbe)) continue;
    final grund = groundBehind(element);
    final ratio = contrastRatio(Color.alphaBlend(farbe, grund), grund);
    if (ratio < minRatio) {
      unlesbar.add(
        '"${widget.data ?? ''}" ${ratio.toStringAsFixed(2)}:1 '
        '($farbe auf $grund)',
      );
    }
  }
  expect(
    unlesbar,
    isEmpty,
    reason: 'unlesbarer Text (< $minRatio:1 auf seiner eigenen Flaeche):\n'
        '${unlesbar.join('\n')}',
  );
}

/// Pumps [build] in light AND dark and requires both passes to run without an
/// exception, overflow included — and every explicitly coloured [Text] to stay
/// visible on the surface it sits on.
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
    expectTextStaysVisible(tester);
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
