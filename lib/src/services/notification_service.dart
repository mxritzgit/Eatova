import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';
import 'crash_reporter.dart';

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

  /// Cancels all scheduled nudges and schedules [specs] instead. Callers must
  /// always pass the full list, since the old entries are dropped first.
  Future<void> scheduleAll(List<NotificationSpec> specs);

  /// Cancels all scheduled/shown nudges (logout, reminders turned off).
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
  Future<void> initialize(InitializationSettings settings);
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
  });
  Future<void> cancelAll();
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
  Future<void> initialize(InitializationSettings settings) =>
      _plugin.initialize(settings: settings);

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
  }) =>
      _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

/// Real platform-backed implementation. Serves iOS/Android only; everywhere
/// else it hard no-ops instead of crashing.
///
/// Robustness (F7-12 / F1-09): every plugin call is fenced. A failing
/// `initialize`/`createNotificationChannel` used to escape as a zone error on
/// each cold start; now it is reported via [CrashReporter], the service stays
/// "not available" ([isAvailable] false — permission reads answer `false`,
/// scheduling no-ops) and the next [init] retries.
class LocalNotificationService
    implements
        NotificationService,
        NotificationPermissionProbe,
        NotificationLocalizable {
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

  /// Locale for the Android channel name/description (see
  /// [NotificationLocalizable]). Defaults to German, reproducing the previous
  /// hardcoded string while nobody calls [setLocalizations].
  AppLocalizations _l10n = deL10n;

  @override
  void setLocalizations(AppLocalizations l10n) => _l10n = l10n;

  static const String _androidChannelId = 'eatova_nudges';
  String get _androidChannelName => _l10n.notifChannelName;
  String get _androidChannelDescription => _l10n.notifChannelDescription;

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
      await _gateway.initialize(settings);
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
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    if (!_supported) return;
    await init();
    if (!_initialized) return;

    try {
      // Clear first, then reschedule — avoids duplicates and orphans when a
      // run yields fewer or different specs.
      await _gateway.cancelAll();

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
  Future<void> cancelAll() async {
    if (!_supported) return;
    await init();
    if (!_initialized) return;
    try {
      await _gateway.cancelAll();
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'notification-cancel');
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
}
