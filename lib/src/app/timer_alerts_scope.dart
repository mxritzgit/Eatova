import 'package:flutter/widgets.dart';

import '../services/notification_service.dart';
import '../services/rest_alerts.dart';

/// The device's local timer alerts above the app's Navigator, so a pushed
/// route (the cooking mode) reaches the notification service the training
/// player gets from the home page.
///
/// The service fences each account session itself ([RestAlertSessionScope]);
/// a caller still pins its scheduling to its account, as the player does
/// (`GuardedRestAlertScheduler`).
class TimerAlertsScope extends InheritedWidget {
  const TimerAlertsScope({
    super.key,
    required this.notifications,
    required super.child,
  });

  final NotificationService? notifications;

  static NotificationService? _of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TimerAlertsScope>()?.notifications;

  /// The scheduler, or null outside the app shell (widget tests, previews)
  /// and where the service carries no local alerts.
  static RestAlertScheduler? schedulerOf(BuildContext context) =>
      switch (_of(context)) {
        final RestAlertScheduler scheduler => scheduler,
        _ => null,
      };

  /// The permission gate next to [schedulerOf]; null without one.
  static RestAlertPermissionGate? permissionOf(BuildContext context) =>
      switch (_of(context)) {
        final RestAlertPermissionGate gate => gate,
        _ => null,
      };

  @override
  bool updateShouldNotify(TimerAlertsScope oldWidget) =>
      !identical(notifications, oldWidget.notifications);
}
