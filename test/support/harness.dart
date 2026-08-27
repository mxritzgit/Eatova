// ---------------------------------------------------------------------------
// Shared widget-test harness.
//
// 124 suites used to copy the same MaterialApp boilerplate (localizations
// delegates, supportedLocales, locale, buildEatovaTheme). This file is the one
// place that knows how an Eatova widget is mounted for a test. It grew out of
// `designHarness` (test/widgets/design/design_harness.dart), which is
// re-exported below so existing suites keep working with a single import.
//
// MIGRATING A SUITE — before:
//
//   await tester.pumpWidget(MaterialApp(
//     theme: buildEatovaTheme(Brightness.dark),
//     locale: const Locale('de'),
//     supportedLocales: const [Locale('de'), Locale('en')],
//     localizationsDelegates: AppLocalizations.localizationsDelegates,
//     home: Scaffold(body: MyWidget()),
//   ));
//
// after:
//
//   await pumpLocalized(tester, const MyWidget());
//
// Need l10n/tokens of the mounted tree inside the assertion? Take the context:
//
//   final c = await pumpLocalizedContext(tester, const MyWidget());
//   expect(find.text(c.l10n.foodTitle), findsOneWidget);
//   expect(color, c.t.ink);
//
// Same claim in light AND dark (and optionally more locales / text scales)?
// `renderMatrix` declares one test per combination and fails on overflow:
//
//   renderMatrix('Karte rendert', (tester, c) async {
//     await c.pump(tester, const MyCard());
//     expect(decorationOf(tester, find.byType(MyCard)).color, c.t.surf);
//   });
//
// Notes for migrations:
//  * [pumpLocalized] defaults to `Brightness.dark`, `designHarness` defaults to
//    light. Pass the brightness explicitly when the assertion names a palette.
//  * `reducedMotion` is on by default (MediaQuery.disableAnimations), so
//    `motionDuration` collapses to zero. Pass `reducedMotion: false` for suites
//    that measure an animation.
//  * `textScale` ALWAYS wins. The harness writes `textScaler` unconditionally,
//    so the default 1.0 RESETS a `platformDispatcher.textScaleFactorTestValue`
//    the suite set before pumping — it does not mean "leave it alone". Pass the
//    scale to `pumpLocalized`/`renderMatrix`, never to the platform dispatcher
//    (harness_self_test pins both directions).
//  * `pumpLocalized` pumps exactly one frame, like `pumpWidget`. Pass
//    `settle: true` for `pumpAndSettle` — but remember it eats snackbars.
//  * Suites that already declare their own `testWidgetsRobust` keep theirs
//    (a local declaration shadows the import). Suites importing
//    `test/flows/flow_test_helpers.dart` AND this file must hide one of the
//    two: `import '../support/harness.dart' hide testWidgetsRobust;`.
//  * This file re-exports `design_harness.dart` but NOT the app libraries.
//    Keep your own `import 'package:eatova/src/theme/app_tokens.dart';` — drop
//    only the `design_harness.dart` import, otherwise `unnecessary_import`
//    fails `flutter analyze --fatal-infos`.
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';

// One import for the whole harness: the design-library helpers
// (`designHarness`, `pinPhoneViewport`, `pinIphone14Pro`, `decorationOf`,
// `expectRendersInBothBrightnesses`, `expectSurvivesTextScale`) stay where the
// design suites expect them and are re-exported here.
export '../widgets/design/design_harness.dart';

// Deliberately NOT re-exported: `package:eatova/src/l10n/l10n.dart` and
// `.../theme/app_tokens.dart`. A re-export would turn every suite's own
// (correct) import of those into an `unnecessary_import` info, and
// `flutter analyze --fatal-infos` treats that as a failure. Suites keep
// importing the app libraries themselves; naming `AppTokens` is not needed to
// read `c.t.ink`.

// --- MOUNTING ---------------------------------------------------------------

/// [child] inside a fully localized, fully themed MaterialApp.
///
/// Prefer [pumpLocalized]; this builder exists for the places that need the
/// widget itself (a loop over brightnesses, a `pumpWidget` of their own).
///
/// [onContext] receives the BuildContext directly above [child] on every build
/// — that is how [pumpLocalizedContext] hands back a context that can resolve
/// `context.t` and `context.l10n`.
Widget localizedApp(
  Widget child, {
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  bool reducedMotion = true,
  NavigatorObserver? navigatorObserver,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  bool scrollable = false,
  bool safeArea = true,
  bool scaffold = true,
  ValueChanged<BuildContext>? onContext,
}) {
  return Builder(
    builder: (rootContext) {
      // The `View` widget above us already provides a MediaQuery; copying it
      // here (instead of inside `home`) puts text scale and reduced motion
      // above the Navigator, so route and sheet transitions see them too.
      final media = MediaQuery.of(rootContext);
      return MediaQuery(
        data: media.copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildEatovaTheme(brightness),
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          navigatorObservers: <NavigatorObserver>[
            if (navigatorObserver != null) navigatorObserver,
          ],
          home: Builder(
            builder: (_) {
              Widget body = Builder(
                builder: (context) {
                  onContext?.call(context);
                  return child;
                },
              );
              if (padding != EdgeInsets.zero) {
                body = Padding(padding: padding, child: body);
              }
              if (scrollable) body = SingleChildScrollView(child: body);
              if (safeArea) body = SafeArea(child: body);
              return scaffold ? Scaffold(body: body) : body;
            },
          ),
        ),
      );
    },
  );
}

/// Mounts [child] in the Eatova theme with all localization delegates wired up.
///
/// Pumps exactly one frame, like `tester.pumpWidget`; pass `settle: true` for
/// `pumpAndSettle`.
///
/// [surfaceSize] is logical, not physical: it is scaled by the current device
/// pixel ratio and reset on teardown, so it composes with [pinPhoneViewport].
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  bool reducedMotion = true,
  Size? surfaceSize,
  NavigatorObserver? navigatorObserver,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  bool scrollable = false,
  bool safeArea = true,
  bool scaffold = true,
  bool settle = false,
}) async {
  await _pumpLocalized(
    tester,
    child,
    locale: locale,
    brightness: brightness,
    textScale: textScale,
    reducedMotion: reducedMotion,
    surfaceSize: surfaceSize,
    navigatorObserver: navigatorObserver,
    padding: padding,
    scrollable: scrollable,
    safeArea: safeArea,
    scaffold: scaffold,
    settle: settle,
  );
}

/// Like [pumpLocalized], but returns the BuildContext directly above [child].
///
/// Use it for assertions that need the mounted tree's own values:
/// `context.t` (design tokens) and `context.l10n` (localized strings).
Future<BuildContext> pumpLocalizedContext(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  bool reducedMotion = true,
  Size? surfaceSize,
  NavigatorObserver? navigatorObserver,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  bool scrollable = false,
  bool safeArea = true,
  bool scaffold = true,
  bool settle = false,
}) async {
  final context = await _pumpLocalized(
    tester,
    child,
    locale: locale,
    brightness: brightness,
    textScale: textScale,
    reducedMotion: reducedMotion,
    surfaceSize: surfaceSize,
    navigatorObserver: navigatorObserver,
    padding: padding,
    scrollable: scrollable,
    safeArea: safeArea,
    scaffold: scaffold,
    settle: settle,
  );
  if (context == null) {
    fail('pumpLocalizedContext: das Kind wurde nie gebaut '
        '(kein BuildContext eingesammelt).');
  }
  return context;
}

Future<BuildContext?> _pumpLocalized(
  WidgetTester tester,
  Widget child, {
  required Locale locale,
  required Brightness brightness,
  required double textScale,
  required bool reducedMotion,
  required Size? surfaceSize,
  required NavigatorObserver? navigatorObserver,
  required EdgeInsetsGeometry padding,
  required bool scrollable,
  required bool safeArea,
  required bool scaffold,
  required bool settle,
}) async {
  if (surfaceSize != null) {
    tester.view.physicalSize = surfaceSize * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
  }
  BuildContext? captured;
  await tester.pumpWidget(
    localizedApp(
      child,
      locale: locale,
      brightness: brightness,
      textScale: textScale,
      reducedMotion: reducedMotion,
      navigatorObserver: navigatorObserver,
      padding: padding,
      scrollable: scrollable,
      safeArea: safeArea,
      scaffold: scaffold,
      onContext: (context) => captured = context,
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return captured;
}

// --- OVERFLOW COLLECTION ----------------------------------------------------

/// Runs [body] with layout errors collected instead of failing (or being
/// swallowed) — the returned list is the evidence.
///
/// Everything that is not a layout error is forwarded to the handler that was
/// installed before, so a real widget exception still fails the test.
///
/// ```dart
/// final overflows = await collectOverflows(() async {
///   await pumpLocalized(tester, const MyCard(), textScale: 2.0);
/// });
/// expect(overflows, isEmpty, reason: describeOverflows(overflows));
/// ```
Future<List<FlutterErrorDetails>> collectOverflows(
  Future<void> Function() body,
) async {
  final collected = <FlutterErrorDetails>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isLayoutError(details)) {
      collected.add(details);
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  return collected;
}

/// One line per collected error — readable as an `expect` reason.
String describeOverflows(List<FlutterErrorDetails> details) => details
    .map((d) => d.exceptionAsString().split('\n').first.trim())
    .join(' | ');

/// True for the layout complaints a headless render pass produces — nothing
/// else.
///
/// `details.library == 'rendering library'` alone used to answer this, which
/// also swallowed unrelated render bugs (paint, intrinsics, hit test, image
/// decode) — invisibly so in a `skipOverflowCheck: true` case. The concrete
/// wordings plus the layout phase in [FlutterErrorDetails.context] are as wide
/// as this needs to be.
bool _isLayoutError(FlutterErrorDetails details) {
  final text = details.exceptionAsString();
  if (text.contains('overflowed') ||
      text.contains('RenderBox was not laid out') ||
      text.contains('unbounded') ||
      text.contains('RenderFlex children have non-zero flex')) {
    return true;
  }
  // Anything the render pass threw while sizing itself, whatever its wording.
  final phase = details.context?.toString() ?? '';
  return details.library == 'rendering library' &&
      (phase.contains('performLayout') || phase.contains('performResize'));
}

// --- RENDER MATRIX ----------------------------------------------------------

/// One combination of locale x brightness x text scale, handed to a
/// [renderMatrix] body.
class RenderCase {
  RenderCase._({
    required this.locale,
    required this.brightness,
    required this.textScale,
  });

  final Locale locale;
  final Brightness brightness;
  final double textScale;

  BuildContext? _context;

  /// Mounts [child] with exactly this combination (see [pumpLocalized]).
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size? surfaceSize,
    bool reducedMotion = true,
    NavigatorObserver? navigatorObserver,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    bool scrollable = false,
    bool safeArea = true,
    bool scaffold = true,
    bool settle = false,
  }) async {
    _context = await pumpLocalizedContext(
      tester,
      child,
      locale: locale,
      brightness: brightness,
      textScale: textScale,
      reducedMotion: reducedMotion,
      surfaceSize: surfaceSize,
      navigatorObserver: navigatorObserver,
      padding: padding,
      scrollable: scrollable,
      safeArea: safeArea,
      scaffold: scaffold,
      settle: settle,
    );
  }

  /// The BuildContext of the mounted child. Only valid after [pump].
  BuildContext get context {
    final context = _context;
    if (context == null) {
      throw StateError(
        'RenderCase.context ist erst nach c.pump(...) verfuegbar.',
      );
    }
    return context;
  }

  /// Design tokens of this combination. Reads the mounted theme after [pump]
  /// and falls back to the static palette before it, so token-only assertions
  /// can use the matrix without pumping a widget.
  AppTokens get t => _context != null
      ? _context!.t
      : (brightness == Brightness.light ? AppTokens.light : AppTokens.dark);

  /// Localized strings of this combination — mounted bundle after [pump],
  /// direct lookup before it.
  AppLocalizations get l10n =>
      _context != null ? _context!.l10n : lookupAppLocalizations(locale);

  /// `de/dark/1.0x` — the suffix [renderMatrix] appends to the test name.
  String get label => _caseLabel(locale, brightness, textScale);

  @override
  String toString() => 'RenderCase($label)';
}

/// Declares one test per combination of [locales] x [brightnesses] x
/// [textScales]; the combination is appended to the test name.
///
/// Every case additionally asserts that no overflow/layout error occurred —
/// switch that off with [skipOverflowCheck] for a subject that is knowingly
/// clipped.
///
/// ```dart
/// renderMatrix('Chips ueberstehen jede Kombination', (tester, c) async {
///   await c.pump(tester, chips(), scrollable: true);
/// }, textScales: const [1.0, 2.0]);
/// ```
@isTest
void renderMatrix(
  String description,
  Future<void> Function(WidgetTester tester, RenderCase c) body, {
  List<Locale> locales = const <Locale>[Locale('de')],
  List<Brightness> brightnesses = const <Brightness>[
    Brightness.dark,
    Brightness.light,
  ],
  List<double> textScales = const <double>[1.0],
  bool skipOverflowCheck = false,
}) {
  for (final locale in locales) {
    for (final brightness in brightnesses) {
      for (final textScale in textScales) {
        final label = _caseLabel(locale, brightness, textScale);
        testWidgets('$description [$label]', (tester) async {
          // A fresh case per run: the captured BuildContext must not leak
          // from one test into the next.
          final c = RenderCase._(
            locale: locale,
            brightness: brightness,
            textScale: textScale,
          );
          final overflows = await collectOverflows(() => body(tester, c));
          if (!skipOverflowCheck) {
            expect(
              overflows,
              isEmpty,
              reason: 'Layout-Fehler in ${c.label}: '
                  '${describeOverflows(overflows)}',
            );
          }
        });
      }
    }
  }
}

// `double.toString()` is the shortest round-tripping form: 1.0 -> "1.0",
// 2.0 -> "2.0", 1.35 -> "1.35". Stable test names, no rounding logic.
String _caseLabel(Locale locale, Brightness brightness, double textScale) =>
    '${locale.languageCode}/${brightness.name}/${textScale}x';

// --- ROBUST WIDGET TEST -----------------------------------------------------

/// `testWidgets` for the CI setup, previously copied into six suites:
///
/// 1. Pins the viewport to iPhone 14 portrait (393x852 @ DPR 3). The 800x600
///    default shifts grid rows and makes scroll drags non-deterministic.
/// 2. Swallows RenderFlex overflow exceptions from the headless render pass;
///    on a real device the app sits in scroll containers.
///
/// `testWidgets` installs its own `FlutterError.onError` AFTER setUp and does
/// not reset `tester.view`, so both must happen inside the test body.
///
/// Use [renderMatrix] instead when the overflow is the thing under test.
///
/// [skip] is the REASON a case is parked. `testWidgets` only takes `bool? skip`
/// (unlike `test`, which also takes a String), so the reason would be dropped
/// on the floor — it goes into the test name instead and stays readable in the
/// runner output.
@isTest
void testWidgetsRobust(
  String description,
  WidgetTesterCallback callback, {
  String? skip,
}) {
  final name = skip == null ? description : '$description [skip: $skip]';
  testWidgets(name, skip: skip != null, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}
