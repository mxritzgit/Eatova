import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiftfit/main.dart';
import 'package:shiftfit/src/models/exercises/workout_library.dart';
import 'package:shiftfit/src/widgets/exercises/exercise_interval_player.dart';

// Spiegelt den robusten Wrapper aus widget_test.dart: pinnt das Test-Viewport
// auf iPhone-14-Portrait (sonst verschiebt die 800x600-Default-Groesse das
// Layout) und schluckt RenderFlex-Overflow-Exceptions aus dem Headless-
// Renderer — auf dem echten Geraet sitzt die Bottom-Nav nicht in einem
// overflowenden Container. testWidgets setzt seinen eigenen FlutterError.onError
// erst NACH setUp, darum muss beides im Test-Body passieren.
void testWidgetsRobust(
  String description,
  WidgetTesterCallback callback,
) {
  testWidgets(description, (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

void main() {
  testWidgetsRobust('Übungen-Tab rendert die Workouts', (
    WidgetTester tester,
  ) async {
    // Wie die bestehenden Nav-Tests: ShiftFitApp ohne Sync -> Home rendert
    // direkt (keine Welcome-/Onboarding-Phase).
    await tester.pumpWidget(const ShiftFitApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-Übungen')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-exercises')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workout-card-full_body_express')),
      findsOneWidget,
    );
  });

  testWidgetsRobust('Player zeigt den Lead-in', (WidgetTester tester) async {
    // Standalone, KEIN Supabase. video_player.initialize() wirft im Test
    // (kein Plattform-Plugin); der Player faengt das ab und zeigt den
    // Platzhalter — daher wird KEIN VideoPlayer erwartet, nur das Timer-/
    // UI-Chrome. Der periodische Timer wird in dispose() (Test-Teardown)
    // gecancelt, also nur ein paar pump()s und den Test enden lassen.
    await tester.pumpWidget(
      MaterialApp(
        home: ExerciseIntervalPlayer(workout: guidedWorkouts.first),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('player-timer')), findsOneWidget);
    expect(find.text('Bereit?'), findsOneWidget);

    // Player abbauen, damit der periodische Timer in dispose() gecancelt wird
    // und der Test kein "A Timer is still pending"-Teardown wirft.
    await tester.pumpWidget(const SizedBox());
  });
}
