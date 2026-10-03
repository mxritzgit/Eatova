import 'package:flutter/services.dart';

/// Keeps the display on (spec A6/D6): while a timed interval or the rest
/// leading into one runs with the player on top, and while dictating.
///
/// Native side: `FLAG_KEEP_SCREEN_ON` on Android (MainActivity),
/// `isIdleTimerDisabled` on iOS (AppDelegate). No package, no permission.
abstract class ScreenAwake {
  Future<void> setKeepAwake(bool on);
}

/// Production implementation over the `eatova/screen` channel.
final class MethodChannelScreenAwake implements ScreenAwake {
  const MethodChannelScreenAwake();

  static const MethodChannel _channel = MethodChannel('eatova/screen');

  @override
  Future<void> setKeepAwake(bool on) async {
    try {
      await _channel.invokeMethod<void>('setKeepAwake', {'on': on});
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
  Future<void> setKeepAwake(bool on) async {}
}
