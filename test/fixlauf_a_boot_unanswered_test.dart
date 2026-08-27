import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/theme/app_theme.dart';

import 'fixlauf_a_helpers.dart';

// Review 2026-08-27, F1-06: without a cached profile the boot budget opened
// the gate on ctor defaults, and `needsOnboarding` (a ctor default too) sent a
// RETURNING user through onboarding — which vanished mid-way once the server
// answered, or whose completion overwrote the server profile.
//
// Contract: the shell shows a "slow connection" state with a retry until the
// server has actually answered (row, or no row). Onboarding only after that.

const UserProfile _bootstrap = UserProfile();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Store-Zustand bootUnanswered', () {
    test('Budget-Timeout ohne Cache: bootUnanswered statt Onboarding, die '
        'spaete Server-Antwort fuehrt korrekt weiter', () {
      fakeAsync((async) {
        final s = fixlaufSetup(disposeClient: false);
        s.server.profileRow = serverProfileRow(completedProfile);
        s.server.holdReads = true;
        var offen = false;
        s.store.profileReady.then((_) => offen = true);

        s.store.start();
        async.elapse(kBootNetworkBudget + const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(offen, isTrue, reason: 'Vorbedingung: das Budget hat das Gate '
            'geoeffnet');
        expect(s.store.bootUnanswered, isTrue,
            reason: 'ohne Server-Antwort weiss der Store nichts — kein '
                'Onboarding auf Ctor-Defaults');

        s.server.releaseReads();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(s.store.bootUnanswered, isFalse);
        expect(s.store.needsOnboarding, isFalse,
            reason: 'Bestandsnutzer: onboarding_completed=true vom Server');
        expect(s.store.profile.weightKg, 80);
      });
    });

    test('Server liefert onboarding_completed=false: dann (und erst dann) '
        'Onboarding', () {
      fakeAsync((async) {
        final s = fixlaufSetup(disposeClient: false);
        s.server.profileRow = serverProfileRow(_bootstrap);
        s.server.holdReads = true;
        s.store.start();
        async.elapse(kBootNetworkBudget + const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(s.store.bootUnanswered, isTrue);

        s.server.releaseReads();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(s.store.bootUnanswered, isFalse);
        expect(s.store.needsOnboarding, isTrue);
      });
    });

    test('keine Zeile (frischer Nutzer) zaehlt als Antwort: Onboarding',
        () async {
      final s = fixlaufSetup();
      await bootStore(s.store);
      expect(s.store.bootUnanswered, isFalse);
      expect(s.store.needsOnboarding, isTrue);
    });

    test('Cache-Profil: nie bootUnanswered, auch bei stummem Server',
        () async {
      final s = fixlaufSetup(disposeClient: false);
      await s.cache!.writeProfile(completedProfile);
      s.server.silent = true;
      s.store.start();
      await s.store.profileReady.timeout(const Duration(seconds: 3));
      expect(s.store.bootUnanswered, isFalse);
      expect(s.store.needsOnboarding, isFalse);
    });

    test('sofortiger Offline-Fehler ohne Cache: bootUnanswered; retryBoot '
        'laedt nach, sobald das Netz da ist', () async {
      final s = fixlaufSetup();
      s.server.profileRow = serverProfileRow(completedProfile);
      s.server.offline = true;
      await bootStore(s.store);
      expect(s.store.bootUnanswered, isTrue,
          reason: 'ein Fehler ist keine Antwort');

      s.server.offline = false;
      await s.store.retryBoot();
      await settle();

      expect(s.store.bootUnanswered, isFalse);
      expect(s.store.profile.weightKg, 80);
      expect(s.store.needsOnboarding, isFalse);
    });

    test('zwei retryBoot-Taps sind EIN Load', () async {
      final s = fixlaufSetup();
      s.server.profileRow = serverProfileRow(completedProfile);
      s.server.offline = true;
      await bootStore(s.store);
      expect(s.store.bootUnanswered, isTrue, reason: 'Vorbedingung');
      expect(s.store.bootLoadInFlight, isFalse, reason: 'Vorbedingung');

      s.server.offline = false;
      final vorher = s.server.requestsTo('/profiles', method: 'GET').length;
      await Future.wait([s.store.retryBoot(), s.store.retryBoot()]);
      await settle();

      expect(s.server.requestsTo('/profiles', method: 'GET').length, vorher + 1,
          reason: 'der zweite Tap darf keinen parallelen Load starten');
      expect(s.store.bootUnanswered, isFalse);
    });

    test('Retry in der Vor-Load-Phase (Replay haengt): kein zweiter Load, die '
        'Shell sieht Fortschritt', () async {
      final s = fixlaufSetup();
      s.server.profileRow = serverProfileRow(completedProfile);
      // A persisted op makes the boot replay BEFORE its server load; the held
      // write pins the chain there.
      await s.cache!.writeOutbox([
        SyncOp.mealInsert(
          LoggedMeal(
            id: 'm-haengt',
            result: mealResult('Haengt'),
            loggedAt: DateTime.now(),
          ),
          trackDay: false,
        ),
      ]);
      s.server.holdWrites = true;
      s.store.start();
      await settle();
      expect(s.server.heldWrites, greaterThanOrEqualTo(1), reason: 'Vorbedingung');
      expect(s.server.requestsTo('/profiles', method: 'GET'), isEmpty,
          reason: 'Vorbedingung: noch vor dem Server-Load');
      expect(s.store.bootLoadInFlight, isTrue,
          reason: 'die ganze Kette zaehlt als Laden — Spinner, kein Button');

      await s.store.retryBoot();
      await settle();
      expect(s.server.requestsTo('/profiles', method: 'GET'), isEmpty,
          reason: 'kein paralleler Load waehrend der Vor-Load-Phase');

      s.server.holdWrites = false;
      s.server.releaseWrites();
      await s.store.profileReady;
      await settle();
      expect(s.server.requestsTo('/profiles', method: 'GET'), hasLength(1));
      expect(s.store.bootLoadInFlight, isFalse);
      expect(s.store.profile.weightKg, 80);
    });

    test('Serverfehler (500) auf profiles ist ebenfalls keine Antwort',
        () async {
      final s = fixlaufSetup();
      s.server.profileRow = serverProfileRow(completedProfile);
      s.server.rejectProfileReads = true;
      await bootStore(s.store);
      expect(s.store.bootUnanswered, isTrue,
          reason: 'ein 500 sagt nichts ueber die Zeile — Onboarding wuerde '
                  'sie mit completeOnboarding ueberschreiben');
    });
  });

  group('Shell', () {
    testWidgets('nach dem Budget zeigt die Shell den Verbindungs-Screen mit '
        'Fortschritt (Load laeuft noch), kein Onboarding; die spaete Antwort '
        'fuehrt ins Onboarding', (tester) async {
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(_bootstrap)
        ..holdReads = true;
      await _pumpHome(tester, server: server);

      // Past the budget: the welcome gate falls without a profile.
      await tester.pump(kBootNetworkBudget + const Duration(seconds: 1));
      await _drain(tester);

      expect(find.byKey(const ValueKey('screen-boot-unanswered')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing,
          reason: 'kein Onboarding, solange der Server nicht geantwortet hat');
      expect(find.text(deL10n.commonBootUnansweredTitle), findsOneWidget);
      // The first load is still on the wire (bounded by the PostgREST
      // timeout in production): progress, no second request.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('boot-unanswered-retry')),
          findsNothing);

      // The server finally answers with the bootstrap row -> onboarding.
      server.releaseReads();
      await _drain(tester);
      expect(find.byKey(const ValueKey('screen-boot-unanswered')),
          findsNothing);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);
    });

    testWidgets('schneller Fehlschlag: Retry-Button loest den Server-Load '
        'erneut aus und fuehrt korrekt weiter', (tester) async {
      final server = FixlaufServer()
        ..profileRow = serverProfileRow(completedProfile)
        ..offline = true;
      await _pumpHome(tester, server: server);
      // postgrest retries a failed GET three times (1 + 2 + 4 s) before the
      // error reaches the store; past that (and the budget) the load is over.
      await tester.pump(kBootNetworkBudget + const Duration(seconds: 1));
      await _drain(tester, rounds: 40);

      expect(find.byKey(const ValueKey('screen-boot-unanswered')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
      expect(find.text(deL10n.commonBootUnansweredRetry), findsOneWidget,
          reason: 'Load beendet -> Retry statt Fortschritt');

      server.offline = false;
      final profileReadsVorher =
          server.requestsTo('/profiles', method: 'GET').length;
      await tester.tap(find.byKey(const ValueKey('boot-unanswered-retry')));
      await _drain(tester, rounds: 40);

      expect(server.requestsTo('/profiles', method: 'GET').length,
          greaterThan(profileReadsVorher),
          reason: 'Retry loest den Server-Load erneut aus');
      expect(find.byKey(const ValueKey('screen-boot-unanswered')),
          findsNothing);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing,
          reason: 'Bestandsnutzer: onboarding_completed=true');
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    });
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required FixlaufServer server,
}) async {
  final supa = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: server.client(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final sync = EatovaSync.forUser(supa, kFixlaufUser);
  final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Reduced motion: the welcome exit finishes without ticking.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  await tester.pumpWidget(MaterialApp(
    theme: buildEatovaTheme(Brightness.dark),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: EatovaHomePage(sync: sync, debugCache: cache, showWelcome: false),
  ));
  await _drain(tester);
  expect(find.byKey(const ValueKey('screen-welcome')), findsOneWidget,
      reason: 'Vorbedingung: ohne Cache-Profil haelt das Gate');
}

Future<void> _drain(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}
