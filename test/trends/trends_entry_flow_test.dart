// The way to the trends page through the real shell (2026-10-18): Today's
// trends card and the Food tab's header button both open it over the
// store's data, and a meal whose write is still in the outbox already counts
// there (TRN-9), although the server window does not know it yet.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/trends_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/services/trend_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

import '../flows/flow_test_helpers.dart';
import '../support/fixlauf_a_helpers.dart';
import '../support/food_navigation.dart';

/// A plain midday, far from any midnight or DST edge.
final DateTime _now = DateTime(2026, 8, 20, 12, 30);
final DateTime _yesterday = DateTime(2026, 8, 19);

/// [pumpSignedIn] with a trends loader that serves [serverTotals]; the
/// server window here never contains the meal logged in the test.
Future<HomeStore> _pumpSignedIn(
  WidgetTester tester,
  FixlaufServer server, {
  required List<TrendDayTotals> serverTotals,
}) async {
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
        trendTotalsLoader: () async => serverTotals,
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

Future<void> _openFromTodayCard(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-Heute')));
  await settleFrames(tester);
  final card = find.byKey(const ValueKey('today-trends'));
  await tester.ensureVisible(card);
  await settleFrames(tester);
  await tester.tap(card);
  await settleFrames(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('trends-close')));
  await settleFrames(tester);
}

void main() {
  testWidgetsRobust(
    'Today-Karte und Food-Kopf oeffnen die Trends, ein Eintrag in der '
    'Outbox zaehlt dort schon',
    (WidgetTester tester) async {
      await withClock(Clock.fixed(_now), () async {
        final server = FixlaufServer()
          ..profileRow = serverProfileRow(completedProfile)
          // The write stays in the outbox (retryable server error).
          ..rejectMealWrites = true;
        final store = await _pumpSignedIn(
          tester,
          server,
          serverTotals: const <TrendDayTotals>[],
        );

        // Book the fake salami (252 kcal) onto yesterday.
        await tester.tap(find.byKey(const ValueKey('nav-Food')));
        await settleFrames(tester);
        await selectFoodDayOffset(tester, 1);
        await settleFrames(tester);
        await logSalami(tester, 'dinner');
        expect(store.mealsForFoodDate(_yesterday), hasLength(1));
        expect(
          store.trendLocalTotals()[localDayKey(_yesterday)]?.kcal,
          252,
          reason: 'the pending write is part of the store day',
        );

        // Back to today: the card shows yesterday's average.
        await selectFoodDayOffset(tester, 0);
        await settleFrames(tester);
        await _openFromTodayCard(tester);
        expect(find.byType(TrendsScreen), findsOneWidget);
        // 252 kcal is below half the goal: a logged but incomplete day. The
        // tile names it instead of "no completed day", so the page knows
        // the day although the server window is empty (TRN-9).
        expect(find.byKey(const ValueKey('trends-empty')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('trends-avg-kcal')),
            matching: find.text('no complete day yet'),
          ),
          findsOneWidget,
          reason: 'the server window is empty; the outbox day counts (TRN-9)',
        );
        expect(find.byKey(const ValueKey('trends-steps')), findsOneWidget);
        await _back(tester);
        expect(find.byType(TrendsScreen), findsNothing);

        // The Food tab's header button leads to the same page.
        await tester.tap(find.byKey(const ValueKey('nav-Food')));
        await settleFrames(tester);
        await tester.tap(find.byKey(const ValueKey('food-trends')));
        await settleFrames(tester);
        expect(find.byType(TrendsScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('trends-weight')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
