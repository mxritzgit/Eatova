import 'dart:convert';
import 'dart:developer' as dev;

import 'package:supabase/supabase.dart';

/// Builds the full GDPR Art. 15/20 data export from the server tables (the
/// authoritative copy), not from in-memory session state: every table with a
/// `*_select_own` policy via an RLS-filtered `select('*')`.
///
/// Each table gets its own try. An unreadable table must neither break the
/// export nor silently look empty — it is named under `unvollstaendig`. A
/// section cut at [einSeitenLimit] is listed separately under `gekappt`, so
/// the recipient does not mistake the cap for their whole data set.
/// Nonempty sections without a server count are explicitly unverified.
///
/// Because every section error is caught, [buildExportJson] never throws
/// offline; how much actually arrived is what [exportUmfangAus] reports.
class DataExportService {
  DataExportService(this._client, this._userId, {this.pageSize = 1000});

  final SupabaseClient _client;
  final String _userId;

  /// Page size of the `logged_meals` pagination; small in tests so the loop
  /// path is actually exercised.
  final int pageSize;

  /// One-page cap for all other tables; only the diary grows without bound
  /// and therefore paginates. If the cap is hit, the section lands in
  /// `gekappt`.
  static const int einSeitenLimit = 10000;

  /// Format tag in every export header; [exportUmfangAus] uses it to tell an
  /// export of this service apart from any other JSON.
  static const String formatKennung = 'eatova-export/1';

  /// `user_id`-filtered tables with a row-owned-by-user policy. `profiles`
  /// (key `id`) and `logged_meals` (paginated) run separately but are part of
  /// [alleExportTabellen].
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
  ];

  /// Every section a complete export must contain. The completeness test
  /// compares this against its own literal derived from supabase/migrations/,
  /// never adopting it as truth — otherwise it would never see table drift.
  static const List<String> alleExportTabellen = <String>[
    'profiles',
    'logged_meals',
    ...userIdTabellen,
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

    Future<void> sektion(
      String name,
      Future<List<Map<String, dynamic>>> Function() laden,
    ) async {
      try {
        export[name] = await laden();
      } catch (e, st) {
        // No silent empty section: it is missing and says so.
        unvollstaendig.add(name);
        dev.log('DataExport: $name nicht lesbar',
            error: e, stackTrace: st, name: 'data_export');
      }
    }

    await sektion(
      'profiles',
      () => _rows('profiles', keySpalte: 'id', gekappt: gekappt,
          ungeprueft: ungeprueft),
    );
    await sektion('logged_meals', _alleLoggedMeals);
    for (final tabelle in userIdTabellen) {
      await sektion(tabelle, () => _rows(tabelle, gekappt: gekappt,
          ungeprueft: ungeprueft));
    }

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
        'grenzeProSektion': einSeitenLimit,
        'sektionen': gekappt.keys.toList(),
        // [einSeitenLimit] is only our cap; PostgREST also cuts at
        // `db-max-rows`. Without the real row count the recipient would again
        // mistake a foreign cap for their data set.
        if (gezaehlt.isNotEmpty) 'zeilenAufDemServer': gezaehlt,
      };
    }
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  /// One section in a single go, detecting truncation from the server's own
  /// count rather than a guess about it.
  ///
  /// `Prefer: count=exact` makes the server count in the same request
  /// (`Content-Range`). If it counts more than arrived, something truncated —
  /// our cap or PostgREST's silent `db-max-rows`, which an over-fetch-by-one
  /// probe would miss entirely.
  Future<List<Map<String, dynamic>>> _rows(
    String tabelle, {
    required Map<String, int?> gekappt,
    required List<String> ungeprueft,
    String keySpalte = 'user_id',
  }) async {
    final (alle, aufDemServer) = await _seiteMitZaehler(tabelle, keySpalte);

    if (aufDemServer != null && aufDemServer > alle.length) {
      gekappt[tabelle] = aufDemServer;
      return alle;
    }
    // Fetch one row past the cap and trim it: without a count that is the
    // only way to tell "exactly [einSeitenLimit] rows" from "more behind".
    if (alle.length > einSeitenLimit) {
      gekappt[tabelle] = null;
      return alle.sublist(0, einSeitenLimit);
    }
    // A short nonempty response without a total may be a smaller server cap.
    // Preserve the data, but do not label unverified completeness as fact.
    if (aufDemServer == null && alle.isNotEmpty) ungeprueft.add(tabelle);
    return alle;
  }

  /// One page plus the server's row count, if it sent one.
  ///
  /// The count is `null` when the response carried no total `Content-Range`
  /// (proxy, older peer) — postgrest-dart throws while unpacking, and the
  /// export must not fail on that. The fallback over-fetches by one and so
  /// still catches our own cap; a real error (500, RLS) throws again and ends
  /// up under `unvollstaendig`.
  Future<(List<Map<String, dynamic>>, int?)> _seiteMitZaehler(
    String tabelle,
    String keySpalte,
  ) async {
    try {
      final antwort = await _client
          .from(tabelle)
          .select('*')
          .eq(keySpalte, _userId)
          .limit(einSeitenLimit)
          .count(CountOption.exact);
      return (
        antwort.data.map((r) => Map<String, dynamic>.of(r)).toList(),
        antwort.count,
      );
    } catch (e, st) {
      dev.log('DataExport: $tabelle ohne Server-Zaehler',
          error: e, stackTrace: st, name: 'data_export');
      final rows = await _client
          .from(tabelle)
          .select('*')
          .eq(keySpalte, _userId)
          .limit(einSeitenLimit + 1);
      return (rows.map((r) => Map<String, dynamic>.of(r)).toList(), null);
    }
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
          .limit(pageSize);
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
