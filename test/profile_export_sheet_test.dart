// C7 (docs/REVIEW-2026-08-08.md): the export sheet shows the COMPLETE server
// export (DataExportService) and falls back honestly on error instead of
// claiming completeness. The entry point is `settings-export`; the file name
// keeps the old profile wording for history.
//
// Without `onExportData` the settings hide the row entirely rather than
// offering a partial result, so `DataExportSheet(vollstaendig: false)` and
// `fallbackSnapshot` have no caller left in the app.
//
// The service tests below run a STRICT MockClient: it answers only tables that
// really exist per supabase/migrations/ and returns 404 for anything else —
// the service used to query five dropped tables, so every export carried an
// `unvollstaendig` even when it was complete.
//
// Where the mock takes that truth from matters: the literal
// [_tabellenLautMigrationen], NOT `DataExportService`. Deriving the allowlist
// from `alleExportTabellen` would be tautological and blind to table drift
// between code and database.

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

/// Tables that really exist per supabase/migrations/ and hold user data under a
/// `*_select_own` policy. A literal on purpose, not derived from
/// [DataExportService] (see file header). The drift guard below reads the
/// migrations and fails once this literal no longer matches them.
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

/// Exists but belongs in no export: `edge_rate_limits` has no `user_id`, only a
/// SHA-256 hash of the subject, and `lifetime_stats_requests` is an idempotency
/// journal. Both revoke `authenticated` entirely, so exporting them would be a
/// permanent `unvollstaendig`.
const Set<String> _nichtExportierbar = <String>{
  'edge_rate_limits',
  'lifetime_stats_requests',
};

/// PostgREST fake that behaves like the REAL server: a table that no longer
/// exists per [_tabellenLautMigrationen] answers 404 (42P01), not an empty
/// result.
class _StrengerPostgrest {
  _StrengerPostgrest({this.zeilen = const <String, int>{}});

  /// Table -> rows on the server; tables not listed are empty. `logged_meals`
  /// stays empty here — its offset pagination has its own test in
  /// test/services/data_export_service_test.dart.
  final Map<String, int> zeilen;

  /// Requested tables that do not (any longer) exist.
  final List<String> unbekannteTabellen = <String>[];

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final tabelle = req.url.path.split('/').last;
    // Only PostgREST paths are table queries; an auth call must not pollute the
    // assertion below as an "unknown table".
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
    // Full device height: the settings are a ListView and the export row sits
    // below the account and preferences groups.
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `theme: buildEatovaTheme(...)` is required: the cards read their colors
    // via `AppTokens.of`, which deliberately throws without the ThemeExtension.
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
    // The LONG excerpt on purpose: the short one also appears in the subtitle
    // of the `settings-export` row, so it would match two widgets.
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
    // Without a server there is no export that satisfies GDPR art. 15, so
    // there is no row promising one either.
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
      // A literal nobody maintains is just a second copy of the same
      // assumption, so this reads a third source: the migrations themselves,
      // replayed in file-name order (create adds, drop removes).
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
        // Strip `--` line comments: the migrations discuss statements that
        // never run.
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
