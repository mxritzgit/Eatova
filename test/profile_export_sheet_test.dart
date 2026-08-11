// C7 (docs/REVIEW-2026-08-08.md): der In-App-Export war ein In-Memory-
// Teil-Snapshot. Das Export-Sheet zeigt jetzt die VOLLSTAENDIGE
// Server-Auskunft (DataExportService) und faellt bei einem Fehler ehrlich
// zurueck, statt Vollstaendigkeit zu behaupten.
//
// **Umgezogen am 2026-08-10.** Der Einstieg lag bis dahin im Profil
// (`profile-action-export`, Block „Daten & Konto"). Der Block ist auf
// Nutzer-Entscheid entfallen, weil er die Einstellungen doppelte — der
// Einstieg heisst jetzt `settings-export`. Die Aussagen dieser Datei sind
// deshalb NICHT gestrichen, sondern auf den verbliebenen Einstieg umgehaengt;
// der Dateiname bleibt, damit die Historie lesbar bleibt.
//
// Eine der drei Aussagen hat sich dabei geaendert und das ist ein Befund:
// den Fall „ohne Sync bleibt der Session-Snapshot" gibt es nicht mehr. Die
// Einstellungen blenden die Zeile ohne `onExportData` ganz aus, statt ein
// Teil-Ergebnis anzubieten. `DataExportSheet(vollstaendig: false)` und
// `fallbackSnapshot` haben damit in der App keinen Aufrufer mehr (s. Bericht).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> oeffneExport(
    WidgetTester tester, {
    required Future<String> Function()? onExportData,
  }) async {
    // Volle Geraetehoehe: die Einstellungen sind eine ListView, und die
    // Export-Zeile liegt unterhalb von KONTO und PRÄFERENZEN.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `theme: buildEatovaTheme(...)` ist Pflicht, seit die Karten ihre Farben
    // ueber `AppTokens.of` lesen: das nackte MaterialApp haengt die
    // ThemeExtension nicht ans Theme, und AppTokens.of wirft dann absichtlich
    // (Verdrahtungs-Detektor).
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsScreen(
          email: 'jonas@example.com',
          onExportData: onExportData,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final zeile = find.byKey(const ValueKey('settings-export'));
    if (onExportData == null) return;
    await tester.ensureVisible(zeile);
    await tester.pumpAndSettle();
    await tester.tap(zeile);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'mit Sync zeigt das Sheet die vollstaendige Server-Auskunft — nicht '
      'mehr den Session-Ausschnitt', (tester) async {
    await oeffneExport(
      tester,
      onExportData: () async => '{"logged_meals": ["alle Zeilen"]}',
    );

    expect(find.text('Datenauskunft'), findsOneWidget);
    // Bewusst der LANGE Ausschnitt: „Vollständige Kopie" allein steht auch im
    // Untertitel der Zeile `settings-export` darunter — die kurze Fassung
    // faende zwei Widgets und pruefte nicht mehr das Sheet.
    expect(
      find.textContaining('Vollständige Kopie deiner gespeicherten Daten'),
      findsOneWidget,
    );
    expect(find.textContaining('logged_meals'), findsOneWidget);
    expect(find.textContaining('In-Memory Snapshot'), findsNothing);
  });

  testWidgets(
      'ohne Sync gibt es die Zeile gar nicht — statt eines halben Exports',
      (tester) async {
    // Frueher zeigte das Profil hier den Session-Snapshot und benannte ihn
    // als solchen. Die Einstellungen gehen einen Schritt weiter: ohne Server
    // gibt es keine Auskunft, die Art. 15 DSGVO genuegt — also auch keinen
    // Eintrag, der eine verspricht.
    await oeffneExport(tester, onExportData: null);

    expect(find.byKey(const ValueKey('settings-export')), findsNothing);
    expect(find.text('Daten Snapshot'), findsNothing);
  });

  testWidgets(
      'scheitert der Server-Abruf, sagt das Sheet es EHRLICH statt '
      'Vollstaendigkeit zu behaupten', (tester) async {
    await oeffneExport(
      tester,
      onExportData: () async => throw Exception('offline'),
    );

    expect(find.textContaining('Server nicht erreichbar'), findsOneWidget);
    expect(
      find.textContaining('Vollständige Kopie deiner gespeicherten Daten'),
      findsNothing,
      reason: 'ein fehlgeschlagener Abruf darf keine Vollstaendigkeit '
          'behaupten',
    );
  });
}
