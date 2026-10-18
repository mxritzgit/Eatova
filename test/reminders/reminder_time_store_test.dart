import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/reminder_prompt.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// C4: the reminder time is chosen, persisted per account and device next to
// the opt-in, and a change re-plans at once. Today's one-time card shows
// after logs on two different days, only while reminders are off, and never
// again after any answer.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

class _Notifications
    implements NotificationService, NotificationPermissionProbe {
  _Notifications({this.grant = true});

  bool grant;
  bool failSchedule = false;
  int requests = 0;
  int probes = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  DateTime get firstPlanned => scheduled.last.first.scheduledFor;

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async {
    requests++;
    return grant;
  }

  @override
  Future<bool> hasPermission() async {
    probes++;
    return grant;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async {
    if (failSchedule) throw StateError('plugin down');
    scheduled.add(specs);
  }

  @override
  Future<void> cancelAll() async {}
}

const MealAnalysisResult _meal = MealAnalysisResult(
  mealName: 'Linsensuppe',
  caloriesKcal: 420,
  estimatedGrams: 350,
  kcalPer100G: 120,
  protein: '20 g',
  carbs: '50 g',
  fat: '10 g',
  confidence: 'Hoch',
  portionNotes: '',
);

HomeStore _store(LocalCache cache, NotificationService notifications) =>
    HomeStore(
      sync: null,
      health: const NoopHealthService(),
      notificationService: notifications,
      initialUserName: 'Test',
      emitSnack: _noopSnack,
      debugCache: cache,
    );

/// Wednesday noon: 20:00 and 21:30 are still ahead, 06:45 is past.
final DateTime _noon = DateTime(2026, 7, 15, 12);

Future<T> _atNoon<T>(Future<T> Function() body) =>
    withClock(Clock.fixed(_noon), body);

const ReminderTime _halfTen = ReminderTime(21, 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Uhrzeit: Planung', () {
    test(
      'aktiv: eine neue Uhrzeit plant sofort neu und wird gespeichert',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = _store(cache, notifications);
        await store.setNotificationsEnabled(true);
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 20));

        await store.setReminderTime(_halfTen);

        expect(
          notifications.scheduled,
          hasLength(2),
          reason: 'the change re-plans at once',
        );
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 21, 30));
        for (final spec in notifications.scheduled.last) {
          expect((spec.scheduledFor.hour, spec.scheduledFor.minute), (21, 30));
        }
        expect(store.reminderTime, _halfTen);
        expect(await cache.readReminderTime(), _halfTen);
      }),
    );

    test(
      'aus: die Uhrzeit wird gemerkt, geplant wird erst beim Einschalten',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = _store(cache, notifications);

        await store.setReminderTime(const ReminderTime(6, 45));
        expect(notifications.scheduled, isEmpty);
        expect(await cache.readReminderTime(), const ReminderTime(6, 45));

        await store.setNotificationsEnabled(true);
        // 06:45 is past at noon: tomorrow morning.
        expect(notifications.firstPlanned, DateTime(2026, 7, 16, 6, 45));
      }),
    );

    test(
      'dieselbe Uhrzeit noch einmal plant nicht erneut',
      () => _atNoon(() async {
        final notifications = _Notifications();
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'user-a'),
          notifications,
        );
        await store.setNotificationsEnabled(true);
        await store.setReminderTime(ReminderTime.standard);
        expect(notifications.scheduled, hasLength(1));
      }),
    );

    test(
      'Kaltstart: schon der erste Plan nutzt die gespeicherte Uhrzeit',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        await cache.writeNotificationsEnabled(true);
        await cache.writeReminderTime(_halfTen);
        final notifications = _Notifications();
        final store = _store(cache, notifications);

        await store.initNotificationsFromCache();

        expect(store.reminderState, ReminderState.active);
        expect(store.reminderTime, _halfTen);
        expect(
          notifications.scheduled,
          hasLength(1),
          reason: 'no 20:00 plan before the stored time arrives',
        );
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 21, 30));
      }),
    );

    test(
      'eine kaputte Uhrzeit im Cache faellt auf 20:00 zurueck',
      () => _atNoon(() async {
        final storage = InMemoryKeyValueStore();
        final cache = LocalCache(storage, 'user-a');
        await cache.writeNotificationsEnabled(true);
        await storage.setString(
          'eatova.v1.reminder_time.user-a',
          '{"hour": 25, "minute": 0}',
        );
        final notifications = _Notifications();
        final store = _store(cache, notifications);

        await store.initNotificationsFromCache();

        expect(store.reminderTime, ReminderTime.standard);
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 20));
      }),
    );

    test(
      'Plugin-Ausfall beim Neuplanen: kein Fehler, die Uhrzeit bleibt',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = _store(cache, notifications);
        await store.setNotificationsEnabled(true);
        notifications.failSchedule = true;

        await expectLater(
          store.setReminderTime(const ReminderTime(22, 0)),
          completes,
        );

        expect(store.reminderTime, const ReminderTime(22, 0));
        expect(await cache.readReminderTime(), const ReminderTime(22, 0));
        expect(store.reminderState, ReminderState.active);
      }),
    );
  });

  group('Kontotrennung', () {
    test(
      'Konto B sieht weder Uhrzeit noch Kartenantwort von Konto A',
      () => _atNoon(() async {
        final storage = InMemoryKeyValueStore();
        final cacheA = LocalCache(storage, 'A');
        await cacheA.writeReminderTime(const ReminderTime(6, 45));
        await cacheA.writeReminderPromptAnswered();
        final cacheB = LocalCache(storage, 'B');
        await cacheB.writeNotificationsEnabled(true);
        final notifications = _Notifications();
        final storeB = _store(cacheB, notifications);

        await storeB.initNotificationsFromCache();

        expect(storeB.reminderTime, ReminderTime.standard);
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 20));
        expect(await cacheB.readReminderTime(), isNull);
        expect(await cacheA.readReminderTime(), const ReminderTime(6, 45));
        expect(storage.snapshot.keys, contains('eatova.v1.reminder_time.A'));
        expect(
          storage.snapshot.keys,
          isNot(contains('eatova.v1.reminder_time.B')),
        );
      }),
    );

    test(
      'Abmelden loescht Uhrzeit und Kartenantwort, Konto B bleibt',
      () async {
        for (final atomic in [true, false]) {
          final storage = InMemoryKeyValueStore();
          final KeyValueStore store = atomic ? storage : _PlainStore(storage);
          for (final user in ['A', 'B']) {
            final cache = LocalCache(store, user);
            await cache.writeReminderTime(_halfTen);
            await cache.writeReminderPromptAnswered();
          }

          await LocalCache(store, 'A').clear(preserveOutbox: true);

          expect(storage.snapshot.keys.toSet(), <String>{
            'eatova.v1.reminder_time.B',
            'eatova.v1.reminder_prompt.B',
          }, reason: atomic ? 'atomic purge' : 'per-key purge');
        }
      },
    );
  });

  group('Karte auf Today', () {
    Future<HomeStore> booted(
      LocalCache cache,
      _Notifications notifications,
    ) async {
      final store = _store(cache, notifications);
      await store.initNotificationsFromCache();
      return store;
    }

    test(
      'erscheint erst nach Eintraegen an zwei verschiedenen Tagen',
      () => _atNoon(() async {
        final store = await booted(
          LocalCache(InMemoryKeyValueStore(), 'user-a'),
          _Notifications(),
        );
        expect(store.reminderPromptVisible, isFalse, reason: 'nothing logged');

        await store.addResultToDailyTotal(_meal);
        await store.addResultToDailyTotal(_meal);
        expect(
          store.reminderPromptVisible,
          isFalse,
          reason: 'two meals, one day',
        );

        await store.addResultToDailyTotal(
          _meal,
          foodDate: DateTime(2026, 7, 13),
        );
        expect(store.reminderPromptVisible, isTrue);
      }),
    );

    test(
      'nie, solange die Antwort des Kontos nicht gelesen ist',
      () => _atNoon(() async {
        final store = _store(
          LocalCache(InMemoryKeyValueStore(), 'user-a'),
          _Notifications(),
        )..lifetimeStats = LifetimeStats(longestStreak: 4);
        expect(store.reminderPromptVisible, isFalse);
        await store.initNotificationsFromCache();
        expect(store.reminderPromptVisible, isTrue);
      }),
    );

    test(
      'Nein danke: weg, auch nach einem Neustart',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = await booted(cache, notifications)
          ..lifetimeStats = LifetimeStats(currentStreak: 2);
        expect(store.reminderPromptVisible, isTrue);

        await store.dismissReminderPrompt();

        expect(store.reminderPromptVisible, isFalse);
        expect(
          notifications.requests,
          0,
          reason: 'no thanks asks the system nothing',
        );
        expect(await cache.readReminderPromptAnswered(), isTrue);
        final restarted = await booted(cache, _Notifications())
          ..lifetimeStats = LifetimeStats(currentStreak: 2);
        expect(restarted.reminderPromptVisible, isFalse);
      }),
    );

    test(
      'Annehmen: der bestehende Berechtigungs-Flow, danach aktiv und weg',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications();
        final store = await booted(cache, notifications)
          ..lifetimeStats = LifetimeStats(longestStreak: 3);
        await store.setReminderTime(_halfTen);

        final state = await store.acceptReminderPrompt();

        expect(state, ReminderState.active);
        expect(notifications.requests, 1);
        expect(notifications.firstPlanned, DateTime(2026, 7, 15, 21, 30));
        expect(store.reminderPromptVisible, isFalse);
        expect(await cache.readReminderPromptAnswered(), isTrue);
      }),
    );

    test(
      'Annehmen, Berechtigung verweigert: blockiert, weg, kein Nachfragen',
      () => _atNoon(() async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        final notifications = _Notifications(grant: false);
        final store = await booted(cache, notifications)
          ..lifetimeStats = LifetimeStats(longestStreak: 3);

        final state = await store.acceptReminderPrompt();

        expect(state, ReminderState.blocked);
        expect(store.reminderPromptVisible, isFalse);
        expect(notifications.requests, 1);
        expect(notifications.scheduled, isEmpty);

        // Next start: the card stays gone and nothing asks again.
        final again = _Notifications(grant: false);
        final restarted = await booted(cache, again)
          ..lifetimeStats = LifetimeStats(longestStreak: 3);
        expect(restarted.reminderPromptVisible, isFalse);
        expect(again.requests, 0);
      }),
    );

    test(
      'nur solange die Erinnerung aus ist',
      () => _atNoon(() async {
        final store = await booted(
          LocalCache(InMemoryKeyValueStore(), 'user-a'),
          _Notifications(),
        );
        store.lifetimeStats = LifetimeStats(longestStreak: 3);
        expect(store.reminderPromptVisible, isTrue);
        await store.setNotificationsEnabled(true);
        expect(store.reminderPromptVisible, isFalse);
        await store.setNotificationsEnabled(false);
        expect(
          store.reminderPromptVisible,
          isFalse,
          reason: 'a choice in the settings answers the card too',
        );
      }),
    );

    test(
      'wer frueher schon eingeschaltet hatte, sieht die Karte nie',
      () => _atNoon(() async {
        // Opted in before the card existed; the OS has since revoked
        // the permission, which writes the opt-in back to false.
        final cache = LocalCache(InMemoryKeyValueStore(), 'user-a');
        await cache.writeNotificationsEnabled(true);
        final store = await booted(cache, _Notifications(grant: false))
          ..lifetimeStats = LifetimeStats(longestStreak: 3);
        expect(store.reminderState, ReminderState.blocked);
        expect(store.reminderPromptVisible, isFalse);
        await pumpEventQueue();

        final restarted = await booted(cache, _Notifications())
          ..lifetimeStats = LifetimeStats(longestStreak: 3);
        expect(restarted.reminderState, ReminderState.off);
        expect(restarted.reminderPromptVisible, isFalse);
      }),
    );
  });

  group('loggedOnTwoDays', () {
    LoggedMeal meal(String id, DateTime at, {String? localDay}) =>
        LoggedMeal(id: id, result: _meal, loggedAt: at, localDay: localDay);

    test('ein Tag reicht nicht, zwei verschiedene schon', () {
      final morning = meal('1', DateTime(2026, 7, 15, 8));
      final evening = meal('2', DateTime(2026, 7, 15, 19));
      expect(loggedOnTwoDays([morning, evening], LifetimeStats()), isFalse);
      expect(
        loggedOnTwoDays([
          morning,
          meal('3', DateTime(2026, 7, 14, 12)),
        ], LifetimeStats()),
        isTrue,
      );
    });

    test('der gespeicherte Kalendertag zaehlt, nicht der Zeitstempel', () {
      // Logged after midnight for the day before (DATA-6).
      final late = meal(
        '1',
        DateTime(2026, 7, 15, 0, 30),
        localDay: '2026-07-14',
      );
      final today = meal('2', DateTime(2026, 7, 15, 12));
      expect(loggedOnTwoDays([late, today], LifetimeStats()), isTrue);
    });

    test('die Serie traegt Tage ausserhalb des geladenen Fensters', () {
      expect(
        loggedOnTwoDays(const [], LifetimeStats(longestStreak: 2)),
        isTrue,
      );
      expect(
        loggedOnTwoDays(const [], LifetimeStats(currentStreak: 2)),
        isTrue,
      );
      expect(
        loggedOnTwoDays(const [], LifetimeStats(currentStreak: 1)),
        isFalse,
      );
    });
  });
}

/// A store without the atomic batch, so [LocalCache.clear] takes its
/// per-key path.
class _PlainStore implements KeyValueStore {
  _PlainStore(this._inner);

  final KeyValueStore _inner;

  @override
  Future<String?> getString(String key) => _inner.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _inner.setString(key, value);

  @override
  Future<void> remove(String key) => _inner.remove(key);
}
