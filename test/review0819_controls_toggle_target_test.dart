import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/design/design.dart';

// ---------------------------------------------------------------------------
// Komplettreview 2026-08-19, Fund 1 — die Trefferflaeche des [AppToggle].
//
// Die Kapsel war 27 px hoch UND das einzige Ziel ihrer Einstellungszeile:
// beide Produktiv-Aufrufer (goals_screen.dart, „Manuell" und „Erinnerungen")
// haengten sie als `trailing` in eine SettingsRow OHNE `onTap`. Wer neben die
// Kapsel tippte, traf nichts — und die Kapsel selbst lag mit 27 px deutlich
// unter den 44 px, die [SquareIconButton] in derselben Datei schon haelt.
//
// Zwei Zusicherungen, weil der Fix zwei Haelften hat: der Schalter traegt
// jetzt selbst ein 44-px-Ziel, und die Zeile schaltet mit.
// ---------------------------------------------------------------------------

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildEatovaTheme(Brightness.light),
    locale: const Locale('de'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    ),
  );
}

Future<void> _openGoals(
  WidgetTester tester, {
  ReminderState? reminderState,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
      home: GoalsScreen(
        profile: const UserProfile(),
        reminderState: reminderState,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Tippt in die LINKE Haelfte der Zeile, in der [inZeile] haengt — also
/// bewusst NEBEN den Schalter, dorthin, wo vor dem Fix nichts passierte.
Future<void> _tippeNebenDenSchalter(WidgetTester tester, Finder inZeile) async {
  final zeile = find.ancestor(of: inZeile, matching: find.byType(SettingsRow));
  expect(zeile, findsOneWidget);
  final rect = tester.getRect(zeile);
  await tester.tapAt(Offset(rect.left + 24, rect.center.dy));
  await tester.pumpAndSettle();
}

bool _wert(WidgetTester tester, String key) =>
    tester.widget<AppToggle>(find.byKey(ValueKey<String>(key))).value;

void main() {
  group('AppToggle', () {
    testWidgets('ist mindestens 44 px hoch, ohne dass die Kapsel waechst',
        (tester) async {
      await tester.pumpWidget(
        _harness(AppToggle(value: false, onChanged: (_) {})),
      );

      expect(
        tester.getSize(find.byType(AppToggle)).height,
        greaterThanOrEqualTo(44.0),
        reason: '27 px sind kein Fingerziel',
      );

      // Aussehen unveraendert: gezeichnet wird weiter die 46x27-Kapsel des
      // Entwurfs, der Zuwachs liegt ausserhalb davon.
      final kapsel = find
          .descendant(
            of: find.byType(AppToggle),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      expect(tester.getSize(kapsel), const Size(46, 27));
    });

    testWidgets('der durchsichtige Saum ueber der Kapsel schaltet mit',
        (tester) async {
      bool? empfangen;
      await tester.pumpWidget(
        _harness(AppToggle(value: false, onChanged: (v) => empfangen = v)),
      );

      // Oberkante des Ziels: liegt ueber der gezeichneten Kapsel und traegt
      // nur, weil der GestureDetector opak ist.
      final rect = tester.getRect(find.byType(AppToggle));
      await tester.tapAt(Offset(rect.center.dx, rect.top + 2));
      expect(empfangen, isTrue);
    });
  });

  group('Einstellungszeilen mit Schalter', () {
    testWidgets('die Manuell-Zeile schaltet auf ihrer ganzen Breite',
        (tester) async {
      await _openGoals(tester);

      final schalter = find.byKey(const ValueKey('settings-manual-energy'));
      await tester.ensureVisible(schalter);
      await tester.pumpAndSettle();
      final vorher = _wert(tester, 'settings-manual-energy');

      await _tippeNebenDenSchalter(tester, schalter);

      expect(_wert(tester, 'settings-manual-energy'), !vorher);
    });

    testWidgets('ein Tap AUF den Schalter legt trotzdem nur einmal um',
        (tester) async {
      // Der innere Erkenner gewinnt die Gesten-Arena; die Zeile darunter darf
      // nicht zusaetzlich feuern, sonst spraenge der Schalter zurueck.
      await _openGoals(tester);

      final schalter = find.byKey(const ValueKey('settings-manual-energy'));
      await tester.ensureVisible(schalter);
      await tester.pumpAndSettle();
      final vorher = _wert(tester, 'settings-manual-energy');

      await tester.tap(schalter);
      await tester.pumpAndSettle();

      expect(_wert(tester, 'settings-manual-energy'), !vorher);
    });

    testWidgets('die Erinnerungs-Zeile schaltet auf ihrer ganzen Breite',
        (tester) async {
      await _openGoals(tester, reminderState: ReminderState.off);

      final schalter = find.byKey(const ValueKey('settings-notifications'));
      await tester.ensureVisible(schalter);
      await tester.pumpAndSettle();
      expect(_wert(tester, 'settings-notifications'), isFalse);

      await _tippeNebenDenSchalter(tester, schalter);

      expect(_wert(tester, 'settings-notifications'), isTrue);
    });

    testWidgets('blockiert: auch die Zeile bleibt taub (D11)', (tester) async {
      // Sonst haette D11 eine Hintertuer: der gesperrte Schalter haengt
      // keinen eigenen Erkenner mehr in die Arena, ein Tap auf ihn liefe also
      // an die Zeile durch.
      await _openGoals(tester, reminderState: ReminderState.blocked);

      final schalter = find.byKey(const ValueKey('settings-notifications'));
      await tester.ensureVisible(schalter);
      await tester.pumpAndSettle();

      await _tippeNebenDenSchalter(tester, schalter);
      expect(_wert(tester, 'settings-notifications'), isFalse);

      await tester.tap(schalter, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(_wert(tester, 'settings-notifications'), isFalse);
    });
  });
}
