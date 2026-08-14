// C7 (docs/REVIEW-2026-08-08.md): der In-App-Export war ein In-Memory-
// Teil-Snapshot. Das Export-Sheet zeigt jetzt die VOLLSTAENDIGE
// Server-Auskunft (DataExportService) und faellt bei einem Fehler ehrlich
// zurueck, statt Vollstaendigkeit zu behaupten.
//
// **Umgezogen am 2026-08-10.** Der Einstieg lag bis dahin im Profil
// (`profile-action-export`, Block „Daten & Konto"). Der Block ist auf
// Nutzer-Entscheid entfallen, weil er die Einstellungen doppelte — der
// Einstieg heisst jetzt `settings-export`. Die Aussagen dieser Datei sind
// deshalb NICHT gestrichen, sondern auf den verbliebenen Einstieg umgehaengt;
// der Dateiname bleibt, damit die Historie lesbar bleibt.
//
// Eine der drei Aussagen hat sich dabei geaendert und das ist ein Befund:
// den Fall „ohne Sync bleibt der Session-Snapshot" gibt es nicht mehr. Die
// Einstellungen blenden die Zeile ohne `onExportData` ganz aus, statt ein
// Teil-Ergebnis anzubieten. `DataExportSheet(vollstaendig: false)` und
// `fallbackSnapshot` haben damit in der App keinen Aufrufer mehr (s. Bericht).
//
// **Audit 2026-08-14.** Das Sheet zeigte weiter, was der DataExportService
// lieferte — und der fragte fuenf Tabellen ab, die
// 20260803120000_drop_removed_feature_tables.sql geloescht hat. PostgREST
// antwortet darauf 404, also stand in JEDER Auskunft ein `unvollstaendig`,
// obwohl sie vollstaendig war. Die Service-Tests unten fahren deshalb einen
// STRIKTEN MockClient: er beantwortet nur Tabellen, die es laut
// supabase/migrations/ wirklich gibt, und gibt auf alles andere 404.
//
// Entscheidend ist, WOHER der Mock diese Wahrheit nimmt: aus dem Literal
// [_tabellenLautMigrationen], NICHT aus `DataExportService`. Der erste Anlauf
// dieses Tests leitete die Allowlist aus `alleExportTabellen` ab und war
// damit tautologisch — jede Tabelle, die der Service abfragt, ist per
// Konstruktion in seiner eigenen Liste, bekaeme also immer 200. Ein Mock,
// dessen Wahrheit aus dem Pruefling stammt, kann Tabellen-Drift zwischen Code
// und Datenbank genauso wenig sehen wie der alte permissive Mock.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Die Tabellen, die es laut supabase/migrations/ heute wirklich gibt und die
/// Nutzerdaten unter einer `*_select_own`-Policy fuehren — Stand 2026-08-14,
/// bewusst als Literal statt aus [DataExportService] abgeleitet (siehe
/// Dateikopf). Der Drift-Waechter unten liest die Migrationen und faellt rot,
/// sobald dieses Literal nicht mehr zu ihnen passt.
const Set<String> _tabellenLautMigrationen = <String>{
  'profiles',
  'logged_meals',
  'lifetime_stats',
  'favorite_meals',
  'weight_log',
  'user_recipes',
  'chat_sessions',
  'chat_messages',
  'chat_quota_usage',
};

/// Existiert, gehoert aber in keine Auskunft: `edge_rate_limits` kennt keine
/// `user_id`, sondern nur einen SHA-256-Hash des Subjekts, und
/// `lifetime_stats_requests` ist ein Idempotenz-Journal verbrauchter
/// Request-IDs. Beiden ist `authenticated` komplett entzogen — der Client
/// kaeme gar nicht heran, ein Export-Versuch waere ein Dauer-`unvollstaendig`.
const Set<String> _nichtExportierbar = <String>{
  'edge_rate_limits',
  'lifetime_stats_requests',
};

/// PostgREST-Attrappe, die sich wie der ECHTE Server verhaelt: eine Tabelle,
/// die es laut [_tabellenLautMigrationen] nicht (mehr) gibt, beantwortet die
/// Abfrage mit 404 (42P01) statt mit einem leeren Ergebnis.
class _StrengerPostgrest {
  _StrengerPostgrest({this.zeilen = const <String, int>{}});

  /// Tabelle -> Zeilen, die auf dem Server liegen. Nicht genannte Tabellen
  /// sind leer. `logged_meals` bleibt in dieser Datei bewusst leer: die
  /// Offset-Pagination des Tagebuchs haengt an einem Handler, der `offset`
  /// auswertet — sie hat ihren eigenen Test in
  /// test/services/data_export_service_test.dart.
  final Map<String, int> zeilen;

  /// Angefragte Tabellen, die es nicht (mehr) gibt.
  final List<String> unbekannteTabellen = <String>[];

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final tabelle = req.url.path.split('/').last;
    // Nur PostgREST-Pfade sind Tabellen-Abfragen — ein Auth-Aufruf soll die
    // Zusicherung unten nicht als „unbekannte Tabelle" verunreinigen.
    final istTabellenAbfrage = req.url.path.contains('/rest/v1/');

    if (!istTabellenAbfrage || !_tabellenLautMigrationen.contains(tabelle)) {
      if (istTabellenAbfrage) unbekannteTabellen.add(tabelle);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'code': '42P01',
          'message': 'relation "public.$tabelle" does not exist',
        }),
        404,
        headers: const {'Content-Type': 'application/json'},
        request: req,
      );
    }

    final vorhanden = zeilen[tabelle] ?? 0;
    final limit =
        int.tryParse(req.url.queryParameters['limit'] ?? '') ?? vorhanden;
    final anzahl = vorhanden < limit ? vorhanden : limit;
    return http.Response(
      jsonEncode(List.generate(
        anzahl,
        (i) => <String, dynamic>{'id': '$tabelle-$i', 'user_id': 'user-export'},
      )),
      200,
      headers: const {'Content-Type': 'application/json'},
      request: req,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<void> oeffneExport(
    WidgetTester tester, {
    required Future<String> Function()? onExportData,
  }) async {
    // Volle Geraetehoehe: die Einstellungen sind eine ListView, und die
    // Export-Zeile liegt unterhalb von KONTO und PRÄFERENZEN.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `theme: buildEatovaTheme(...)` ist Pflicht, seit die Karten ihre Farben
    // ueber `AppTokens.of` lesen: das nackte MaterialApp haengt die
    // ThemeExtension nicht ans Theme, und AppTokens.of wirft dann absichtlich
    // (Verdrahtungs-Detektor).
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: SettingsScreen(
          email: 'jonas@example.com',
          onExportData: onExportData,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final zeile = find.byKey(const ValueKey('settings-export'));
    if (onExportData == null) return;
    await tester.ensureVisible(zeile);
    await tester.pumpAndSettle();
    await tester.tap(zeile);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'mit Sync zeigt das Sheet die vollstaendige Server-Auskunft — nicht '
      'mehr den Session-Ausschnitt', (tester) async {
    await oeffneExport(
      tester,
      onExportData: () async => '{"logged_meals": ["alle Zeilen"]}',
    );

    expect(find.text('Datenauskunft'), findsOneWidget);
    // Bewusst der LANGE Ausschnitt: „Vollständige Kopie" allein steht auch im
    // Untertitel der Zeile `settings-export` darunter — die kurze Fassung
    // faende zwei Widgets und pruefte nicht mehr das Sheet.
    expect(
      find.textContaining('Vollständige Kopie deiner gespeicherten Daten'),
      findsOneWidget,
    );
    expect(find.textContaining('logged_meals'), findsOneWidget);
    expect(find.textContaining('In-Memory Snapshot'), findsNothing);
  });

  testWidgets(
      'ohne Sync gibt es die Zeile gar nicht — statt eines halben Exports',
      (tester) async {
    // Frueher zeigte das Profil hier den Session-Snapshot und benannte ihn
    // als solchen. Die Einstellungen gehen einen Schritt weiter: ohne Server
    // gibt es keine Auskunft, die Art. 15 DSGVO genuegt — also auch keinen
    // Eintrag, der eine verspricht.
    await oeffneExport(tester, onExportData: null);

    expect(find.byKey(const ValueKey('settings-export')), findsNothing);
    expect(find.text('Daten Snapshot'), findsNothing);
  });

  testWidgets(
      'scheitert der Server-Abruf, sagt das Sheet es EHRLICH statt '
      'Vollstaendigkeit zu behaupten', (tester) async {
    await oeffneExport(
      tester,
      onExportData: () async => throw Exception('offline'),
    );

    expect(find.textContaining('Server nicht erreichbar'), findsOneWidget);
    expect(
      find.textContaining('Vollständige Kopie deiner gespeicherten Daten'),
      findsNothing,
      reason: 'ein fehlgeschlagener Abruf darf keine Vollstaendigkeit '
          'behaupten',
    );
  });

  group('welche Tabellen die Auskunft abdecken muss', () {
    test('genau die heute existierenden Nutzertabellen — keine mehr, keine '
        'weniger', () {
      expect(
        DataExportService.alleExportTabellen.toSet(),
        _tabellenLautMigrationen,
        reason: 'Zuviel abgefragt heisst 404 und ein Dauer-`unvollstaendig`, '
            'das niemanden mehr warnt; zuwenig abgefragt heisst eine '
            'unvollstaendige Auskunft nach Art. 15 DSGVO, die sich als '
            'vollstaendig ausgibt — der schlimmere der beiden Fehler',
      );
    });

    test('das Literal oben deckt sich mit supabase/migrations/', () {
      // Ein Literal, das niemand nachzieht, waere nur eine zweite Kopie
      // derselben Annahme. Deshalb hier die dritte Quelle: die Migrationen
      // selbst, in Dateinamen-Reihenfolge abgespielt (create legt an, drop
      // nimmt weg — 20260803120000 loescht fuenf Tabellen wieder).
      final anweisung = RegExp(
        r'(create|drop)\s+table\s+(?:if\s+(?:not\s+)?exists\s+)?public\.'
        r'([a-z_]+)',
        caseSensitive: false,
      );
      final dateien = Directory('supabase/migrations')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(
        dateien,
        isNotEmpty,
        reason: 'Migrationen nicht gefunden (aufgelöst von '
            '${Directory.current.path})',
      );

      final lebend = <String>{};
      for (final datei in dateien) {
        // `--`-Zeilenkommentare raus: die Migrationen erklaeren ihre
        // Sicherheitsentscheidungen ausfuehrlich und nennen dabei auch
        // Anweisungen, die nie laufen.
        final sql = datei
            .readAsStringSync()
            .split('\n')
            .map((z) {
              final i = z.indexOf('--');
              return i < 0 ? z : z.substring(0, i);
            })
            .join('\n');
        for (final treffer in anweisung.allMatches(sql)) {
          final name = treffer.group(2)!;
          if (treffer.group(1)!.toLowerCase() == 'create') {
            lebend.add(name);
          } else {
            lebend.remove(name);
          }
        }
      }

      expect(
        _tabellenLautMigrationen.difference(lebend),
        isEmpty,
        reason: 'diese Tabellen fuehrt das Test-Literal, es gibt sie aber '
            'nicht mehr',
      );
      expect(
        lebend.difference(_tabellenLautMigrationen.union(_nichtExportierbar)),
        isEmpty,
        reason: 'neue Tabelle in supabase/migrations/: entweder gehoert sie '
            'in die Auskunft (dann in _tabellenLautMigrationen UND in '
            'DataExportService.userIdTabellen) oder begruendet nicht (dann '
            'in _nichtExportierbar)',
      );
    });
  });

  group('die Quelle des Sheets gegen einen strikten Server', () {
    DataExportService service(_StrengerPostgrest server) {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: server.client(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      return DataExportService(client, 'user-export');
    }

    test(
        'antworten alle existierenden Tabellen, meldet sich die Auskunft NICHT '
        'mehr als unvollstaendig', () async {
      final server = _StrengerPostgrest(
        zeilen: const <String, int>{'profiles': 1, 'weight_log': 3},
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      expect(
        server.unbekannteTabellen,
        isEmpty,
        reason: 'der Export fragt Tabellen ab, die es nicht mehr gibt '
            '(20260803120000_drop_removed_feature_tables.sql) — PostgREST '
            'antwortet 404',
      );
      expect(
        json.containsKey('unvollstaendig'),
        isFalse,
        reason: 'eine vollstaendige Auskunft, die sich dauerhaft als '
            'unvollstaendig ausweist, macht das Warnsignal wertlos',
      );
      for (final tabelle in _tabellenLautMigrationen) {
        expect(json.containsKey(tabelle), isTrue,
            reason: '$tabelle existiert, steht aber in keiner Sektion des '
                'Exports');
      }
      expect(json['weight_log'], hasLength(3));
    });

    test(
        'liegen mehr Zeilen auf dem Server, als eine Seite fasst, steht die '
        'Kappung im Export', () async {
      final server = _StrengerPostgrest(
        zeilen: const <String, int>{
          'chat_messages': DataExportService.einSeitenLimit + 1,
        },
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      final gekappt = json['gekappt'] as Map<String, dynamic>?;
      expect(
        gekappt,
        isNotNull,
        reason: 'ein stilles Abschneiden macht die Auskunft unauffaellig '
            'unvollstaendig — der Empfaenger haelt die Grenze fuer seinen '
            'Datenbestand',
      );
      expect(gekappt!['sektionen'], contains('chat_messages'));
      expect(gekappt['grenzeProSektion'], DataExportService.einSeitenLimit);
      expect(
          json['chat_messages'], hasLength(DataExportService.einSeitenLimit));
      expect(
        json.containsKey('unvollstaendig'),
        isFalse,
        reason: 'eine gekappte Sektion ist da, nur nicht ganz — das ist etwas '
            'anderes als eine fehlende',
      );
    });

    test(
        'genau eine volle Seite ist KEINE Kappung — sonst waere der Hinweis '
        'derselbe Dauerlaeufer wie das alte unvollstaendig', () async {
      final server = _StrengerPostgrest(
        zeilen: const <String, int>{
          'chat_messages': DataExportService.einSeitenLimit,
        },
      );
      final json = jsonDecode(await service(server).buildExportJson())
          as Map<String, dynamic>;

      expect(json.containsKey('gekappt'), isFalse);
      expect(
          json['chat_messages'], hasLength(DataExportService.einSeitenLimit));
    });
  });
}
