// The profile screen after the design refactor.
//
// Covers three things nothing else did:
//   * both display modes (the screen reads its colors from tokens),
//   * the steps format '<actual>/<goal>', which profile_route_refresh_test
//     relies on,
//   * the identity card invents no data (no PREMIUM, no "MEMBER SINCE" — the
//     design mock shows both, we have neither).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';

Widget _profile({
  UserProfile profile = const UserProfile(),
  WeightLog weightLog = const WeightLog(),
  int dailySteps = 1000,
  int dailyConsumedKcal = 900,
  VoidCallback? onEditProfile,
  VoidCallback? onOpenSettings,
  HealthAuthState healthAuthState = HealthAuthState.unknown,
}) {
  return ProfileScreen(
    name: 'Moritz Schneider',
    profile: profile,
    weightLog: weightLog,
    stats: LifetimeStats(mealsLogged: 12, weightLogs: 3, longestStreak: 4),
    dailyConsumedKcal: dailyConsumedKcal,
    dailySteps: dailySteps,
    healthAuthState: healthAuthState,
    healthLastFetch: null,
    onLogWeight: (_) {},
    onEditProfile: onEditProfile ?? () {},
    onOpenSettings: onOpenSettings ?? () {},
    onConnectHealth: () {},
    onRefreshHealth: () {},
  );
}

/// The start screen the profile is pushed from, so `profile-close`
/// (maybePop) actually has something to close.
Widget _opener(Widget screen) => Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          key: const ValueKey('open-profile'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => screen),
          ),
          child: const Text('öffnen'),
        ),
      ),
    );

/// Pumps the screen as its own route above that start screen.
Future<void> _pumpAsRoute(
  WidgetTester tester,
  Widget screen, {
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  Locale locale = const Locale('de'),
}) async {
  await pumpLocalized(
    tester,
    _opener(screen),
    brightness: brightness,
    locale: locale,
    textScale: textScale,
    safeArea: false,
  );
  await tester.tap(find.byKey(const ValueKey('open-profile')));
  await tester.pumpAndSettle();
}

void main() {
  // Both brightnesses AND both languages from one call; the old file declared
  // the same four cases in two separate loops.
  renderMatrix(
    'Das Profil rendert overflow-frei',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(tester, _opener(_profile()), safeArea: false);
      await tester.tap(find.byKey(const ValueKey('open-profile')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
      expect(find.text(c.l10n.profileTitle), findsOneWidget);
      expect(find.text('Moritz Schneider'), findsOneWidget);
      // The last section heading, in the language of this case.
      expect(find.text(c.l10n.profileSectionConnections), findsOneWidget);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
  );

  testWidgets('der Kopf traegt Zurueck-Knopf und Zahnrad', (tester) async {
    pinPhoneViewport(tester);
    var einstellungen = 0;
    var ziele = 0;
    await _pumpAsRoute(
      tester,
      _profile(
        onOpenSettings: () => einstellungen++,
        onEditProfile: () => ziele++,
      ),
    );

    // The gear opens SETTINGS, not the goals page; both once hung on the same
    // callback and the settings were effectively unreachable.
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();
    expect(einstellungen, 1);
    expect(ziele, 0, reason: 'das Zahnrad darf NICHT auf die Ziele fuehren');

    // And the back button closes the route.
    await tester.tap(find.byKey(const ValueKey('profile-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsNothing);
  });

  // The account block was removed because it duplicated the settings, so the
  // six rows must NOT be here. `test/settings_erreichbarkeit_test.dart` pins
  // their counterparts in the settings so the removal is not a silent loss.
  testWidgets('der Block „Daten & Konto" steht nicht mehr im Profil',
      (tester) async {
    pinPhoneViewport(tester);
    await _pumpAsRoute(tester, _profile());

    for (final key in <String>[
      'profile-action-edit',
      'profile-action-reset',
      'profile-action-export',
      'profile-action-about',
      'profile-action-logout',
      'profile-action-delete',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.text('DATEN & KONTO'), findsNothing);
    expect(find.text('Daten & Konto'), findsNothing);
    // The day-reset action is gone from the whole app, here and on the goals
    // page (`settings-reset-day`).
    expect(find.text('Tagesdaten zurücksetzen'), findsNothing);
    // The last section is now Connections, followed only by the wordmark and
    // version.
    expect(find.text('Verbindungen'), findsOneWidget);
  });

  testWidgets('die Bearbeiten-Knoepfe an Plan- und Zielkarte tragen die Ziele',
      (tester) async {
    // `profile-action-edit` went with the account block, so the route to the
    // goals page now hangs solely on these two buttons (plus
    // `settings-open-goals`).
    pinPhoneViewport(tester);
    var editCalls = 0;
    await _pumpAsRoute(tester, _profile(onEditProfile: () => editCalls++));

    for (final key in const <String>[
      'profile-goalplan-edit',
      'profile-edit-goals',
    ]) {
      final knopf = find.byKey(ValueKey(key));
      await tester.ensureVisible(knopf);
      await tester.pumpAndSettle();
      await tester.tap(knopf);
      await tester.pumpAndSettle();
    }
    expect(editCalls, 2);
  });

  testWidgets(
      'die Schritte-Zeile rendert EIN Text-Widget im Format <ist>/<soll>',
      (tester) async {
    pinPhoneViewport(tester);
    await _pumpAsRoute(tester, _profile(dailySteps: 1000));

    // Findable without scrolling: the screen builds eagerly
    // (SingleChildScrollView, not ListView), which
    // profile_route_refresh_test relies on.
    expect(find.text('1000/8000'), findsOneWidget);
    expect(find.text('1000 / 8000'), findsNothing);
    // The calories row beside it uses the same notation.
    expect(find.text('900/2200'), findsOneWidget);
  });

  testWidgets('die Identitaetskarte erfindet keine Daten', (tester) async {
    pinPhoneViewport(tester);
    await _pumpAsRoute(tester, _profile());

    expect(find.text('PREMIUM'), findsNothing);
    expect(find.textContaining('MEMBER SINCE'), findsNothing);
    expect(find.textContaining('Seit 20'), findsNothing);
    // Instead the two fields that really exist. The goal label also appears on
    // the plan card below, so search inside the identity card specifically.
    expect(
      find.descendant(
        of: find.byType(IdentityCard),
        matching: find.text('Gewicht halten'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(IdentityCard),
        matching: find.text('Kaum aktiv'),
      ),
      findsOneWidget,
    );
  });

  // The profile sheets are where a fixed sheet height meets large system text
  // — the break point from §5 of the contract. Two of the original four cases
  // moved to `test/settings_screen_render_test.dart` with their sheets.
  for (final sheet in <({String name, String key, String? tooltip})>[
    (name: 'Gewicht loggen', key: 'profile-log-weight', tooltip: null),
    (name: 'BMI-Erklärung', key: '', tooltip: 'BMI-Erklärung'),
  ]) {
    testWidgets('Sheet „${sheet.name}" oeffnet bei textScaler 2.0 ohne '
        'Overflow', (tester) async {
      pinPhoneViewport(tester);
      final overflows = await collectOverflows(() async {
        await _pumpAsRoute(tester, _profile(), textScale: 2.0);
        final oeffner = sheet.tooltip != null
            ? find.byTooltip(sheet.tooltip!)
            : find.byKey(ValueKey(sheet.key));
        await tester.ensureVisible(oeffner);
        await tester.pumpAndSettle();
        await tester.tap(oeffner);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
    });
  }

  // The dense variant (target weight, sparkline, health card) at double font
  // size — a fixture the matrix above deliberately does not carry.
  renderMatrix(
    'Das gefuellte Profil rendert bei doppelter Schrift overflow-frei',
    (tester, c) async {
      pinPhoneViewport(tester);
      await c.pump(
        tester,
        _opener(
          _profile(
            profile: const UserProfile(
              weightKg: 78,
              targetWeightKg: 68,
              weightGoal: WeightGoal.lose05kg,
              activityLevel: ActivityLevel.athlete,
            ),
            weightLog: WeightLog(
              entries: <WeightLogEntry>[
                WeightLogEntry(
                  timestamp: DateTime(2026, 7, 1),
                  weightKg: 80.4,
                ),
                WeightLogEntry(
                  timestamp: DateTime(2026, 8, 1),
                  weightKg: 77.8,
                ),
              ],
            ),
            healthAuthState: HealthAuthState.unverified,
            dailySteps: 12345,
          ),
        ),
        safeArea: false,
      );
      await tester.tap(find.byKey(const ValueKey('open-profile')));
      await tester.pumpAndSettle();

      // Scroll to the end so the lower cards actually lay out. The anchor is
      // the health card's connect button, the page's last control (visible at
      // `unverified`).
      await tester.ensureVisible(
        find.byKey(const ValueKey('profile-health-connect')),
      );
      await tester.pumpAndSettle();
    },
    brightnesses: const <Brightness>[Brightness.dark],
    textScales: const <double>[2.0],
  );
}
