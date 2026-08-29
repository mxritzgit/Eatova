// Goals -> Today flow: change body data, activity and pace on the goals page,
// save, and watch the Today tab's hero adopt the new daily target. Then set the
// target by hand and prove the F7-01 mechanics end to end: with
// `profiles.manual_energy` on, the hero says "manual", a later weight change no
// longer moves the number — and the flag REACHES THE SERVER ROW.
//
// Runs on the real `EatovaApp`, now over a real `EatovaSync` on a fake
// PostgREST (`EatovaApp.syncBuilder`). Before that seam existed the app always
// landed in preview mode (`sync == null`), where `applySettings` returns at
// home_store_profile.dart before cache write and outbox op — so "manual_energy
// is persisted, not reconstructed" could only ever check an in-memory field.
//
// The device locale is pinned to English — flow tests run in English and the
// assertions resolve their texts through `enL10n`, never through hard-coded
// sentences.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_texts.dart' show kcalThousands;
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/kcal_calculator.dart';
import 'package:eatova/src/widgets/design/design.dart' show AppToggle;

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

/// The server row the returning user boots from (78 kg, sedentary, maintain,
/// live mode, onboarding done).
///
/// Written through `applyLiveGoals` on purpose: `ProfileSync.load` heals a row
/// whose goals no longer match the calculator and would then queue a
/// write-back — a second profiles write that has nothing to do with this flow.
///
/// The target weight is explicit and below every weight this flow types (90,
/// later 70): since P9-08 the goals page rejects a target that contradicts the
/// chosen direction, and the default 78 kg would collide with the deficit goal
/// at step 4. Target weight feeds only the forecast, never `calculate`, so no
/// number asserted here moves.
final UserProfile _startProfil = const KcalCalculator().applyLiveGoals(
  const UserProfile(onboardingCompleted: true, targetWeightKg: 65),
);

/// Manual target, deliberately far from every computed value so a stale hero
/// cannot pass by accident. Inside the DB bounds (800..7000).
const int _manuellesZiel = 1750;

/// The Today hero's goal line, verbatim.
String _heuteZielText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('today-kcal-goal')))
    .data!;

String _erwartet(int kcal) =>
    enL10n.todayKcalGoalLabel(kcalThousands(kcal, enL10n));

HomeStore _storeOf(WidgetTester tester) =>
    (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;

/// Bounded settle instead of `pumpAndSettle`.
///
/// A shell WITH sync never settles: the welcome gate orbits its comet with
/// `repeat()` and every progress indicator on the boot path animates forever.
Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps until [finder] matches; fails with [was] instead of hanging.
Future<void> _warteAuf(
  WidgetTester tester,
  Finder finder,
  String was, {
  int maxFrames = 900,
}) async {
  for (var i = 0; i < maxFrames && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget, reason: '$was erscheint nicht');
  await _settle(tester);
}

/// Food tab -> settings -> "Profile & Goals".
///
/// The settings page is a lazy [ListView], so the row is dragged into the
/// build range first and only then scrolled into view — `tap` needs a hit
/// target, `findsOneWidget` does not.
Future<void> _oeffneZiele(WidgetTester tester) async {
  await _tippe(tester, find.byKey(const ValueKey('nav-Food')));
  await _tippe(tester, find.byKey(const ValueKey('topbar-settings')));
  expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);

  final zeile = find.byKey(const ValueKey('settings-open-goals'));
  if (zeile.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      zeile,
      find.byKey(const ValueKey('screen-settings')),
      const Offset(0, -150),
    );
  }
  await _tippe(tester, zeile);
  expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
}

/// Saves the goals page and closes settings, so the shell is visible again.
///
/// The settings list is still scrolled down from [_oeffneZiele], so its header
/// back button has to be dragged back into the build range first.
Future<void> _speichernUndSchliessen(WidgetTester tester) async {
  await _tippe(tester, find.byKey(const ValueKey('settings-save')));
  expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget,
      reason: 'Speichern poppt zurueck auf die Einstellungen');

  final zurueck = find.byKey(const ValueKey('settings-back'));
  if (zurueck.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      zurueck,
      find.byKey(const ValueKey('screen-settings')),
      const Offset(0, 200),
    );
  }
  await _tippe(tester, zurueck);
}

/// Scrolls [finder] into view, then taps it.
Future<void> _tippe(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

/// Opens a picker sheet from [rowKey] and takes the option [optionKey].
Future<void> _waehle(
  WidgetTester tester,
  String rowKey,
  String optionKey,
) async {
  await _tippe(tester, find.byKey(ValueKey(rowKey)));
  final option = find.byKey(ValueKey(optionKey));
  expect(option, findsOneWidget, reason: '$optionKey fehlt im Picker');
  await _tippe(tester, option);
}

Future<String> _heuteTab(WidgetTester tester) async {
  await _tippe(tester, find.byKey(const ValueKey('nav-Heute')));
  expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);
  return _heuteZielText(tester);
}

bool _manuellSchalter(WidgetTester tester) => tester
    .widget<AppToggle>(find.byKey(const ValueKey('settings-manual-energy')))
    .value;

String _feld(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// What the server row says about the manual mode — `null` while no profile
/// write has landed at all.
({bool manual, int kcal})? _serverProfil(FixlaufServer server) {
  final row = server.profileRow;
  if (row == null) return null;
  return (
    manual: row['manual_energy'] as bool,
    kcal: (row['daily_kcal_goal'] as num).toInt(),
  );
}

void main() {
  // Rechner-Modus: goal follows body data, activity and pace.
  final rechnerProfil = _startProfil.copyWith(
    weightKg: 90,
    activityLevel: ActivityLevel.moderate,
    weightGoal: WeightGoal.lose05kg,
  );
  final rechnerZiel = const KcalCalculator().calculate(rechnerProfil);
  // Same profile at 70 kg — the number the manual mode must NOT jump to.
  final leichteresZiel = const KcalCalculator()
      .calculate(rechnerProfil.copyWith(weightKg: 70));

  testWidgetsRobust(
      'Ziele: Rechner-Modus landet auf Heute, Manuell friert das Ziel ein',
      (WidgetTester tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    final server = FixlaufServer()..profileRow = serverProfileRow(_startProfil);
    // NOT disposed in a tearDown: `SupabaseClient.dispose()` awaits its REST,
    // functions and isolate layers, and a tearDown runs OUTSIDE the fake-async
    // zone, so that await never completes and the test hangs into the
    // ten-minute timeout. The MockClient holds no socket worth closing.
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      // Or GoTrue's refresh ticker stays a pending timer past the test.
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    // Memoised: AuthGate's builder runs on every rebuild, and a fresh sync per
    // build would leave the shell writing through an object nobody reads.
    EatovaSync? sync;

    await tester.pumpWidget(EatovaApp(
      syncBuilder: (userId) => sync ??= EatovaSync.forUser(client, userId),
    ));
    // Boot: welcome gate -> server load -> shell. `pumpAndSettle` would hang
    // on the gate's endlessly repeating animation.
    await _warteAuf(
      tester,
      find.byKey(const ValueKey('nav-Heute')),
      'die Shell nach dem Boot-Load',
    );
    expect(_storeOf(tester).sync, isNotNull,
        reason: 'ohne echten Sync prueft dieser Flow nur In-Memory-Felder');

    // Cold start: the hero shows the server profile.
    expect(await _heuteTab(tester), _erwartet(_startProfil.dailyKcalGoal));

    // --- 1. Rechner-Modus: Gewicht, Aktivität, Ziel ------------------------
    await _oeffneZiele(tester);
    expect(_manuellSchalter(tester), isFalse,
        reason: 'ein frisches Profil startet im Rechner-Modus');
    expect(find.byKey(const ValueKey('settings-kcal')), findsNothing,
        reason: 'ohne Manuell gibt es kein kcal-Feld');
    expect(find.byKey(const ValueKey('settings-plan-eyebrow-live')),
        findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('settings-weight')),
      '${rechnerProfil.weightKg}',
    );
    await _settle(tester);
    await _waehle(tester, 'settings-activity',
        'settings-activity-${rechnerProfil.activityLevel.name}');
    await _waehle(tester, 'settings-weight-goal',
        'settings-weight-goal-${rechnerProfil.weightGoal.name}');

    // The plan hero already shows the live calculation, before saving.
    expect(find.text('${rechnerZiel.kcal}'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-validation-note')), findsNothing);

    await _speichernUndSchliessen(tester);

    // --- 2. das neue Tagesziel steht auf Heute UND auf dem Server ----------
    expect(await _heuteTab(tester), _erwartet(rechnerZiel.kcal));
    expect(_heuteZielText(tester), isNot(_erwartet(_startProfil.dailyKcalGoal)));
    expect(_serverProfil(server), (manual: false, kcal: rechnerZiel.kcal),
        reason: 'der Rechner-Modus muss als Serverzeile ankommen');

    // Gespeichert: die Seite oeffnet mit den neuen Werten.
    await _oeffneZiele(tester);
    expect(_feld(tester, 'settings-weight'), '${rechnerProfil.weightKg}');
    expect(_manuellSchalter(tester), isFalse);

    // --- 3. Ziel manuell setzen -------------------------------------------
    await _tippe(tester, find.byKey(const ValueKey('settings-manual-energy')));
    expect(_manuellSchalter(tester), isTrue);
    // Der Umschaltmoment uebernimmt die Rechnerwerte als Startpunkt.
    expect(_feld(tester, 'settings-kcal'), '${rechnerZiel.kcal}');

    await tester.enterText(
      find.byKey(const ValueKey('settings-kcal')),
      '$_manuellesZiel',
    );
    await _settle(tester);

    // Der Hero nennt sich jetzt „manuell" und zeigt die eigene Zahl.
    expect(find.byKey(const ValueKey('settings-plan-eyebrow-manual')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('settings-plan-eyebrow-live')),
        findsNothing);
    expect(find.text('$_manuellesZiel'), findsWidgets);

    await _speichernUndSchliessen(tester);
    expect(await _heuteTab(tester), _erwartet(_manuellesZiel));

    // Der eigentliche F7-01-Beleg: manual_energy steht in der SERVERZEILE.
    // Im Preview-Modus (sync == null) kam `applySettings` hier nie hin — es
    // kehrt vor Cache-Write und Outbox-Op zurueck.
    expect(_serverProfil(server), (manual: true, kcal: _manuellesZiel),
        reason: 'manual_energy ist persistiert, nicht rekonstruiert');
    expect(_storeOf(tester).pendingOutbox, isEmpty,
        reason: 'die Zustellung ist durch, nichts haengt in der Outbox');

    // --- 4. Gewichtsänderung bewegt das manuelle Ziel nicht mehr ----------
    await _oeffneZiele(tester);
    expect(_manuellSchalter(tester), isTrue,
        reason: 'manual_energy kommt aus dem persistierten Profil');
    expect(_feld(tester, 'settings-kcal'), '$_manuellesZiel');

    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '70');
    await _settle(tester);
    // Selbst auf der Seite bleibt das Ziel stehen, obwohl der Rechner laenger
    // etwas anderes ausrechnen wuerde.
    expect(find.text('${leichteresZiel.kcal}'), findsNothing);

    await _speichernUndSchliessen(tester);

    expect(await _heuteTab(tester), _erwartet(_manuellesZiel),
        reason: 'im Manuell-Modus zieht das Gewicht das Tagesziel nicht mehr');
    expect(_heuteZielText(tester), isNot(_erwartet(leichteresZiel.kcal)));
    expect(_serverProfil(server), (manual: true, kcal: _manuellesZiel),
        reason: 'auch das leichtere Gewicht darf die Serverzeile nicht '
            'auf den Rechnerwert zurueckziehen');
  });
}
