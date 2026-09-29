import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// Notifies its listeners at the start of every local hour, but only while
/// anyone listens.
///
/// For views whose content follows the time of day (a greeting, the current
/// meal slot) without any store change behind it: merge it into the view's
/// `StoreSelector` listenable and select the time-derived value, so the view
/// rebuilds exactly when that value changes.
///
/// One-shot timers re-armed from [clock], not `Timer.periodic`: a periodic
/// timer drifts over DST changes and suspended app time. The timer stops with
/// the last listener, so an unmounted view leaves nothing pending.
class LocalHourTicker extends ChangeNotifier {
  /// Fires this long after the hour, so the listener's `clock.now()` has
  /// certainly crossed it.
  static const Duration margin = Duration(seconds: 1);

  Timer? _timer;

  /// Whether a tick is scheduled (for tests).
  @visibleForTesting
  bool get isArmed => _timer?.isActive ?? false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _arm();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _disarm();
  }

  void _arm() {
    if (_timer != null) return;
    // Local on purpose: a UTC `now` (e.g. a fixed test clock) would otherwise
    // name a "next hour" in the past and spin the timer at zero delay.
    final now = clock.now().toLocal();
    // DateTime normalises hour 24 to the next day's midnight.
    final next = DateTime(now.year, now.month, now.day, now.hour + 1);
    var wait = next.difference(now);
    // Belt and braces: never a zero or negative delay (a re-arm loop).
    if (wait <= Duration.zero) wait = const Duration(hours: 1);
    _timer = Timer(wait + margin, () {
      _timer = null;
      notifyListeners();
      if (hasListeners) _arm();
    });
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _disarm();
    super.dispose();
  }
}
