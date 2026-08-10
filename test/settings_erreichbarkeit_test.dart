import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_app.dart';

// Nutzer-Befund 2026-08-10: „ich finde die Einstellung nicht".
//
// Beim Aufteilen von Einstellungen und „Profil & Ziele" hingen im Profil
// beide an EINEM Callback. Das Zahnrad dort trug die Beschriftung
// „Einstellungen", oeffnete aber die Ziele — und die Einstellungen selbst
// waren nur ueber ein Schieberegler-Symbol im Food-Kopf erreichbar.
//
// Analyzer und Testsuite waren dabei gruen: beide Ziele existierten, beide
// Routen funktionierten, nur zeigte der falsche Knopf auf die falsche Seite.
// Diese Tests pruefen deshalb nicht, DASS es die Screens gibt, sondern dass
// man von der Oberflaeche aus TATSAECHLICH bei ihnen ankommt.

void main() {
  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();
  }

  Future<void> oeffneProfil(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('today-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
  }

  testWidgets('das Zahnrad im Profil fuehrt in die EINSTELLUNGEN',
      (tester) async {
    await boot(tester);
    await oeffneProfil(tester);

    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget,
        reason: 'ein Zahnrad mit der Beschriftung „Einstellungen" muss in '
            'die Einstellungen fuehren');
    expect(find.byKey(const ValueKey('screen-goals')), findsNothing);
  });

  testWidgets('die Bearbeiten-Zeile im Profil fuehrt auf „Profil & Ziele"',
      (tester) async {
    await boot(tester);
    await oeffneProfil(tester);

    final zeile = find.byKey(const ValueKey('profile-action-edit'));
    await tester.ensureVisible(zeile);
    await tester.pumpAndSettle();
    await tester.tap(zeile);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-settings')), findsNothing);
  });

  testWidgets('auch der Kopf des Food-Tabs fuehrt in die Einstellungen',
      (tester) async {
    await boot(tester);
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
  });

  testWidgets('von den Einstellungen kommt man weiter zu den Zielen',
      (tester) async {
    await boot(tester);
    await oeffneProfil(tester);
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();

    final zeile = find.byKey(const ValueKey('settings-open-goals'));
    await tester.ensureVisible(zeile);
    await tester.pumpAndSettle();
    await tester.tap(zeile);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-goals')), findsOneWidget);
  });
}
