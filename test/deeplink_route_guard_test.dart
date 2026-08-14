// AUDIT 2026-08-14 — fernausloesbare Fehlerberichte ueber die Deeplink-ROUTE.
//
// Zweiter, unabhaengiger Ausgang derselben Angriffsflaeche wie
// `test/auth_deeplink_predicate_test.dart`: der Intent-Filter in
// `android/app/src/main/AndroidManifest.xml` ist BROWSABLE, jede fremde App
// und jede Webseite darf `eatova://…` schicken.
//
// Am 2026-08-14 auf dem Emulator reproduziert:
//
//   adb shell am start -a android.intent.action.VIEW \
//     -d "eatova://login-callback/#access_token=FAKE&refresh_token=FAKE&token_type=bearer"
//
// Android reicht so eine URI beim `onNewIntent` NICHT nur an `app_links`
// weiter (dort greift laengst das Session-Praedikat aus
// `EatovaSupabaseConfig.isOAuthCallbackDeeplink`), sondern ZUSAETZLICH als
// Route ueber `SystemChannels.navigation`. Aus dem Fragment wird der
// Routenname `/#access_token=FAKE&refresh_token=FAKE&token_type=bearer`, und
// weil die App weder `routes:` noch `onGenerateRoute` noch `onUnknownRoute`
// kennt, warf `_WidgetsAppState.didPushRouteInformation` -> `pushNamed`:
//
//   EXCEPTION CAUGHT BY WIDGETS LIBRARY
//   … while dispatching notifications for
//   WidgetsBindingObserver.didPushRouteInformation:
//   Could not find a generator for route RouteSettings("/#access_token=…")
//   in the _WidgetsAppState. … Unfortunately, onUnknownRoute was not set.
//
// Das laeuft ueber `FlutterError.reportError` in die globalen Handler aus
// `main.dart:131-142` und damit in Sentry. Kein Datenverlust — aber ein
// Angreifer kann aus der Ferne beliebig viele Fehlerberichte erzeugen und die
// echten Meldungen im Fehlerbudget zudecken.
//
// Geprueft wird auf drei Ebenen:
//
//   1. GEGENPROBE: dass dieselbe Route auf einer nackten `MaterialApp` mit
//      `home:` immer noch wirft. Ohne diesen Fall koennte der Test gruen
//      bleiben, weil die Route gar nicht mehr zugestellt wird (falscher
//      Kanal, falsches Nachrichtenformat) — und wir haetten einen Waechter,
//      der nichts bewacht.
//   2. Dass `EatovaApp` sie STILL schluckt: keine Exception, kein neuer
//      Eintrag im Navigationsstapel, keine leere Seite, kein Verlust des
//      sichtbaren Zustands.
//   3. Dass der ECHTE OAuth-Rueckweg davon unberuehrt bleibt. Er laeuft ueber
//      den `app_links`-EventChannel und `detectSessionInUriPredicate`
//      (`lib/src/config/supabase_config.dart`) — ein anderer Kanal als
//      `SystemChannels.navigation`; hier faellt nur der sinnlose
//      Routen-Nachhall desselben Intents weg.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/app/eatova_home_page.dart';

/// Der Routenname, den Android aus dem Angriffs-Deeplink baut: `onNewIntent`
/// gibt Pfad + Query + Fragment der Intent-Daten an den Navigations-Kanal.
const String _angriffsRoute =
    '/#access_token=FAKE&refresh_token=FAKE&token_type=bearer';

/// Derselbe Nachhall beim LEGITIMEN Rueckweg: auch `?code=…` kommt zusaetzlich
/// als Route an und warf vorher exakt dieselbe Exception.
const String _echterRueckwegRoute = '/?code=abc';

/// Spielt die Plattform: exakt der Weg, den die Engine nimmt
/// (`flutter/navigation`, Methode `pushRouteInformation`), damit hier nicht
/// eine Test-Abkuerzung geprueft wird, die es auf dem Geraet nicht gibt.
///
/// Rueckgabe ist die Antwort des Frameworks: `true` = ein Beobachter hat die
/// Route uebernommen, `false` = niemand fuehlte sich zustaendig (so endet es
/// auch, wenn der Navigator dabei geworfen hat — `handlePushRouteInformation`
/// faengt den Fehler, meldet ihn und macht weiter).
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

/// Der Root-Navigator der laufenden App.
NavigatorState _rootNavigator(WidgetTester tester) => Navigator.of(
      tester.element(find.byType(EatovaHomePage)),
      rootNavigator: true,
    );

Future<void> _pumpEatovaApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // Headless-Schriftmetriken erzeugen Overflows, die auf dem Geraet nicht
  // auftreten (gleiche Begruendung wie in test/flows/flow_test_helpers.dart).
  // Alles andere wird durchgereicht — `tester.takeException()` sieht es also
  // weiterhin.
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);

  // Ohne Repository greift der Preview-Pfad (kDebugMode) — eingeloggter
  // Preview-Nutzer, echte Schale, kein Supabase.
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
      // `eatova://login-callback/?code=…` kommt doppelt an: einmal ueber
      // app_links (dort passiert der PKCE-Austausch, s.
      // test/auth_deeplink_predicate_test.dart) und einmal als Route. Nur der
      // zweite Weg gehoert hierher — und der ist ebenso wertlos wie der
      // Angriffs-Nachhall, weil die App keine benannten Routen hat.
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
