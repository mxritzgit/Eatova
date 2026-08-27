import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/theme/app_tokens.dart';

import 'harness.dart';

// The harness carries 124 suites, so its own guarantees are asserted here:
// a silently broken overflow check would weaken every file that uses
// `renderMatrix`.

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

/// Proof that the `skipOverflowCheck: true` case below really ran — a silently
/// dropped case would make the negative test vacuous.
bool _ueberlaufFallLief = false;

void main() {
  group('pumpLocalized', () {
    testWidgets('liefert Theme, Locale und Tokens der Kombination',
        (tester) async {
      final context = await pumpLocalizedContext(
        tester,
        const SizedBox(),
        locale: const Locale('en'),
        brightness: Brightness.light,
      );
      expect(Localizations.localeOf(context), const Locale('en'));
      expect(context.t, AppTokens.light);
      expect(context.l10n, isA<AppLocalizations>());
      expect(Theme.of(context).brightness, Brightness.light);
    });

    testWidgets('ohne Angabe ist die Helligkeit dunkel', (tester) async {
      // designHarness defaulted to light; a migrated suite that names a
      // palette without passing `brightness` would read the wrong tokens.
      final context = await pumpLocalizedContext(tester, const SizedBox());
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(context.t, AppTokens.dark);
    });

    testWidgets('Default-Baum: Scaffold -> SafeArea -> Kind, ohne Polster',
        (tester) async {
      const kind = ValueKey<String>('harness-kind');
      await pumpLocalized(tester, const SizedBox.expand(key: kind));

      expect(
        find.ancestor(of: find.byKey(kind), matching: find.byType(Scaffold)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: find.byKey(kind), matching: find.byType(SafeArea)),
        findsOneWidget,
      );

      // `padding` defaults to zero — designHarness padded EdgeInsets.all(20),
      // so a migrated overflow probe gets 40 px MORE width than before unless
      // it passes the padding itself.
      final ohnePolster = tester.getRect(find.byKey(kind));
      expect(
        ohnePolster.size,
        tester.view.physicalSize / tester.view.devicePixelRatio,
        reason: 'das Kind fuellt die Flaeche, nichts polstert dazwischen',
      );

      await pumpLocalized(
        tester,
        const SizedBox.expand(key: kind),
        padding: const EdgeInsets.all(20),
      );
      final mitPolster = tester.getRect(find.byKey(kind));
      expect(mitPolster.width, ohnePolster.width - 40);
      expect(mitPolster.height, ohnePolster.height - 40);
    });

    testWidgets('setzt textScale und reducedMotion ueber dem Navigator',
        (tester) async {
      final context = await pumpLocalizedContext(
        tester,
        const SizedBox(),
        textScale: 1.5,
      );
      final media = MediaQuery.of(context);
      expect(media.textScaler.scale(10), 15);
      expect(media.disableAnimations, isTrue,
          reason: 'reducedMotion ist der Default');
    });

    testWidgets(
        'textScale schlaegt platformDispatcher.textScaleFactorTestValue — '
        'auch mit dem Default 1.0', (tester) async {
      // The harness writes `textScaler` unconditionally, so 1.0 is a RESET,
      // not "unveraendert". A suite that pins the scale on the platform
      // dispatcher (see fixlauf_b) measures nothing.
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      var context = await pumpLocalizedContext(tester, const SizedBox());
      expect(MediaQuery.textScalerOf(context).scale(10), 10,
          reason: 'der Default 1.0 ueberschreibt die 2.0 des Dispatchers');

      context = await pumpLocalizedContext(
        tester,
        const SizedBox(),
        textScale: 2.0,
      );
      expect(MediaQuery.textScalerOf(context).scale(10), 20,
          reason: 'der Skalierungsweg fuehrt ueber den Harness-Parameter');
    });

    testWidgets('reducedMotion:false laesst Animationen laufen',
        (tester) async {
      final context = await pumpLocalizedContext(
        tester,
        const SizedBox(),
        reducedMotion: false,
      );
      expect(MediaQuery.of(context).disableAnimations, isFalse);
    });

    testWidgets('surfaceSize ist logisch, nicht physisch', (tester) async {
      final context = await pumpLocalizedContext(
        tester,
        const SizedBox(),
        surfaceSize: const Size(320, 640),
      );
      expect(MediaQuery.of(context).size, const Size(320, 640));
    });

    testWidgets('navigatorObserver haengt am Navigator', (tester) async {
      final observer = _RecordingObserver();
      await pumpLocalized(
        tester,
        const SizedBox(),
        navigatorObserver: observer,
      );
      expect(observer.pushed, isNotEmpty, reason: 'home wurde gepusht');
    });
  });

  group('collectOverflows', () {
    testWidgets('faengt einen RenderFlex-Overflow ein', (tester) async {
      final overflows = await collectOverflows(() async {
        await pumpLocalized(
          tester,
          const Row(
            children: <Widget>[
              SizedBox(
                width: 900,
                height: 10,
                child: ColoredBox(color: Color(0xFFFF0000)),
              ),
            ],
          ),
          surfaceSize: const Size(300, 600),
        );
      });
      expect(overflows, isNotEmpty,
          reason: 'ohne diesen Fang waere die renderMatrix-Pruefung blind');
      expect(describeOverflows(overflows), contains('overflowed'));
    });

    testWidgets('meldet ohne Ueberlauf eine leere Liste', (tester) async {
      final overflows = await collectOverflows(() async {
        await pumpLocalized(tester, const SizedBox(width: 10, height: 10));
      });
      expect(overflows, isEmpty);
      expect(describeOverflows(overflows), isEmpty);
    });
  });

  group('renderMatrix', () {
    // 2 Locales x 2 Helligkeiten = vier Faelle; die Namen tragen die
    // Kombination.
    renderMatrix('reicht Kombination und Tokens durch', (tester, c) async {
      final erwartet =
          c.brightness == Brightness.light ? AppTokens.light : AppTokens.dark;
      // Vor dem Pump: statische Palette, damit Token-Tests ohne Widget laufen.
      expect(c.t, erwartet);
      expect(c.l10n, isA<AppLocalizations>());
      expect(() => c.context, throwsStateError);

      await c.pump(tester, const SizedBox());

      // Nach dem Pump: aus dem gemounteten Theme gelesen.
      expect(c.t, erwartet);
      expect(Localizations.localeOf(c.context), c.locale);
      expect(c.label, '${c.locale.languageCode}/${c.brightness.name}/1.0x');
    }, locales: const <Locale>[Locale('de'), Locale('en')]);

    // Negative case to the check above: with `skipOverflowCheck: true` a real
    // overflow must NOT fail the case. The spy forwards to the collector the
    // matrix installed, so the overflow reaches it — and is ignored there.
    renderMatrix('skipOverflowCheck laesst einen Ueberlauf durch',
        (tester, c) async {
      final collector = FlutterError.onError;
      var gemeldet = 0;
      FlutterError.onError = (details) {
        gemeldet++;
        collector?.call(details);
      };
      try {
        await c.pump(
          tester,
          const Row(
            children: <Widget>[
              SizedBox(
                width: 900,
                height: 10,
                child: ColoredBox(color: Color(0xFFFF0000)),
              ),
            ],
          ),
          surfaceSize: const Size(300, 600),
        );
      } finally {
        FlutterError.onError = collector;
      }
      expect(gemeldet, greaterThan(0),
          reason: 'dieser Fall muss wirklich ueberlaufen, sonst beweist er '
              'nichts');
      _ueberlaufFallLief = true;
    },
        brightnesses: const <Brightness>[Brightness.dark],
        skipOverflowCheck: true);

    test('der skipOverflowCheck-Negativfall wurde ausgefuehrt', () {
      expect(_ueberlaufFallLief, isTrue);
    });
  });
}
