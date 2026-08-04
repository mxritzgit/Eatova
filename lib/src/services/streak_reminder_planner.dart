import '../models/lifetime_stats.dart';
import 'notification_service.dart';

/// Plant die abendlichen Streak-Retter-Reminder (PROD-1, rein lokal).
///
/// PURE Funktion ohne IO/Plattform-Abhaengigkeit: aus (now, stats) entsteht
/// eine deterministische Spec-Liste, die der Aufrufer 1:1 an
/// [NotificationService.scheduleAll] weiterreicht (cancel-first, daher immer
/// die volle Liste). Testbar ohne Plugins.

/// Wandzeit-Stunde, zu der der Reminder abends feuert (20:00 Lokalzeit).
const int streakReminderHour = 20;

/// Planungshorizont in Tagen. Mehr als eine Woche lohnt nicht — jeder Log und
/// jeder App-Start re-scheduled ohnehin die volle Liste.
const int streakReminderDays = 7;

/// ID-Basis fuer den Streak-Slot. ID = Basis + Wochentag (1 = Mo .. 7 = So),
/// also 701..707: pro Wochentag stabil-deterministisch, und weil der Horizont
/// genau 7 aufeinanderfolgende Tage umfasst, kollidieren zwei Specs eines
/// Laufs nie. Re-Schedule ueberschreibt so alte Eintraege statt zu
/// duplizieren (scheduleAll raeumt zusaetzlich per cancelAll auf).
const int _streakReminderIdBase = 700;

/// Baut die Reminder-Specs fuer die naechsten [streakReminderDays] Abende.
///
/// - Ein Spec pro Tag um [streakReminderHour]:00 (lokale Wandzeit).
/// - Heute schon getrackt (lastTrackedDate == heute)? Dann braucht heute
///   keinen Reminder — Start ab morgen.
/// - Heute noch nicht getrackt, aber jetzt schon >= 20:00? Ebenfalls ab
///   morgen — nie in die Vergangenheit planen (die Plattform wuerde sofort
///   feuern).
/// - Lebt eine Streak (effectiveStreakOn >= 1), traegt NUR der erste geplante
///   Tag die konkrete Zahl im Text — fuer spaetere Tage waere sie stale
///   (jeder neue Log re-scheduled ohnehin mit frischer Zahl).
List<NotificationSpec> planStreakReminders(DateTime now, LifetimeStats stats) {
  final today = DateTime(now.year, now.month, now.day);

  final last = stats.lastTrackedDate;
  final trackedToday = last != null &&
      DateTime(last.year, last.month, last.day) == today;

  final slotToday = DateTime(
    today.year,
    today.month,
    today.day,
    streakReminderHour,
  );
  final skipToday = trackedToday || !now.isBefore(slotToday);
  final firstOffset = skipToday ? 1 : 0;

  final streak = stats.effectiveStreakOn(now);

  final specs = <NotificationSpec>[];
  for (var i = 0; i < streakReminderDays; i++) {
    // Tag-Ueberlauf laeuft durch den DateTime-Ctor (normalisiert Monats-/
    // Jahresgrenzen) statt ueber Duration-Addition — so bleibt die Wandzeit
    // auch ueber DST-Wechsel hinweg exakt 20:00.
    final when = DateTime(
      today.year,
      today.month,
      today.day + firstOffset + i,
      streakReminderHour,
    );

    final String title;
    final String body;
    if (streak >= 1) {
      title = 'Streak retten';
      body = i == 0
          ? 'Deine $streak-Tage-Serie wartet — ein Foto genügt.'
          : 'Heute schon geloggt? Deine Streak wartet.';
    } else {
      title = 'Streak starten';
      body = 'Ein Log genügt, um deine Serie zu starten.';
    }

    specs.add(NotificationSpec(
      id: _streakReminderIdBase + when.weekday,
      title: title,
      body: body,
      scheduledFor: when,
    ));
  }
  return specs;
}
