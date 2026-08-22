// Audit 2026-08-14 — remotely triggerable error reports via the deeplink
// ROUTE. The BROWSABLE intent filter lets any app or web page send
// `eatova://…`.
//
// Android hands such a URI not only to `app_links` (where the session
// predicate already applies) but ALSO as a route over
// `SystemChannels.navigation`. With no `routes:`, `onGenerateRoute` or
// `onUnknownRoute`, `didPushRouteInformation` -> `pushNamed` threw "Could not
// find a generator for route", which reaches Sentry via the global handlers.
// No data loss, but an attacker could flood the error budget remotely.
//
// Checked on three levels:
//
//   1. Counter-check: the same route still throws on a bare `MaterialApp`.
//      Otherwise the test could stay green because the route is no longer
//      delivered at all, guarding nothing.
//   2. `EatovaApp` swallows it silently: no exception, no navigator entry,
//      no lost visible state.
//   3. The real OAuth return path is untouched — it runs over the
//      `app_links` channel; only the pointless route echo disappears.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/eatova_home_page.dart';

/// The route name Android builds from the attack deeplink: `onNewIntent`
/// passes path + query + fragment to the navigation channel.
const String _angriffsRoute =
    '/#access_token=FAKE&refresh_token=FAKE&token_type=bearer';

/// The same echo on the legitimate return path: `?code=…` also arrives as a
/// route and used to throw the same exception.
const String _echterRueckwegRoute = '/?code=abc';

/// Plays the platform on exactly the engine's path (`flutter/navigation`,
/// `pushRouteInformation`), so no test-only shortcut is under test.
///
/// Returns the framework's answer: `true` = an observer took the route,
/// `false` = nobody did (also the outcome when the navigator threw).
Future<bool?> _plattformSchicktRoute(
  WidgetTester tester,
  String location,
) async {
  final antwort =
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    SystemChannels.navigation.codec.encodeMethodCall(
      MethodCall(
        'pushRouteInformation',
        <String, Object?>{'location': location, 'state': null},
      ),
    ),
    null,
  );
  await tester.pump();
  if (antwort == null) return null;
  return SystemChannels.navigation.codec.decodeEnvelope(antwort) as bool?;
}

/// The running app's root navigator.
NavigatorState _rootNavigator(WidgetTester tester) => Navigator.of(
      tester.element(find.byType(EatovaHomePage)),
      rootNavigator: true,
    );

Future<void> _pumpEatovaApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Headless font metrics cause overflows that never happen on a device.
  // Everything else passes through, so `tester.takeException()` still sees it.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  // Without a repository the preview path applies (kDebugMode): signed-in
  // preview user, real shell, no Supabase.
  await tester.pumpWidget(const EatovaApp());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'GEGENPROBE: dieselbe Route wirft auf einer Schale ohne Waechter',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('ohne Waechter'))),
      );
      await tester.pumpAndSettle();

      final uebernommen = await _plattformSchicktRoute(tester, _angriffsRoute);

      expect(
        uebernommen,
        isFalse,
        reason: 'Ohne Waechter uebernimmt niemand die Route — das Framework '
            'meldet dem Aufrufer „nicht behandelt", nachdem der Navigator '
            'geworfen hat.',
      );
      expect(
        tester.takeException().toString(),
        contains('Could not find a generator for route'),
        reason: 'Wenn hier NICHTS mehr wirft, stellt dieser Test die Route '
            'gar nicht mehr zu — dann bewacht der Test unten nichts.',
      );
    },
  );

  testWidgets(
    'EatovaApp schluckt die untergeschobene Deeplink-Route lautlos',
    (tester) async {
      await _pumpEatovaApp(tester);

      expect(find.byType(EatovaHomePage), findsOneWidget);
      expect(_rootNavigator(tester).canPop(), isFalse);

      final uebernommen = await _plattformSchicktRoute(tester, _angriffsRoute);
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'Die Route darf keinen Fehlerbericht mehr erzeugen — sonst '
            'kann jede fremde App das Fehlerbudget aus der Ferne fluten.',
      );
      expect(
        uebernommen,
        isTrue,
        reason: 'Der Waechter meldet „behandelt" und beendet damit die '
            'Zustellung, BEVOR _WidgetsAppState daraus ein pushNamed macht.',
      );
      expect(
        find.byType(EatovaHomePage),
        findsOneWidget,
        reason: 'Der Nutzer bleibt, wo er ist: keine zweite Schale, keine '
            'leere Seite darueber.',
      );
      expect(
        _rootNavigator(tester).canPop(),
        isFalse,
        reason: 'Nichts wurde auf den Navigationsstapel gelegt — und nichts '
            'davon genommen.',
      );
    },
  );

  testWidgets(
    'auch ein Dauerbeschuss legt nichts auf den Navigationsstapel',
    (tester) async {
      await _pumpEatovaApp(tester);

      for (var i = 0; i < 25; i++) {
        await _plattformSchicktRoute(tester, '$_angriffsRoute&nr=$i');
      }
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(EatovaHomePage), findsOneWidget);
      expect(_rootNavigator(tester).canPop(), isFalse);
    },
  );

  testWidgets(
    'der Routen-Nachhall des ECHTEN OAuth-Rueckwegs stoert ebenfalls nicht',
    (tester) async {
      // `eatova://login-callback/?code=…` arrives twice: via app_links (PKCE
      // exchange) and as a route. Only the route belongs here, and it is as
      // worthless as the attack echo since the app has no named routes.
      await _pumpEatovaApp(tester);

      final uebernommen =
          await _plattformSchicktRoute(tester, _echterRueckwegRoute);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(uebernommen, isTrue);
      expect(find.byType(EatovaHomePage), findsOneWidget);
      expect(_rootNavigator(tester).canPop(), isFalse);
    },
  );
}
