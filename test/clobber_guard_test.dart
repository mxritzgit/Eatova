import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/theme/app_theme.dart';

// DATA-3 clobber guard: an offline cold start (ProfileSync.load() throws)
// must never overwrite the real server profile row with the bare ctor
// defaults (78 kg / 178 cm).
//
// These tests drive the real EatovaHomePage with a real EatovaSync over a
// recording MockClient:
//   * every GET on /profiles answers 500 -> load() throws -> no hydration
//   * all other reads return empty lists (_safeLoad swallows them)
//   * every write request (POST/PATCH/PUT) is recorded
//
// The LocalCache is injected via the `debugCache` seam (no plugin channel,
// no Supabase session).
//
// Invariant: no profiles write with weight_kg == 78 during the whole boot.

class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  http.Client client() {
    return MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      final isWrite = req.method == 'POST' ||
          req.method == 'PATCH' ||
          req.method == 'PUT';

      // profiles GET fails hard -> load() throws, no hydration.
      if (path.contains('/profiles') && req.method == 'GET') {
        return http.Response(
          jsonEncode({'message': 'offline'}),
          500,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }

      // Writes: 200 with an echo-like body (PostgREST .select() expects a
      // row back).
      if (isWrite) {
        return http.Response(
          jsonEncode([<String, dynamic>{}]),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }

      // All other reads: empty list (loadLoggedMeals, loadRange, ...)
      return http.Response(
        jsonEncode(const <dynamic>[]),
        200,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    });
  }

  Iterable<http.Request> get profileWrites => requests.where((r) =>
      r.url.path.contains('/profiles') &&
      (r.method == 'POST' || r.method == 'PATCH' || r.method == 'PUT'));

  int? _weightOf(http.Request r) {
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['weight_kg'] is num) {
        return (body['weight_kg'] as num).toInt();
      }
      if (body is List &&
          body.isNotEmpty &&
          body.first is Map &&
          (body.first as Map)['weight_kg'] is num) {
        return ((body.first as Map)['weight_kg'] as num).toInt();
      }
    } catch (_) {
      // ignore: non-JSON or unexpected shape -> no weight.
    }
    return null;
  }

  bool get clobberedWithDefaults =>
      profileWrites.any((r) => _weightOf(r) == 78);

  bool profileWroteWeight(int kg) =>
      profileWrites.any((r) => _weightOf(r) == kg);
}

EatovaSync _sync(WidgetTester tester, http.Client client) {
  final supa = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: client,
    // testWidgets runs on the FakeAsync clock: GoTrue's periodic auto-refresh
    // ticker would linger as a pending timer after the tree is disposed. This
    // test does not exercise auth refresh, so the ticker is off.
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  // No supa.dispose() teardown: dispose() does real async (realtime/auth
  // close) that never completes in the FakeAsync zone, so the teardown would
  // hang until the test timeout. With autoRefreshToken:false no timer is left
  // pending and the client is simply GC'd.
  return EatovaSync.forUser(supa, 'user-clobber');
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required EatovaSync sync,
  LocalCache? debugCache,
}) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Force reduced motion. Under disableAnimations motionDuration collapses
  // every welcome duration to zero, so _exitController.forward() finishes
  // without a tick and the screen moves to onboarding/home deterministically.
  // Otherwise the indeterminate spinner never settles and pumpAndSettle runs
  // into the runner timeout. The clobber guard's behaviour is unaffected.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  await tester.pumpWidget(MaterialApp(
    // Shell, onboarding and Food tab read colors via `context.t`; `AppTokens.of`
    // throws by design when the extension is missing, so without `theme:` the
    // first build dies before the guard runs.
    theme: buildEatovaTheme(Brightness.dark),
    // _navItems() reads context.l10n; without these delegates
    // AppLocalizations.of() throws while building the bottom nav.
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: EatovaHomePage(
      sync: sync,
      debugCache: debugCache,
      showWelcome: false,
    ),
  ));

  // Boot mixes real async (Supabase HTTP, cache reads) with fake-async
  // animation. pumpAndSettle would never settle while the indeterminate
  // welcome spinner is in the tree, so pump in a bounded loop instead — never
  // a 10-minute hang even if the boot jams.
  final welcome = find.byKey(const ValueKey('screen-welcome'));
  for (var i = 0; i < 80 && welcome.evaluate().isNotEmpty; i++) {
    await _drain(tester, rounds: 1);
  }
  // Welcome is gone -> drain a bit more so the onboarding/home tree is fully
  // painted.
  await _drain(tester, rounds: 6);
}

/// Bounded "settle": pumps frames on fake time but never waits for a full
/// settle, so it cannot hang on a permanent spinner or a periodic timer.
Future<void> _drain(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
      'Offline-Kaltstart OHNE Cache: Onboarding-Gate statt Clobber, kein '
      'profiles-Write mit 78kg', (tester) async {
    final recorder = _Recorder();
    final sync = _sync(tester, recorder.client());

    // Empty cache -> no hydration -> profile stays on ctor defaults and
    // _hydratedFromRealSource stays false.
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-clobber');

    await _pumpHome(tester, sync: sync, debugCache: cache);

    // Without a real profile source the app shows mandatory onboarding, so
    // the user never reaches the settings to save defaults.
    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);

    // And the boot itself sent no profiles write with the 78 kg defaults.
    expect(recorder.clobberedWithDefaults, isFalse);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets(
      'Offline-Kaltstart MIT Cache: Home aus Cache, Save nutzt echte Werte '
      '(81kg) — NIE die 78kg-Defaults', (tester) async {
    final recorder = _Recorder();
    final sync = _sync(tester, recorder.client());

    // Preload the cache with a real, completed profile. Hydration adopts it
    // before the throwing server load -> home appears,
    // _hydratedFromRealSource = true.
    final store = InMemoryKeyValueStore();
    final cache = LocalCache(store, 'user-clobber');
    await cache.writeProfile(const UserProfile(
      weightKg: 80,
      heightCm: 180,
      onboardingCompleted: true,
    ));

    await _pumpHome(tester, sync: sync, debugCache: cache);

    // The cached onboarding_completed=true removes the onboarding gate.
    expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
    // Landing point is the Today tab (index 0), not the Food tab.
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

    // The gear lives in the Food tab's header, and the lazy IndexedStack only
    // builds that tab on first visit — so switch there first.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await _drain(tester);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    // Open settings, set weight to 81, save. With _hydratedFromRealSource
    // true the save may run — but with the edited value, not 78.
    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _drain(tester);

    // Body data and "save" live one level deeper, on the profile & goals
    // page; the write path under test is unchanged.
    final zuDenZielen = find.byKey(const ValueKey('settings-open-goals'));
    await tester.ensureVisible(zuDenZielen);
    await _drain(tester);
    await tester.tap(zuDenZielen);
    await _drain(tester);

    final weightField = find.byKey(const ValueKey('settings-weight'));
    expect(weightField, findsOneWidget);
    await tester.enterText(weightField, '81');
    await _drain(tester);

    final saveBtn = find.byKey(const ValueKey('settings-save'));
    await tester.ensureVisible(saveBtn);
    await _drain(tester);
    await tester.tap(saveBtn);
    await _drain(tester);

    // Exactly one real profile save went out, carrying 81 and not 78.
    expect(recorder.profileWrites, isNotEmpty,
        reason: 'mit echter (gecachter) Basis MUSS der Save laufen');
    expect(recorder.clobberedWithDefaults, isFalse,
        reason: 'der Save darf die echte Zeile NIE mit 78kg ueberschreiben');
    expect(recorder.profileWroteWeight(81), isTrue,
        reason: 'der Save traegt den editierten echten Wert');
  }, timeout: const Timeout(Duration(seconds: 45)));
}
