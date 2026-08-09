import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/screens/meal_analysis_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

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

/// Baut den Food-Tab in derselben Huelle wie EatovaHomePage: Scaffold mit
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
      theme: buildEatovaTheme(Brightness.dark),
      home: MediaQuery(
        // Spiegelt den Textscaler-Deckel aus EatovaApp (seit dem
        // A11y-Pass 2.0 statt 1.3, s. text_scale_stress_test.dart).
        data: MediaQueryData(
          textScaler: TextScaler.linear(textScale).clamp(maxScaleFactor: 2.0),
          size: _usableSize,
        ),
        child: Scaffold(
          // Der Seitengrund kommt aus dem Theme (scaffoldBackgroundColor);
          // eine harte Konstante haette den Hell-Modus ausgeschlossen.
          //
          // Verifikations-Welle 2026-08-09: Diese Huelle stand vorher auf
          // `EatovaBottomNav` — der 3-Tab-Leiste von vor dem Refactor, die
          // ihre Farben noch aus `app_colors.dart` las und in der App
          // nirgends mehr vorkam (die Schale baut `AppNavBar`). Die Leiste
          // hier traegt jetzt dieselben vier Eintraege wie EatovaHomePage,
          // damit die Huelle das misst, was die App wirklich zeichnet.
          bottomNavigationBar: AppNavBar(
            index: 1,
            onChanged: (_) {},
            items: const <AppNavItem>[
              AppNavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: 'Heute',
              ),
              AppNavItem(
                icon: Icons.restaurant_outlined,
                activeIcon: Icons.restaurant_rounded,
                label: 'Food',
              ),
              AppNavItem(
                icon: Icons.menu_book_outlined,
                activeIcon: Icons.menu_book_rounded,
                label: 'Rezepte',
              ),
              AppNavItem(
                icon: Icons.auto_awesome_outlined,
                activeIcon: Icons.auto_awesome_rounded,
                label: 'Coach',
              ),
            ],
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

    // Seit der absteigenden 30-Tage-Leiste ist chip-0 „Heute"; der erste
    // Chip mit Wochentags-Kopfzeile ist chip-2 (Vor 2 Tagen): Kopfzeile =
    // Wochentag, Unterzeile = Datum. Beide duerfen nicht identisch sein.
    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('food-date-chip-2')),
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
    ]) {
      final label = tester.widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      );
      expect(label.data, isNot(contains('\n')));
      expect(label.maxLines, 1);
    }
  });
}
