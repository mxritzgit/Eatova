import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import 'support/harness.dart';

// W6-07 — "unknown" must not mean "full".
//
// loadQuotaToday() swallowed every error and returned
// ChatQuotaSnapshot.unknown, which was defined as a FULL quota, and
// _refreshQuota wrote that straight into _quota. A failing RPC after an
// exhausted quota therefore reopened the composer and the next attempt hit 429.
//
// These tests run the REAL chain: a real CoachChatService on a real
// SupabaseClient whose HTTP layer is a MockClient. No fake overrides
// loadQuotaToday(), otherwise the test would check the stub instead of the
// error handling that does the damage.

/// `request:` is mandatory: `PostgrestBuilder._parseResponse` dereferences
/// `response.request!`, so without it every RPC in the test fails with a
/// TypeError and only the service's error path would be exercised.
http.Response _json(http.Request req, Object? body, int status) => http.Response(
      jsonEncode(body),
      status,
      request: req,
      headers: const {'Content-Type': 'application/json'},
    );

/// Fake Supabase backend: routes the RPC/function paths [CoachChatService]
/// actually calls.
class _Backend {
  int quotaCalls = 0;
  int sessionCalls = 0;

  /// From which `get_chat_quota_today` call on the RPC fails (1-based).
  int quotaScheitertAbCall = 1 << 30;

  /// From which `ensure_default_chat_session` call on the RPC succeeds.
  int sessionKlapptAbCall = 1;

  /// Row `get_chat_quota_today` returns on success.
  Map<String, Object?> quotaZeile = const {
    'used': 5,
    'remaining': 0,
    'daily_limit': 5,
  };

  /// Status code of the `coach-chat` Edge Function.
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
    // chat_messages select and everything else: empty.
    return _json(req, <dynamic>[], 200);
  }
}

/// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
/// constructor that every widget test would trip over.
CoachChatService _service(_Backend backend) {
  final client = SupabaseClient(
    'https://example.supabase.co',
    'test-anon-key',
    httpClient: backend.client(),
  );
  client.auth.stopAutoRefresh();
  return CoachChatService(client, 'user-123');
}

/// Microphone that always refuses — the shortest path to an error banner
/// without networking.
///
/// Not via a failed `send()`: `functions.invoke` never runs under a widget
/// test's FakeAsync (the future just hangs), so the test would silently check
/// nothing. The banner does not care where the error came from.
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

/// Replica of the tab shell: [IndexedStack] + [TickerMode].
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

Future<void> _pumpHost(WidgetTester tester, CoachChatService svc) async {
  await pumpLocalized(
    tester,
    _TabHost(service: svc),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// One tab switch. Call twice for away and back.
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
      // Empty table return: the RPC was reachable but returned no row. `?? 5`
      // silently turned that into "5 left".
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
      // P5-06: gesperrt wird nur gegen ein Limit, das der SERVER genannt hat —
      // `get_chat_quota_today` echot nur zurueck, was der Client hineinreicht.
      // Das ist der Zustand, den die App nach der ersten Antwort der Edge
      // Function erreicht; hier vorgegeben, weil `functions.invoke` unter dem
      // FakeAsync eines Widget-Tests nie aufloest.
      final svc = _service(backend)..serverDailyLimit = 5;
      await _pumpHost(tester, svc);

      expect(backend.quotaCalls, 1);
      expect(find.text('Limit für heute erreicht'), findsOneWidget,
          reason: 'Bootstrap: 5/5 verbraucht');
      expect(_composerTippbar(tester), isFalse);

      await _wechsleTab(tester); // away
      await _wechsleTab(tester); // and back -> RPC fails

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
      // The mic renders on iOS only; tests run as Android by default. Reset
      // in `finally`: the binding checks foundation vars before tearDowns.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final backend = _Backend()
          ..quotaZeile = const {'used': 0, 'remaining': 5, 'daily_limit': 5};
        await pumpLocalized(
          tester,
          _TabHost(
            service: _service(backend),
            speechInput: const _StummesMikro(),
          ),
          reducedMotion: false,
          scaffold: false,
          safeArea: false,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(_StummesMikro.meldung), findsOneWidget);

        await _wechsleTab(tester);
        await _wechsleTab(tester);

        expect(find.text(_StummesMikro.meldung), findsNothing,
            reason:
                'vor D6 raeumte der Tab-Wechsel das Banner mit dem Screen ab');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
