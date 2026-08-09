import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/secure_screen.dart';

// Screenshot-/Recents-Schutz (Sicherheits-Audit 2026-08-09): sensible
// Screens (Auth-Code, Passwort, Gesundheitsdaten) sollen nicht im
// Android-Recents-Thumbnail / iOS-App-Switcher-Snapshot landen.
//
// Der native Teil (FLAG_SECURE / Snapshot-Cover) ist hier nicht testbar —
// getestet wird die REF-ZAEHLUNG: nur der Wechsel 0<->1 loest den nativen
// Aufruf aus, damit verschachtelte Guards (AuthScreen -> AuthCodeScreen)
// das Flag nicht vorzeitig loeschen.

void main() {
  test('acquire/release schaltet nur beim Wechsel 0<->1', () async {
    final calls = <bool>[];
    final secure = SecureScreen(invoker: (on) async => calls.add(on));

    await secure.acquire(); // 0 -> 1: enable
    await secure.acquire(); // 1 -> 2: nichts
    expect(calls, [true]);
    expect(secure.activeCount, 2);

    await secure.release(); // 2 -> 1: nichts
    expect(calls, [true]);

    await secure.release(); // 1 -> 0: disable
    expect(calls, [true, false]);
    expect(secure.activeCount, 0);
  });

  test('release unter 0 ist ein gefahrloses No-Op', () async {
    final calls = <bool>[];
    final secure = SecureScreen(invoker: (on) async => calls.add(on));

    await secure.release();
    expect(calls, isEmpty);
    expect(secure.activeCount, 0);
  });

  testWidgets('SecureScreenGuard acquired beim Mount, released beim Unmount',
      (tester) async {
    final calls = <bool>[];
    final secure = SecureScreen(invoker: (on) async => calls.add(on));

    await tester.pumpWidget(MaterialApp(
      home: SecureScreenGuard(
        secureScreen: secure,
        child: const Text('geheim'),
      ),
    ));
    await tester.pump();
    expect(calls, [true]);
    expect(find.text('geheim'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Text('woanders')));
    await tester.pump();
    expect(calls, [true, false]);
  });

  testWidgets('verschachtelte Guards: das Flag bleibt, bis der letzte weg ist',
      (tester) async {
    final calls = <bool>[];
    final secure = SecureScreen(invoker: (on) async => calls.add(on));

    await tester.pumpWidget(MaterialApp(
      home: SecureScreenGuard(
        secureScreen: secure,
        child: SecureScreenGuard(
          secureScreen: secure,
          child: const Text('doppelt'),
        ),
      ),
    ));
    await tester.pump();
    expect(calls, [true], reason: 'nur EIN enable trotz zweier Guards');
    expect(secure.activeCount, 2);

    // Nur den inneren entfernen — das Flag muss bleiben.
    await tester.pumpWidget(MaterialApp(
      home: SecureScreenGuard(
        secureScreen: secure,
        child: const Text('nur einer'),
      ),
    ));
    await tester.pump();
    expect(calls, [true], reason: 'noch kein disable, ein Guard lebt weiter');

    await tester.pumpWidget(const MaterialApp(home: Text('keiner')));
    await tester.pump();
    expect(calls, [true, false]);
  });
}
