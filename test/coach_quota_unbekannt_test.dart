import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/theme/app_theme.dart';

// W6-07 — „unbekannt" darf nicht „voll" heissen.
//
// Die Kette, die Verifizierer V2 belegt hat:
//   1. loadQuotaToday() faengt JEDEN Fehler und liefert ChatQuotaSnapshot.unknown
//   2. `unknown` war definiert als used: 0, remaining: 5, dailyLimit: 5 — also
//      nicht „unbekannt", sondern „volles Kontingent"
//   3. _refreshQuota schrieb das ungeprueft in _quota
// Ergebnis: 5/5 verbraucht, Composer korrekt gesperrt, Tab-Wechsel, RPC
// scheitert (Flugmodus/abgelaufener Token) -> Anzeige springt auf „5 uebrig",
// Composer wieder offen, naechster Versuch laeuft in den 429.
//
// Diese Tests fahren bewusst die ECHTE Kette: echter CoachChatService auf
// einem echten SupabaseClient, dessen HTTP-Schicht durch MockClient ersetzt
// ist. Kein Fake ueberschreibt loadQuotaToday() — sonst prueft der Test die
// Attrappe statt der Fehlerbehandlung, die den Schaden anrichtet.

/// `request:` ist Pflicht, nicht Kosmetik: `PostgrestBuilder._parseResponse`
/// greift ungeprueft auf `response.request!` zu — ohne diesen Durchstich
/// scheitert JEDER RPC im Test an einem TypeError, und die Tests wuerden nur
/// den Fehlerpfad des Services pruefen statt seines Erfolgspfads.
http.Response _json(http.Request req, Object? body, int status) => http.Response(
      jsonEncode(body),
      status,
      request: req,
      headers: const {'Content-Type': 'application/json'},
    );

/// Gefakter Supabase-Backend-Endpunkt: routet auf die RPC-/Function-Pfade,
/// die [CoachChatService] wirklich anspricht.
class _Backend {
  int quotaCalls = 0;
  int sessionCalls = 0;

  /// Ab dem wievielten `get_chat_quota_today` der RPC scheitert (1-basiert).
  int quotaScheitertAbCall = 1 << 30;

  /// Ab dem wievielten `ensure_default_chat_session` der RPC klappt.
  int sessionKlapptAbCall = 1;

  /// Zeile, die `get_chat_quota_today` im Erfolgsfall liefert.
  Map<String, Object?> quotaZeile = const {
    'used': 5,
    'remaining': 0,
    'daily_limit': 5,
  };

  /// Statuscode der Edge Function `coach-chat`.
  int sendStatus = 200;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/rpc/get_chat_quota_today')) {
      quotaCalls++;
      if (quotaCalls >= quotaScheitertAbCall) {
        return _json(req, {'message': 'rpc kaputt'}, 500);
      }
      return _json(req, [quotaZeile], 200);
    }
    if (path.endsWith('/rpc/ensure_default_chat_session')) {
      sessionCalls++;
      if (sessionCalls < sessionKlapptAbCall) {
        return _json(req, {'message': 'offline'}, 500);
      }
      return _json(req, 's1', 200);
    }
    if (path.endsWith('/rpc/list_chat_sessions')) {
      return _json(req, <dynamic>[], 200);
    }
    if (path.contains('coach-chat')) {
      if (sendStatus != 200) {
        return _json(req, {'error': 'internal'}, sendStatus);
      }
      return _json(req, {
        'reply': 'Klar, mach das.',
        'refusal': false,
        'remaining': 3,
        'session_id': 's1',
      }, 200);
    }
    // chat_messages-Select und alles andere: leer.
    return _json(req, <dynamic>[], 200);
  }
}

/// `stopAutoRefresh()` ist Pflicht: GoTrue startet im Konstruktor einen
/// periodischen Timer, an dem jeder Widget-Test scheitert.
CoachChatService _service(_Backend backend) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: backend.client(),
  );
  client.auth.stopAutoRefresh();
  return CoachChatService(client, 'user-123');
}

/// Mikrofon, das immer absagt — der kuerzeste Weg zu einem Fehlerbanner OHNE
/// Netz.
///
/// Bewusst nicht ueber ein gescheitertes `send()`: `functions.invoke` laeuft
/// unter dem FakeAsync eines Widget-Tests nie an (die Anfrage geht nicht
/// einmal raus, die Future bleibt haengen) — der Test wuerde dann still gar
/// nichts pruefen. Fuer das Banner ist die Quelle des Fehlers ohnehin egal.
class _StummesMikro extends CoachSpeechInput {
  const _StummesMikro();

  static const String meldung =
      'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.';

  @override
  Future<String?> listen({
    String localeId = 'de_DE',
    required AppLocalizations l10n,
  }) async {
    throw const CoachSpeechException(meldung);
  }
}

/// Nachbau des Tab-Rahmens seit D6: [IndexedStack] + [TickerMode].
class _TabHost extends StatefulWidget {
  const _TabHost({
    required this.service,
    this.speechInput = const CoachSpeechInput(),
  });

  final CoachChatService service;
  final CoachSpeechInput speechInput;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  int _index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(
          index: _index,
          sizing: StackFit.expand,
          children: <Widget>[
            TickerMode(
              enabled: _index == 0,
              child: CoachChatScreen(
                service: widget.service,
                userName: 'M',
                speechInput: widget.speechInput,
              ),
            ),
            TickerMode(
              enabled: _index == 1,
              child: const Center(child: Text('anderer Tab')),
            ),
          ],
        ),
        bottomNavigationBar: TextButton(
          key: const ValueKey('switch-tab'),
          onPressed: () => setState(() => _index = _index == 0 ? 1 : 0),
          child: const Text('wechseln'),
        ),
      );
}

/// Delegates + feste Locale `de`: der Coach ruft seit der i18n-Migration
/// (Paket 4) context.l10n — ohne Lokalisierung wirft AppLocalizations.of()
/// beim ersten Build (Muster: home_page_tabs_test.dart).
const List<LocalizationsDelegate<dynamic>> _l10nDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

Future<void> _pumpHost(WidgetTester tester, CoachChatService svc) async {
  await tester.pumpWidget(MaterialApp(
    // Ohne das Eatova-Theme wirft `AppTokens.of` — der Screen liest seine
    // Farben seit dem Design-Refactor ueber `context.t`.
    theme: buildEatovaTheme(Brightness.dark),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: _l10nDelegates,
    home: _TabHost(service: svc),
  ));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Ein Tab-Wechsel. Zweimal aufrufen = weg und zurueck.
Future<void> _wechsleTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('switch-tab')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

bool _composerTippbar(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const ValueKey('coach-input')))
        .enabled ??
    true;

void main() {
  group('CoachChatService.loadQuotaToday: „unbekannt" ist kein Wert', () {
    test('ein gescheiterter RPC darf nicht als volles Kontingent zurueckkommen',
        () async {
      final svc = _service(_Backend()..quotaScheitertAbCall = 1);
      await expectLater(
        svc.loadQuotaToday(),
        throwsA(isA<CoachDataUnavailable>()),
        reason: 'ChatQuotaSnapshot.unknown behauptet "5 von 5 frei", obwohl '
            'der Server nichts gesagt hat',
      );
    });

    test('eine Antwort ohne Zahlen darf keine Zahlen erfinden', () async {
      // Leere Table-Return-Liste: der RPC war erreichbar, hat aber keine Zeile
      // geliefert. `?? 5` machte daraus lautlos „5 uebrig".
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((req) async => _json(req, <dynamic>[], 200)),
      );
      client.auth.stopAutoRefresh();
      final svc = CoachChatService(client, 'user-123');
      await expectLater(
        svc.loadQuotaToday(),
        throwsA(isA<CoachDataUnavailable>()),
        reason: 'ohne used/remaining/daily_limit weiss niemand etwas',
      );
    });

    test('eine gueltige Antwort kommt unveraendert durch (Kontrast)', () async {
      final svc = _service(
        _Backend()
          ..quotaZeile = const {'used': 2, 'remaining': 3, 'daily_limit': 5},
      );
      final q = await svc.loadQuotaToday();
      expect(q.used, 2);
      expect(q.remaining, 3);
      expect(q.dailyLimit, 5);
    });
  });

  group('Coach-Screen: was weiss ich, und darf ich meinen Stand verwerfen', () {
    testWidgets(
        'Nachzug ueber ein erschoepftes Kontingent: scheitert der RPC, bleibt '
        'die Sperre stehen', (tester) async {
      final backend = _Backend()..quotaScheitertAbCall = 2;
      await _pumpHost(tester, _service(backend));

      expect(backend.quotaCalls, 1);
      expect(find.text('Limit für heute erreicht'), findsOneWidget,
          reason: 'Bootstrap: 5/5 verbraucht');
      expect(_composerTippbar(tester), isFalse);

      await _wechsleTab(tester); // weg
      await _wechsleTab(tester); // und zurueck -> RPC scheitert

      expect(backend.quotaCalls, 2, reason: 'die Rueckkehr fragt nach');
      expect(find.text('Limit für heute erreicht'), findsOneWidget,
          reason: 'eine Netzstoerung darf das Kontingent nicht verschenken');
      expect(_composerTippbar(tester), isFalse,
          reason: 'sonst laeuft der naechste Versuch in den 429');
    });

    testWidgets(
        'Kaltstart ohne Netz: unbekannt sperrt NICHT — der Server entscheidet '
        'selbst', (tester) async {
      final backend = _Backend()..quotaScheitertAbCall = 1;
      await _pumpHost(tester, _service(backend));

      expect(find.text('Limit für heute erreicht'), findsNothing,
          reason: 'niemand weiss, ob das Kontingent leer ist');
      expect(_composerTippbar(tester), isTrue);
      expect(find.byKey(const ValueKey('coach-quota-hint')), findsNothing,
          reason: '„Noch N Fragen heute" waere eine erfundene Zahl');
    });

    testWidgets(
        'offline beim ersten Coach-Besuch: der Tab-Wechsel heilt die Session, '
        'statt den Composer fuer den Rest des App-Laufs totzustellen',
        (tester) async {
      final backend = _Backend()
        ..sessionKlapptAbCall = 2
        ..quotaZeile = const {'used': 0, 'remaining': 5, 'daily_limit': 5};
      await _pumpHost(tester, _service(backend));

      expect(find.text('Konnte keine Coach-Session laden.'), findsOneWidget);
      expect(_composerTippbar(tester), isFalse);

      await _wechsleTab(tester);
      await _wechsleTab(tester);

      expect(find.text('Konnte keine Coach-Session laden.'), findsNothing,
          reason: 'der zweite Anlauf hat eine Session bekommen');
      expect(_composerTippbar(tester), isTrue,
          reason: 'ohne Heilungspfad bliebe _activeSessionId fuer immer null');
    });

    testWidgets(
        'ein Fehlerbanner ueberlebt den Tab-Wechsel nicht — es ist Rueckmeldung '
        'auf eine Aktion, kein Dauerzustand', (tester) async {
      final backend = _Backend()
        ..quotaZeile = const {'used': 0, 'remaining': 5, 'daily_limit': 5};
      await tester.pumpWidget(MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: _l10nDelegates,
        home: _TabHost(
          service: _service(backend),
          speechInput: const _StummesMikro(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const ValueKey('coach-mic')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(_StummesMikro.meldung), findsOneWidget);

      await _wechsleTab(tester);
      await _wechsleTab(tester);

      expect(find.text(_StummesMikro.meldung), findsNothing,
          reason: 'vor D6 raeumte der Tab-Wechsel das Banner mit dem Screen ab');
    });
  });
}
