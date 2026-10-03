import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';
import 'crash_reporter.dart';
import 'rest_alerts.dart';

/// Ids reserved for reminder nudges; the streak planner fills the whole
/// range. [NotificationService.scheduleAll] and the reminder opt-out cancel
/// exactly these, so alerts outside it (training rest alerts) survive.
const int reminderNudgeIdFirst = 700;
const int reminderNudgeIdCount = 28;

/// A fully resolved, schedule-ready notification spec. Pure immutable value
/// type passed straight to zonedSchedule; no Flutter or IO dependency.
class NotificationSpec {
  const NotificationSpec({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledFor,
  });

  /// Stable, deterministic platform id: same inputs -> same ids, so a repeat
  /// scheduleAll overwrites old entries instead of duplicating them.
  final int id;
  final String title;
  final String body;

  /// Wall-clock time (local zone) the nudge should fire at.
  final DateTime scheduledFor;

  @override
  bool operator ==(Object other) =>
      other is NotificationSpec &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.scheduledFor == scheduledFor;

  @override
  int get hashCode => Object.hash(id, title, body, scheduledFor);

  @override
  String toString() =>
      'NotificationSpec(id: $id, scheduledFor: $scheduledFor, title: "$title")';
}

/// Abstract notification layer (PROD-1, on-device retention).
///
/// An interface so callers can test against a mock/noop without the platform
/// plugins. [LocalNotificationService] schedules purely locally via
/// zonedSchedule — no APNs/FCM/server, which keeps the zero-cost constraint.
abstract class NotificationService {
  /// One-time init (timezone DB + plugin). Idempotent.
  Future<void> init();

  /// Triggers the system permission dialog (iOS: alert/badge/sound,
  /// Android 13+: POST_NOTIFICATIONS). True if granted.
  Future<bool> requestPermission();

  /// Replaces every scheduled reminder nudge with [specs]. Callers must
  /// always pass the full list, since the old nudges are dropped first.
  /// Other alerts (training rest alerts) stay.
  Future<void> scheduleAll(List<NotificationSpec> specs);

  /// Cancels everything scheduled or shown: the session-end operation
  /// (sign-out, account switch, deletion). Reminder paths prefer
  /// [NotificationScopedCancel] when the service offers it.
  Future<void> cancelAll();
}

/// Extra seam on [NotificationService]: reads the OS-level permission without
/// triggering a system dialog (D11, Review 2026-08-08).
///
/// Checking is not asking: [NotificationService.requestPermission] shows a
/// dialog and needs an explicit gesture; [hasPermission] is silent and may run
/// any time, notably on cold start.
///
/// A separate interface, not another member of [NotificationService], so
/// existing `implements` test doubles keep compiling. Callers probe via `is`
/// and treat absence as "unknown".
abstract class NotificationPermissionProbe {
  /// Whether the OS currently delivers this app's notifications. Never
  /// prompts, and never cacheable — system settings can change it any time.
  Future<bool> hasPermission();
}

/// Extra seam on [NotificationService] (same pattern as
/// [NotificationPermissionProbe]): passes the active locale in so the Android
/// channel name/description is (re-)created in that language on the next
/// `init()`.
///
/// A separate interface keeps `init()`'s parameterless signature and existing
/// test doubles valid. Callers probe via `is`; absence just means the channel
/// stays German.
abstract class NotificationLocalizable {
  void setLocalizations(AppLocalizations l10n);
}

/// Extra seam (same pattern as [NotificationPermissionProbe]): narrower
/// cancellations, so reminder paths and the cold-start backstop leave the
/// running workout's rest alert alone (spec A5). Callers probe via `is` and
/// fall back to [NotificationService.cancelAll].
abstract class NotificationScopedCancel {
  /// Cancels the reminder nudges only (opt-out, OS permission withdrawn).
  Future<void> cancelNudges();

  /// Cold-start backstop: clears everything an earlier session or process
  /// left behind, but keeps the rest alert this process scheduled since the
  /// last session end, which belongs to the session now running.
  Future<void> cancelStaleSchedules();
}

/// No-op implementation for platforms without local notifications (web/test)
/// or as a safe default injection. Does nothing, never crashes.
class NoopNotificationService
    implements NotificationService, NotificationPermissionProbe {
  const NoopNotificationService();

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  /// Honest `false`: this implementation never delivers anything.
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async {}
}

/// Platform [LocalNotificationService] targets. Detected from [Platform] in
/// production; tests inject one so the plugin-backed paths run on the host.
enum NotificationPlatform { ios, android, unsupported }

NotificationPlatform _detectPlatform() {
  if (kIsWeb) return NotificationPlatform.unsupported;
  if (Platform.isIOS) return NotificationPlatform.ios;
  if (Platform.isAndroid) return NotificationPlatform.android;
  return NotificationPlatform.unsupported;
}

/// Thin seam over [FlutterLocalNotificationsPlugin] (F7-04 test seam).
///
/// The plugin resolves its per-platform implementations at runtime, so a
/// fake of the plugin class alone cannot answer `resolvePlatformSpecific…`.
/// The gateway exposes exactly the calls the service makes; [_PluginGateway]
/// forwards them to the real plugin, tests implement this interface.
abstract class NotificationPluginGateway {
  Future<void> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onResponse,
  });
  Future<void> createAndroidChannel(AndroidNotificationChannel channel);
  Future<bool?> requestIosPermissions();
  Future<bool?> requestAndroidPermission();
  Future<bool?> iosPermissionGranted();
  Future<bool?> androidNotificationsEnabled();
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
    String? payload,
  });
  Future<void> cancel(int id);
  Future<void> cancelAll();
  Future<NotificationAppLaunchDetails?> launchDetails();
}

class _PluginGateway implements NotificationPluginGateway {
  _PluginGateway(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();

  @override
  Future<void> initialize(
    InitializationSettings settings, {
    DidReceiveNotificationResponseCallback? onResponse,
  }) =>
      _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: onResponse,
      );

  @override
  Future<void> createAndroidChannel(AndroidNotificationChannel channel) async =>
      _android?.createNotificationChannel(channel);

  @override
  Future<bool?> requestIosPermissions() async =>
      _ios?.requestPermissions(alert: true, badge: true, sound: true);

  @override
  Future<bool?> requestAndroidPermission() async =>
      _android?.requestNotificationsPermission();

  @override
  Future<bool?> iosPermissionGranted() async =>
      (await _ios?.checkPermissions())?.isEnabled;

  @override
  Future<bool?> androidNotificationsEnabled() async =>
      _android?.areNotificationsEnabled();

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails details,
    String? payload,
  }) =>
      _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() =>
      _plugin.getNotificationAppLaunchDetails();
}

/// Real platform-backed implementation. Serves iOS/Android only; everywhere
/// else it hard no-ops instead of crashing.
///
/// Robustness (F7-12 / F1-09): every plugin call is fenced. A failing
/// `initialize`/`createNotificationChannel` used to escape as a zone error on
/// each cold start; now it is reported via [CrashReporter], the service stays
/// "not available" ([isAvailable] false — permission reads answer `false`,
/// scheduling no-ops) and the next [init] retries.
///
/// It also carries the training rest alerts (spec A5): their own Android
/// channel and reserved ids, ordered through the same FIFO as the reminders,
/// and fenced at session end ([cancelAll]).
class LocalNotificationService
    implements
        NotificationService,
        NotificationPermissionProbe,
        NotificationLocalizable,
        NotificationScopedCancel,
        RestAlertScheduler,
        RestAlertPermissionGate,
        NotificationTapSource {
  /// [gateway], [platform] and [localTimezoneName] are test seams; production
  /// passes nothing and gets the real plugin, the detected platform and
  /// `flutter_timezone`.
  LocalNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    NotificationPluginGateway? gateway,
    NotificationPlatform? platform,
    Future<String> Function()? localTimezoneName,
  })  : _gateway =
            gateway ?? _PluginGateway(plugin ?? FlutterLocalNotificationsPlugin()),
        _platform = platform ?? _detectPlatform(),
        _localTimezoneName = localTimezoneName ?? _flutterTimezoneName;

  final NotificationPluginGateway _gateway;
  final NotificationPlatform _platform;
  final Future<String> Function() _localTimezoneName;
  bool _initialized = false;

  // Native schedules may complete after a later cancel. Keep the entire
  // cancel-first replacement atomic with respect to other replacements and
  // logout/opt-out cancellations, in invocation order.
  Future<void> _pendingMutation = Future<void>.value();

  Future<void> _enqueueMutation(Future<void> Function() action) {
    final result = _pendingMutation.then((_) => action());
    // An unexpected failure must not poison all future cancellation attempts.
    _pendingMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Locale for the Android channel name/description (see
  /// [NotificationLocalizable]). Defaults to German, reproducing the previous
  /// hardcoded string while nobody calls [setLocalizations].
  AppLocalizations _l10n = deL10n;

  @override
  void setLocalizations(AppLocalizations l10n) => _l10n = l10n;

  static const String _androidChannelId = 'eatova_nudges';
  String get _androidChannelName => _l10n.notifChannelName;
  String get _androidChannelDescription => _l10n.notifChannelDescription;

  /// Separate channel, so workout alerts can be tuned apart from reminders.
  static const String _restChannelId = 'eatova_training';

  /// Device flag: the workout explainer has asked for alert permission.
  static const String restAlertsAskedKey = 'eatova.v1.rest_alerts_asked';

  final StreamController<String> _taps = StreamController<String>.broadcast();
  bool _launchPayloadRead = false;

  // Session fence for rest alerts. Their ids derive from the training
  // session id, so an id seen before a session end belongs to that session
  // for good: a later request for it is a late continuation of the ended
  // session (e.g. the signed-out player) and is refused.
  final Set<int> _sessionRestAlertIds = <int>{};
  final Set<int> _endedRestAlertIds = <int>{};

  // Rest alerts handed to the OS since the last session end, so the
  // cold-start backstop can keep them (see [cancelStaleSchedules]).
  final Map<int, ({tz.TZDateTime when, String title, String body})>
      _liveRestAlerts = {};

  bool get _supported => _platform != NotificationPlatform.unsupported;

  /// Whether the plugin came up. False before [init] and after a failed one.
  bool get isAvailable => _initialized;

  /// flutter_timezone 5.x returns a TimezoneInfo; the full IANA name is in
  /// .identifier, and only that resolves via getLocation.
  static Future<String> _flutterTimezoneName() async =>
      (await FlutterTimezone.getLocalTimezone()).identifier;

  @override
  Future<void> init() async {
    if (_initialized || !_supported) return;

    // Android reads the small icon only through its alpha channel, so the
    // fully opaque @mipmap/ic_launcher rendered as a white square. Hence the
    // monochrome vector drawable whose shape lives in transparency. It is the
    // default for all nudges; AndroidNotificationDetails.icon stays empty in
    // _details() so no call site has to repeat the reference.
    const androidInit =
        AndroidInitializationSettings('@drawable/ic_notification');
    const iosInit = DarwinInitializationSettings(
      // Do not force permission at init — that runs via requestPermission().
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    try {
      // zonedSchedule needs a local location set, or tz.local throws. Use
      // the system zone; on failure stay on UTC (better than crashing).
      // Inside the fence (G M-6): a throwing tz database must not escape
      // init as a zone error either.
      tzdata.initializeTimeZones();
      await _setLocalTimezone();
      await _gateway.initialize(settings, onResponse: _onResponse);
      // Android 8+ needs an explicit channel or nudges are not shown.
      // Idempotent — recreating it is a no-op.
      if (_platform == NotificationPlatform.android) {
        await _gateway.createAndroidChannel(
          AndroidNotificationChannel(
            _androidChannelId,
            _androidChannelName,
            description: _androidChannelDescription,
            importance: Importance.defaultImportance,
          ),
        );
        await _gateway.createAndroidChannel(
          AndroidNotificationChannel(
            _restChannelId,
            _l10n.trainingRestChannelName,
            description: _l10n.trainingRestChannelDescription,
            importance: Importance.defaultImportance,
          ),
        );
      }
      _initialized = true;
    } catch (e, st) {
      // Not available for now; the next init() retries. Reported, not
      // rethrown: a PlatformException here was a zone error per cold start.
      await CrashReporter.capture(e, st, context: 'notification-init');
    }
  }

  /// Sets the local tz location from the device's IANA zone name. Uses
  /// flutter_timezone, not DateTime.now().timeZoneName, which often yields
  /// only abbreviations (CET/CEST) that fall back to UTC.
  ///
  /// On failure the UTC default stays — harmless for [scheduleAll], which
  /// converts the INSTANT ([tz.TZDateTime.from]), not the wall-clock parts.
  /// Still reported (F7-04): a silent fallback hid this for weeks.
  Future<void> _setLocalTimezone() async {
    try {
      final name = await _localTimezoneName();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-timezone');
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      await init();
      if (!_initialized) return false;
      final granted = switch (_platform) {
        NotificationPlatform.ios => await _gateway.requestIosPermissions(),
        NotificationPlatform.android =>
          await _gateway.requestAndroidPermission(),
        NotificationPlatform.unsupported => false,
      };
      return granted ?? false;
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-request');
      return false;
    }
  }

  /// Reads the permission silently. Each platform exposes it in a DIFFERENT
  /// plugin method:
  ///
  ///  * Android: `areNotificationsEnabled()` — `POST_NOTIFICATIONS` from API
  ///    33, the "allow notifications" switch before. No `checkPermissions()`.
  ///  * iOS: `checkPermissions()`; `isEnabled` maps to
  ///    `authorizationStatus == UNAuthorizationStatusAuthorized`, so "never
  ///    asked" correctly counts as not granted. No `areNotificationsEnabled()`.
  ///
  /// Defensive, init included: a failing platform call counts as not granted
  /// — an honest blocked state beats a switch that lies.
  @override
  Future<bool> hasPermission() async {
    if (!_supported) return false;
    try {
      await init();
      if (!_initialized) return false;
      final granted = switch (_platform) {
        NotificationPlatform.ios => await _gateway.iosPermissionGranted(),
        NotificationPlatform.android =>
          await _gateway.androidNotificationsEnabled(),
        NotificationPlatform.unsupported => false,
      };
      return granted ?? false;
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-permission');
      return false;
    }
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) {
    final scheduled = List<NotificationSpec>.of(specs);
    return _enqueueMutation(() => _scheduleAll(scheduled));
  }

  Future<void> _scheduleAll(List<NotificationSpec> specs) async {
    if (!_supported) return;
    await init();
    if (!_initialized) return;

    try {
      // Clear first, then reschedule — avoids duplicates and orphans when a
      // run yields fewer or different specs. Nudge ids only: a running rest
      // alert in the same plugin must survive a re-plan (spec A5).
      await _cancelNudgeIds();

      final details = _details();
      final now = tz.TZDateTime.now(tz.local);
      for (final spec in specs) {
        // The INSTANT, not the wall-clock components (F7-04): building
        // TZDateTime(tz.local, y, m, d, 20, 0) reinterpreted a local 20:00
        // as 20:00 in whatever tz.local was — with the UTC fallback that is
        // 22:00 in Berlin summer, 21:00 in winter, straight into iOS Focus.
        final when = tz.TZDateTime.from(spec.scheduledFor, tz.local);
        // Defensive: never schedule into the past (zonedSchedule would fire
        // immediately).
        if (!when.isAfter(now)) continue;
        // Deliberately WITHOUT matchDateTimeComponents (D10, Review
        // 2026-08-08). `DateTimeComponents.time` would be a bug: both
        // platforms then drop the DATE part and keep only hour/minute/second,
        // so n specs at the same wall-clock time collapse into n daily
        // repeating notifications, forever. The planner therefore resolves
        // the horizon into dated one-shots (see streak_reminder_planner.dart).
        await _gateway.zonedSchedule(
          id: spec.id,
          title: spec.title,
          body: spec.body,
          scheduledDate: when,
          details: details,
        );
      }
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-schedule');
    }
  }

  @override
  Future<void> cancelAll() {
    // Session end. Fenced synchronously, so a request issued after this call
    // is refused even while the cancel still waits in the queue.
    _endedRestAlertIds.addAll(_sessionRestAlertIds);
    _sessionRestAlertIds.clear();
    return _enqueueMutation(_cancelAll);
  }

  Future<void> _cancelAll() async {
    _liveRestAlerts.clear();
    if (!_supported) return;
    await init();
    if (!_initialized) return;
    try {
      await _gateway.cancelAll();
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-cancel');
    }
  }

  @override
  Future<void> cancelNudges() => _enqueueMutation(() async {
        if (!_supported) return;
        await init();
        if (!_initialized) return;
        try {
          await _cancelNudgeIds();
        } catch (e, st) {
          await CrashReporter.capture(e, st, context: 'notification-cancel');
        }
      });

  /// Per id, so a rest alert in the same plugin survives. `cancel` also
  /// removes a nudge already shown, as `cancelAll` did.
  Future<void> _cancelNudgeIds() async {
    for (var id = reminderNudgeIdFirst;
        id < reminderNudgeIdFirst + reminderNudgeIdCount;
        id++) {
      await _gateway.cancel(id);
    }
  }

  @override
  Future<void> cancelStaleSchedules() =>
      _enqueueMutation(_cancelStaleSchedules);

  Future<void> _cancelStaleSchedules() async {
    if (!_supported) return;
    await init();
    if (!_initialized) return;
    try {
      await _gateway.cancelAll();
      // Boot can reach this backstop after the player already resumed a
      // rest; that alert is this session's, so it is planned again.
      final kept = Map.of(_liveRestAlerts);
      _liveRestAlerts.clear();
      for (final MapEntry(key: id, value: alert) in kept.entries) {
        if (!alert.when.isAfter(clock.now())) continue;
        await _scheduleRestAlertNow(id, alert.when, alert.title, alert.body);
      }
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-cancel');
    }
  }

  // --- Rest alerts (spec A5) ------------------------------------------------

  @override
  Future<void> scheduleRestAlert({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) {
    if (!isRestAlertId(id) || _endedRestAlertIds.contains(id)) {
      return Future<void>.value();
    }
    _sessionRestAlertIds.add(id);
    return _enqueueMutation(() => _scheduleRestAlert(id, at, title, body));
  }

  Future<void> _scheduleRestAlert(
    int id,
    DateTime at,
    String title,
    String body,
  ) async {
    if (!_supported) return;
    await init();
    if (!_initialized) return;
    try {
      final when = tz.TZDateTime.from(at, tz.local);
      if (when.isAfter(clock.now())) {
        await _scheduleRestAlertNow(id, when, title, body);
      } else {
        // The plugin rejects past dates, and a deadline already reached needs
        // no alert: drop the one planned for the earlier deadline instead.
        _liveRestAlerts.remove(id);
        await _gateway.cancel(id);
      }
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-rest-schedule');
    }
  }

  Future<void> _scheduleRestAlertNow(
    int id,
    tz.TZDateTime when,
    String title,
    String body,
  ) async {
    await _gateway.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: when,
      details: _restDetails(),
      payload: trainingRestNotificationPayload,
    );
    _liveRestAlerts[id] = (when: when, title: title, body: body);
  }

  @override
  Future<void> cancelRestAlert(int id) {
    if (!isRestAlertId(id)) return Future<void>.value();
    if (!_endedRestAlertIds.contains(id)) _sessionRestAlertIds.add(id);
    return _enqueueMutation(() => _cancelRestAlert(id));
  }

  Future<void> _cancelRestAlert(int id) async {
    _liveRestAlerts.remove(id);
    if (!_supported) return;
    await init();
    if (!_initialized) return;
    try {
      await _gateway.cancel(id);
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-rest-cancel');
    }
  }

  // --- Permission gate ------------------------------------------------------

  @override
  Future<RestAlertPermission> state() async {
    if (await hasPermission()) return RestAlertPermission.granted;
    return await _restAlertsAsked()
        ? RestAlertPermission.denied
        : RestAlertPermission.notAsked;
  }

  @override
  Future<bool> request() async {
    await _markRestAlertsAsked();
    return requestPermission();
  }

  /// A failing read counts as asked: a quiet "Alerts off" hint beats an
  /// explainer before every workout.
  Future<bool> _restAlertsAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(restAlertsAskedKey) ?? false;
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'rest-alert-flag');
      return true;
    }
  }

  Future<void> _markRestAlertsAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(restAlertsAskedKey, true);
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'rest-alert-flag');
    }
  }

  // --- Taps -----------------------------------------------------------------

  @override
  Stream<String> get taps => _taps.stream;

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (response.notificationResponseType !=
            NotificationResponseType.selectedNotification ||
        payload == null ||
        payload.isEmpty) {
      return;
    }
    _taps.add(payload);
  }

  @override
  Future<String?> launchPayload() async {
    if (!_supported || _launchPayloadRead) return null;
    _launchPayloadRead = true;
    try {
      final details = await _gateway.launchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      final payload = details.notificationResponse?.payload;
      return payload == null || payload.isEmpty ? null : payload;
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-launch');
      return null;
    }
  }

  NotificationDetails _details() {
    final android = AndroidNotificationDetails(
      _androidChannelId,
      _androidChannelName,
      channelDescription: _androidChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    return NotificationDetails(android: android, iOS: ios);
  }

  /// Foreground: sound only, the app adds a haptic; in the background the
  /// alert shows normally (spec A5). No badge for a timer.
  NotificationDetails _restDetails() {
    final android = AndroidNotificationDetails(
      _restChannelId,
      _l10n.trainingRestChannelName,
      channelDescription: _l10n.trainingRestChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const ios = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: true,
      presentBanner: false,
      presentList: false,
    );
    return NotificationDetails(android: android, iOS: ios);
  }
}
