import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';

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

/// Real platform-backed implementation. Serves iOS/Android only; everywhere
/// else it hard no-ops instead of crashing.
class LocalNotificationService
    implements
        NotificationService,
        NotificationPermissionProbe,
        NotificationLocalizable {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
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

  bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  @override
  Future<void> init() async {
    if (_initialized || !_supported) return;

    // zonedSchedule needs a local location set, or tz.local throws. Use the
    // system zone; on failure stay on UTC (better than crashing).
    tzdata.initializeTimeZones();
    await _setLocalTimezone();

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
    await _plugin.initialize(settings: settings);

    // Android 8+ needs an explicit channel or nudges are not shown.
    // Idempotent — recreating it is a no-op.
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: _androidChannelDescription,
        importance: Importance.defaultImportance,
      ),
    );

    _initialized = true;
  }

  /// Sets the local tz location from the device's IANA zone name. Uses
  /// flutter_timezone, not DateTime.now().timeZoneName, which often yields
  /// only abbreviations (CET/CEST) that fall back to UTC. Wrapped in
  /// try/catch: if plugin call or lookup fails, the UTC default stays.
  Future<void> _setLocalTimezone() async {
    try {
      // flutter_timezone 5.x returns a TimezoneInfo; the full IANA name is in
      // .identifier, and only that resolves via getLocation.
      final name = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Keep the UTC default — planned times are local wall clock and are
      // interpreted as local in scheduleAll.
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    await init();

    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final granted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? false;
    }

    return false;
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
  /// Defensive: a failing platform call counts as not granted — an honest
  /// blocked state beats a switch that lies.
  @override
  Future<bool> hasPermission() async {
    if (!_supported) return false;
    await init();
    try {
      if (Platform.isIOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final options = await ios?.checkPermissions();
        return options?.isEnabled ?? false;
      }
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        return await android?.areNotificationsEnabled() ?? false;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    if (!_supported) return;
    await init();

    // Clear first, then reschedule — avoids duplicates and orphans when a run
    // yields fewer or different specs.
    await _plugin.cancelAll();

    final details = _details();
    final now = tz.TZDateTime.now(tz.local);
    for (final spec in specs) {
      final when = tz.TZDateTime(
        tz.local,
        spec.scheduledFor.year,
        spec.scheduledFor.month,
        spec.scheduledFor.day,
        spec.scheduledFor.hour,
        spec.scheduledFor.minute,
        spec.scheduledFor.second,
      );
      // Defensive: never schedule into the past (zonedSchedule would fire
      // immediately).
      if (!when.isAfter(now)) continue;
      // Deliberately WITHOUT matchDateTimeComponents (D10, Review
      // 2026-08-08). `DateTimeComponents.time` would be a bug: both platforms
      // then drop the DATE part and keep only hour/minute/second, so n specs
      // at the same wall-clock time collapse into n daily repeating
      // notifications, forever. The planner therefore resolves the horizon
      // into dated one-shots (see streak_reminder_planner.dart).
      await _plugin.zonedSchedule(
        id: spec.id,
        title: spec.title,
        body: spec.body,
        scheduledDate: when,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!_supported) return;
    await init();
    await _plugin.cancelAll();
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
