import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';

// C8 — Offenlegung der KI-Interaktion im Coach-Tab (Art. 50 Abs. 1 EU-AI-Act).
//
// Bis zum Review stand in der UI nirgends „KI": der Tab heisst „Coach", der
// Leerzustand fragt „Wie kann ich dir helfen?", der Platzhalter sagt „Frag
// Eatova…" und der (i)-Button zeigte nur das Tageskontingent. Dass jede
// Nachricht zusaetzlich einen Tages-Snapshot (Gewicht, Ziel, Kalorien, Makros,
// Namen der geloggten Mahlzeiten) an einen Drittanbieter in den USA schickt,
// war ausschliesslich in PRIVACY.md nachlesbar.
//
// Diese Tests fixieren beides: die KI ist VOR dem Tippen sichtbar, und das
// Detail (welche Daten, wohin) steht im (i)-Sheet.
//
// `service: null` ist der eingebaute Offline-Zustand des Screens (nicht
// eingeloggt): kein Netz, kein Bootstrap, aber Hero + Composer rendern normal.

/// Nutzbare Flaeche eines iPhone 16 Pro — die 800x600-Standardview des
/// Testbindings ist kuerzer als jedes Zielgeraet und laesst den Hero
/// ueberlaufen (vgl. food_tab_layout_test.dart).
const _usableSize = Size(402, 781);

Future<void> _pumpCoach(WidgetTester tester) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      home: const MediaQuery(
        // Orb + Composer animieren sonst endlos -> pumpAndSettle liefe aus.
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: CoachChatScreen(service: null, userName: 'Moritz'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Leerzustand nennt die KI, bevor der Nutzer tippt',
      (tester) async {
    await _pumpCoach(tester);

    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-ai-note')), findsOneWidget);
    expect(find.textContaining('KI'), findsAtLeastNWidgets(1));
  });

  testWidgets('Composer-Platzhalter macht die KI auch im laufenden Chat sichtbar',
      (tester) async {
    await _pumpCoach(tester);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.decoration?.hintText, contains('KI'));
  });

  testWidgets('(i)-Sheet nennt Daten und Empfaenger, nicht nur das Kontingent',
      (tester) async {
    await _pumpCoach(tester);

    await tester.tap(find.byKey(const ValueKey('coach-info')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);

    // WAS mitgeht — die vier Bestandteile aus home_store.coachContext.
    expect(find.textContaining('Gewicht'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Kalorien'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Makros'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Mahlzeiten'), findsAtLeastNWidgets(1));

    // WOHIN es geht — Drittanbieter und Land.
    expect(find.textContaining('USA'), findsAtLeastNWidgets(1));

    // Das Tageskontingent bleibt im selben Sheet erreichbar.
    expect(find.textContaining('Fragen heute frei'), findsOneWidget);
  });

  testWidgets('Hero-Hinweis oeffnet dasselbe (i)-Sheet', (tester) async {
    await _pumpCoach(tester);

    final note = find.byKey(const ValueKey('coach-ai-note'));
    await tester.ensureVisible(note);
    await tester.pumpAndSettle();
    await tester.tap(note);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-info-sheet')), findsOneWidget);
  });
}
