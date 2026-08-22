import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/secure_screen.dart';

// Screenshot/recents protection: sensitive screens (auth code, password, health
// data) must not appear in the Android recents thumbnail or iOS app-switcher
// snapshot.
//
// The native part is not testable here; what is tested is the REF COUNT — only
// the 0<->1 transition calls native, so nested guards do not clear the flag
// early.

void main() {
  test('acquire/release schaltet nur beim Wechsel 0<->1', () async {
    final calls = <bool>[];
    final secure = SecureScreen(invoker: (on) async => calls.add(on));

    await secure.acquire(); // 0 -> 1: enable
    await secure.acquire(); // 1 -> 2: nothing
    expect(calls, [true]);
    expect(secure.activeCount, 2);

    await secure.release(); // 2 -> 1: nothing
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

    // Remove only the inner guard — the flag must stay.
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
