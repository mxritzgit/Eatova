import '../models/lifetime_stats.dart';
import 'day_math.dart';
import 'notification_service.dart';

/// Plant die abendlichen Streak-Retter-Reminder (PROD-1, rein lokal).
///
/// PURE Funktion ohne IO/Plattform-Abhaengigkeit: aus (now, stats) entsteht
/// eine deterministische Spec-Liste, die der Aufrufer 1:1 an
/// [NotificationService.scheduleAll] weiterreicht (cancel-first, daher immer
/// die volle Liste). Testbar ohne Plugins.

/// Wandzeit-Stunde, zu der der Reminder abends feuert (20:00 Lokalzeit).
const int streakReminderHour = 20;

/// Harte Obergrenze des Planungshorizonts in Kalendertagen.
///
/// D10 (Review 2026-08-08): Vorher waren es 7 Tage, nachgefuellt nur bei
/// Kaltstart oder Mahlzeit-Log. Die Begruendung war zirkulaer — die Erinnerung
/// existiert, um Leute zurueckzuholen, die aufgehoert haben die App zu oeffnen,
/// und schaltete sich nach genau der Menge Vernachlaessigung ab, die sie noetig
/// macht. Ein zweiwoechiger Urlaub reichte, um sie fuer immer verstummen zu
/// lassen.
///
/// Vier Wochen sind die gewaehlte Obergrenze:
///  * Kuerzer deckt keinen Urlaub/keine Krankheitswoche ab — genau der Fall,
///    der den Reminder braucht.
///  * Laenger ist Spam. Wer vier Wochen weder loggt noch die App oeffnet, ist
///    weg; taegliche Nudges ins Leere fuehren zu Deinstallation oder dazu,
///    dass der Nutzer Benachrichtigungen im System abschaltet (und damit in
///    den blockiert-Zustand aus D11 faellt, aus dem die App sich nicht selbst
///    befreien kann).
///  * Der Ausstieg MUSS ueber einen endlichen Horizont laufen: eine echte
///    Wiederholung (`matchDateTimeComponents`) waere OS-verwaltet und liesse
///    sich ohne laufende App nie wieder stoppen. Siehe [streakReminderDayOffsets].
const int streakReminderHorizonDays = 28;

/// Die Kalendertags-Abstaende (ab dem ersten geplanten Abend), an denen ein
/// Reminder liegt: erste Woche taeglich, danach woechentlich.
///
/// Der Taper ist Absicht. Die erste Woche traegt die Gewohnheitsbildung und
/// faengt den „einen Tag vergessen"-Fall; ab da ist die Serie ohnehin gerissen
/// und ein taeglicher Nudge waere nur noch Druck. 10 Termine ueber 4 Wochen
/// statt 28 — das bleibt zugleich weit unter dem iOS-Limit von 64 gleichzeitig
/// vorgemerkten lokalen Benachrichtigungen (darueber verwirft iOS still die
/// spaetesten).
///
/// Bewusst datierte Einzeltermine statt `DateTimeComponents.time`: beide
/// Plattformen verwerfen bei gesetztem `matchDateTimeComponents` den
/// Datums-Anteil und wiederholen NUR die Uhrzeit — n Specs zur selben Wandzeit
/// wuerden zu n taeglichen Benachrichtigungen fuer immer (Belege als
/// `Datei:Zeile` in `notification_service.dart`, `scheduleAll`).
const List<int> streakReminderDayOffsets = <int>[
  0, 1, 2, 3, 4, 5, 6, // erste Woche: jeden Abend
  13, 20, 27, // danach woechentlich, harter Stopp nach 4 Wochen
];

/// ID-Basis fuer den Streak-Slot.
///
/// ID = Basis + (Kalendertag mod [streakReminderHorizonDays]), also
/// 700..727: pro Kalendertag stabil-deterministisch, und weil der Horizont
/// nie mehr als [streakReminderHorizonDays] Tage umspannt, kollidieren zwei
/// Specs eines Laufs nie. Ein Re-Schedule ueberschreibt so alte Eintraege
/// statt zu duplizieren (scheduleAll raeumt zusaetzlich per cancelAll auf).
const int _streakReminderIdBase = 700;

/// Fixer Bezugspunkt der ID-Arithmetik. Beliebig, aber unveraenderlich — er
/// bestimmt nur, welcher Kalendertag welchen Rest liefert.
final DateTime _idEpoch = DateTime(2000, 1, 1);

/// Baut die Reminder-Specs fuer die kommenden Abende.
///
/// - Ein Spec pro Eintrag in [streakReminderDayOffsets], jeweils um
///   [streakReminderHour]:00 (lokale Wandzeit).
/// - Heute schon getrackt (lastTrackedDate == heute)? Dann braucht heute
///   keinen Reminder — Start ab morgen.
/// - Heute noch nicht getrackt, aber jetzt schon >= 20:00? Ebenfalls ab
///   morgen — nie in die Vergangenheit planen (die Plattform wuerde sofort
///   feuern).
/// - Lebt eine Streak (effectiveStreakOn >= 1), traegt NUR der erste geplante
///   Tag die konkrete Zahl im Text. Das ist keine Bequemlichkeit, sondern
///   beweisbar: der erste Slot feuert innerhalb von ~24 h nach der Planung,
///   und jeder Log plant vorher neu — die Zahl stimmt dort also immer. Feuert
///   dagegen Slot 2 oder spaeter, hat der Nutzer seit der Planung nachweislich
///   nicht geloggt, die Serie ist zu diesem Zeitpunkt gerissen. Ein Text wie
///   „Deine Streak wartet" waere dort dauerhaft falsch — deshalb tragen alle
///   spaeteren Slots den Start-Text, der ohne Zahl und ohne Behauptung
///   auskommt.
List<NotificationSpec> planStreakReminders(DateTime now, LifetimeStats stats) {
  final today = startOfDay(now);

  final last = stats.lastTrackedDate;
  final trackedToday = last != null && startOfDay(last) == today;

  final slotToday = DateTime(
    today.year,
    today.month,
    today.day,
    streakReminderHour,
  );
  final skipToday = trackedToday || !now.isBefore(slotToday);
  // Kalenderarithmetik ueber addDays statt Duration — 20:00 bleibt ueber jede
  // DST-Kante hinweg 20:00 (s. day_math.dart).
  final firstSlot = addDays(slotToday, skipToday ? 1 : 0);

  final streak = stats.effectiveStreakOn(now);

  final specs = <NotificationSpec>[];
  for (var i = 0; i < streakReminderDayOffsets.length; i++) {
    final when = addDays(firstSlot, streakReminderDayOffsets[i]);

    final String title;
    final String body;
    if (i == 0 && streak >= 1) {
      title = 'Streak retten';
      body = 'Deine $streak-Tage-Serie wartet — ein Foto genügt.';
    } else {
      title = 'Streak starten';
      body = 'Ein Log genügt, um deine Serie zu starten.';
    }

    specs.add(NotificationSpec(
      id: _streakReminderIdBase +
          daysBetween(when, _idEpoch) % streakReminderHorizonDays,
      title: title,
      body: body,
      scheduledFor: when,
    ));
  }
  return specs;
}
