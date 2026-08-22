import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/shared/settings_sheet.dart';

// D5 — the goals form used to discard filled-in data silently: ten numeric
// controllers plus the macro toggle, gone on one careless close gesture.
//
// As a modal BottomSheet there were THREE close paths, and dragging bypassed
// PopScope entirely, which is why the sheet needed a `_DiscardDragGuard` in
// the gesture arena. As a ROUTE only two remain — the header back button
// (`settings-close`) and the system back — and both run through the SAME
// PopScope. The two dropped cases are gone, not untested: nothing can trigger
// them any more.
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
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
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

  /// Visibility probe. A title text match is useless on a page: the title
  /// scrolls away, and the discard dialog carries the name itself.
  bool seiteOffen(WidgetTester tester) =>
      find.byKey(const ValueKey('screen-goals')).evaluate().isNotEmpty;

  String feldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  /// The header back button. It uses the [PageHeader] default
  /// (`Navigator.maybePop`), so it runs through the same [PopScope] as the
  /// system back.
  Future<void> tippeZurueck(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('settings-close')));
    await tester.pumpAndSettle();
  }

  // --- Path 1: back button --------------------------------------------------

  testWidgets('der Zurueck-Knopf fragt nach, wenn etwas eingetippt wurde',
      (tester) async {
    final resultFuture = await openSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    await tippeZurueck(tester);

    expect(seiteOffen(tester), isTrue, reason: 'nichts darf still verpuffen');
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);

    // Keep editing leaves everything in place.
    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();
    expect(seiteOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');

    // Discard really closes.
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

  // --- Path 2: system back --------------------------------------------------

  testWidgets('der System-Zurueck-Button fragt genauso nach', (tester) async {
    await openSettings(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();

    // What Android sends on the back swipe.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(seiteOffen(tester), isTrue);
    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsOneWidget);
  });

  testWidgets('unveraenderte Seite laesst der System-Zurueck sofort gehen',
      (tester) async {
    // Also proves this path really closes; otherwise the dirty case above
    // would show no difference.
    final resultFuture = await openSettings(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(seiteOffen(tester), isFalse);
    expect(await resultFuture, isNull);
  });

  // --- Dialog behaviour -----------------------------------------------------

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

    // The dialog sits over the page and its barrier swallows the tap: only
    // the dialog closes, the page keeps its input.
    await tester.tapAt(const Offset(196, 20));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('discard-changes-dialog')), findsNothing);
    expect(seiteOffen(tester), isTrue);
    expect(feldText(tester, 'settings-weight'), '80');
  });

  testWidgets('der Verwerfen-Schutz blockiert weder Tippen noch Auswahl',
      (tester) async {
    await openSettings(tester);
    // From here the page is dirty.
    await tester.enterText(find.byKey(const ValueKey('settings-weight')), '80');
    await tester.pump();

    // Typing in other fields still works.
    await tester.enterText(find.byKey(const ValueKey('settings-height')), '182');
    await tester.enterText(find.byKey(const ValueKey('settings-water')), '3000');
    await tester.pump();
    expect(feldText(tester, 'settings-height'), '182');
    expect(feldText(tester, 'settings-water'), '3000');

    // The macro toggle still reacts to taps.
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

    // Measure the ScrollPosition, not the header: on a page the header
    // scrolls away and is no longer a reference.
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
