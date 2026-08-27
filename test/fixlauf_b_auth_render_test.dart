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
import 'package:eatova/src/widgets/design/controls.dart';

import 'support/harness.dart';

// Fix run 2026-08-27, package B (F2-01/F8-01, F2-02, F2-04/F8-05, F2-06):
// the two auth screens follow the theme (light AND dark readable), render at
// 130 % and 200 % system font without RenderFlex overflow, use borderless
// soft-capsule fields, carry button semantics on every control and wire the
// password manager (AutofillGroup, finishAutofillContext, no autocorrect on
// e-mail fields).

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

/// Contract for a DISABLED primary action (owner: package H,
/// PrimaryActionButton): the surface is no longer plain `ink`, or the button
/// sits under an opacity below 1. Checks the rendered widgets, not the API.
bool _wirktDeaktiviert(WidgetTester tester, Key key, AppTokens t) {
  final button = find.byKey(key);
  final materialAnders = find
      .descendant(of: button, matching: find.byType(Material))
      .evaluate()
      .map((e) => e.widget as Material)
      .any((m) => m.color != null && m.color != t.ink);
  final containerAnders = find
      .descendant(of: button, matching: find.byType(DecoratedBox))
      .evaluate()
      .map((e) => (e.widget as DecoratedBox).decoration)
      .whereType<BoxDecoration>()
      .any((d) => d.color != null && d.color != t.ink);
  bool gedimmt(Finder f) =>
      f.evaluate().any((e) => (e.widget as Opacity).opacity < 1);
  bool animiertGedimmt(Finder f) =>
      f.evaluate().any((e) => (e.widget as AnimatedOpacity).opacity < 1);
  final opacityAnders = gedimmt(find.descendant(
          of: button, matching: find.byType(Opacity))) ||
      gedimmt(find.ancestor(of: button, matching: find.byType(Opacity))) ||
      animiertGedimmt(find.descendant(
          of: button, matching: find.byType(AnimatedOpacity))) ||
      animiertGedimmt(
          find.ancestor(of: button, matching: find.byType(AnimatedOpacity)));
  return materialAnders || containerAnders || opacityAnders;
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

void main() {
  group('F2-01/F8-01 Theme-folgend, hell UND dunkel, ohne Overflow', () {
    for (final brightness in Brightness.values) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        testWidgets('AuthScreen $brightness @$scale (Login + Registrieren)',
            (tester) async {
          _pinPhone(tester);
          final overflows = await _overflowsDuring(() async {
            await _pumpAuth(tester, brightness, textScale: scale);
            final scaffold = tester
                .widget<Scaffold>(find.byKey(const ValueKey('screen-auth')));
            expect(scaffold.backgroundColor, _tokensFor(brightness).bg,
                reason: 'der Grund folgt dem Modus, keine feste Dunkelbuehne');

            await tester.ensureVisible(
                find.byKey(const ValueKey('auth-toggle-register')));
            await tester
                .tap(find.byKey(const ValueKey('auth-toggle-register')));
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('auth-name-field')),
                findsOneWidget);
            await tester
                .ensureVisible(find.byKey(const ValueKey('auth-submit')));
            await tester.pumpAndSettle();
          });
          expect(tester.takeException(), isNull);
          expect(overflows, isEmpty, reason: overflows.join('\n'));
        });

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
    }

    testWidgets('Titel und Text des Code-Screens tragen ink des Modus',
        (tester) async {
      _pinPhone(tester);
      for (final brightness in Brightness.values) {
        await _pumpCode(tester, brightness, flow: AuthCodeFlow.signup);
        final title = tester.widget<Text>(find.text(deL10n.authCodeTitleCode));
        expect(title.style?.color, _tokensFor(brightness).ink,
            reason: '$brightness: sonst schwarz auf schwarz (F2-01)');
      }
    });
  });

  group('F2-02 rahmenlose Felder', () {
    for (final brightness in Brightness.values) {
      testWidgets(
          '$brightness: kein Border, Tiefe via Schatten, Fokus = fieldFocus',
          (tester) async {
        _pinPhone(tester);
        final tokens = _tokensFor(brightness);
        await _pumpAuth(tester, brightness);

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
    }

    testWidgets('Code-Screen nutzt dasselbe Feld-Widget', (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.light, flow: AuthCodeFlow.recovery);
      final deco = _capsuleOf(tester, const ValueKey('code-email-field'));
      expect(deco.border, isNull);
      expect(deco.boxShadow, isNotEmpty);
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

    testWidgets('OTP-Feld traegt AutofillHints.oneTimeCode und einen Punkt '
        'pro Ziffer', (tester) async {
      _pinPhone(tester);
      await _pumpCode(tester, Brightness.dark, flow: AuthCodeFlow.signup);
      final code =
          tester.widget<TextField>(find.byKey(const ValueKey('code-field')));
      expect(code.autofillHints, contains(AutofillHints.oneTimeCode));
      expect(code.decoration?.hintText, hasLength(8));
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

    testWidgets('laufendes OAuth: deaktivierte CTA sieht deaktiviert aus '
        '(Kontrakt Paket H)', (tester) async {
      _pinPhone(tester);
      final repo = _HangingOAuthRepository();
      addTearDown(repo.dispose);
      await _pumpAuth(tester, Brightness.light, repo: repo);
      await tester.tap(find.byKey(const ValueKey('auth-google-oauth')));
      await tester.pump();

      expect(
        _wirktDeaktiviert(tester, const ValueKey('auth-submit'),
            AppTokens.light),
        isTrue,
        reason: 'eine deaktivierte Primaeraktion darf nicht wie eine aktive '
            'aussehen (Flaeche != ink oder Opacity < 1)',
      );
    });

    testWidgets('Sperre nach fuenf falschen Codes: CTA deaktiviert UND '
        'gedimmt (Kontrakt Paket H)', (tester) async {
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
        expect(_wirktDeaktiviert(tester, primary, AppTokens.dark), isTrue,
            reason: 'gesperrt muss auch so aussehen');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    });
  });
}
