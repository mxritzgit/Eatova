import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/services/local_cache.dart'
    show InMemoryKeyValueStore;
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/auth_controls.dart';
import 'package:eatova/src/widgets/auth/auth_entry_header.dart';
import 'package:eatova/src/widgets/design/controls.dart';

import '../support/harness.dart';

// The two auth screens (fix run 2026-08-27, package B): they follow the theme
// (light AND dark readable), walk every step at 200 % system font without
// RenderFlex overflow, use borderless soft-capsule fields, carry button
// semantics on every control and wire the password manager (AutofillGroup,
// finishAutofillContext, no autocorrect on e-mail fields).
//
// 1.0x layout and the real-font login/signup/code pages at 1.0 and 2.0 live in
// auth_entry_design_test.dart; this suite keeps the 2.0 walk through all three
// recovery steps, which nothing else takes.

AppTokens _tokensFor(Brightness b) =>
    b == Brightness.light ? AppTokens.light : AppTokens.dark;

/// Viewport only. The text scale does NOT belong here: the harness writes
/// `textScaler` into its own MediaQuery unconditionally, so a
/// `platformDispatcher.textScaleFactorTestValue` set before the pump is
/// overwritten and measures nothing. It goes to `_pumpScreen` instead.
void _pinPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Collects overflow errors during [body]; other errors keep their handler.
Future<List<String>> _overflowsDuring(Future<void> Function() body) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      overflows.add(details.summary.toString());
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  return overflows;
}

/// Both screens bring their own Scaffold, so the harness adds none. The text
/// scale goes through the harness because it owns the MediaQuery.
Future<void> _pumpScreen(
  WidgetTester tester,
  Brightness brightness,
  Widget screen, {
  double textScale = 1.0,
}) async {
  await pumpLocalized(
    tester,
    screen,
    reducedMotion: false,
    brightness: brightness,
    textScale: textScale,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpAuth(
  WidgetTester tester,
  Brightness brightness, {
  AuthRepository? repo,
  double textScale = 1.0,
}) =>
    _pumpScreen(
      tester,
      brightness,
      AuthScreen(authRepository: repo ?? InMemoryAuthRepository()),
      textScale: textScale,
    );

Future<void> _pumpCode(
  WidgetTester tester,
  Brightness brightness, {
  required AuthCodeFlow flow,
  InMemoryAuthRepository? repo,
  double textScale = 1.0,
}) =>
    _pumpScreen(
      tester,
      brightness,
      AuthCodeScreen(
        authRepository: repo ?? InMemoryAuthRepository(),
        flow: flow,
        initialEmail: 'user@example.com',
      ),
      textScale: textScale,
    );

/// OAuth that never returns — keeps the screen in its busy state.
class _HangingOAuthRepository extends InMemoryAuthRepository {
  @override
  Future<void> signInWithOAuth(EatovaOAuthProvider provider) =>
      Completer<void>().future;
}

BoxDecoration _capsuleOf(WidgetTester tester, Key fieldKey) {
  final capsule = find
      .ancestor(
        of: find.byKey(fieldKey),
        matching: find.byType(AnimatedContainer),
      )
      .first;
  return tester.widget<AnimatedContainer>(capsule).decoration!
      as BoxDecoration;
}

Finder _textIn(Finder scope, String text) =>
    find.descendant(of: scope, matching: find.text(text));

/// Every visible edge line inside [scope]: decoration borders, the sides of
/// decoration, Material and ink shapes.
List<BorderSide> _visibleSides(WidgetTester tester, Finder scope) {
  Iterable<BorderSide> sides(Object? shape) => switch (shape) {
        OutlinedBorder(:final side) => [side],
        Border(:final top, :final right, :final bottom, :final left) => [
            top,
            right,
            bottom,
            left,
          ],
        BorderDirectional(:final top, :final start, :final bottom, :final end) =>
          [top, start, bottom, end],
        _ => const <BorderSide>[],
      };
  final found = <BorderSide>[];
  for (final element in find
      .descendant(of: scope, matching: find.byWidgetPredicate((_) => true))
      .evaluate()) {
    final widget = element.widget;
    if (widget is DecoratedBox) {
      found.addAll(sides(switch (widget.decoration) {
        ShapeDecoration(:final shape) => shape,
        BoxDecoration(:final border) => border,
        _ => null,
      }));
    } else if (widget is Material) {
      found.addAll(sides(widget.shape));
    } else if (widget is InkWell) {
      found.addAll(sides(widget.customBorder));
    }
  }
  return [
    for (final side in found)
      if (side.style != BorderStyle.none && side.width > 0 && side.color.a > 0)
        side,
  ];
}

/// The fill painted under [point] inside [scope]: every decoration whose box
/// covers it, composited in paint order over [ground].
Color _fillAt(WidgetTester tester, Finder scope, Offset point, Color ground) {
  var fill = ground;
  for (final element in find
      .descendant(of: scope, matching: find.byType(DecoratedBox))
      .evaluate()) {
    final box = element.renderObject! as RenderBox;
    if (!(box.localToGlobal(Offset.zero) & box.size).contains(point)) continue;
    final color = switch ((element.widget as DecoratedBox).decoration) {
      ShapeDecoration(:final color) || BoxDecoration(:final color) => color,
      _ => null,
    };
    if (color != null) fill = Color.alphaBlend(color, fill);
  }
  return fill;
}

void main() {
  group('F2-01/F8-01 Theme-folgend, hell UND dunkel, ohne Overflow', () {
    for (final brightness in Brightness.values) {
      // 2.0 is the WCAG cap and the tightest case.
      const scale = 2.0;
      testWidgets('AuthCodeScreen $brightness @$scale (alle drei Schritte)',
          (tester) async {
        _pinPhone(tester);
        final overflows = await _overflowsDuring(() async {
          await _pumpCode(tester, brightness,
              flow: AuthCodeFlow.recovery, textScale: scale);
          expect(find.byType(AppBar), findsNothing,
              reason: 'kein Material-AppBar mit fremder Flaeche');
          final scaffold = tester.widget<Scaffold>(
              find.byKey(const ValueKey('auth-code-screen')));
          expect(scaffold.backgroundColor, _tokensFor(brightness).bg);

          // e-mail -> code (at 200 % the CTA sits below the fold)
          const primary = ValueKey('code-primary');
          await tester.ensureVisible(find.byKey(primary));
          await tester.tap(find.byKey(primary));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('code-field')), findsOneWidget);

          // code -> password
          await tester.enterText(
              find.byKey(const ValueKey('code-field')), '48291357');
          await tester.ensureVisible(find.byKey(primary));
          await tester.tap(find.byKey(primary));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('code-password-field')),
              findsOneWidget);
        });
        expect(tester.takeException(), isNull);
        expect(overflows, isEmpty, reason: overflows.join('\n'));
      });
    }

    testWidgets('Grund und Titel folgen dem Modus', (tester) async {
      _pinPhone(tester);
      for (final brightness in Brightness.values) {
        await _pumpAuth(tester, brightness);
        final scaffold =
            tester.widget<Scaffold>(find.byKey(const ValueKey('screen-auth')));
        expect(scaffold.backgroundColor, _tokensFor(brightness).bg,
            reason: '$brightness: der Grund folgt dem Modus, keine feste '
                'Dunkelbuehne');

        await _pumpCode(tester, brightness, flow: AuthCodeFlow.signup);
        final title = tester.widget<Text>(find.text(deL10n.authCodeTitleCode));
        expect(title.style?.color, _tokensFor(brightness).ink,
            reason: '$brightness: sonst schwarz auf schwarz (F2-01)');
      }
    });
  });

  // The capsule's palette per brightness is FieldCapsule's own contract
  // (widgets/design/fixlauf_h_design_system_test.dart); here only that the
  // auth fields use it, in the non-default light palette.
  group('F2-02 rahmenlose Felder', () {
    testWidgets('kein Border, Tiefe via Schatten, Fokus = fieldFocus',
        (tester) async {
      _pinPhone(tester);
      final tokens = _tokensFor(Brightness.light);
      await _pumpAuth(tester, Brightness.light);

      const emailKey = ValueKey('auth-email-field');
      var deco = _capsuleOf(tester, emailKey);
      expect(deco.border, isNull, reason: 'kein Hairline-Rahmen');
      expect(deco.boxShadow, isNotEmpty, reason: 'Tiefe kommt vom Schatten');
      expect(deco.color, tokens.field);

      await tester.tap(find.byKey(emailKey));
      await tester.pumpAndSettle();
      deco = _capsuleOf(tester, emailKey);
      expect(deco.border, isNull, reason: 'auch im Fokus kein Ring');
      expect(deco.color, tokens.fieldFocus,
          reason: 'Fokus ist eine Flaechenaufhellung');
    });

    testWidgets('Code-Screen nutzt dasselbe Feld-Widget', (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.light, flow: AuthCodeFlow.recovery);
      final deco = _capsuleOf(tester, const ValueKey('code-email-field'));
      expect(deco.border, isNull);
      expect(deco.boxShadow, isNotEmpty);
    });
  });

  // Polish 2026-10-25: the mode switch and the Google pill lost their
  // hairlines. Without the accent edge the thumb's own fill has to carry the
  // selection boundary (WCAG 1.4.11, 3:1 against the track), and keyboard
  // focus has to brighten what it lands on.
  group('Modus-Umschalter und Google-Knopf ohne Ring', () {
    final selector = find.byType(AuthModeSelector);
    final google = find.byType(AuthSecondaryButton);

    for (final brightness in Brightness.values) {
      testWidgets('kein Rand, Auswahl >= 3:1 gegen die Spur ($brightness)',
          (tester) async {
        _pinPhone(tester);
        final t = _tokensFor(brightness);
        await _pumpAuth(tester, brightness);

        for (final scope in [selector, google]) {
          expect(_visibleSides(tester, scope), isEmpty,
              reason: '$brightness: keine Hairline, kein Ring');
        }
        Color fillUnder(String text) => _fillAt(tester, selector,
            tester.getCenter(_textIn(selector, text)), t.bg);
        final track = fillUnder(deL10n.authToggleActionRegister);
        final chosen = fillUnder(deL10n.authToggleActionLogin);
        expect(contrastRatio(chosen, track), greaterThanOrEqualTo(3.0),
            reason: '$brightness: der Daumen selbst traegt die Auswahl');
      });
    }

    testWidgets('Tastaturfokus hellt auf, in beiden Modi', (tester) async {
      _pinPhone(tester);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic);
      for (final brightness in Brightness.values) {
        final t = _tokensFor(brightness);
        // A fresh tree: the previous pass left the segment focused.
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpAuth(tester, brightness);
        final label = _textIn(selector, deL10n.authToggleActionRegister);
        Color fill() =>
            _fillAt(tester, selector, tester.getCenter(label), t.bg);
        final rest = fill();
        Focus.of(tester.element(label)).requestFocus();
        await tester.pumpAndSettle();
        expect(fill().computeLuminance(),
            greaterThan(rest.computeLuminance()),
            reason: '$brightness: Fokus hellt die Spur auf, kein Ring');
        expect(tester.widget<Text>(label).style?.color ??
                DefaultTextStyle.of(tester.element(label)).style.color,
            t.ink, reason: '$brightness: das Label wird zu ink');
      }
    });
  });

  group('F2-04/F8-05 Semantik und Trefferflaechen', () {
    testWidgets('AuthScreen: alle Controls sind Knoepfe mit Label',
        (tester) async {
      _pinPhone(tester);
      await _pumpAuth(tester, Brightness.light);

      expect(
        tester.getSemantics(find.byKey(const ValueKey('auth-google-oauth'))),
        isSemantics(isButton: true, label: deL10n.authGoogleCta),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('auth-submit'))),
        isSemantics(isButton: true, label: deL10n.authSubmitLogin),
      );
      final toggle =
          tester.getSemantics(find.byKey(const ValueKey('auth-toggle-register')));
      expect(toggle, isSemantics(isButton: true));
      expect(toggle.label, contains(deL10n.authToggleActionRegister));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('auth-forgot-password'))),
        isSemantics(isButton: true, label: deL10n.authForgotPasswordCta),
      );

      const eye = ValueKey('auth-toggle-password');
      expect(
        tester.getSemantics(find.byKey(eye)),
        isSemantics(isButton: true, label: deL10n.authShowPasswordTooltip),
      );
      final size = tester.getSize(find.byKey(eye));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(eye));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(eye)),
        isSemantics(isButton: true, label: deL10n.authHidePasswordTooltip),
      );
      expect(find.byTooltip(deL10n.authHidePasswordTooltip), findsOneWidget);

      // The wordmark is painted lettering plus a ring: one label, not "eat va".
      final mark = find.bySemanticsLabel('Eatova');
      expect(mark, findsOneWidget);
    });

    testWidgets('Code-Screen: Zurueck und Neuanfordern sind Knoepfe',
        (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.dark, flow: AuthCodeFlow.signup);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('auth-code-back'))),
        isSemantics(isButton: true, label: deL10n.authBackSemanticLabel),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('code-resend'))),
        isSemantics(isButton: true, label: deL10n.authCodeResendCta),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('code-primary'))),
        isSemantics(isButton: true, label: deL10n.authCodeVerifyCta),
      );
    });
  });

  group('F2-06 Autofill', () {
    testWidgets('E-Mail-Formular in einer AutofillGroup, E-Mail-Feld ohne '
        'Autokorrektur, Erfolg schliesst den Autofill-Kontext', (tester) async {
      _pinPhone(tester);
      final repo = InMemoryAuthRepository();
      addTearDown(repo.dispose);
      await _pumpAuth(tester, Brightness.dark, repo: repo);

      expect(find.byType(AutofillGroup), findsOneWidget);
      final email =
          tester.widget<TextField>(find.byKey(const ValueKey('auth-email-field')));
      expect(email.autocorrect, isFalse);
      expect(email.enableSuggestions, isFalse);
      expect(email.textCapitalization, TextCapitalization.none);
      expect(email.autofillHints, contains(AutofillHints.email));
      final password = tester
          .widget<TextField>(find.byKey(const ValueKey('auth-password-field')));
      expect(password.autofillHints, contains(AutofillHints.password));

      await tester.enterText(
          find.byKey(const ValueKey('auth-email-field')), 'moritz@example.com');
      await tester.enterText(
          find.byKey(const ValueKey('auth-password-field')), 'eatova123');
      tester.testTextInput.log.clear();
      await tester.tap(find.byKey(const ValueKey('auth-submit')));
      await tester.pumpAndSettle();

      expect(repo.currentUser?.email, 'moritz@example.com');
      expect(
        tester.testTextInput.log
            .any((call) => call.method == 'TextInput.finishAutofillContext'),
        isTrue,
        reason: 'sonst speichert der Passwort-Manager die Zugangsdaten nicht',
      );
    });

    testWidgets('Code-Screen: E-Mail-Feld traegt den E-Mail-Autofill-Hint',
        (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.dark, flow: AuthCodeFlow.recovery);
      final email = tester
          .widget<TextField>(find.byKey(const ValueKey('code-email-field')));
      expect(email.autofillHints, contains(AutofillHints.email));
      expect(email.autocorrect, isFalse);
      expect(find.byType(AutofillGroup), findsOneWidget);
    });

    testWidgets('OTP-Feld traegt AutofillHints.oneTimeCode und eine Zelle '
        'pro Ziffer', (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.dark, flow: AuthCodeFlow.signup);
      final code =
          tester.widget<TextField>(find.byKey(const ValueKey('code-field')));
      expect(code.autofillHints, contains(AutofillHints.oneTimeCode));

      // The real field is transparent; the eight cells draw the code. How an
      // empty cell looks (dot, caret) is design, not pinned here.
      final cells = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CodeCell',
      );
      expect(cells, findsNWidgets(8));
      for (var i = 0; i < 8; i++) {
        expect(
          find.descendant(of: cells.at(i), matching: find.byType(Text)),
          findsNothing,
          reason: 'Cell $i is empty before typing.',
        );
      }

      await tester.enterText(find.byKey(const ValueKey('code-field')), '4829');
      await tester.pumpAndSettle();
      const typed = '4829';
      for (var i = 0; i < 8; i++) {
        final shown = find.descendant(
          of: cells.at(i),
          matching: find.byType(Text),
        );
        if (i < typed.length) {
          expect(shown, findsOneWidget, reason: 'Cell $i shows a digit.');
          expect(tester.widget<Text>(shown).data, typed[i]);
        } else {
          expect(shown, findsNothing, reason: 'Cell $i stays empty.');
        }
      }
      for (final digit in typed.split('')) {
        expect(
          find.descendant(of: cells, matching: find.text(digit)),
          findsOneWidget,
        );
      }
    });
  });

  group('Fix-Runde 1', () {
    testWidgets('Felder tragen ein gesprochenes Label, nicht nur den Hint',
        (tester) async {
      _pinPhone(tester);
      await _pumpAuth(tester, Brightness.light);
      // An empty TextField merges its hint into the label ("E-Mail\nhint"),
      // so the node label must START with the spoken name.
      String labelOf(Key key) => tester.getSemantics(find.byKey(key)).label;
      expect(labelOf(const ValueKey('auth-email-field')),
          startsWith(deL10n.authFieldEmailLabel));
      expect(labelOf(const ValueKey('auth-password-field')),
          startsWith(deL10n.authFieldPasswordLabel));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('auth-email-field'))),
        isSemantics(isTextField: true),
      );

      await _pumpCode(tester, Brightness.light, flow: AuthCodeFlow.signup);
      expect(labelOf(const ValueKey('code-field')),
          startsWith(deL10n.authCodeFieldLabel),
          reason: 'sonst hoert ein Screenreader nur die Punkte des Hints');
    });

    testWidgets('laufendes OAuth: Primaer-CTA ist deaktiviert', (tester) async {
      _pinPhone(tester);
      final repo = _HangingOAuthRepository();
      addTearDown(repo.dispose);
      await _pumpAuth(tester, Brightness.light, repo: repo);
      await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
      await tester.pump();

      const submit = ValueKey('auth-submit');
      expect(tester.widget<PrimaryActionButton>(find.byKey(submit)).onTap,
          isNull,
          reason: 'AuthPrimaryButton reicht enabled:false als onTap:null '
              'durch');
      expect(tester.getSemantics(find.byKey(submit)),
          isSemantics(isButton: true, isEnabled: false));
    });

    // How a disabled PrimaryActionButton dims is the button's own contract
    // (widgets/design/dialogs_test.dart).
    testWidgets('Sperre nach fuenf falschen Codes: CTA deaktiviert',
        (tester) async {
      _pinPhone(tester);
      final repo = InMemoryAuthRepository();
      addTearDown(repo.dispose);
      await withClock(Clock.fixed(DateTime(2026, 8, 27, 9)), () async {
        await _pumpScreen(
          tester,
          Brightness.dark,
          AuthCodeScreen(
            authRepository: repo,
            flow: AuthCodeFlow.signup,
            initialEmail: 'user@example.com',
            throttleStore: InMemoryKeyValueStore(),
          ),
        );

        const primary = ValueKey('code-primary');
        for (var versuch = 1; versuch <= 5; versuch++) {
          repo.verifyFails = true;
          await tester.enterText(
              find.byKey(const ValueKey('code-field')), '0000000$versuch');
          await tester.tap(find.byKey(primary));
          await tester.pumpAndSettle();
        }
        expect(find.text(deL10n.authCodeTooManyAttempts), findsOneWidget);
        expect(tester.widget<PrimaryActionButton>(find.byKey(primary)).onTap,
            isNull);
        expect(tester.getSemantics(find.byKey(primary)),
            isSemantics(isButton: true, isEnabled: false));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    });
  });
}
