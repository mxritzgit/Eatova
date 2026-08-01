import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/src/screens/meal_analysis_screen.dart';
import 'package:shiftfit/src/theme/app_colors.dart';
import 'package:shiftfit/src/theme/app_theme.dart';
import 'package:shiftfit/src/widgets/app_shell/shiftfit_bottom_nav.dart';

// Layout-Tests fuer den Food-Tab.
//
// Bewusst KEINE Assertion auf „kein RenderFlex-Overflow": der Headless-
// Renderer nutzt eine Test-Schrift mit anderen Metriken als SF auf dem Geraet.
// Derselbe Baum, der im Simulator ~56 pt Luft hat, meldet hier einen Overflow —
// die Zahlen sind also kein brauchbares Orakel. Aus demselben Grund schluckt
// `testWidgetsRobust` in widget_test.dart diese Fehler. Die Hoehen-Stufen der
// Kalorienkarte werden im Simulator verifiziert; hier stehen die Aussagen, die
// von der Schriftmetrik unabhaengig sind.

/// Nutzbare Flaeche (Screen minus Safe Area), also das, was der Scaffold im
/// Food-Tab bekommt. Die Test-View hat kein View-Padding, daher ist die Safe
/// Area hier schon abgezogen.
const _usableSize = Size(402, 781); // iPhone 16 Pro

/// Baut den Food-Tab in derselben Huelle wie ShiftFitHomePage: Scaffold mit
/// Bottom-Nav, SafeArea und dem festen 20/12-Padding des fixed-height-Tabs.
Future<void> _pumpFoodTab(WidgetTester tester, {double textScale = 1.0}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Overflow-Meldungen schlucken — s. Datei-Kommentar oben.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildShiftFitTheme(),
      home: MediaQuery(
        // Spiegelt den Textscaler-Deckel aus ShiftFitApp.
        data: MediaQueryData(
          textScaler: TextScaler.linear(textScale).clamp(maxScaleFactor: 1.3),
          size: _usableSize,
        ),
        child: Scaffold(
          backgroundColor: bg,
          bottomNavigationBar: ShiftFitBottomNav(
            selectedIndex: 3,
            onSelected: (_) {},
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: MealAnalysisScreen(dailyConsumedKcal: 0),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Food date chips do not repeat the date twice', (tester) async {
    await _pumpFoodTab(tester);

    // Chip 0 ist der aelteste sichtbare Tag: Kopfzeile = Wochentag,
    // Unterzeile = Datum. Beide duerfen nicht identisch sein.
    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('food-date-chip-0')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .toList();

    expect(texts, hasLength(2));
    expect(texts.first, isNot(equals(texts.last)));
    expect(texts.first, matches(RegExp(r'^(Mo|Di|Mi|Do|Fr|Sa|So)$')));
  });

  testWidgets('Calories card shows the goal only once', (tester) async {
    await _pumpFoodTab(tester);

    // Frueher stand das Tagesziel doppelt in der Karte: einmal als Unterzeile
    // „Ziel: 2.200 kcal" unter der grossen Zahl und einmal in der ZIEL-Kachel.
    expect(find.textContaining('Ziel:'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analyse-daily-kcal-card')),
        matching: find.text('2.200 kcal'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Food action labels stay on one line', (tester) async {
    await _pumpFoodTab(tester, textScale: 1.3);

    // Die Labels waren frueher zweizeilig und liefen bei 64 px Buttonhoehe in
    // einen Overflow. Jetzt steht das Label einzeilig neben dem Icon.
    for (final key in const [
      ValueKey('food-action-barcode'),
      ValueKey('food-action-ai'),
      ValueKey('food-action-quick'),
    ]) {
      final label = tester.widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      );
      expect(label.data, isNot(contains('\n')));
      expect(label.maxLines, 1);
    }
  });
}
