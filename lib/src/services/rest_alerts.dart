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
int restAlertIdForSession(String sessionId) => _restAlertSlot(sessionId, 0);

/// Id of the alert for the rest after a running timed set: the app applies
/// that rest only once it sees the interval end, so it is planned at ▶
/// next to [restAlertIdForSession]. Never equal to it.
int restAlertFollowUpIdForSession(String sessionId) =>
    _restAlertSlot(sessionId, 1);

/// Id of the [RestAlertCue] of a session, apart from both planned alerts.
int restAlertCueIdForSession(String sessionId) => _restAlertSlot(sessionId, 2);

int _restAlertSlot(String sessionId, int offset) {
  var hash = 0x811c9dc5;
  for (final unit in sessionId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return restAlertIdFirst + (hash + offset) % restAlertIdCount;
}

/// Payload of every rest/interval alert; a tap carrying it opens Training.
const String trainingRestNotificationPayload = 'training-rest';

/// Schedules and cancels the alert for the current rest or timed interval.
abstract class RestAlertScheduler {
  /// Schedules one alert at [at] under [id], replacing an earlier one with
  /// the same id. The player uses [restAlertIdForSession] for the alert of
  /// the current phase and [restAlertFollowUpIdForSession] for the rest that
  /// follows a timed interval. Texts must stay generic (D5: no exercise names
  /// or weights on the lock screen).
  ///
  /// Ignored from a session end until the next account's session opens
  /// (see [RestAlertSessionScope]).
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  });

  /// Cancels the pending or shown alert [id]; nothing else. Always runs,
  /// also after a session end.
  Future<void> cancelRestAlert(int id);
}

/// Extra seam on a [RestAlertScheduler] (probed via `is`): the cue for a
/// phase end the player saw in the foreground.
///
/// Android schedules rest alerts inexactly and may deliver them late, while
/// the player cancels the pending one at the deadline. So Android posts this
/// cue at once (sound, no heads-up, gone after a few seconds). iOS delivers
/// the planned alert on time and posts nothing here.
abstract class RestAlertCue {
  /// Same rules as [RestAlertScheduler.scheduleRestAlert]: [id] from
  /// [restAlertCueIdForSession], generic texts, ignored after a session end.
  Future<void> cueRestAlert({
    required int id,
    required String title,
    required String body,
  });
}

/// Session scope of the rest alerts, probed via `is` by the auth gate.
///
/// A session end (`NotificationService.cancelAll`) closes rest alerts: every
/// later [RestAlertScheduler.scheduleRestAlert] is ignored, whatever its id,
/// until the gate opens the next signed-in account here. Ids seen in an
/// ended session stay refused for every other account; the same account
/// signing back in may resume its workout under the same id.
///
/// Residual: once the next account is open, a request for an id never seen
/// before cannot be told apart from that account's own. A player therefore
/// stops scheduling when its owner store ends and cancels its id on dispose.
abstract class RestAlertSessionScope {
  /// The signed-in account [ownerId] (its user id) now owns the device.
  void openRestAlerts(String ownerId);
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

  /// Not granted, and this device never requested the system prompt
  /// ([RestAlertPermissionGate.request]).
  notAsked,

  /// Not granted although the system prompt was requested (or the user said
  /// no elsewhere); only the notification settings can change it.
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

/// Extra seam on a [RestAlertPermissionGate] (same pattern as
/// [RestAlertSessionScope]): whether the workout explainer was shown.
///
/// Kept apart from [RestAlertPermission.notAsked] on purpose: "Not now" ends
/// the explainer for good, yet leaves the system prompt unrequested, so the
/// "Alerts off" chip can still ask (iOS lists an app's notification switch
/// only once it has asked). Callers probe via `is`; without it the explainer
/// returns at every workout until the user answers it.
abstract class RestAlertExplainerMemory {
  /// Silent read: whether this device already showed the explainer.
  Future<bool> explainerShown();

  /// Records that the explainer was shown; never a system dialog.
  Future<void> markExplainerShown();
}

/// Taps on this app's notifications, as their payloads.
abstract class NotificationTapSource {
  /// Payloads of notifications tapped while the app is running.
  Stream<String> get taps;

  /// Payload of the notification that launched the app, if any. Answers at
  /// most once per process, so a later home page cannot replay it.
  Future<String?> launchPayload();
}
