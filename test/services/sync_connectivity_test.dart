import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/services/sync_connectivity.dart';

class _Connectivity implements SyncConnectivity {
  final events = StreamController<bool>.broadcast(sync: true);
  bool available = false;
  Future<bool> Function()? check;
  int checks = 0;

  @override
  Future<bool> hasNetworkInterface() {
    checks++;
    return check?.call() ?? Future.value(available);
  }

  @override
  Stream<bool> get networkInterfaceChanges => events.stream;

  void emit(bool value) {
    available = value;
    events.add(value);
  }
}

void main() {
  test('Wiederverbindung startet nach Debounce ohne 30s Retry-Timer', () {
    fakeAsync((time) {
      final connectivity = _Connectivity();
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () async {
          calls++;
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      expect(calls, 0);
      connectivity.emit(true);
      time.elapse(const Duration(milliseconds: 499));
      expect(calls, 0);
      time.elapse(const Duration(milliseconds: 1));
      expect(calls, 1);
      connectivity.emit(true);
      connectivity.emit(true);
      time.elapse(const Duration(seconds: 2));
      expect(calls, 1);
      coordinator.dispose();
    });
  });

  test('Flattern erzeugt keine gleichzeitigen oder unbegrenzten Passes', () {
    fakeAsync((time) {
      final connectivity = _Connectivity()..available = true;
      final gates = <Completer<void>>[];
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () {
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(gates, hasLength(1));
      for (var i = 0; i < 8; i++) {
        connectivity.emit(false);
        connectivity.emit(true);
        time.elapse(const Duration(seconds: 1));
      }
      expect(gates, hasLength(1));
      gates.first.complete();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(gates, hasLength(2));
      gates.last.complete();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 5));
      expect(gates, hasLength(2));
      coordinator.dispose();
    });
  });

  test('spaeter Initialcheck ueberschreibt kein neueres Offline-Event', () {
    fakeAsync((time) {
      final check = Completer<bool>();
      final connectivity = _Connectivity()..check = () => check.future;
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () async {
          calls++;
        },
      );
      coordinator.start();
      connectivity.emit(false);
      check.complete(true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(calls, 0);
      coordinator.dispose();
    });
  });

  test('Pause stoppt Hints und Resume fragt Zustand erneut ab', () {
    fakeAsync((time) {
      final connectivity = _Connectivity();
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () async {
          calls++;
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      coordinator.pause();
      connectivity.emit(true);
      time.elapse(const Duration(seconds: 1));
      expect(calls, 0);
      coordinator.resume();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      expect(connectivity.checks, 2);
      coordinator.dispose();
    });
  });

  test('Offline nach einem Hint verwirft den geplanten Lauf', () {
    fakeAsync((time) {
      final connectivity = _Connectivity();
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () async {
          calls++;
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      connectivity.emit(true);
      connectivity.emit(false);
      time.elapse(const Duration(seconds: 1));
      expect(calls, 0);
      coordinator.dispose();
    });
  });

  test('Dispose entfernt Listener und verwirft laufenden Nachholbedarf', () {
    fakeAsync((time) {
      final connectivity = _Connectivity()..available = true;
      final gate = Completer<void>();
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () {
          calls++;
          return gate.future;
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      connectivity.emit(false);
      connectivity.emit(true);
      time.elapse(const Duration(seconds: 1));
      coordinator.dispose();
      coordinator.dispose();
      gate.complete();
      connectivity.emit(true);
      coordinator.resume();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 2));
      expect(calls, 1);
      expect(connectivity.events.hasListener, isFalse);
    });
  });

  test('Plugin- und Syncfehler lassen spaetere Verbindungshints zu', () {
    fakeAsync((time) {
      final connectivity = _Connectivity()
        ..check = () => Future.error(StateError('plugin'));
      var calls = 0;
      final coordinator = ReconnectSyncCoordinator(
        connectivity: connectivity,
        synchronize: () async {
          calls++;
          throw StateError('offline');
        },
      );
      coordinator.start();
      time.flushMicrotasks();
      connectivity.events.addError(StateError('stream'));
      connectivity.emit(true);
      time.elapse(const Duration(seconds: 1));
      connectivity.emit(false);
      connectivity.emit(true);
      time.elapse(const Duration(seconds: 1));
      expect(calls, 2);
      coordinator.dispose();
    });
  });
}
