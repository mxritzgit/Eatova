import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Stress-Test fuer den textScaler-Cap (EatovaApp deckelt bei 2.0, WCAG
// 1.4.4): die Kern-Screens muessen bei Systemschrift 200 % ohne
// RenderFlex-Overflow rendern. Anders als testWidgetsRobust (widget_test.dart)
// werden Overflows hier NICHT geschluckt, sondern gesammelt und als
// Testfehler gemeldet — genau sie sind der Pruefgegenstand.

const double _stressScale = 2.0;

/// iPhone-14-Viewport (393x852 logical) + Systemschrift auf [_stressScale].
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = _stressScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Faengt waehrend [body] alle Overflow-Fehler ab und meldet sie gesammelt.
///
/// WICHTIG: FlutterError.onError wird VOR dem expect() wiederhergestellt —
/// das Test-Binding asserted sonst beim ersten TestFailure, solange der
/// Handler noch ueberschrieben ist. Nicht-Overflow-Fehler laufen unveraendert
/// in den Framework-Handler (normaler Testfehler).
Future<void> _expectNoOverflow(
  String screen,
  Future<void> Function() body,
) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      // Zusammenfassung + Verursacher-Widget fuer eine brauchbare Diagnose.
      final full = details.toString();
      final culprit = RegExp(r'\S+:file:///\S+').firstMatch(full)?.group(0);
      overflows.add(
        '${details.summary} (${culprit ?? 'Verursacher unbekannt'})',
      );
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(
    overflows,
    isEmpty,
    reason:
        '$screen overflowt bei textScale $_stressScale:\n'
        '${overflows.join('\n')}',
  );
}

DateTime _daysAgo(int n) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - n);
}

void main() {
  testWidgets('Auth-Screen rendert bei textScale 2.0 ohne Overflow', (
    tester,
  ) async {
    _pinViewport(tester);
    await _expectNoOverflow('Auth-Screen', () async {
      final authRepository = InMemoryAuthRepository();
      addTearDown(authRepository.dispose);
      await tester.pumpWidget(EatovaApp(authRepository: authRepository));
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);

      // Auch die Registrieren-Variante (zusaetzliches Namensfeld) pumpen.
      await tester.ensureVisible(
        find.byKey(const ValueKey('auth-toggle-register')),
      );
      await tester.tap(
        find.byKey(const ValueKey('auth-toggle-register')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Food-Tab (EatovaHomePage) rendert bei textScale 2.0 '
      'ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow('Food-Tab', () async {
      await tester.pumpWidget(const EatovaApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

      // Datums-Chip-Wechsel rendert die Auswahl-Zustaende beider Chip-Formen.
      await tester.tap(
        find.byKey(const ValueKey('food-date-chip-3')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Trend-Ansicht rendert bei textScale 2.0 ohne Overflow', (
    tester,
  ) async {
    _pinViewport(tester);
    await _expectNoOverflow('Trend-Ansicht', () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(),
          home: TrendsScreen(
            kcalGoal: 2200,
            loadTotals: () => Future.value([
              for (var i = 0; i < 7; i++)
                TrendDayTotals(
                  day: _daysAgo(i),
                  kcal: 1800 + i * 60,
                  proteinG: 120,
                  carbsG: 200,
                  fatG: 70,
                ),
            ]),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trends-chart')), findsOneWidget);
    });
  });
}
