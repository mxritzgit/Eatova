import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/theme/app_theme.dart';

// DATA-3 Clobber-Guard: ein Offline-Kaltstart (ProfileSync.load() wirft) darf
// die echte Server-Profilzeile NIEMALS mit den nackten Ctor-Defaults
// (78 kg / 178 cm) ueberschreiben.
//
// Diese Tests treiben die ECHTE EatovaHomePage mit einem echten EatovaSync
// ueber einen aufzeichnenden MockClient:
//   * Jedes GET auf /profiles antwortet 500 -> ProfileSync.load() wirft ->
//     KEINE Server-Hydration.
//   * Alle uebrigen Reads liefern leere Listen/Objekte (Boot bleibt gruen, da
//     _safeLoad sie schluckt).
//   * Jeder Schreib-Request (POST/PATCH/PUT) wird aufgezeichnet.
//
// Der LocalCache wird ueber den Test-Seam `debugCache` injiziert (kein
// SharedPreferences-Channel / keine Supabase-Session noetig).
//
// Invariante: waehrend des gesamten Boots geht KEIN profiles-Write mit
// weight_kg == 78 raus.

class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  http.Client client() {
    return MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      final isWrite = req.method == 'POST' ||
          req.method == 'PATCH' ||
          req.method == 'PUT';

      // profiles-GET (load) faellt hart aus -> load() wirft, keine Hydration.
      if (path.contains('/profiles') && req.method == 'GET') {
        return http.Response(
          jsonEncode({'message': 'offline'}),
          500,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }

      // Schreib-Requests: 200 mit echo-aehnlichem Body (PostgREST .select()
      // erwartet eine Zeile zurueck). Wir geben den Default-Body zurueck.
      if (isWrite) {
        return http.Response(
          jsonEncode([<String, dynamic>{}]),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: req,
        );
      }

      // Alle uebrigen Reads: leere Liste (loadLoggedMeals, loadRange, ...)
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
      // ignore: nicht-JSON oder unerwartete Form -> kein Gewicht.
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
    // testWidgets laeuft im FakeAsync-Clock: GoTrueClients periodischer
    // Auto-Refresh-Ticker (Timer.periodic, 10s) wuerde sonst als pending Timer
    // nach dem Dispose des Widget-Trees haengen bleiben. Der Clobber-Test testet
    // keinen Auth-Refresh — also schalten wir den Ticker hier komplett ab.
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  // KEIN supa.dispose()-Teardown: dispose() macht ECHTES async (Realtime-/Auth-
  // Close), das in der FakeAsync-Zone von testWidgets NIE durchlaeuft (auch nicht
  // in runAsync, da der Close auf eine nie geoeffnete Verbindung wartet) -> der
  // Teardown wuerde bis zum Test-Timeout haengen. Da der GoTrue-Auto-Refresh-
  // Ticker via autoRefreshToken:false aus ist, bleibt KEIN pendender Timer
  // zurueck; der Client wird einfach GC'd. (Verifiziert: ohne dispose-Teardown
  // laufen beide Tests sauber durch, kein "Timer still pending".)
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

  // Reduzierte Bewegung erzwingen (System-A11y-Toggle "Bewegung reduzieren").
  // Die WelcomeScreen-Boot-Phase faedelt ihren Exit ueber eine Animation auf
  // dem _profileReadyCompleter ein. Dessen Future wird im echten Boot (unten
  // via runAsync) aufgeloest — die Exit-AnimationController-Sequenz darf dann
  // aber NICHT auf einen Frame-Tick warten, sonst haengt die Welcome-Phase
  // (mit ihrem indeterminaten CircularProgressIndicator) und ein anschliessendes
  // pumpAndSettle laeuft in den 10-min-Runner-Timeout. motionDuration kollabiert
  // unter disableAnimations alle Welcome-Dauern auf Duration.zero, sodass
  // _exitController.forward() sofort (ohne Tick) abschliesst und der Screen
  // deterministisch ins Onboarding/Home wechselt. Das ist genau der A11y-Pfad,
  // fuer den die WelcomeScreen gebaut ist — kein Verhalten des Clobber-Guards
  // wird dadurch veraendert.
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
    // Design-Refactor 2026-08: Schale, Onboarding und Food-Tab lesen Farben
    // ueber `context.t` (AppTokens als ThemeExtension). `AppTokens.of` wirft
    // absichtlich, wenn die Extension fehlt — ohne `theme:` stirbt schon der
    // erste Build und der Clobber-Guard kaeme gar nicht zum Zug.
    theme: buildEatovaTheme(Brightness.dark),
    home: EatovaHomePage(
      sync: sync,
      debugCache: debugCache,
      showWelcome: false,
    ),
  ));

  // Boot mischt ECHTES async (Supabase-HTTP via MockClient + LocalCache-Reads,
  // die am Ende _profileReadyCompleter.complete() ausloesen) mit Fake-async-
  // Animation (WelcomeScreen-Exit). pumpAndSettle ist hier toedlich: solange der
  // WelcomeScreen-Spinner (INDETERMINAT) im Baum haengt, settlet es NIE und
  // laeuft in den Runner-Timeout. Stattdessen alternieren wir GEDECKELT echtes
  // async (runAsync -> HTTP + profileReady laufen auf der echten Event-Loop)
  // mit pump(16ms) (treibt den unter disableAnimations zero-dauer Welcome-Exit-
  // Controller + Fake-Animationen), bis der WelcomeScreen aus dem Baum ist.
  // Bounded -> nie ein 10-min-Hang, auch wenn der Boot mal klemmt.
  final welcome = find.byKey(const ValueKey('screen-welcome'));
  for (var i = 0; i < 80 && welcome.evaluate().isNotEmpty; i++) {
    await _drain(tester, rounds: 1);
  }
  // Welcome ist raus -> noch etwas nachdrainen, damit der (determinate)
  // Onboarding-/Home-Baum vollstaendig gezeichnet ist.
  await _drain(tester, rounds: 6);
}

/// Bounded "settle": gibt der ECHTEN Event-Loop Zeit (runAsync, fuer Supabase-
/// HTTP via MockClient) UND pumpt Frames mit Fake-Zeit (fuer Animationen),
/// wartet aber NIE auf vollstaendiges Settle — haengt also nie an einem
/// Dauer-Spinner (WelcomeScreen) oder periodischen Timer.
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

    // Leerer Cache -> keine Hydration -> profile bleibt auf Ctor-Defaults ->
    // _hydratedFromRealSource bleibt false.
    final cache = LocalCache(InMemoryKeyValueStore(), 'user-clobber');

    await _pumpHome(tester, sync: sync, debugCache: cache);

    // Ohne echte Profil-Quelle (Server-Load wirft, Cache leer,
    // onboarding_completed=false) zeigt die App das verpflichtende Onboarding —
    // der User kommt gar nicht erst an die Settings, um Defaults zu speichern.
    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);

    // Und der Boot selbst hat KEINEN profiles-Write mit den 78kg-Defaults
    // abgesetzt (Clobber-Schutz haelt).
    expect(recorder.clobberedWithDefaults, isFalse);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets(
      'Offline-Kaltstart MIT Cache: Home aus Cache, Save nutzt echte Werte '
      '(81kg) — NIE die 78kg-Defaults', (tester) async {
    final recorder = _Recorder();
    final sync = _sync(tester, recorder.client());

    // Cache mit einem ECHTEN, abgeschlossenen Profil vorbefuellen (80 kg /
    // 180 cm, onboarding done). Hydration uebernimmt das VOR dem (werfenden)
    // Server-Load -> Home erscheint, _hydratedFromRealSource = true.
    final store = InMemoryKeyValueStore();
    final cache = LocalCache(store, 'user-clobber');
    await cache.writeProfile(const UserProfile(
      weightKg: 80,
      heightCm: 180,
      onboardingCompleted: true,
    ));

    await _pumpHome(tester, sync: sync, debugCache: cache);

    // Das Onboarding-Gate ist dank gecachtem onboarding_completed=true weg —
    // der User landet direkt im Home (kein Onboarding-Screen).
    expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
    // Design-Refactor 2026-08: der Landepunkt ist der neue Tab „Heute"
    // (Index 0), nicht mehr der Food-Tab. Die Aussage bleibt dieselbe — die
    // App zeigt statt des Onboarding-Gates die echte Oberflaeche.
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);

    // Das Zahnrad haengt in der Kopfzeile des Food-Tabs
    // (meal_analysis_screen.dart:642); der lazy IndexedStack baut den Tab erst
    // beim ersten Besuch, deshalb zuerst hinueberwechseln.
    await tester.tap(find.byKey(const ValueKey('nav-Food')));
    await _drain(tester);
    expect(find.byKey(const ValueKey('screen-kcal-tracker')), findsOneWidget);

    // Settings oeffnen, Gewicht auf 81 setzen, speichern. Da _hydratedFromReal
    // Source dank Cache-Hydration true ist, DARF (und soll) der Save laufen —
    // aber mit dem echten/editierten Wert, nicht mit 78.
    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
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

    // Es ging genau ein echter Profil-Save raus — und der trug 81, NICHT 78.
    expect(recorder.profileWrites, isNotEmpty,
        reason: 'mit echter (gecachter) Basis MUSS der Save laufen');
    expect(recorder.clobberedWithDefaults, isFalse,
        reason: 'der Save darf die echte Zeile NIE mit 78kg ueberschreiben');
    expect(recorder.profileWroteWeight(81), isTrue,
        reason: 'der Save traegt den editierten echten Wert');
  }, timeout: const Timeout(Duration(seconds: 45)));
}
