// C4: Today offers the reminder once — after logs on two different days,
// only while it is off, and never again after "yes" or "no thanks".

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/reminder_time.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/today/today_reminder_prompt.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';

import '../support/harness.dart';
import '../support/today_summary.dart';

class _Notifications
    implements NotificationService, NotificationPermissionProbe {
  _Notifications({this.grant = true});

  final bool grant;
  int requests = 0;
  final List<List<NotificationSpec>> scheduled = <List<NotificationSpec>>[];

  @override
  Future<void> init() async {}
  @override
  Future<bool> hasPermission() async => grant;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return grant;
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      scheduled.add(specs);
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

final DateTime _now = DateTime(2026, 9, 8, 12);

const Key _card = ValueKey('today-reminder-prompt');

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('Karte', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      Future<void> Function()? onAccept,
      Future<void> Function()? onDismiss,
      ValueChanged<ReminderTime>? onChangeTime,
    }) => pumpLocalized(
      tester,
      SingleChildScrollView(
        child: TodayReminderPromptCard(
          time: const ReminderTime(21, 30),
          onAccept: onAccept ?? () async {},
          onDismiss: onDismiss ?? () async {},
          onChangeTime: onChangeTime,
        ),
      ),
      settle: true,
    );

    testWidgets('fragt mit Uhrzeit und bietet Ja und Nein danke', (
      tester,
    ) async {
      pinPhoneViewport(tester);
      await pumpCard(tester, onChangeTime: (_) {});
      expect(find.text('Soll ich dich abends erinnern?'), findsOneWidget);
      expect(
        find.text(
          'Um 21:30, falls du an dem Tag noch nichts eingetragen hast, damit '
          'deine Serie hält. Alles bleibt auf deinem Gerät.',
        ),
        findsOneWidget,
      );
      expect(find.text('Ja, erinnere mich'), findsOneWidget);
      expect(find.text('Nein danke'), findsOneWidget);
      expect(find.text('Andere Uhrzeit'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Uhrzeit der Erinnerung ändern, jetzt 21:30'),
        findsOneWidget,
      );
    });

    testWidgets('eine Antwort zur Zeit: ein zweiter Tipp waehrenddessen zaehlt '
        'nicht', (tester) async {
      pinPhoneViewport(tester);
      final pending = Completer<void>();
      var accepted = 0;
      var dismissed = 0;
      await pumpCard(
        tester,
        onAccept: () {
          accepted++;
          return pending.future;
        },
        onDismiss: () async => dismissed++,
      );
      await tester.tap(
        find.byKey(const ValueKey('today-reminder-prompt-accept')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('today-reminder-prompt-dismiss')),
      );
      await tester.pump();
      expect((accepted, dismissed), (1, 0));
      pending.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('andere Uhrzeit ueber den Timepicker', (tester) async {
      pinPhoneViewport(tester);
      final picked = <ReminderTime>[];
      await pumpCard(tester, onChangeTime: picked.add);

      await _tap(
        tester,
        find.byKey(const ValueKey('today-reminder-prompt-time')),
      );
      await _tap(tester, find.byIcon(Icons.keyboard_outlined));
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '19');
      await tester.enterText(fields.at(1), '0');
      await _tap(tester, find.text('OK'));

      expect(picked, const <ReminderTime>[ReminderTime(19, 0)]);
    });

    renderMatrix(
      'passt bei 320 px und doppelter Schrift',
      (tester, c) async {
        await c.pump(
          tester,
          SizedBox(
            width: 320,
            child: TodayReminderPromptCard(
              time: const ReminderTime(21, 30),
              onAccept: () async {},
              onDismiss: () async {},
              onChangeTime: (_) {},
            ),
          ),
          scrollable: true,
        );
        expect(tester.takeException(), isNull);
      },
      locales: const [Locale('de'), Locale('en')],
      textScales: const [1.0, 2.0],
    );
  });

  group('auf dem Today-Screen', () {
    TodayScreen today({required DateTime selectedDate, ReminderTime? prompt}) =>
        TodayScreen(
          userName: 'Moritz',
          profile: const UserProfile(),
          summary: todaySummary(profile: const UserProfile()),
          meals: const [],
          selectedDate: selectedDate,
          streak: 0,
          reminderPrompt: prompt,
          onAcceptReminderPrompt: () async {},
          onDismissReminderPrompt: () async {},
        );

    Future<void> pumpToday(WidgetTester tester, TodayScreen screen) =>
        withClock(Clock.fixed(_now), () async {
          await pumpLocalized(
            tester,
            screen,
            surfaceSize: const Size(390, 2400),
            scaffold: false,
            safeArea: false,
          );
          await tester.pump(const Duration(seconds: 2));
        });

    testWidgets('heute mit Angebot: die Karte steht da', (tester) async {
      await pumpToday(
        tester,
        today(selectedDate: startOfDay(_now), prompt: ReminderTime.standard),
      );
      expect(find.byKey(_card), findsOneWidget);
    });

    testWidgets('ohne Angebot oder an einem Archivtag nicht', (tester) async {
      await pumpToday(tester, today(selectedDate: startOfDay(_now)));
      expect(find.byKey(_card), findsNothing);
      await pumpToday(
        tester,
        today(
          selectedDate: addDays(startOfDay(_now), -1),
          prompt: ReminderTime.standard,
        ),
      );
      expect(find.byKey(_card), findsNothing);
    });
  });

  group('im App-Geruest', () {
    Future<HomeStore> pumpShell(
      WidgetTester tester,
      LocalCache cache,
      _Notifications notifications,
    ) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        EatovaHomePage(notificationService: notifications, debugCache: cache),
        scaffold: false,
        safeArea: false,
      );
      final store =
          (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
              .debugStore;
      await store.initNotificationsFromCache();
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('erst nach dem zweiten Tag, nach Nein danke nie wieder', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final cache = LocalCache(InMemoryKeyValueStore(), 'today-card');
        var store = await pumpShell(tester, cache, _Notifications());

        await store.addResultToDailyTotal(_meal);
        await tester.pumpAndSettle();
        expect(find.byKey(_card), findsNothing, reason: 'one day only');

        await store.addResultToDailyTotal(
          _meal,
          foodDate: DateTime(2026, 9, 6),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_card), findsOneWidget);
        expect(find.textContaining('Um 20:00, falls du'), findsOneWidget);

        await _tap(
          tester,
          find.byKey(const ValueKey('today-reminder-prompt-dismiss')),
        );
        expect(find.byKey(_card), findsNothing);
        expect(store.reminderState, ReminderState.off);

        // "Restart" on the same account cache: still gone.
        await tester.pumpWidget(const SizedBox.shrink());
        store = await pumpShell(tester, cache, _Notifications());
        await store.addResultToDailyTotal(_meal);
        await store.addResultToDailyTotal(
          _meal,
          foodDate: DateTime(2026, 9, 6),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_card), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('Ja: Berechtigung, Erinnerung an, ehrliche Bestaetigung', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final notifications = _Notifications();
        final store = await pumpShell(
          tester,
          LocalCache(InMemoryKeyValueStore(), 'today-card'),
          notifications,
        );
        await store.addResultToDailyTotal(_meal);
        await store.addResultToDailyTotal(
          _meal,
          foodDate: DateTime(2026, 9, 7),
        );
        await tester.pumpAndSettle();

        await _tap(
          tester,
          find.byKey(const ValueKey('today-reminder-prompt-accept')),
        );

        expect(notifications.requests, 1);
        expect(store.reminderState, ReminderState.active);
        expect(find.byKey(_card), findsNothing);
        expect(find.text('Erinnerung an: täglich um 20:00.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    testWidgets('Ja, aber verweigert: ehrlich gesagt, Karte weg', (
      tester,
    ) async {
      await withClock(Clock.fixed(_now), () async {
        final notifications = _Notifications(grant: false);
        final store = await pumpShell(
          tester,
          LocalCache(InMemoryKeyValueStore(), 'today-card'),
          notifications,
        );
        await store.addResultToDailyTotal(_meal);
        await store.addResultToDailyTotal(
          _meal,
          foodDate: DateTime(2026, 9, 7),
        );
        await tester.pumpAndSettle();

        await _tap(
          tester,
          find.byKey(const ValueKey('today-reminder-prompt-accept')),
        );

        expect(store.reminderState, ReminderState.blocked);
        expect(find.byKey(_card), findsNothing);
        expect(
          find.text(
            'Mitteilungen sind für Eatova nicht erlaubt. Du kannst sie in den '
            'Systemeinstellungen einschalten.',
          ),
          findsOneWidget,
        );
        expect(notifications.requests, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  });
}
