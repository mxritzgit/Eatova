// C7 (docs/REVIEW-2026-08-08.md): der In-App-Export war ein In-Memory-
// Teil-Snapshot. Das Export-Sheet zeigt jetzt die VOLLSTAENDIGE
// Server-Auskunft (DataExportService), faellt ohne Server ehrlich auf den
// Session-Snapshot zurueck — und benennt beides klar.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

void main() {
  Future<void> oeffneExport(
    WidgetTester tester, {
    Future<String> Function()? onBuildFullExport,
  }) async {
    // Bewusst die Default-Testflaeche (800x600 logisch) — hier geht es nur um
    // das Export-Sheet, nicht um die Kopfgeometrie des Screens.
    //
    // `theme: buildEatovaTheme(...)` ist Pflicht, seit die Karten ihre Farben
    // ueber `AppTokens.of` lesen: das nackte MaterialApp haengt die
    // ThemeExtension nicht ans Theme, und AppTokens.of wirft dann absichtlich
    // (Verdrahtungs-Detektor). Ohne diese Zeile scheiterten alle drei Faelle
    // schon vor dem Design-Refactor an einem Null-Check in basic_widgets.dart.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        home: ProfileScreen(
          name: 'Moritz',
          profile: const UserProfile(),
          weightLog: const WeightLog(),
          stats: LifetimeStats(),
          dailyConsumedKcal: 0,
          dailySteps: 0,
          healthAuthState: HealthAuthState.unknown,
          healthLastFetch: null,
          favoritesCount: 0,
          onLogWeight: (_) {},
          onEditProfile: () {},
          onResetDay: () {},
          onConnectHealth: () {},
          onRefreshHealth: () {},
          onBuildFullExport: onBuildFullExport,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final aktion = find.byKey(const ValueKey('profile-action-export'));
    await tester.ensureVisible(aktion);
    await tester.pumpAndSettle();
    await tester.tap(aktion);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'mit Sync zeigt das Sheet die vollstaendige Server-Auskunft — nicht '
      'mehr den Session-Ausschnitt', (tester) async {
    await oeffneExport(
      tester,
      onBuildFullExport: () async => '{"logged_meals": ["alle Zeilen"]}',
    );

    expect(find.text('Datenauskunft'), findsOneWidget);
    expect(find.textContaining('Vollständige Kopie'), findsOneWidget);
    expect(find.textContaining('logged_meals'), findsOneWidget);
    expect(find.textContaining('In-Memory Snapshot'), findsNothing);
  });

  testWidgets('ohne Sync (Preview) bleibt der Session-Snapshot und sagt es',
      (tester) async {
    await oeffneExport(tester);

    expect(find.text('Daten Snapshot'), findsOneWidget);
    expect(find.textContaining('In-Memory Snapshot'), findsOneWidget);
  });

  testWidgets(
      'scheitert der Server-Abruf, faellt das Sheet EHRLICH auf den '
      'Session-Snapshot zurueck statt Vollstaendigkeit zu behaupten',
      (tester) async {
    await oeffneExport(
      tester,
      onBuildFullExport: () async => throw Exception('offline'),
    );

    expect(find.textContaining('Server nicht erreichbar'), findsOneWidget);
    expect(find.textContaining('Vollständige Kopie'), findsNothing);
  });
}
