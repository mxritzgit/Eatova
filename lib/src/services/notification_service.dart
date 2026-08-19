import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';

/// Ein vollstaendig aufgeloester, plan-fertiger Notification-Spec. Reiner
/// Wert-Typ (immutable, mit Gleichheit), den der NotificationService 1:1 an
/// zonedSchedule weiterreichen kann. Keine Flutter-/IO-Abhaengigkeit.
///
/// Lebte frueher in der NotificationContentEngine (Heute-Tab-Nudges); die
/// Engine ist mit dem Heute-Tab entfernt, der Spec bleibt als Wire-Format
/// fuer kuenftige Erinnerungen.
class NotificationSpec {
  const NotificationSpec({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledFor,
  });

  /// Stabile, deterministische Plattform-ID. Gleiche Eingaben -> gleiche IDs,
  /// damit ein erneutes scheduleAll alte Eintraege ueberschreibt statt zu
  /// duplizieren.
  final int id;
  final String title;
  final String body;

  /// Wandzeit (lokale Zone), zu der der Nudge feuern soll.
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

/// Abstrakte Notification-Schicht (PROD-1, on-device-Retention).
///
/// Bewusst als Interface, damit Aufrufer (Onboarding/Boot/Settings) gegen eine
/// Mock-/Noop-Implementierung testen koennen, ohne die Plattform-Plugins zu
/// ziehen. Die echte Implementierung [LocalNotificationService] kapselt
/// flutter_local_notifications + timezone und plant rein lokal via
/// zonedSchedule — KEIN APNs/FCM/Server, das haelt den Gratis-Apple-Team-Status
/// und die Zero-Cost-Constraint.
abstract class NotificationService {
  /// Einmalige Initialisierung (Timezone-DB + Plugin-Init). Idempotent.
  Future<void> init();

  /// Loest den System-Permission-Dialog aus (iOS: alert/badge/sound,
  /// Android 13+: POST_NOTIFICATIONS). Liefert true, wenn erlaubt.
  Future<bool> requestPermission();

  /// Loescht alle bisher geplanten Nudges und plant [specs] neu.
  /// Aufrufer soll IMMER die volle Liste uebergeben — die alten Eintraege
  /// werden zuvor verworfen, damit nichts dupliziert/verwaist.
  Future<void> scheduleAll(List<NotificationSpec> specs);

  /// Verwirft alle geplanten/angezeigten Nudges (z.B. bei Logout oder wenn der
  /// User Erinnerungen in den Settings deaktiviert).
  Future<void> cancelAll();
}

/// Zusatz-Naht zu [NotificationService]: liest die Berechtigung auf OS-Ebene
/// GEGEN — ohne einen Systemdialog auszuloesen.
///
/// **Pruefen ist nicht Anfragen.** [NotificationService.requestPermission]
/// zeigt dem Nutzer einen Dialog und darf nur auf eine explizite Geste hin
/// laufen (Settings-Schalter, Onboarding). [hasPermission] ist still und darf
/// jederzeit laufen — insbesondere beim Kaltstart, wo ein Dialog den Nutzer
/// ueberfallen wuerde (D11, Review 2026-08-08).
///
/// Bewusst ein EIGENES Interface statt eines weiteren Members von
/// [NotificationService]: bestehende Test-Doubles implementieren das
/// Basis-Interface per `implements` und wuerden von einem neuen abstrakten
/// Member gebrochen. Aufrufer pruefen deshalb per `is` und behandeln das
/// Fehlen als „unbekannt" (siehe `home_store_profile.dart`).
abstract class NotificationPermissionProbe {
  /// Ob das OS Benachrichtigungen dieser App aktuell ausliefert.
  ///
  /// Fragt NICHT nach — der Nutzer sieht keinen Dialog. Der Wert kann sich
  /// jederzeit ohne Zutun der App aendern (Systemeinstellungen), er ist also
  /// nie cachebar.
  Future<bool> hasPermission();
}

/// Zusatz-Naht zu [NotificationService] (Muster [NotificationPermissionProbe]):
/// traegt der Dienst einen Android-Notification-Kanal mit Name/Beschreibung
/// (nur [LocalNotificationService]), reicht [setLocalizations] das aktive
/// Sprachpaket hinein — der Kanal-Text wird beim naechsten `init()` in dieser
/// Sprache (re-)angelegt (Scan/Coach-PR, 2026-08-11).
///
/// Bewusst ein EIGENES Interface statt eines neuen Members von
/// [NotificationService]: [NotificationService.init] behaelt seine
/// parameterlose Signatur, bestehende Test-Doubles (`implements
/// NotificationService`, `init()` ohne Argumente) bleiben unveraendert
/// gueltig. Der Aufrufer prueft per `is` (Muster
/// `home_store_profile.dart._osDeliversNotifications`) und behandelt das
/// Fehlen als „unlokalisierbar" — kein Fehler, der Kanal bleibt dann Deutsch.
abstract class NotificationLocalizable {
  void setLocalizations(AppLocalizations l10n);
}

/// No-op-Implementierung fuer Plattformen ohne lokale Notifications (Web/Test)
/// oder als sichere Default-Injection. Tut nichts, crasht nie.
class NoopNotificationService
    implements NotificationService, NotificationPermissionProbe {
  const NoopNotificationService();

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  /// Ehrlich `false`: diese Implementierung stellt nie etwas zu.
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {}

  @override
  Future<void> cancelAll() async {}
}

/// Echte, plattform-gestuetzte Implementierung. Nur iOS/Android werden bedient;
/// auf allen anderen Plattformen no-op-pt sie hart (statt zu crashen).
class LocalNotificationService
    implements
        NotificationService,
        NotificationPermissionProbe,
        NotificationLocalizable {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  /// Sprachpaket fuer den Android-Kanal-Namen/-Beschreibung — s.
  /// [NotificationLocalizable]. Default Deutsch ([deL10n]): reproduziert den
  /// vorherigen hartkodierten Text, solange niemand [setLocalizations] ruft
  /// (bestehende Tests bleiben unveraendert gruen).
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

    // Timezone-DB laden + lokale Zone setzen. zonedSchedule braucht eine
    // gesetzte local-Location, sonst wirft tz.local. Wir nehmen die vom System
    // gemeldete Zone; faellt das fehl, bleibt UTC (besser als Crash).
    tzdata.initializeTimeZones();
    await _setLocalTimezone();

    // Das Small Icon wertet Android seit API 21 NUR ueber den Alphakanal aus
    // und faerbt das Ergebnis selbst ein (minSdk 26 — der Fall tritt immer
    // ein). @mipmap/ic_launcher ist ein vollflaechig deckendes Bitmap, sein
    // Alphakanal ist ueberall 255; in der Statusleiste kam davon ein weisses
    // Quadrat an. Deshalb das eigene, monochrome Vektor-Drawable, dessen Form
    // allein in der Transparenz steckt (res/drawable/ic_notification.xml,
    // Fokusring der Wortmarke). Es ist der DEFAULT fuer alle Nudges —
    // AndroidNotificationDetails.icon bleibt in _details() bewusst leer,
    // sonst muesste jede Aufrufstelle den Verweis mitpflegen.
    const androidInit =
        AndroidInitializationSettings('@drawable/ic_notification');
    const iosInit = DarwinInitializationSettings(
      // Permission NICHT beim Init erzwingen — der explizite Schritt laeuft
      // ueber requestPermission() (Onboarding-gesteuert).
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _plugin.initialize(settings: settings);

    // Android 8+ braucht einen expliziten Channel, sonst werden Nudges nicht
    // angezeigt. Idempotent — wiederholtes Anlegen ist ein no-op.
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

  /// Setzt die lokale tz-Location aus dem IANA-Namen der Geraete-Zone
  /// (z.B. "Europe/Berlin"). flutter_timezone liefert den vollen IANA-Namen,
  /// den tz.getLocation aufloesen kann — anders als DateTime.now().timeZoneName,
  /// das oft nur Abkuerzungen (CET/CEST) liefert und damit auf UTC zurueckfaellt
  /// (der CET/CEST->UTC-Fallback, den die Infra angemerkt hat). In try/catch:
  /// schlaegt der Plugin-Call oder der Location-Lookup fehl (unsupported
  /// Platform / fehlender Plattform-Channel im Test), bleibt der UTC-Default.
  Future<void> _setLocalTimezone() async {
    try {
      // flutter_timezone 5.x liefert ein TimezoneInfo; der volle IANA-Name
      // (z.B. "Europe/Berlin") steht in .identifier. getLocation loest nur
      // diesen vollen Namen auf (nicht die CET/CEST-Abkuerzungen).
      final name = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // UTC-Default behalten — Engine-Plan-Zeiten sind lokale Wandzeiten, die
      // wir in scheduleAll als local interpretieren.
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

  /// Liest die Berechtigung still gegen. Die Wahrheit steht pro Plattform in
  /// einer ANDEREN Plugin-Methode:
  ///
  ///  * Android: `AndroidFlutterLocalNotificationsPlugin.areNotificationsEnabled()`
  ///    (`flutter_local_notifications-22.2.0/lib/src/platform_flutter_local_notifications.dart:624`).
  ///    Ab Android 13 (API 33) ist das der Stand von `POST_NOTIFICATIONS`,
  ///    davor der Schalter „Benachrichtigungen zulassen" (Default an). Eine
  ///    `checkPermissions()`-Variante gibt es auf Android NICHT.
  ///  * iOS: `IOSFlutterLocalNotificationsPlugin.checkPermissions()`
  ///    (dieselbe Datei, Zeile 770) liefert ein
  ///    [NotificationsEnabledOptions]; `isEnabled` ist nativ
  ///    `authorizationStatus == UNAuthorizationStatusAuthorized`
  ///    (`ios/.../FlutterLocalNotificationsPlugin.m:552`). „Noch nie gefragt"
  ///    zaehlt damit korrekt als NICHT erlaubt. Ein `areNotificationsEnabled()`
  ///    gibt es auf iOS nicht.
  ///
  /// Defensiv: schlaegt der Plattform-Call fehl (kein Channel im Test,
  /// unbekannte Plattform), gilt „nicht erlaubt" — lieber der ehrliche
  /// blockiert-Zustand als ein Schalter, der wieder luegt.
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

    // Erst aufraeumen, dann neu planen — verhindert Duplikate/Waisen, wenn die
    // Engine zwischen zwei Laeufen weniger oder andere Specs liefert.
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
      // Defensive: nie in die Vergangenheit planen (Plattform-zonedSchedule
      // wuerde sonst sofort feuern).
      if (!when.isAfter(now)) continue;
      // BEWUSST OHNE matchDateTimeComponents (D10, Review 2026-08-08).
      // Das naheliegende `DateTimeComponents.time` waere hier ein Bug: beide
      // Plattformen verwerfen dann den DATUMS-Anteil und behalten nur die
      // Uhrzeit —
      //   Android: `zonedSchedule` ueberschreibt scheduledDateTime mit
      //     getNextFireDateMatchingDateTimeComponents(...)
      //     (android/.../FlutterLocalNotificationsPlugin.java:1687-1692 bzw.
      //     :1369-1410), das nur Stunde/Minute/Sekunde uebernimmt;
      //   iOS: `Time` baut NSDateComponents ausschliesslich aus
      //     hour/minute/second und triggert `repeats:YES`
      //     (ios/.../FlutterLocalNotificationsPlugin.m:835-844).
      // Eine Liste aus n Specs zur selben Wandzeit wuerde damit zu n taeglich
      // wiederkehrenden Benachrichtigungen kollabieren — jeden Abend n Stueck,
      // fuer immer. Der Planner loest den Horizont deshalb in datierte
      // Einzeltermine auf; das ist zugleich der einzige Ausstieg, der ohne
      // laufende App greift (siehe streak_reminder_planner.dart).
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
