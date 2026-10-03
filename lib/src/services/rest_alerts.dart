/// Training rest/interval alerts (spec A5): one local notification per phase,
/// scheduled for the phase deadline so it fires while the phone is locked.
///
/// The seams here are separate interfaces, not members of
/// `NotificationService`, so existing `implements` test doubles keep
/// compiling. Callers probe the notification service via `is` and treat
/// absence as "no alerts" (see [NoopRestAlertScheduler]).
library;

/// First id of the range reserved for rest alerts. Far above the reminder
/// nudges (700..727), so reminder paths that cancel only nudge ids never
/// touch a running rest alert.
const int restAlertIdFirst = 2000000000;

/// Size of the reserved rest-alert id range.
const int restAlertIdCount = 1000000;

/// Whether [id] lies in the reserved rest-alert range.
bool isRestAlertId(int id) =>
    id >= restAlertIdFirst && id < restAlertIdFirst + restAlertIdCount;

/// Deterministic notification id for a training session's rest alert.
///
/// FNV-1a (32 bit) over the session id, folded into the reserved range.
/// Stable across processes and app versions — unlike `String.hashCode` — so
/// a recovered session cancels the alert its previous process scheduled.
int restAlertIdForSession(String sessionId) {
  var hash = 0x811c9dc5;
  for (final unit in sessionId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return restAlertIdFirst + hash % restAlertIdCount;
}

/// Payload of every rest/interval alert; a tap carrying it opens Training.
const String trainingRestNotificationPayload = 'training-rest';

/// Schedules and cancels the alert for the current rest or timed interval.
abstract class RestAlertScheduler {
  /// Schedules one alert at [at] under [id] (from [restAlertIdForSession]),
  /// replacing an earlier one with the same id. Texts must stay generic
  /// (D5: no exercise names or weights on the lock screen).
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  });

  /// Cancels the pending or shown alert [id]; nothing else.
  Future<void> cancelRestAlert(int id);
}

/// Default for platforms and tests without local notifications.
final class NoopRestAlertScheduler implements RestAlertScheduler {
  const NoopRestAlertScheduler();

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancelRestAlert(int id) async {}
}

/// Whether rest alerts can reach the user.
enum RestAlertPermission {
  /// The OS delivers this app's notifications.
  granted,

  /// Not granted, and the workout explainer has never asked on this device.
  notAsked,

  /// Not granted although the explainer already asked (or the user said no
  /// elsewhere); the player shows a quiet "Alerts off" hint instead.
  denied,
}

/// Permission flow for rest alerts, independent of the reminder toggle.
abstract class RestAlertPermissionGate {
  /// Silent read: never shows a system dialog.
  Future<RestAlertPermission> state();

  /// Marks this device as asked, then shows the system dialog. True if
  /// granted. Call only after the in-context explainer.
  Future<bool> request();
}

/// Taps on this app's notifications, as their payloads.
abstract class NotificationTapSource {
  /// Payloads of notifications tapped while the app is running.
  Stream<String> get taps;

  /// Payload of the notification that launched the app, if any. Answers at
  /// most once per process, so a later home page cannot replay it.
  Future<String?> launchPayload();
}
