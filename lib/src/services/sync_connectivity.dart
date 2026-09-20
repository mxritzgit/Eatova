import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Interface availability is a retry hint, never proof of Internet access.
abstract interface class SyncConnectivity {
  Future<bool> hasNetworkInterface();
  Stream<bool> get networkInterfaceChanges;
}

class PlatformSyncConnectivity implements SyncConnectivity {
  PlatformSyncConnectivity({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _available(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  @override
  Future<bool> hasNetworkInterface() async =>
      _available(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get networkInterfaceChanges =>
      _connectivity.onConnectivityChanged.map(_available).distinct();
}

/// One account's foreground retry hints; delivery/backoff belongs to the store.
class ReconnectSyncCoordinator {
  ReconnectSyncCoordinator({
    required SyncConnectivity connectivity,
    required Future<void> Function() synchronize,
    this.debounce = const Duration(milliseconds: 500),
  }) : _connectivity = connectivity,
       _synchronize = synchronize;

  final SyncConnectivity _connectivity;
  final Future<void> Function() _synchronize;
  final Duration debounce;
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  bool _disposed = false;
  bool _active = true;
  bool? _available;
  bool _running = false;
  bool _again = false;
  int _observation = 0;

  void start() {
    if (_disposed || _subscription != null) return;
    _subscription = _connectivity.networkInterfaceChanges.listen(
      (available) {
        _observation++;
        _observe(available);
      },
      onError: (Object _, StackTrace __) {
        // A broken plugin must not disable the store's independent retries.
      },
    );
    unawaited(_check());
  }

  void pause() {
    _active = false;
    _again = false;
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (_disposed) return;
    _active = true;
    // Android does not promise connectivity events while suspended.
    unawaited(_check(force: true));
  }

  Future<void> _check({bool force = false}) async {
    final observation = ++_observation;
    try {
      final available = await _connectivity.hasNetworkInterface();
      if (_disposed || observation != _observation) return;
      _observe(available, force: force);
    } catch (_) {
      // Missing permission/channel does not become an unhandled zone error.
    }
  }

  void _observe(bool available, {bool force = false}) {
    final changed = available != _available;
    _available = available;
    if (!available) {
      _timer?.cancel();
      _timer = null;
      _again = false;
      return;
    }
    if (!_active || (!changed && !force)) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      if (_running) {
        _again = true;
      } else {
        unawaited(_run());
      }
    });
  }

  Future<void> _run() async {
    if (_disposed || !_active || _available != true) return;
    _running = true;
    try {
      await _synchronize();
    } catch (_) {
      // The store retains and classifies failed writes; a hint owns no retries.
    } finally {
      _running = false;
      if (_again && !_disposed && _active && _available == true) {
        _again = false;
        _timer = Timer(debounce, () {
          _timer = null;
          unawaited(_run());
        });
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
