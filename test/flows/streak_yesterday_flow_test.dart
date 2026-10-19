// Saving the streak by back-filling yesterday, through the real shell
// (2026-10-19): before today's first entry, with yesterday empty and the
// chain ending the day before yesterday, Today shows a quiet hint. It opens
// the add sheet on yesterday, and the entry goes out with track_day for
// yesterday's local day, which the server's record_tracking_day counts +1.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/theme/app_theme.dart';

import 'flow_test_helpers.dart';
import '../support/fixlauf_a_helpers.dart';

/// Thursday midday, far from any midnight or DST edge.
final DateTime _now = DateTime(2026, 8, 20, 12, 30);

Future<HomeStore> _pumpSignedIn(
  WidgetTester tester,
  FixlaufServer server,
) async {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.light),
      locale: const Locale('en'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: EatovaHomePage(
        productService: FakeProductLookupService(),
        sync: EatovaSync.forUser(client, kFixlaufUser),
        debugCache: LocalCache(InMemoryKeyValueStore(), kFixlaufUser),
        showWelcome: false,
      ),
    ),
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'das Boot-Gate verschwindet',
  );
  return storeOf(tester);
}

void main() {
  testWidgetsRobust(
    'der Hinweis oeffnet gestern, der Nachtrag zaehlt gestern und rettet die '
    'Serie',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(_now), () async {
        final server = FixlaufServer()
          ..profileRow = serverProfileRow(completedProfile);
        final store = await _pumpSignedIn(tester, server);
        store.lifetimeStats = LifetimeStats(
          mealsLogged: 30,
          currentStreak: 5,
          longestStreak: 5,
          lastTrackedDate: DateTime(2026, 8, 18),
        );
        await tester.tap(find.byKey(const ValueKey('nav-Heute')));
        await settleFrames(tester);

        final hint = find.byKey(const ValueKey('today-yesterday-hint'));
        expect(hint, findsOneWidget);
        expect(
          find.text('Yesterday is still empty – logging it keeps your streak.'),
          findsOneWidget,
        );
        // The broken chain shows no pill until yesterday is back.
        expect(find.byKey(const ValueKey('today-streak')), findsNothing);

        await tester.ensureVisible(hint);
        await settleFrames(tester);
        await tester.tap(hint);
        await settleFrames(tester);

        expect(store.selectedTab, 1);
        expect(store.selectedFoodDate, DateTime(2026, 8, 19));
        expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('add-meal-date-context')))
              .data,
          contains('Aug 19'),
        );

        await tester.enterText(
          find.byKey(const ValueKey('kcal-product-search-input')),
          'Dr Oetker Salami',
        );
        await tester.tap(
          find.byKey(const ValueKey('kcal-product-search-button')),
        );
        await settleFrames(tester);
        await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
        await settleFrames(tester);
        final add = find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
        await tester.ensureVisible(add);
        await settleFrames(tester);
        await tester.tap(add);
        await settleFrames(tester);
        await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
        await settleFrames(tester);

        expect(store.mealsForFoodDate(DateTime(2026, 8, 19)), hasLength(1));
        // The +1 itself is the store test's (home_store_streak_backfill);
        // this fake server answers every stats read with a streak of 1.
        expect(store.lifetimeStats.lastTrackedDate, DateTime(2026, 8, 19));
        await pumpUntil(
          tester,
          () => server.trackedDay != null,
          'the insert reaches the server',
        );
        expect(
          server.trackedDay,
          '2026-08-19',
          reason: 'track_day for yesterday: record_tracking_day(yesterday)',
        );

        // Back on today: the chain is alive again, the hint is gone.
        store.setFoodDate(DateTime(2026, 8, 20));
        await tester.tap(find.byKey(const ValueKey('nav-Heute')));
        await settleFrames(tester);
        expect(find.byKey(const ValueKey('today-yesterday-hint')), findsNothing);
        expect(find.byKey(const ValueKey('today-streak')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
