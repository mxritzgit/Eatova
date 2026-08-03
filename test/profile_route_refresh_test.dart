import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/src/app/shiftfit_home_page.dart';
import 'package:shiftfit/src/services/health_service.dart';
import 'package:shiftfit/src/theme/app_theme.dart';

// INT-B / ARCH-1+PERF-2 Tests fuer shiftfit_home_page.dart:
//
//  * Der setState-Override bumpt _profileRefresh nicht mehr UNBEDINGT, sondern
//    NUR solange die via _openProfile gepushte ProfileScreen-Route offen ist
//    (_profileRouteOpen). Die ProfileScreen-Route liegt in einem eigenen
//    Navigator-Subtree, den das HomePage-setState NICHT erreicht — der
//    AnimatedBuilder + _profileRefresh ist die Bruecke, die einen MID-ROUTE
//    State-Wechsel (hier: ein Health-Steps-Refresh) auf die OFFENE
//    ProfileScreen durchreicht. Test 1 beweist, dass diese Bruecke intakt
//    geblieben ist (sonst zeigte die offene ProfileScreen die alten Schritte).
//  * Test 2 (Scoping-Sanity): nach dem Schliessen der Route bumpt ein
//    Store-Notify das _profileRefresh nicht mehr — eine Mutation auf dem
//    Food-Tab (Datum wechseln) bleibt crash-frei; die geschlossene
//    Profil-Bruecke wird nicht laenger pro Notify mitgeschleift.
//
// Bewusst sync == null: dann landet die Page sofort auf dem Home (kein
// Onboarding-/Boot-Gate) und _logWeight/_refreshHealthSteps laufen ohne
// Supabase. Der injizierte HealthService liefert kontrollierte Snapshots.

/// HealthService mit umschaltbarer Steps-Antwort. authState = granted, damit
/// die ProfileScreen den 'profile-health-refresh'-Button zeigt (nur bei
/// granted sichtbar). [nextSteps] steuert, welchen Steps-Wert der naechste
/// readSnapshot() liefert.
class _StepsHealthService implements HealthService {
  _StepsHealthService(this.nextSteps);

  int nextSteps;
  HealthAuthState _state = HealthAuthState.granted;
  int snapshotReads = 0;

  @override
  HealthAuthState get authState => _state;

  @override
  Future<HealthAuthState> requestAuthorization() async {
    _state = HealthAuthState.granted;
    return _state;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    snapshotReads++;
    return HealthSnapshot(stepsToday: nextSteps, fetchedAt: DateTime.now());
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => true;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async =>
      const <WeightSample>[];

  @override
  Future<SleepSample?> readLastSleep({DateTime? before}) async => null;
}

void _pinViewport(WidgetTester tester) {
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
}

void main() {
  testWidgets(
      'Offene ProfileScreen reflektiert einen mid-route Health-Steps-Refresh '
      '(AnimatedBuilder/_profileRefresh-Bruecke intakt)', (tester) async {
    _pinViewport(tester);
    // Boot-Snapshot: 1000 Schritte. Der PostFrame-_connectHealth ruft
    // requestAuthorization (-> granted) und readSnapshot (-> 1000), setzt also
    // dailySteps = 1000 und macht den Refresh-Button (granted) sichtbar.
    final health = _StepsHealthService(1000);

    await tester.pumpWidget(MaterialApp(
      theme: buildShiftFitTheme(),
      home: ShiftFitHomePage(
        initialUserName: 'Moritz',
        healthService: health,
      ),
    ));
    await tester.pumpAndSettle();

    // ProfileScreen oeffnen (TopBar-Avatar -> _openProfile -> _profileRouteOpen
    // = true).
    await tester.tap(find.byKey(const ValueKey('topbar-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);

    // Default-Steps-Ziel ist 8000. Die "Schritte"-Kachel zeigt aktuell den
    // Boot-Stand 1000/8000.
    expect(find.text('1000/8000'), findsOneWidget);

    // Jetzt MID-ROUTE den Health-Store auf 12345 Schritte umstellen und ueber
    // den Refresh-Button (auf der offenen ProfileScreen) _refreshHealthSteps
    // ausloesen. Das ist ein setState der HomePage UNTER der offenen Route —
    // nur die _profileRefresh-Bruecke bringt den neuen Wert in die ProfileScreen.
    health.nextSteps = 12345;
    // Der Refresh-Button liegt in der HealthConnectionCard weit unten in der
    // scrollbaren ProfileScreen — bei der gepinnten Viewport-Hoehe (852 logisch)
    // off-screen. Erst sichtbar scrollen, sonst trifft tap() ins Leere.
    final refreshBtn = find.byKey(const ValueKey('profile-health-refresh'));
    await tester.ensureVisible(refreshBtn);
    await tester.pumpAndSettle();
    await tester.tap(refreshBtn);
    await tester.pumpAndSettle();

    // Beweis: die OFFENE ProfileScreen zeigt jetzt den frischen Steps-Wert.
    expect(find.text('12345/8000'), findsOneWidget,
        reason: 'mid-route Health-Refresh muss auf der offenen ProfileScreen '
            'ankommen (_profileRouteOpen-gegated _profileRefresh-Bump)');
    expect(find.text('1000/8000'), findsNothing);
  });

  testWidgets(
      'Nach Schliessen der ProfileScreen bleibt eine Food-Tab-Mutation '
      'crash-frei (Scoping-Sanity: geschlossene Profil-Bruecke)', (tester) async {
    _pinViewport(tester);
    final health = _StepsHealthService(2000);

    await tester.pumpWidget(MaterialApp(
      theme: buildShiftFitTheme(),
      home: ShiftFitHomePage(
        initialUserName: 'Moritz',
        healthService: health,
      ),
    ));
    await tester.pumpAndSettle();

    // Oeffnen + sofort wieder schliessen -> _profileRouteOpen wieder false.
    await tester.tap(find.byKey(const ValueKey('topbar-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    // Eine Store-Mutation (Food-Datum wechseln) loest jetzt ein Notify aus,
    // OHNE dass eine Profil-Route offen ist -> _profileRefresh wird nicht mehr
    // gebumpt. Das muss crash-frei bleiben und der Tab neu rendern.
    await tester.tap(find.byKey(const ValueKey('food-date-chip-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);
  });
}
