import 'package:app_settings/app_settings.dart';

import 'rest_alerts.dart';

/// Rest alerts pinned to the account that opened the player: scheduling
/// stops once [isCurrent] fails (sign-out, account switch); cancelling
/// always runs.
final class GuardedRestAlertScheduler implements RestAlertScheduler {
  const GuardedRestAlertScheduler(this._inner, this._isCurrent);

  final RestAlertScheduler _inner;
  final bool Function() _isCurrent;

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    if (!_isCurrent()) return;
    await _inner.scheduleRestAlert(id: id, at: at, title: title, body: body);
  }

  @override
  Future<void> cancelRestAlert(int id) => _inner.cancelRestAlert(id);
}

/// Opens the OS notification settings ("Alerts off" chip). Never throws:
/// without the plugin (tests, desktop) the tap is a no-op.
Future<void> openNotificationSettings() async {
  try {
    await AppSettings.openAppSettings(type: AppSettingsType.notification);
  } catch (_) {
    // MissingPluginException / PlatformException: nothing to open here.
  }
}
