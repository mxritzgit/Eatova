import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/widgets/design/sheets.dart' show SheetHandle;

import 'support/harness.dart';

// The two account-change sheets could be swiped away mid-flow (Review
// 2026-08-29, P4-06).
//
// Both open through `showEatovaSheet` with the defaults isDismissible: true /
// enableDrag: true, and the WHOLE progress lives in the sheet's State —
// including `_altBestaetigt`, whose own comment says why: "GoTrue burns a
// confirmed code, so without remembering this a typo in the SECOND code would
// make the whole flow unrecoverable." A swipe, or a tap beside the sheet while
// dismissing the keyboard, threw away a code that was ALREADY SPENT
// server-side — and the mail quota is shared by the whole project.
//
// The framework routes the three close paths differently, which is why each
// gets its own case:
//   barrier tap → ModalBarrier.handleDismiss → Navigator.maybePop → PopScope
//   drag        → BottomSheet._handleDragEnd → onClosing → Navigator.pop,
//                 which asks NOBODY — hence SheetDismissGuard
//   handle      → Material's own handle pops the same way, above any guard in
//                 the sheet, hence `dragHandle: false` + the sheet's own
//                 SheetHandle

/// Lets the FIRST `confirmEmailChange` through and rejects the second — the
/// state the finding is about: one code burned, the flow still open.
class _ZweiterCodeScheitert extends InMemoryAuthRepository {
  _ZweiterCodeScheitert({super.initialUser});

  int _aufrufe = 0;

  @override
  Future<void> confirmEmailChange({
    required String email,
    required String code,
  }) async {
    _aufrufe++;
    if (_aufrufe == 2) {
      throw const AuthException('Token has expired or is invalid');
    }
    return super.confirmEmailChange(email: email, code: code);
  }
}

Finder get _mailSheet => find.byKey(const ValueKey<String>('email-change-sheet'));
Finder get _passwortSheet =>
    find.byKey(const ValueKey<String>('password-change-sheet'));
Finder get _dialog =>
    find.byKey(const ValueKey<String>('account-change-discard-dialog'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  InMemoryAuthRepository baueRepo({InMemoryAuthRepository? eigen}) {
    final repo = eigen ??
        InMemoryAuthRepository(
          initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
        );
    addTearDown(repo.dispose);
    return repo;
  }

  Future<void> pump(WidgetTester tester, AuthRepository repo) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLocalized(
      tester,
      SettingsScreen(email: 'alt@eatova.de', authRepository: repo),
      brightness: Brightness.light,
      scaffold: false,
      safeArea: false,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tippe(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> schreibe(
    WidgetTester tester,
    String schluessel,
    String text,
  ) async {
    await tester.enterText(find.byKey(ValueKey<String>(schluessel)), text);
    await tester.pumpAndSettle();
  }

  /// Top edge of the open sheet — the barrier sits above it.
  Offset sheetOben(WidgetTester tester) => tester.getTopLeft(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Material),
            )
            .first,
      );

  /// Path 1: the tap beside the sheet that dismisses the keyboard.
  Future<void> tippeAufBarriere(WidgetTester tester) async {
    final oben = sheetOben(tester).dy;
    expect(oben, greaterThan(4),
        reason: 'ohne Barriere gaebe es nichts zu tippen');
    await tester.tapAt(Offset(196, oben > 48 ? oben - 40 : oben / 2));
    await tester.pumpAndSettle();
  }

  /// Path 2/3: the swipe down, taken exactly where the handle sits (top 24 px
  /// of the sheet) — the gesture that used to pop past every guard.
  Future<void> wischeWeg(WidgetTester tester) async {
    expect(find.byType(SheetHandle), findsOneWidget,
        reason: 'ohne eigenen Griff popt der Zug an Materials Griff an '
            'PopScope vorbei (sheets.dart)');
    await tester.flingFrom(
      Offset(196, sheetOben(tester).dy + 12),
      const Offset(0, 400),
      2000,
    );
    await tester.pumpAndSettle();
  }

  /// Opens the email change up to the two-code step, with the first code
  /// CONFIRMED (server-side burned) and the second rejected.
  Future<_ZweiterCodeScheitert> oeffneMitVerbranntemCode(
    WidgetTester tester,
  ) async {
    final repo = _ZweiterCodeScheitert(
      initialUser: const EatovaUser(id: 'u1', email: 'alt@eatova.de'),
    );
    baueRepo(eigen: repo);
    await pump(tester, repo);
    await tippe(tester, find.byKey(const ValueKey<String>(
        'settings-change-email')));
    await schreibe(tester, 'email-change-new-address', 'neu@eatova.de');
    await tippe(tester, find.text('Codes anfordern'));
    await schreibe(tester, 'email-change-code-old', '11111111');
    await schreibe(tester, 'email-change-code-new', '22222222');
    await tippe(tester, find.text('Adresse jetzt ändern'));

    // Precondition of the whole suite: exactly this half-finished state.
    expect(
      tester
          .widget<TextField>(
              find.byKey(const ValueKey<String>('email-change-code-old')))
          .enabled,
      isFalse,
      reason: 'der erste Code ist bestaetigt und damit verbraucht',
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    return repo;
  }

  /// Opens the password change up to the code step (one mail spent).
  Future<InMemoryAuthRepository> oeffnePasswortSchritt2(
    WidgetTester tester,
  ) async {
    final repo = baueRepo();
    await pump(tester, repo);
    await tippe(tester,
        find.byKey(const ValueKey<String>('settings-change-password')));
    await tippe(tester, find.text('Code anfordern'));
    expect(find.byKey(const ValueKey<String>('password-change-code')),
        findsOneWidget);
    return repo;
  }

  group('P4-06 — der Zwei-Code-Schritt ueberlebt einen Wisch', () {
    testWidgets(
        'ein Wisch verliert den bereits bestaetigten Code NICHT, sondern '
        'fragt nach', (tester) async {
      await oeffneMitVerbranntemCode(tester);

      await wischeWeg(tester);

      expect(_mailSheet, findsOneWidget,
          reason: 'ein serverseitig verbrannter Code darf nicht an einer '
              'Wischgeste haengen');
      expect(_dialog, findsOneWidget);
      expect(find.text(deL10n.settingsAccountDiscardBodyConfirmed),
          findsOneWidget,
          reason: 'die Warnung muss sagen, was wirklich verloren geht');

      // "Weiter" leaves every bit of progress in place.
      await tippe(tester,
          find.byKey(const ValueKey<String>('account-change-discard-keep')));
      expect(_dialog, findsNothing);
      expect(_mailSheet, findsOneWidget);
      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey<String>('email-change-code-old')))
            .enabled,
        isFalse,
        reason: 'der erste Code bleibt bestaetigt',
      );
      expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey<String>('email-change-code-new')))
            .controller!
            .text,
        '22222222',
        reason: 'und der getippte zweite Code steht noch da',
      );
    });

    testWidgets('ein Tap neben das Sheet fragt genauso nach', (tester) async {
      await oeffneMitVerbranntemCode(tester);

      await tippeAufBarriere(tester);

      expect(_mailSheet, findsOneWidget);
      expect(_dialog, findsOneWidget);
    });

    testWidgets('erst „Abbrechen" im Dialog schliesst das Sheet wirklich',
        (tester) async {
      await oeffneMitVerbranntemCode(tester);

      await wischeWeg(tester);
      await tippe(tester,
          find.byKey(const ValueKey<String>('account-change-discard-confirm')));

      expect(_mailSheet, findsNothing);
      expect(_dialog, findsNothing);
      expect(find.text('E-Mail-Adresse geändert.'), findsNothing,
          reason: 'ein abgebrochener Vorgang ist kein erfolgreicher');
    });

    testWidgets('zwei Wische stapeln keine zwei Dialoge', (tester) async {
      await oeffneMitVerbranntemCode(tester);

      await wischeWeg(tester);
      await wischeWeg(tester);

      expect(_dialog, findsOneWidget);
    });

    testWidgets(
        'der Schliessen-Knoten fuer Screenreader bleibt — und fragt auch nach',
        (tester) async {
      // `dragHandle: false` nimmt Materials Griff samt seiner
      // Dismiss-Semantik weg. Ohne Ersatz haette ein TalkBack-Nutzer keinen
      // Weg mehr aus dem Sheet.
      final semantik = tester.ensureSemantics();
      await oeffneMitVerbranntemCode(tester);

      final knoten = find.semantics.byLabel('Schließen');
      expect(knoten, findsOneWidget);
      tester.semantics.performAction(knoten, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(_mailSheet, findsOneWidget);
      expect(_dialog, findsOneWidget,
          reason: 'der Ersatzgriff geht ueber maybePop, also durch den Guard');
      semantik.dispose();
    });
  });

  group('P4-06 — der Schritt VOR dem ersten Code bleibt frei wegwischbar', () {
    testWidgets('das Mail-Sheet im Adress-Schritt schliesst ohne Rueckfrage',
        (tester) async {
      // Nothing was spent yet, so a guard here would only be in the way.
      final repo = baueRepo();
      await pump(tester, repo);
      await tippe(tester,
          find.byKey(const ValueKey<String>('settings-change-email')));
      expect(_mailSheet, findsOneWidget);

      await wischeWeg(tester);

      expect(_dialog, findsNothing);
      expect(_mailSheet, findsNothing);
    });
  });

  group('P4-06 — auch das Passwort-Sheet haelt seinen Code fest', () {
    testWidgets('ein Wisch im Code-Schritt fragt nach', (tester) async {
      await oeffnePasswortSchritt2(tester);

      await wischeWeg(tester);

      expect(_passwortSheet, findsOneWidget);
      expect(_dialog, findsOneWidget);
      expect(find.text(deL10n.settingsAccountDiscardBody), findsOneWidget,
          reason: 'hier ist noch kein Code bestaetigt — der mildere Text');
    });

    testWidgets('im Anforderungs-Schritt schliesst es sofort', (tester) async {
      final repo = baueRepo();
      await pump(tester, repo);
      await tippe(tester,
          find.byKey(const ValueKey<String>('settings-change-password')));
      expect(_passwortSheet, findsOneWidget);

      await wischeWeg(tester);

      expect(_dialog, findsNothing);
      expect(_passwortSheet, findsNothing);
    });
  });
}
