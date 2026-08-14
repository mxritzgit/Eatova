import 'dart:convert';
import 'dart:developer' as dev;

import 'package:supabase/supabase.dart';

/// Baut die vollstaendige Datenauskunft (DSGVO Art. 15/20) direkt aus den
/// Server-Tabellen — der autoritativen Kopie — statt aus dem In-Memory-Zustand
/// der Session.
///
/// Hintergrund (C7, docs/REVIEW-2026-08-08.md): der fruehere „Daten Snapshot"
/// enthielt weder Tagebuch noch Favoriten, Rezepte oder Coach-Verlauf und
/// nannte sich selbst ehrlich „In-Memory Snapshot deiner aktuellen Session".
/// Fuer die Auskunfts-Vollstaendigkeit verwies PRIVACY.md auf einen manuellen
/// E-Mail-Prozess. Dieser Service holt stattdessen JEDE Tabelle mit einer
/// `*_select_own`-Policy per RLS-gefiltertem `select('*')`.
///
/// Die Tabellen der zurueckgebauten Features (daily_logs, caffeine_entries,
/// sleep_entries, weekly_plans, workout_sets) standen hier bis 2026-08-14 mit
/// in der Liste, unter dem Argument „Altbestand ist Nutzerdaten, egal ob das
/// Feature noch ein Tab ist". Diesen Altbestand gibt es nicht mehr:
/// 20260803120000_drop_removed_feature_tables.sql hat die fuenf Tabellen samt
/// Inhalt geloescht. PostgREST antwortete auf die Abfragen mit 404, womit
/// JEDE Auskunft sich als unvollstaendig auswies, obwohl sie vollstaendig
/// war — ein Warnsignal, das immer feuert, warnt niemanden.
///
/// Fehler-Politik wie bei `_restoreDroppedDeletes`: jede Tabelle in ihrem
/// eigenen try. Eine nicht lesbare Tabelle darf weder den Export reissen noch
/// still als „leer" erscheinen — sie steht namentlich unter `unvollstaendig`.
/// Eine bei [einSeitenLimit] abgeschnittene Sektion ist etwas anderes als eine
/// fehlende und steht deshalb getrennt unter `gekappt`: sonst haelt der
/// Empfaenger die Kappungsgrenze fuer seinen vollstaendigen Datenbestand.
class DataExportService {
  DataExportService(this._client, this._userId, {this.pageSize = 1000});

  final SupabaseClient _client;
  final String _userId;

  /// Seitengroesse der `logged_meals`-Pagination — im Test klein stellbar,
  /// damit der Schleifenpfad wirklich laeuft.
  final int pageSize;

  /// Obergrenze fuer die uebrigen Tabellen (eine Seite): Favoriten sind auf
  /// 200 gedeckelt, Chat/Rezepte/Gewicht liegen um Groessenordnungen unter
  /// diesem Limit. Nur das Tagebuch waechst unbegrenzt und paginiert deshalb.
  /// Wird die Grenze doch erreicht, steht die Sektion unter `gekappt`.
  static const int einSeitenLimit = 10000;

  /// `user_id`-gefilterte Tabellen mit einer Zeile-gehoert-dem-User-Policy.
  /// `profiles` (Schluessel `id`) und `logged_meals` (paginiert) laufen
  /// separat, stehen aber mit in [alleExportTabellen].
  ///
  /// Gegen supabase/migrations/ abgeglichen (Stand 2026-08-14): das sind alle
  /// heute existierenden Tabellen mit einer `*_select_own`-Policy. Bewusst
  /// NICHT dabei ist `edge_rate_limits` — die Tabelle kennt keine `user_id`,
  /// sondern nur einen SHA-256-Hash des Subjekts, hat keine select-Policy und
  /// ist `authenticated` komplett entzogen (nur die security-definer-RPC
  /// schreibt hinein). Eine neue Tabelle mit Nutzerdaten gehoert hier her,
  /// sonst faellt sie aus der Auskunft.
  static const List<String> userIdTabellen = <String>[
    'lifetime_stats',
    'favorite_meals',
    'weight_log',
    'user_recipes',
    'chat_sessions',
    'chat_messages',
    'chat_quota_usage',
  ];

  /// Jede Sektion, die ein vollstaendiger Export enthalten muss. Der
  /// Vollstaendigkeits-Test vergleicht diese Liste gegen ein eigenes, aus
  /// supabase/migrations/ abgeleitetes Literal — er darf sie nicht als
  /// Wahrheit uebernehmen, sonst sieht er Tabellen-Drift nie.
  static const List<String> alleExportTabellen = <String>[
    'profiles',
    'logged_meals',
    ...userIdTabellen,
  ];

  /// Die komplette Auskunft als eingerücktes JSON.
  Future<String> buildExportJson() async {
    final export = <String, dynamic>{
      'format': 'eatova-export/1',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'userId': _userId,
    };
    final unvollstaendig = <String>[];
    final gekappt = <String>[];

    Future<void> sektion(
      String name,
      Future<List<Map<String, dynamic>>> Function() laden,
    ) async {
      try {
        export[name] = await laden();
      } catch (e, st) {
        // Kein stilles Leer-Vortaeuschen: die Sektion FEHLT und sagt es.
        unvollstaendig.add(name);
        dev.log('DataExport: $name nicht lesbar',
            error: e, stackTrace: st, name: 'data_export');
      }
    }

    await sektion(
      'profiles',
      () => _rows('profiles', keySpalte: 'id', gekappt: gekappt),
    );
    await sektion('logged_meals', _alleLoggedMeals);
    for (final tabelle in userIdTabellen) {
      await sektion(tabelle, () => _rows(tabelle, gekappt: gekappt));
    }

    if (unvollstaendig.isNotEmpty) {
      export['unvollstaendig'] = unvollstaendig;
    }
    if (gekappt.isNotEmpty) {
      export['gekappt'] = <String, dynamic>{
        'grenzeProSektion': einSeitenLimit,
        'sektionen': gekappt,
      };
    }
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  Future<List<Map<String, dynamic>>> _rows(
    String tabelle, {
    required List<String> gekappt,
    String keySpalte = 'user_id',
  }) async {
    // Eine Zeile ueber der Grenze mitholen und wieder abschneiden: nur so
    // laesst sich „genau [einSeitenLimit] Zeilen vorhanden" von „es liegen
    // mehr dahinter" unterscheiden. Ein falscher Kappungs-Hinweis waere
    // derselbe Fehler wie ein falsches `unvollstaendig`.
    final rows = await _client
        .from(tabelle)
        .select('*')
        .eq(keySpalte, _userId)
        .limit(einSeitenLimit + 1);
    final alle = rows.map((r) => Map<String, dynamic>.of(r)).toList();
    if (alle.length > einSeitenLimit) {
      gekappt.add(tabelle);
      return alle.sublist(0, einSeitenLimit);
    }
    return alle;
  }

  /// Das Tagebuch ist die einzige unbegrenzt wachsende Tabelle —
  /// Offset-Pagination mit stabiler Gesamtordnung (logged_at, id), damit
  /// Zeit-Gleichstaende an einer Seitengrenze keine Zeile verlieren.
  Future<List<Map<String, dynamic>>> _alleLoggedMeals() async {
    final rows = <Map<String, dynamic>>[];
    final gesehen = <Object?>{};
    var von = 0;
    while (true) {
      final seite = await _client
          .from('logged_meals')
          .select('*')
          .eq('user_id', _userId)
          .order('logged_at', ascending: false)
          .order('id', ascending: false)
          .range(von, von + pageSize - 1);
      for (final row in seite) {
        final map = Map<String, dynamic>.of(row);
        if (gesehen.add(map['id'])) rows.add(map);
      }
      if (seite.length < pageSize) break;
      von += pageSize;
    }
    return rows;
  }
}
