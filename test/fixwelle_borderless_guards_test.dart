// Fix wave 2026-08-27 (Review G, gap a): borderless guards for the two
// capsules that had none — the weigh-in field (profile sheet) and the
// account-change code field. App-wide focus language: rest `field`, focus
// `fieldFocus`, error `fieldError`; never a hairline, never a focus ring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import 'support/harness.dart';

void _telefon(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The nearest decorated capsule around [inner] (FieldCapsule's container).
BoxDecoration _capsuleOf(WidgetTester tester, Finder inner) {
  final containers = find.ancestor(of: inner, matching: find.byType(Container));
  for (final element in containers.evaluate()) {
    final decoration = (element.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration;
    }
  }
  throw StateError('keine dekorierte Kapsel um $inner');
}

AppTokens _tokens(WidgetTester tester, Finder inner) =>
    AppTokens.of(tester.element(inner));

WeightLog _log() => WeightLog(
      entries: <WeightLogEntry>[
        for (var i = 0; i < 3; i++)
          WeightLogEntry(
            timestamp: DateTime(2026, 1, 1).add(Duration(days: i)),
            weightKg: 90 - i * 0.1,
          ),
      ],
    );

Future<void> _oeffneGewichtsSheet(
  WidgetTester tester,
  Brightness brightness,
) async {
  _telefon(tester);
  await pumpLocalized(
    tester,
    WeightCard(
      profile: const UserProfile(),
      log: _log(),
      onLogWeight: (_) {},
    ),
    brightness: brightness,
    padding: const EdgeInsets.all(20),
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('profile-log-weight')));
  await tester.pumpAndSettle();
}

Future<void> _oeffnePasswortCode(
  WidgetTester tester,
  Brightness brightness,
) async {
  _telefon(tester);
  final repo = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'u1', email: 'jonas@beispiel.de'),
  );
  addTearDown(repo.dispose);
  await pumpLocalized(
    tester,
    SettingsScreen(email: 'jonas@beispiel.de', authRepository: repo),
    brightness: brightness,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();

  final zeile = find.byKey(const ValueKey<String>('settings-change-password'));
  await tester.scrollUntilVisible(
    zeile,
    200,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('screen-settings')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(zeile);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Code anfordern'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final brightness in Brightness.values) {
    testWidgets(
        'Gewichtsfeld: rahmenlos, autofocus = fieldFocus, Ruhe = field, '
        'Fehler = fieldError ($brightness)', (tester) async {
      await _oeffneGewichtsSheet(tester, brightness);

      final input = find.byKey(const ValueKey('profile-weight-input'));
      final t = _tokens(tester, input);
      final feld = tester.widget<TextField>(input);
      expect(feld.decoration!.enabledBorder, InputBorder.none);
      expect(feld.decoration!.focusedBorder, InputBorder.none);
      expect(feld.decoration!.errorBorder, InputBorder.none);

      // autofocus: the sheet opens with the field focused -> lifted fill.
      expect(feld.focusNode?.hasFocus, isTrue);
      var capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'Hairline am Gewichtsfeld');
      expect(capsule.boxShadow, isNotEmpty, reason: 'Tiefe kommt vom Schatten');
      expect(capsule.color, t.fieldFocus);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull);
      expect(capsule.color, t.field);

      // Out of range (20..400 kg): error line below AND fieldError fill.
      await tester.enterText(input, '7.55');
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'auch im Fehlerfall kein Ring');
      expect(capsule.color, t.fieldError, reason: 'Fehler schlägt Fokus');
      expect(find.byKey(const ValueKey('profile-weight-error')), findsOneWidget);
    });

    testWidgets(
        'Code-Feld der Kontoänderung: rahmenlos, Ruhe = field, Fokus = '
        'fieldFocus, Fehler = fieldError ($brightness)', (tester) async {
      await _oeffnePasswortCode(tester, brightness);

      final input = find.byKey(const ValueKey<String>('password-change-code'));
      final t = _tokens(tester, input);
      final feld = tester.widget<TextField>(input);
      expect(feld.decoration!.enabledBorder, InputBorder.none);
      expect(feld.decoration!.focusedBorder, InputBorder.none);

      var capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'Hairline am Code-Feld');
      expect(capsule.boxShadow, isNotEmpty, reason: 'Tiefe kommt vom Schatten');
      expect(capsule.color, t.field);

      await tester.tap(input);
      await tester.pumpAndSettle();
      capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull, reason: 'im Fokus kein Ring');
      expect(capsule.color, t.fieldFocus, reason: 'Fokus = Flächen-Aufhellung');

      // Too short a code -> field error: line below AND fieldError fill.
      await tester.enterText(input, '12345');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Passwort jetzt ändern'));
      await tester.tap(find.text('Passwort jetzt ändern'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code hat 8 Ziffern.'), findsOneWidget);
      capsule = _capsuleOf(tester, input);
      expect(capsule.border, isNull);
      expect(capsule.color, t.fieldError);
    });
  }
}
