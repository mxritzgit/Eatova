// Der Profil-Screen nach dem Design-Refactor 2026-08-09.
//
// Drei Dinge sichert dieser Test, die vorher nirgends abgedeckt waren:
//   * beide Anzeige-Modi (der Screen liest seine Farben jetzt ueber Tokens),
//   * das Schritte-Format '<ist>/<soll>' — daran haengt der Live-Refresh-
//     Beweis in profile_route_refresh_test, der derzeit an der Schale
//     scheitert; hier haelt ihn ein Test, der ohne die Schale auskommt,
//   * die Identitaetskarte erfindet keine Daten (kein PREMIUM, kein
//     „MEMBER SINCE" — die Design-Vorlage zeigt beides, wir haben es nicht).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

/// iPhone-14-Viewport (393x852 logisch).
void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _expectNoOverflow(Future<void> Function() body) async {
  final overflows = <String>[];
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) {
      final full = details.toString();
      final culprit = RegExp(r'\S+:file:///\S+').firstMatch(full)?.group(0);
      overflows.add('${details.summary} (${culprit ?? 'unbekannt'})');
      return;
    }
    prior?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prior;
  }
  expect(overflows, isEmpty, reason: overflows.join('\n'));
}

Widget _profile({
  UserProfile profile = const UserProfile(),
  WeightLog weightLog = const WeightLog(),
  int dailySteps = 1000,
  int dailyConsumedKcal = 900,
  VoidCallback? onEditProfile,
  VoidCallback? onOpenSettings,
  HealthAuthState healthAuthState = HealthAuthState.unknown,
}) {
  return ProfileScreen(
    name: 'Moritz Schneider',
    profile: profile,
    weightLog: weightLog,
    stats: LifetimeStats(mealsLogged: 12, weightLogs: 3, longestStreak: 4),
    dailyConsumedKcal: dailyConsumedKcal,
    dailySteps: dailySteps,
    healthAuthState: healthAuthState,
    healthLastFetch: null,
    onLogWeight: (_) {},
    onEditProfile: onEditProfile ?? () {},
    onOpenSettings: onOpenSettings ?? () {},
    onConnectHealth: () {},
    onRefreshHealth: () {},
  );
}

/// Pumpt den Screen als eigene Route ueber einem Start-Screen, damit
/// `profile-close` (maybePop) wirklich etwas zu schliessen hat.
Future<void> _pumpAsRoute(
  WidgetTester tester,
  Widget screen, {
  Brightness brightness = Brightness.dark,
  TextScaler? textScaler,
  Locale locale = const Locale('de'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(brightness),
      // ProfileScreen liest seit der i18n-Migration context.l10n.
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('open-profile'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => screen),
              ),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-profile')));
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in <Brightness>[Brightness.light, Brightness.dark]) {
    testWidgets('rendert in ${brightness.name} ohne Exception', (tester) async {
      _pinViewport(tester);
      await _pumpAsRoute(tester, _profile(), brightness: brightness);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('screen-profile')), findsOneWidget);
      expect(find.text('Mein Profil'), findsOneWidget);
      expect(find.text('Moritz Schneider'), findsOneWidget);
    });
  }

  testWidgets('der Kopf traegt Zurueck-Knopf und Zahnrad', (tester) async {
    _pinViewport(tester);
    var einstellungen = 0;
    var ziele = 0;
    await _pumpAsRoute(
      tester,
      _profile(
        onOpenSettings: () => einstellungen++,
        onEditProfile: () => ziele++,
      ),
    );

    // Das Zahnrad fuehrt in die EINSTELLUNGEN — nicht auf „Profil & Ziele".
    // Bis 2026-08-10 hingen beide am selben Callback; das Zahnrad trug die
    // Beschriftung „Einstellungen" und oeffnete die Ziele, waehrend die
    // Einstellungen nur hinter einem Schieberegler-Symbol im Food-Kopf lagen.
    // Der Nutzer fand sie schlicht nicht.
    await tester.tap(find.byKey(const ValueKey('profile-open-settings')));
    await tester.pumpAndSettle();
    expect(einstellungen, 1);
    expect(ziele, 0, reason: 'das Zahnrad darf NICHT auf die Ziele fuehren');

    // Und der Zurueck-Knopf schliesst die Route.
    await tester.tap(find.byKey(const ValueKey('profile-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-profile')), findsNothing);
  });

  // Bis 2026-08-10 stand hier „alle sechs Konto-Aktionen sind da". Der Block
  // „Daten & Konto" ist auf Nutzer-Entscheid entfallen, weil er die
  // Einstellungen doppelte. Aus der Zusicherung wird damit ihr Gegenteil: die
  // sechs Zeilen duerfen hier NICHT mehr stehen — und weil ein blosses
  // „ist weg" ein stiller Funktionsverlust waere, haelt
  // `test/settings_erreichbarkeit_test.dart` die Gegenstuecke in den
  // Einstellungen fest (`settings-open-goals`, `settings-export`,
  // `settings-about`, `settings-sign-out`, `settings-delete-account`).
  testWidgets('der Block „Daten & Konto" steht nicht mehr im Profil',
      (tester) async {
    _pinViewport(tester);
    await _pumpAsRoute(tester, _profile());

    for (final key in <String>[
      'profile-action-edit',
      'profile-action-reset',
      'profile-action-export',
      'profile-action-about',
      'profile-action-logout',
      'profile-action-delete',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect(find.text('DATEN & KONTO'), findsNothing);
    expect(find.text('Daten & Konto'), findsNothing);
    // „Tagesdaten zurücksetzen" gibt es in der ganzen App nicht mehr — weder
    // hier noch auf „Profil & Ziele" (`settings-reset-day`).
    expect(find.text('Tagesdaten zurücksetzen'), findsNothing);
    // Der letzte Abschnitt ist jetzt „Verbindungen"; darunter nur noch die
    // Wortmarke mit der Version.
    expect(find.text('Verbindungen'), findsOneWidget);
  });

  testWidgets('die Bearbeiten-Knoepfe an Plan- und Zielkarte tragen die Ziele',
      (tester) async {
    // Mit dem Block „Daten & Konto" ist die Zeile `profile-action-edit`
    // entfallen. Der Weg auf „Profil & Ziele" darf dadurch nicht abreissen —
    // er haengt seither ausschliesslich an diesen beiden Knoepfen (und an der
    // Zeile `settings-open-goals` in den Einstellungen).
    _pinViewport(tester);
    var editCalls = 0;
    await _pumpAsRoute(tester, _profile(onEditProfile: () => editCalls++));

    for (final key in const <String>[
      'profile-goalplan-edit',
      'profile-edit-goals',
    ]) {
      final knopf = find.byKey(ValueKey(key));
      await tester.ensureVisible(knopf);
      await tester.pumpAndSettle();
      await tester.tap(knopf);
      await tester.pumpAndSettle();
    }
    expect(editCalls, 2);
  });

  testWidgets(
      'die Schritte-Zeile rendert EIN Text-Widget im Format <ist>/<soll>',
      (tester) async {
    _pinViewport(tester);
    await _pumpAsRoute(tester, _profile(dailySteps: 1000));

    // Ohne Scrollen findbar — der Screen baut eifrig (SingleChildScrollView),
    // kein ListView. Genau darauf verlaesst sich profile_route_refresh_test.
    expect(find.text('1000/8000'), findsOneWidget);
    expect(find.text('1000 / 8000'), findsNothing);
    // Und die Kalorien-Zeile daneben in derselben Schreibweise.
    expect(find.text('900/2200'), findsOneWidget);
  });

  testWidgets('die Identitaetskarte erfindet keine Daten', (tester) async {
    _pinViewport(tester);
    await _pumpAsRoute(tester, _profile());

    expect(find.text('PREMIUM'), findsNothing);
    expect(find.textContaining('MEMBER SINCE'), findsNothing);
    expect(find.textContaining('Seit 20'), findsNothing);
    // Stattdessen die beiden Felder, die es wirklich gibt. („Gewicht halten"
    // steht zusaetzlich auf der Plan-Karte weiter unten — deshalb hier
    // gezielt in der Identitaetskarte suchen.)
    expect(
      find.descendant(
        of: find.byType(IdentityCard),
        matching: find.text('Gewicht halten'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(IdentityCard),
        matching: find.text('Kaum aktiv'),
      ),
      findsOneWidget,
    );
  });

  // Die Sheets des Profils standen bisher in KEINEM Test. Sie sind der Ort, an
  // dem eine feste Sheet-Hoehe und grosse Systemschrift aufeinander treffen —
  // genau die Bruchstelle aus §5 des Vertrags.
  //
  // Aus den urspruenglich vier Faellen sind zwei geworden: „Über Eatova" und
  // die „Datenauskunft" haengen seit 2026-08-10 an den Einstellungen. Ihre
  // 2.0-Faelle sind nicht gestrichen, sondern nach
  // `test/settings_screen_render_test.dart` umgezogen.
  for (final sheet in <({String name, String key, String? tooltip})>[
    (name: 'Gewicht loggen', key: 'profile-log-weight', tooltip: null),
    (name: 'BMI-Erklärung', key: '', tooltip: 'BMI-Erklärung'),
  ]) {
    testWidgets('Sheet „${sheet.name}" oeffnet bei textScaler 2.0 ohne '
        'Overflow', (tester) async {
      _pinViewport(tester);
      await _expectNoOverflow(() async {
        await _pumpAsRoute(
          tester,
          _profile(),
          textScaler: const TextScaler.linear(2.0),
        );
        final oeffner = sheet.tooltip != null
            ? find.byTooltip(sheet.tooltip!)
            : find.byKey(ValueKey(sheet.key));
        await tester.ensureVisible(oeffner);
        await tester.pumpAndSettle();
        await tester.tap(oeffner);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('rendert bei textScaler 2.0 ohne Overflow', (tester) async {
    _pinViewport(tester);
    await _expectNoOverflow(() async {
      await _pumpAsRoute(
        tester,
        _profile(
          profile: const UserProfile(
            weightKg: 78,
            targetWeightKg: 68,
            weightGoal: WeightGoal.lose05kg,
            activityLevel: ActivityLevel.athlete,
          ),
          weightLog: WeightLog(
            entries: <WeightLogEntry>[
              WeightLogEntry(
                timestamp: DateTime(2026, 7, 1),
                weightKg: 80.4,
              ),
              WeightLogEntry(
                timestamp: DateTime(2026, 8, 1),
                weightKg: 77.8,
              ),
            ],
          ),
          healthAuthState: HealthAuthState.unverified,
          dailySteps: 12345,
        ),
        textScaler: const TextScaler.linear(2.0),
      );
      // Bis ans Ende scrollen, damit auch die unteren Karten wirklich
      // gelayoutet werden. Anker ist seit dem Wegfall des Blocks
      // „Daten & Konto" der Verbinden-Knopf der Health-Karte — der letzte
      // Bedienpunkt der Seite (bei `unverified` sichtbar, s. oben).
      await tester.ensureVisible(
        find.byKey(const ValueKey('profile-health-connect')),
      );
      await tester.pumpAndSettle();
    });
  });

  group('EN-Render-Smoke (i18n-Paket 5, Spec §6)', () {
    // Rendert unter Locale `en` in beiden Helligkeiten: kein Absturz, und
    // mindestens eine echte englische Uebersetzung steht im Baum. Muster:
    // test/coach_design_test.dart (Paket 4).
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      testWidgets('rendert unter en in $brightness ohne Ausnahme',
          (tester) async {
        _pinViewport(tester);
        await _pumpAsRoute(
          tester,
          _profile(),
          brightness: brightness,
          locale: const Locale('en'),
        );

        expect(tester.takeException(), isNull,
            reason: 'Rendering unter en/$brightness ist fehlgeschlagen');
        // „Mein Profil" -> „My Profile", „Verbindungen" -> „Connections".
        expect(find.text('My Profile'), findsOneWidget);
        expect(find.text('Connections'), findsOneWidget);
      });
    }
  });
}
