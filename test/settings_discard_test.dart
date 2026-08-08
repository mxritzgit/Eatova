import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// D5 — das Sheet verwarf ausgefuellte Formulare kommentarlos: sieben
// numerische Controller plus Makro-Umschalter, und ein Tap knapp ueber das
// Sheet (auf die Barriere), um die Tastatur zu schliessen, war alles weg.
//
// Es gibt ZWEI Schliesswege, und sie laufen im Framework verschieden:
//
//   Barriere-Tap → ModalBarrier.handleDismiss → Navigator.maybePop
//                  (modal_barrier.dart:225-230)  → fragt PopScope
//   Ziehen       → BottomSheet._handleDragEnd → onClosing → Navigator.pop
//                  (bottom_sheet.dart:769-771)   → fragt PopScope NICHT
//
// Ein reines PopScope deckt also nur die Haelfte ab. Beide Wege werden hier
// einzeln geprueft.
void main() {
  Future<Future<SettingsResult?>> openSheet(WidgetTester tester) async {
    // Bewusst hoher Viewport: das Sheet ist rund 1980 px hoch und fuellt einen
    // normalen Bildschirm komplett — dann gaebe es gar keine Barriere zum
    // Antippen. Bei 2200 px bleibt oben ein Streifen frei.
    tester.view.physicalSize = const Size(1179, 6600);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    late Future<SettingsResult?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () {
                  result = showSettingsSheet(
                    context,
                    profile: const UserProfile(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();
    return result;
  }

  bool sheetOffen(WidgetTester tester) =>
      find.text('Profil & Ziele').evaluate().isNotEmpty;

  String feldText(WidgetTester tester, String key) => tester
      .widget<TextField>(find.byKey(ValueKey(key)))
      .controller!
      .text;

  Offset sheetOben(WidgetTester tester) => tester.getTopLeft(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Material),
            )
            .first,
      );

  /// Tippt oberhalb des Sheets — genau die Geste, mit der man die Tastatur
  /// schliessen will.
  Future<void> tippeAufBarriere(WidgetTester tester) async {
    await tester.tapAt(Offset(196, sheetOben(tester).dy - 40));
    await tester.pumpAndSettle();
  }

  /// Zieht das Sheet am oberen Rand kraeftig nach unten.
  Future<void> ziehSheetWeg(WidgetTester tester) async {
    await tester.flingFrom(
      Offset(196, sheetOben(tester).dy + 12),
      const Offset(0, 400),
      2000,
    );
    await tester.pumpAndSettle();
  }

  // --- Weg 1: Barriere-Tap --------------------------------------------------

  testWidgets('Barriere-Tap fragt nach, wenn etwas eingetippt wurde',
      (tester) async {
    final resultFuture = await openSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await tippeAufBarriere(tester);

    expect(sheetOffen(tester), isTrue, reason: 'nichts darf still verpuffen');
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);

    // „Weiter bearbeiten" laesst alles stehen.
    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();
    expect(sheetOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');

    // Und „Verwerfen" schliesst wirklich.
    await tippeAufBarriere(tester);
    await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
    await tester.pumpAndSettle();
    expect(sheetOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  testWidgets('unveraendertes Sheet schliesst der Barriere-Tap sofort',
      (tester) async {
    final resultFuture = await openSheet(tester);

    await tippeAufBarriere(tester);

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(sheetOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  // --- Weg 2: Ziehen --------------------------------------------------------

  testWidgets('Wegziehen fragt nach, wenn etwas eingetippt wurde',
      (tester) async {
    final resultFuture = await openSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await ziehSheetWeg(tester);

    expect(sheetOffen(tester), isTrue,
        reason: 'PopScope sieht diesen Weg nicht — der Drag-Guard muss ran');
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(feldText(tester, 'settings-weight'), '80');

    await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
    await tester.pumpAndSettle();
    expect(sheetOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  testWidgets('unveraendertes Sheet laesst sich weiterhin wegziehen',
      (tester) async {
    // Zugleich der Beleg, dass dieser Weg wirklich schliesst: waere er es
    // nicht, saehe man am dirty-Fall oben gar keinen Unterschied.
    final resultFuture = await openSheet(tester);

    await ziehSheetWeg(tester);

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(sheetOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  // --- Weg 3: System-Zurueck ------------------------------------------------

  testWidgets('der System-Zurueck-Button fragt genauso nach', (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();

    // Was Android beim Zurueck-Wisch schickt.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(sheetOffen(tester), isTrue);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  // --- Verhalten des Dialogs und des Guards ---------------------------------

  testWidgets('auch der Makro-Umschalter zaehlt als Aenderung', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();

    await tippeAufBarriere(tester);

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  testWidgets('ein Tap neben den Dialog ist „Abbrechen", nicht „Verwerfen"',
      (tester) async {
    await openSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await tippeAufBarriere(tester);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);

    // Zweiter Tap an dieselbe Stelle: der Dialog liegt darueber und schluckt
    // ihn — es geht nur der Dialog zu, das Sheet bleibt mit seinen Eingaben.
    await tester.tapAt(const Offset(196, 20));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(sheetOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');
  });

  testWidgets('der Drag-Guard blockiert weder Tippen noch Auswahl',
      (tester) async {
    await openSheet(tester);
    // Ab hier ist der Guard aktiv.
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    // Weitertippen in anderen Feldern geht.
    await tester.enterText(find.byKey(const ValueKey('settings-height')), '182');
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();
    expect(feldText(tester, 'settings-height'), '182');
    expect(feldText(tester, 'settings-water'), '3000');

    // Und der Makro-Umschalter reagiert weiterhin auf Taps.
    await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
  });

  testWidgets('der Drag-Guard laesst das Sheet weiter scrollen',
      (tester) async {
    // Kleiner Viewport, damit es ueberhaupt etwas zu scrollen gibt.
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () => showSettingsSheet(
                  context,
                  profile: const UserProfile(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    final vorher = tester.getTopLeft(find.text('Profil & Ziele')).dy;
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('Profil & Ziele')).dy, lessThan(vorher));
    expect(sheetOffen(tester), isTrue);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
  });
}
