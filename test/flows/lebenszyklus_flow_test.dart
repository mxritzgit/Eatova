// The whole lifecycle of a new account in ONE continuous path: register ->
// onboarding -> first meal -> diary -> slot total -> delete -> undo. Split
// into separate tests each half would start from a state the other half never
// produced, which is exactly where integration bugs hide.
//
// Unlike the other flows this suite composes the shell itself (AuthGate over
// EatovaHomePage with a real EatovaSync on a fake PostgREST). `EatovaApp`
// builds its sync from `Supabase.instance`, which no test can inject, so
// pumping EatovaApp lands in preview mode where `needsOnboarding` never opens
// and no write ever reaches a server. Runs in English.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/theme/app_theme.dart';

import '../fixlauf_a_helpers.dart';
import 'flow_test_helpers.dart';

/// Pumps until [finder] is gone; fails with [what] instead of hanging.
///
/// The mirror image of [pumpUntil], which waits for a condition to BECOME
/// true; here the boot gate has to disappear.
Future<void> _waitGone(
  WidgetTester tester,
  Finder finder,
  String what, {
  int maxFrames = 900,
}) async {
  for (var i = 0; i < maxFrames && finder.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsNothing, reason: '$what verschwindet nicht');
  await settleFrames(tester);
}

void main() {
  testWidgetsRobust(
      'Registrierung, Onboarding, erste Mahlzeit, Tagebuch, Löschen, Undo',
      (WidgetTester tester) async {
    // No profile row: the onboarding gate must open after the boot load.
    final server = FixlaufServer();
    // NOT disposed in a tearDown: `SupabaseClient.dispose()` awaits its REST,
    // functions and isolate layers, and a tearDown runs OUTSIDE the fake-async
    // zone, so that await never completes and the test hangs into the
    // ten-minute timeout. The MockClient holds no socket worth closing.
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: server.client(),
      // Or GoTrue's refresh ticker stays a pending timer past the test.
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final authRepository = InMemoryAuthRepository();
    addTearDown(authRepository.dispose);
    final kv = InMemoryKeyValueStore();

    // Memoised: AuthGate's builder runs on every rebuild, and a fresh sync or
    // cache per build would leave the shell writing through objects nobody
    // reads.
    EatovaSync? sync;
    LocalCache? cache;

    await tester.pumpWidget(MaterialApp(
      theme: buildEatovaTheme(Brightness.light),
      locale: const Locale('en'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: AuthGate(
        authRepository: authRepository,
        // `LocalCache.create` needs SharedPreferences and the OS keystore.
        debugPurgeCache: (_) async {},
        builder: (context, user, freshLogin) {
          sync ??= EatovaSync.forUser(client, user.id);
          cache ??= LocalCache(kv, user.id);
          return EatovaHomePage(
            key: ValueKey('home-${user.id}'),
            productService: FakeProductLookupService(),
            initialUserName: user.firstNameFor(context.l10n),
            sync: sync,
            showWelcome: freshLogin,
            debugCache: cache,
          );
        },
      ),
    ));
    await tester.pump();

    // ---- 1. Registration ---------------------------------------------------
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
    await settleFrames(tester);

    await tester.enterText(
      find.byKey(const ValueKey('auth-name-field')),
      'Moritz',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'neu@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password-field')),
      'eatova123',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await settleFrames(tester);

    // Sign-up confirms the address with an 8-digit code before the home page.
    expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('code-field')),
      '12345678',
    );
    await tester.tap(find.byKey(const ValueKey('code-primary')));
    await tester.pump();

    // `InMemoryAuthRepository._verify` accepts ANY string, so reaching the home
    // page proves nothing about the code. This is the only line that shows the
    // TYPED code (address included) actually reached the repository — a screen
    // that swallowed the field and sent a constant would pass everything else.
    expect(authRepository.verifiedCodes, <String>['neu@example.com:12345678'],
        reason: 'genau EIN verifizierter Code, und zwar der eingetippte '
            '8-stellige');

    // ---- 2. Boot gate, then mandatory onboarding ---------------------------
    await _waitGone(
      tester,
      find.byKey(const ValueKey('screen-welcome')),
      'das Boot-Gate',
    );

    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget,
        reason: 'ein frisches Konto ohne Profilzeile muss ins Onboarding');
    expect(find.byKey(const ValueKey('onboarding-step-intro')), findsOneWidget);

    Future<void> tapKey(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await settleFrames(tester);
    }

    Future<void> next(String expectedStep) async {
      await tapKey('onboarding-next');
      expect(
        find.byKey(ValueKey('onboarding-step-$expectedStep')),
        findsOneWidget,
        reason: 'nach „Weiter" fehlt der Schritt $expectedStep',
      );
    }

    await next('sex');
    await tapKey('onboarding-sex-female');
    await next('age');
    await next('height');
    await next('weight');
    await next('activity');
    await tapKey('onboarding-activity-moderate');
    await next('goal');
    // Losing weight unlocks target and pace.
    await tapKey('onboarding-goal-lose');
    await next('target');
    await next('pace');
    await tapKey('onboarding-pace-lose05kg');
    await next('diet');
    await tapKey('onboarding-diet-vegetarian');
    await next('summary');
    expect(find.byKey(const ValueKey('onboarding-summary-kcal')), findsOneWidget);

    await tapKey('onboarding-finish');
    await settleFrames(tester);

    expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing,
        reason: 'nach „Plan aktivieren" darf das Gate nicht mehr stehen');
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    // The finished plan reached the server, not just the local store.
    expect(server.profileRow?['onboarding_completed'], isTrue,
        reason: 'das Onboarding hat keine Profilzeile geschrieben');

    final store = storeOf(tester);
    expect(store.profile.onboardingCompleted, isTrue);

    // ---- 3. First meal, logged into a slot the user picked -----------------
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await settleFrames(tester);

    // The day starts empty.
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);

    // The slot card's plus button opens the sheet for THIS slot, so the entry
    // cannot land elsewhere via the time-of-day heuristic.
    await tester.tap(find.byKey(const ValueKey('food-slot-add-breakfast')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('add-meal-sheet')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('kcal-product-search-input')),
      'Dr Oetker Salami',
    );
    await tester.tap(find.byKey(const ValueKey('kcal-product-search-button')));
    await settleFrames(tester);

    await tester.tap(find.byKey(const ValueKey('kcal-product-suggestion-0')));
    await settleFrames(tester);
    final addButton =
        find.byKey(const ValueKey('kcal-product-suggestion-add-0'));
    await tester.ensureVisible(addButton);
    await settleFrames(tester);
    await tester.tap(addButton);
    await settleFrames(tester);
    expect(find.text('Added 252 kcal to Breakfast.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-meal-sheet-close')));
    await settleFrames(tester);

    // ---- 4. Diary shows it, slot total and day total agree -----------------
    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(find.text('252 kcal · 1 entry'), findsOneWidget,
        reason: 'die Slot-Summe der Frühstückskarte fehlt');
    expect(store.loggedMeals.single.slot, MealSlot.breakfast);
    // The write reached the fake server as ONE row.
    expect(server.mealRows.length, 1);
    expect(store.pendingOutbox, isEmpty,
        reason: 'online darf nichts in der Outbox liegen bleiben');

    // The Heute tab carries the same day total …
    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await settleFrames(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('today-stat-eaten')),
        matching: find.text('252'),
      ),
      findsOneWidget,
      reason: 'der Heute-Hero nennt nicht 252 gegessene kcal',
    );
    // … and the breakfast row its slot total.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('today-meal-row-breakfast')),
        matching: find.text('252'),
      ),
      findsOneWidget,
      reason: 'die Frühstückszeile im Heute-Tab trägt die Slot-Summe nicht',
    );

    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await settleFrames(tester);

    // ---- 5. Delete via swipe -----------------------------------------------
    // Let the confirmation toast expire: it covers the bottom diary rows.
    await tester.pump(const Duration(seconds: 4));
    await settleFrames(tester);

    await tester.ensureVisible(
      find.byKey(const ValueKey('food-history-entry-0')),
    );
    await settleFrames(tester);
    await tester.drag(
      find.byKey(const ValueKey('food-history-entry-0')),
      const Offset(-300, 0),
    );
    await settleFrames(tester);
    final deleteAction = find.byKey(const ValueKey('food-history-delete-0'));
    expect(deleteAction, findsOneWidget);
    await tester.ensureVisible(deleteAction);
    await settleFrames(tester);
    await tester.tap(deleteAction);
    // The row resizes out over a hard 220 ms before onDelete fires.
    await settleFrames(tester);

    expect(find.byKey(const ValueKey('food-history-entry-0')), findsNothing);
    expect(store.loggedMeals, isEmpty);
    expect(server.mealRows, isEmpty,
        reason: 'der Delete hat den Server nicht erreicht');

    // ---- 6. Undo brings it back --------------------------------------------
    expect(find.text('Meal deleted'), findsOneWidget);
    final undo = find.text('Undo');
    expect(undo, findsOneWidget, reason: 'der Lösch-Toast bietet kein Undo an');
    await tester.tap(undo);
    await settleFrames(tester);

    expect(find.byKey(const ValueKey('food-history-entry-0')), findsOneWidget);
    expect(store.loggedMeals.single.slot, MealSlot.breakfast);
    expect(find.text('252 kcal · 1 entry'), findsOneWidget,
        reason: 'nach dem Undo stimmt die Slot-Summe nicht mehr');
    // Restored server-side too — and as the SAME row, not a second one.
    expect(server.mealRows.length, 1);

    await tester.tap(find.byKey(const ValueKey('nav-Heute')));
    await settleFrames(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('today-stat-eaten')),
        matching: find.text('252'),
      ),
      findsOneWidget,
      reason: 'nach dem Undo fehlen die 252 kcal in der Tagessumme',
    );
  });
}
