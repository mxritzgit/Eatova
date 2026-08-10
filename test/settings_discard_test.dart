import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// D5 — „Profil & Ziele" verwarf ausgefuellte Formulare kommentarlos: zehn
// numerische Controller plus Makro-Umschalter, und eine unbedachte
// Schliess-Geste war alles weg.
//
// ## Warum diese Datei neu gefasst wurde (Design-Refactor 2026-08-09)
//
// Als modales BottomSheet gab es DREI Schliesswege, und sie liefen im
// Framework verschieden:
//
//   Barriere-Tap → ModalBarrier.handleDismiss → Navigator.maybePop → PopScope
//   Ziehen       → BottomSheet._handleDragEnd → Navigator.pop  → KEIN PopScope
//   Systemzurueck→ Navigator.maybePop                          → PopScope
//
// Genau deshalb brauchte das Sheet zusaetzlich zum PopScope einen
// `_DiscardDragGuard` in der Gesten-Arena. Als ROUTE existieren die ersten
// beiden Wege nicht mehr: eine Route hat keine Barriere und laesst sich nicht
// wegziehen. Uebrig bleiben der Zurueck-Knopf im Seitenkopf
// (`settings-close`, laeuft ueber `Navigator.maybePop`) und der
// System-Zurueck — und beide laufen jetzt durch DASSELBE PopScope. Das ist die
// eigentliche Vereinfachung des Umbaus.
//
// Die beiden gestrichenen Faelle sind ersatzlos entfallen, nicht ungeprueft
// geblieben: es gibt nichts mehr, das sie ausloesen koennte. Alle Erwartungen
// an den Dialog selbst (Keys, Titel, „Weiter bearbeiten" haelt die Eingaben,
// Tap neben den Dialog = Abbrechen) sind woertlich uebernommen.
void main() {
  Future<Future<SettingsResult?>> openSettings(WidgetTester tester) async {
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

    late Future<SettingsResult?> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open-settings'),
                onPressed: () {
                  result = Navigator.of(context).push<SettingsResult>(
                    MaterialPageRoute<SettingsResult>(
                      builder: (_) =>
                          const GoalsScreen(profile: UserProfile()),
                    ),
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

  /// Sichtbarkeits-Sonde. Frueher stand hier `find.text('Profil & Ziele')` —
  /// als Seite unbrauchbar: der Titel scrollt weg, und der Verwerfen-Dialog
  /// traegt den Namen selbst in einem laengeren Satz.
  bool seiteOffen(WidgetTester tester) =>
      find.byKey(const ValueKey('screen-goals')).evaluate().isNotEmpty;

  String feldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  /// Der Zurueck-Knopf im Seitenkopf. Er nutzt den Standard von [PageHeader],
  /// also `Navigator.maybePop` — damit laeuft er durch dasselbe [PopScope] wie
  /// der System-Zurueck.
  Future<void> tippeZurueck(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
  }

  // --- Weg 1: Zurueck-Knopf -------------------------------------------------

  testWidgets('der Zurueck-Knopf fragt nach, wenn etwas eingetippt wurde',
      (tester) async {
    final resultFuture = await openSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await tippeZurueck(tester);

    expect(seiteOffen(tester), isTrue, reason: 'nichts darf still verpuffen');
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);

    // „Weiter bearbeiten" laesst alles stehen.
    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();
    expect(seiteOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');

    // Und „Verwerfen" schliesst wirklich.
    await tippeZurueck(tester);
    await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
    await tester.pumpAndSettle();
    expect(seiteOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  testWidgets('unveraenderte Seite schliesst der Zurueck-Knopf sofort',
      (tester) async {
    final resultFuture = await openSettings(tester);

    await tippeZurueck(tester);

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(seiteOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  // --- Weg 2: System-Zurueck ------------------------------------------------

  testWidgets('der System-Zurueck-Button fragt genauso nach', (tester) async {
    await openSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();

    // Was Android beim Zurueck-Wisch schickt.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(seiteOffen(tester), isTrue);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  testWidgets('unveraenderte Seite laesst der System-Zurueck sofort gehen',
      (tester) async {
    // Zugleich der Beleg, dass dieser Weg wirklich schliesst: waere er es
    // nicht, saehe man am dirty-Fall oben gar keinen Unterschied.
    final resultFuture = await openSettings(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(seiteOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  // --- Verhalten des Dialogs ------------------------------------------------

  testWidgets('auch der Makro-Umschalter zaehlt als Aenderung', (tester) async {
    await openSettings(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
    await tippeZurueck(tester);

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  testWidgets('ein Tap neben den Dialog ist „Abbrechen", nicht „Verwerfen"',
      (tester) async {
    await openSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await tippeZurueck(tester);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);

    // Der Dialog liegt ueber der Seite und sein Barrier schluckt den Tap — es
    // geht nur der Dialog zu, die Seite bleibt mit ihren Eingaben.
    await tester.tapAt(const Offset(196, 20));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(seiteOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');
  });

  testWidgets('der Verwerfen-Schutz blockiert weder Tippen noch Auswahl',
      (tester) async {
    await openSettings(tester);
    // Ab hier ist die Seite „dirty".
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    // Weitertippen in anderen Feldern geht.
    await tester.enterText(find.byKey(const ValueKey('settings-height')), '182');
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();
    expect(feldText(tester, 'settings-height'), '182');
    expect(feldText(tester, 'settings-water'), '3000');

    // Und der Makro-Umschalter reagiert weiterhin auf Taps.
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-manual-energy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-kcal')), findsNothing);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
  });

  testWidgets('der Verwerfen-Schutz laesst die Seite weiter scrollen',
      (tester) async {
    await openSettings(tester);

    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    // Gemessen wird die ScrollPosition, nicht die Lage der Kopfzeile: der Kopf
    // scrollt auf einer Seite mit heraus und taugt nicht mehr als Referenz.
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    final vorher = position.pixels;

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(position.pixels, greaterThan(vorher));
    expect(seiteOffen(tester), isTrue);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
  });
}
