import 'dart:convert';
import 'dart:developer' as dev;

import 'package:supabase/supabase.dart';

import 'sync_error_messages.dart' show isNetworkSyncError;
import 'user_recipe_reads.dart';

/// Builds the full GDPR Art. 15/20 data export from the server tables (the
/// authoritative copy), not from in-memory session state: every table with a
/// `*_select_own` policy via an RLS-filtered `select('*')`.
///
/// Each table gets its own try. An unreadable table must neither break the
/// export nor silently look empty — it is named under `unvollstaendig`. Every
/// section is read in keyset pages until the server has no more rows, so the
/// live PostgREST `max_rows` of 1000 no longer cuts it. A section that still
/// has rows beyond [grenzeProSektion] is listed separately under `gekappt`,
/// so the recipient does not mistake the bound for their whole data set. A
/// section that ends with fewer rows than its first page counted (rows
/// deleted while paging) is explicitly unverified.
///
/// Because every section error is caught, [buildExportJson] never throws
/// offline; how much actually arrived is what [exportUmfangAus] reports.
///
/// The sheet waits on the whole export, so reads fail fast: no client-side
/// retry backoff, and a network error before the first section arrived skips
/// the rest, which would only wait for the same failure. The user exports
/// again once online.
class DataExportService {
  DataExportService(
    this._client,
    this._userId, {
    this.pageSize = 1000,
    this.grenzeProSektion = standardGrenzeProSektion,
  });

  final SupabaseClient _client;
  final String _userId;

  /// Rows asked for per page; small in tests so the loop path is actually
  /// exercised. The server may answer with fewer (`max_rows`): paging
  /// continues after the last row until a page comes back empty.
  final int pageSize;

  /// Safety bound per section (the diary excepted): far above any real
  /// account, it only stops a server that keeps answering. Rows behind it
  /// put the section into `gekappt`.
  final int grenzeProSektion;

  static const int standardGrenzeProSektion = 100000;

  /// Keyset column per paged section: the primary key without `user_id`,
  /// unique within the account, so `key > last` neither skips nor repeats a
  /// row. `profiles` and `lifetime_stats` hold one row per account. Every
  /// table read through `_rows` needs an entry, or it ends up in
  /// `unvollstaendig`.
  static const Map<String, String> schluesselSpalten = <String, String>{
    'profiles': 'id',
    'lifetime_stats': 'user_id',
    'favorite_meals': 'favorite_key',
    'weight_log': 'id',
    'training_plans': 'id',
    'planned_meals': 'id',
    'shopping_checks': 'id',
    'training_history': 'id',
    'training_history_deletions': 'id',
    'chat_sessions': 'id',
    'chat_messages': 'id',
    'chat_quota_usage': 'day',
    'ai_provider_user_usage': 'usage_date',
    'ai_consents': 'id',
    'ai_reports': 'id',
  };

  /// Format tag in every export header; [exportUmfangAus] uses it to tell an
  /// export of this service apart from any other JSON.
  static const String formatKennung = 'eatova-export/1';

  /// `user_id`-filtered tables with a row-owned-by-user policy. `profiles`
  /// (filtered by `id`) and `logged_meals` (its own cursor) run separately
  /// but are part of [alleExportTabellen].
  ///
  /// `edge_rate_limits` is deliberately absent: no `user_id` (only a SHA-256
  /// subject hash), no select policy, revoked from `authenticated`. Any new
  /// table holding user data belongs here or it drops out of the export.
  /// `lifetime_stats_requests` contains operational replay markers and is
  /// reserved for a separate, authorized operator data-access request.
  static const List<String> userIdTabellen = <String>[
    'lifetime_stats',
    'favorite_meals',
    'weight_log',
    'user_recipes',
    'training_plans',
    'planned_meals',
    'shopping_checks',
    'training_history',
    'training_history_deletions',
    'chat_sessions',
    'chat_messages',
    'chat_quota_usage',
    'ai_provider_user_usage',
    'ai_consents',
    'ai_reports',
  ];

  /// Every section a complete export must contain. The completeness test
  /// compares this against its own literal derived from supabase/migrations/,
  /// never adopting it as truth — otherwise it would never see table drift.
  static const List<String> alleExportTabellen = <String>[
    'profiles',
    'logged_meals',
    ...userIdTabellen,
    'user_recipe_history',
  ];

  /// The complete export as indented JSON.
  Future<String> buildExportJson() async {
    final export = <String, dynamic>{
      'format': formatKennung,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'userId': _userId,
    };
    final unvollstaendig = <String>[];
    final ungeprueft = <String>[];
    // Section -> rows the server really holds; `null` if it did not count.
    final gekappt = <String, int?>{};
    var angekommen = false;
    var offline = false;

    Future<void> sektion(
      String name,
      Future<List<Map<String, dynamic>>> Function() laden,
    ) async {
      if (offline) {
        unvollstaendig.add(name);
        return;
      }
      try {
        export[name] = await laden();
        angekommen = true;
      } catch (e, st) {
        // No silent empty section: it is missing and says so.
        unvollstaendig.add(name);
        if (!angekommen && isNetworkSyncError(e)) offline = true;
        dev.log('DataExport: $name nicht lesbar',
            error: e, stackTrace: st, name: 'data_export');
      }
    }

    await sektion(
      'profiles',
      () => _rows('profiles', filterSpalte: 'id', gekappt: gekappt,
          ungeprueft: ungeprueft),
    );
    await sektion('logged_meals', _alleLoggedMeals);
    for (final tabelle in userIdTabellen) {
      await sektion(tabelle, () => tabelle == 'user_recipes'
          ? UserRecipeReads(_client, _userId).loadRows()
          : _rows(tabelle, gekappt: gekappt, ungeprueft: ungeprueft));
    }
    await sektion('user_recipe_history', _allRecipeHistory);

    if (unvollstaendig.isNotEmpty) {
      export['unvollstaendig'] = unvollstaendig;
    }
    if (ungeprueft.isNotEmpty) {
      export['vollstaendigkeitUnbekannt'] = ungeprueft;
    }
    if (gekappt.isNotEmpty) {
      final gezaehlt = <String, int>{
        for (final eintrag in gekappt.entries)
          if (eintrag.value != null) eintrag.key: eintrag.value!,
      };
      export['gekappt'] = <String, dynamic>{
        'grenzeProSektion': grenzeProSektion,
        'sektionen': gekappt.keys.toList(),
        // Without the real row count the recipient would mistake the bound
        // for their data set.
        if (gezaehlt.isNotEmpty) 'zeilenAufDemServer': gezaehlt,
      };
    }
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  /// The append-only journal uses an exclusive revision cursor. New events
  /// above the initial page do not shift older entries across page boundaries.
  Future<List<Map<String, dynamic>>> _allRecipeHistory() async {
    final reader = UserRecipeReads(_client, _userId);
    final rows = <Map<String, dynamic>>[];
    int? before;
    do {
      final page = await reader.loadHistory(beforeRevision: before);
      rows.addAll(page.versions.map((version) => version.toJson()));
      before = page.nextBefore;
    } while (before != null);
    return rows;
  }

  /// One section, keyset-paged on its [schluesselSpalten] column: each page
  /// asks for the rows after the previous page's last key, so deleting an
  /// already read row cannot shift an unread one past a page boundary, and a
  /// server cap below [pageSize] (PostgREST `max_rows`) only means more
  /// pages. Paging ends at an empty page, not at a short one.
  ///
  /// The first page also asks the server to count (`Prefer: count=exact`,
  /// same request): when it already holds every counted row the section is
  /// done in one request. At [grenzeProSektion] one more row decides
  /// between "exactly the bound" and `gekappt`. Reads skip the client's
  /// retry backoff (see the class comment).
  Future<List<Map<String, dynamic>>> _rows(
    String tabelle, {
    required Map<String, int?> gekappt,
    required List<String> ungeprueft,
    String filterSpalte = 'user_id',
  }) async {
    final schluessel = schluesselSpalten[tabelle];
    if (schluessel == null) {
      throw StateError('No export key column for $tabelle');
    }
    final rows = <Map<String, dynamic>>[];
    final gesehen = <Object>{};
    Object? nach;
    int? aufDemServer;
    var erste = true;
    while (true) {
      final rest = grenzeProSektion - rows.length;
      final limit = rest <= 0 ? 1 : (rest < pageSize ? rest : pageSize);
      final List<Map<String, dynamic>> seite;
      if (erste) {
        (seite, aufDemServer) =
            await _ersteSeite(tabelle, filterSpalte, schluessel, limit);
      } else {
        seite = await _seite(tabelle, filterSpalte, schluessel, limit, nach);
      }
      if (seite.isEmpty) break;
      if (rest <= 0) {
        // Rows behind the bound; the probe row is no export content.
        gekappt[tabelle] = aufDemServer;
        return rows;
      }
      final vorher = rows.length;
      for (final row in seite) {
        final Object? key = row[schluessel];
        // Only scalar keys enter the next filter.
        if (key == null || (key is! String && key is! int)) {
          throw FormatException('Invalid export cursor in $tabelle');
        }
        if (gesehen.add(key)) rows.add(row);
      }
      if (rows.length == vorher) {
        throw FormatException('Export paging of $tabelle made no progress');
      }
      if (erste && aufDemServer != null && rows.length >= aufDemServer) {
        return rows;
      }
      erste = false;
      nach = seite.last[schluessel];
    }
    // Fewer rows than the first page counted: rows were deleted while paging,
    // so the section is not proven to be the account's current set.
    if (aufDemServer != null && rows.length < aufDemServer) {
      ungeprueft.add(tabelle);
    }
    return rows;
  }

  /// The first page plus the server's row count, if it sent one.
  ///
  /// The count is `null` when the response carried no total `Content-Range`
  /// (proxy, older peer) — postgrest-dart throws while unpacking, and the
  /// export must not fail on that: the page is read again without a count,
  /// and paging to an empty page still proves completeness. A real error
  /// (500, RLS) throws again and ends up under `unvollstaendig`.
  Future<(List<Map<String, dynamic>>, int?)> _ersteSeite(
    String tabelle,
    String filterSpalte,
    String schluessel,
    int limit,
  ) async {
    try {
      final antwort =
          await _abfrage(tabelle, filterSpalte, schluessel, limit, null)
              .count(CountOption.exact)
              .retry(enabled: false);
      return (
        antwort.data.map((r) => Map<String, dynamic>.of(r)).toList(),
        antwort.count,
      );
    } catch (e, st) {
      // No answer means no missing count: a second request would only wait
      // for the same network failure.
      if (isNetworkSyncError(e)) rethrow;
      dev.log('DataExport: $tabelle ohne Server-Zaehler',
          error: e, stackTrace: st, name: 'data_export');
      final rows = await _seite(tabelle, filterSpalte, schluessel, limit, null);
      return (rows, null);
    }
  }

  Future<List<Map<String, dynamic>>> _seite(
    String tabelle,
    String filterSpalte,
    String schluessel,
    int limit,
    Object? nach,
  ) async {
    final rows = await _abfrage(tabelle, filterSpalte, schluessel, limit, nach)
        .retry(enabled: false);
    return rows.map((r) => Map<String, dynamic>.of(r)).toList();
  }

  PostgrestTransformBuilder<PostgrestList> _abfrage(
    String tabelle,
    String filterSpalte,
    String schluessel,
    int limit,
    Object? nach,
  ) {
    var query = _client.from(tabelle).select('*').eq(filterSpalte, _userId);
    // A plain `gt` filter takes the value verbatim; no filter grammar.
    if (nach != null) query = query.gt(schluessel, nach);
    return query.order(schluessel, ascending: true).limit(limit);
  }

  /// Seek after the last (logged_at, id), so deleting a previously read row
  /// cannot shift an unread meal past the next page. This is not a database
  /// snapshot: concurrent edits to a meal's timestamp can still move it.
  Future<List<Map<String, dynamic>>> _alleLoggedMeals() async {
    final rows = <Map<String, dynamic>>[];
    final gesehen = <Object?>{};
    ({DateTime at, String id})? cursor;
    while (true) {
      var query = _client
          .from('logged_meals')
          .select('*')
          .eq('user_id', _userId);
      if (cursor != null) {
        // Only canonical timestamps and UUIDs enter the filter grammar.
        final at = cursor.at.toIso8601String();
        query = query.or(
          'logged_at.lt.$at,and(logged_at.eq.$at,id.lt.${cursor.id})',
        );
      }
      final seite = await query
          .order('logged_at', ascending: false)
          .order('id', ascending: false)
          .limit(pageSize)
          .retry(enabled: false);
      if (seite.isEmpty) break;
      final vorher = rows.length;
      for (final row in seite) {
        final map = Map<String, dynamic>.of(row);
        if (gesehen.add(map['id'])) rows.add(map);
      }
      if (rows.length == vorher) {
        throw const FormatException('Diary pagination made no progress');
      }
      final id = seite.last['id'];
      final stamp = seite.last['logged_at'];
      final at = stamp is String ? DateTime.tryParse(stamp) : null;
      if (id is! String ||
          !RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
          ).hasMatch(id) ||
          at == null ||
          !at.isUtc) {
        throw const FormatException('Invalid diary cursor');
      }
      if (cursor != null &&
          !(at.isBefore(cursor.at) ||
              (at == cursor.at && id.compareTo(cursor.id) < 0))) {
        throw const FormatException('Diary cursor made no progress');
      }
      // A server-side row cap may be lower than pageSize. A short page does
      // not prove completion; continue after its final row until empty.
      cursor = (at: at, id: id);
    }
    return rows;
  }
}

/// How complete a finished export really is.
///
/// Not the same as "the fetch did not throw":
/// [DataExportService.buildExportJson] catches every section error and never
/// throws offline, so without this the sheet would claim completeness even
/// when no section arrived.
enum ExportUmfang {
  /// Every section present, nothing truncated.
  vollstaendig,

  /// At least one section missing, truncated or not proven complete.
  teilweise,

  /// Not a single section arrived.
  nichtsGeladen,
}

/// Reads the scope out of a finished export JSON.
///
/// `null` means "not an export of this format" — nothing can be said about
/// it, and guessing would repeat the very completeness claim this guards
/// against.
///
/// Deliberately a full `jsonDecode`, not a text search: a user value that
/// happens to look like a key would silently report the wrong thing. Called
/// once per export, not per frame.
ExportUmfang? exportUmfangAus(String json) {
  final auskunft = _alsAuskunft(json);
  if (auskunft == null) return null;

  final geladen =
      DataExportService.alleExportTabellen.where(auskunft.containsKey).length;
  if (geladen == 0) return ExportUmfang.nichtsGeladen;
  if (geladen < DataExportService.alleExportTabellen.length ||
      auskunft.containsKey('unvollstaendig') ||
      auskunft.containsKey('gekappt') ||
      auskunft.containsKey('vollstaendigkeitUnbekannt')) {
    return ExportUmfang.teilweise;
  }
  return ExportUmfang.vollstaendig;
}

/// Decodes [json] if it is a [DataExportService] export, else `null`. The
/// format tag is the gate: foreign JSON has no sections of these names and
/// would otherwise look like an empty export.
Map<String, dynamic>? _alsAuskunft(String json) {
  try {
    final wert = jsonDecode(json);
    if (wert is! Map<String, dynamic>) return null;
    if (wert['format'] != DataExportService.formatKennung) return null;
    return wert;
  } catch (_) {
    return null;
  }
}
