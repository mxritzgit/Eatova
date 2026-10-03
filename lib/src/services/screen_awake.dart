import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the display on (spec A6/D6): while a timed interval or the rest
/// leading into one runs with the player on top, and while dictating.
///
/// Native side: `FLAG_KEEP_SCREEN_ON` on Android (MainActivity),
/// `isIdleTimerDisabled` on iOS (AppDelegate). No package, no permission.
abstract class ScreenAwake {
  /// Holds ([on]) or releases the display for [owner]. The display stays on
  /// while any owner holds it (ruling R16: the workout player and the Coach
  /// dictation never release each other's hold).
  Future<void> setKeepAwake(bool on, {String owner = 'default'});
}

/// Production implementation over the `eatova/screen` channel.
final class MethodChannelScreenAwake implements ScreenAwake {
  const MethodChannelScreenAwake();

  static const MethodChannel _channel = MethodChannel('eatova/screen');

  // The native flag is process-wide, so its owners are too.
  static final Set<String> _owners = {};

  @visibleForTesting
  static void debugReset() => _owners.clear();

  @override
  Future<void> setKeepAwake(bool on, {String owner = 'default'}) async {
    final wasOn = _owners.isNotEmpty;
    if (on) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    final isOn = _owners.isNotEmpty;
    if (isOn == wasOn) return;
    try {
      await _channel.invokeMethod<void>('setKeepAwake', {'on': isOn});
    } on MissingPluginException {
      // Desktop/web/test: no native counterpart, so no-op.
    } on PlatformException {
      // A display flag must never break the workout or the dictation.
    }
  }
}

/// Default where nothing should touch the display (tests, previews).
final class NoopScreenAwake implements ScreenAwake {
  const NoopScreenAwake();

  @override
  Future<void> setKeepAwake(bool on, {String owner = 'default'}) async {}
}
