// Onboarding flow: a fresh account without a profile lands in the mandatory
// onboarding, taps through every step and arrives on the Today tab.
//
// `HomeStore.needsOnboarding` only opens with a real EatovaSync (never in
// preview, by design), so unlike the other flows this one does not pump
// `EatovaApp()` with an InMemoryAuthRepository: it boots `EatovaHomePage` over
// a MockClient Supabase that answers every read with `[]` (no profile -> no
// `onboarding_completed`), like test/home_page_onboarding_pop_test.dart.
// Runs in English.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/theme/app_theme.dart';

import 'flow_test_helpers.dart';

const String _userId = 'user-onboarding-flow';

/// Empty fake server: reads return `[]`, writes an empty row. The profile
/// upsert after the last step lands here and must not fail the flow.
http.Client _emptyServer() => MockClient((req) async {
      final isWrite = req.method == 'POST' ||
          req.method == 'PATCH' ||
          req.method == 'PUT';
      return http.Response(
        jsonEncode(isWrite ? [<String, dynamic>{}] : const <dynamic>[]),
        200,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    });

EatovaSync _sync() {
  // autoRefreshToken: false, or GoTrue's ticker stays a pending timer.
  final supa = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: _emptyServer(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  return EatovaSync.forUser(supa, _userId);
}

/// Bounded pump instead of pumpAndSettle: the boot spinner and periodic
/// timers would otherwise never settle.
Future<void> _drain(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgetsRobust(
      'Frisches Konto ohne Profil: Onboarding-Gate, alle Schritte, dann Heute',
      (WidgetTester tester) async {
    // Reduced motion collapses the welcome durations and the step switcher
    // to zero, so a few frames per step are enough.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

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
      home: EatovaHomePage(
        sync: _sync(),
        debugCache: LocalCache(InMemoryKeyValueStore(), _userId),
        showWelcome: false,
      ),
    ));

    // Welcome screen until the (empty) boot load returns, then the gate.
    final welcome = find.byKey(const ValueKey('screen-welcome'));
    for (var i = 0; i < 80 && welcome.evaluate().isNotEmpty; i++) {
      await _drain(tester, rounds: 1);
    }
    await _drain(tester);

    expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget,
        reason: 'ohne Profil muss das Onboarding-Gate greifen');
    expect(find.byKey(const ValueKey('screen-today')), findsNothing);
    expect(find.byKey(const ValueKey('onboarding-step-intro')), findsOneWidget);

    Future<void> tapKey(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await _drain(tester);
    }

    Future<void> next(String expectedStep) async {
      await tapKey('onboarding-next');
      expect(find.byKey(ValueKey('onboarding-step-$expectedStep')),
          findsOneWidget,
          reason: 'nach „Weiter" fehlt der Schritt $expectedStep');
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
    await _drain(tester, rounds: 12);

    expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing,
        reason: 'nach „Plan aktivieren" darf das Gate nicht mehr stehen');
    expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
    expect(find.byKey(const ValueKey('today-kcal-hero')), findsOneWidget);
  });
}
