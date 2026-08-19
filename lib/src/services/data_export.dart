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
///
/// Weil hier JEDER Sektionsfehler einzeln abgefangen wird, wirft
/// [buildExportJson] offline NIE — wer nur am ausbleibenden Fehler misst, haelt
/// deshalb auch eine Auskunft fuer vollstaendig, in der keine einzige Sektion
/// steht. Wie viel wirklich ankam, sagt [exportUmfangAus].
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

  /// Format-Kennung im Kopf jeder Auskunft. Steht als Konstante hier, weil
  /// [exportUmfangAus] daran erkennt, dass ein Text ueberhaupt eine Auskunft
  /// DIESES Services ist und nicht irgendein anderes JSON.
  static const String formatKennung = 'eatova-export/1';

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
      'format': formatKennung,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'userId': _userId,
    };
    final unvollstaendig = <String>[];
    // Sektion -> Zeilen, die der Server WIRKLICH fuer diesen Nutzer haelt.
    // `null`, wenn er nicht mitgezaehlt hat (siehe [_rows]).
    final gekappt = <String, int?>{};

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
      final gezaehlt = <String, int>{
        for (final eintrag in gekappt.entries)
          if (eintrag.value != null) eintrag.key: eintrag.value!,
      };
      export['gekappt'] = <String, dynamic>{
        'grenzeProSektion': einSeitenLimit,
        'sektionen': gekappt.keys.toList(),
        // [einSeitenLimit] ist nur UNSERE Grenze; PostgREST kappt zusaetzlich
        // bei `db-max-rows`. Ohne die echte Zeilenzahl haelt der Empfaenger
        // sonst wieder eine fremde Grenze fuer seinen Datenbestand — derselbe
        // Fehler, gegen den `gekappt` ueberhaupt eingefuehrt wurde.
        if (gezaehlt.isNotEmpty) 'zeilenAufDemServer': gezaehlt,
      };
    }
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  /// Eine Sektion in einem Rutsch — die Kappung erkannt am Zaehler des
  /// Servers, nicht an einer Vermutung ueber ihn.
  ///
  /// Bis 2026-08-19 forderte diese Methode EINE Zeile ueber der Grenze an und
  /// schloss aus „eine zuviel gekommen" auf eine Kappung. Das setzt voraus,
  /// dass der Server so viele Zeilen ueberhaupt herausgibt — PostgREST tut das
  /// nicht: bei gesetztem `db-max-rows` (Supabase-Default 1000) schneidet es
  /// STILL auf sein eigenes Maximum ab. Die Zeile, an der die Erkennung hing,
  /// kam dann nie an, der Hinweis blieb aus, und der Empfaenger hielt 1000
  /// Zeilen fuer seinen vollstaendigen Datenbestand.
  ///
  /// `Prefer: count=exact` laesst den Server im SELBEN Request mitzaehlen (die
  /// Zahl kommt als `Content-Range` zurueck). Zaehlt er mehr, als angekommen
  /// ist, wurde gekappt — unabhaengig davon, WER gekappt hat.
  Future<List<Map<String, dynamic>>> _rows(
    String tabelle, {
    required Map<String, int?> gekappt,
    String keySpalte = 'user_id',
  }) async {
    final (alle, aufDemServer) = await _seiteMitZaehler(tabelle, keySpalte);

    if (aufDemServer != null && aufDemServer > alle.length) {
      gekappt[tabelle] = aufDemServer;
      return alle;
    }
    // Eine Zeile ueber der Grenze mitholen und wieder abschneiden: nur so
    // laesst sich ohne Zaehler „genau [einSeitenLimit] Zeilen vorhanden" von
    // „es liegen mehr dahinter" unterscheiden. Ein falscher Kappungs-Hinweis
    // waere derselbe Fehler wie ein falsches `unvollstaendig`.
    if (alle.length > einSeitenLimit) {
      gekappt[tabelle] = null;
      return alle.sublist(0, einSeitenLimit);
    }
    return alle;
  }

  /// Eine Seite plus — wenn der Server ihn mitschickt — seinen Zeilen-Zaehler.
  ///
  /// Der Zaehler ist `null`, wenn die Antwort kein `Content-Range` mit
  /// Gesamtzahl trug (Proxy davor, aeltere Gegenstelle): postgrest-dart wirft
  /// dann beim Auspacken, und daran darf die Auskunft nicht scheitern. Der
  /// Rueckfall holt eine Zeile ueber der Grenze und erkennt damit wenigstens
  /// die SELBST gesetzte Kappung. Ein echter Fehler (500, RLS) wirft im
  /// zweiten Anlauf erneut und landet wie bisher unter `unvollstaendig`.
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

/// Wie vollstaendig eine fertige Auskunft WIRKLICH ist.
///
/// Nicht dasselbe wie „der Abruf hat nicht geworfen":
/// [DataExportService.buildExportJson] faengt jeden Sektionsfehler einzeln ab
/// und wirft offline nie. Ohne diese Unterscheidung meldet das Export-Sheet
/// eine vollstaendige Auskunft auch dann, wenn KEINE einzige Sektion ankam.
enum ExportUmfang {
  /// Jede Sektion da, nichts abgeschnitten.
  vollstaendig,

  /// Mindestens eine Sektion fehlt oder wurde gekappt.
  teilweise,

  /// Nicht eine einzige Sektion ist angekommen.
  nichtsGeladen,
}

/// Liest den Umfang aus dem fertigen Export-JSON.
///
/// `null` heisst „keine Auskunft dieses Formats" — Sitzungs-Auszug,
/// Rueckfall-Text, unvollstaendiges JSON. Darueber ist hier nichts zu sagen,
/// und Raten waere derselbe Fehler wie die Vollstaendigkeits-Behauptung, gegen
/// die diese Funktion antritt.
///
/// Bewusst ein voller `jsonDecode` und keine Textsuche: die Sektionsnamen
/// stehen ueber die ganze Datei verteilt, und eine Heuristik auf Rohtext haette
/// bei einem Nutzerwert, der zufaellig wie ein Schluessel aussieht, still das
/// Falsche gemeldet. Der Aufrufer ruft das genau EINMAL pro Auskunft auf, nicht
/// pro Frame.
ExportUmfang? exportUmfangAus(String json) {
  final auskunft = _alsAuskunft(json);
  if (auskunft == null) return null;

  final geladen =
      DataExportService.alleExportTabellen.where(auskunft.containsKey).length;
  if (geladen == 0) return ExportUmfang.nichtsGeladen;
  if (geladen < DataExportService.alleExportTabellen.length ||
      auskunft.containsKey('unvollstaendig') ||
      auskunft.containsKey('gekappt')) {
    return ExportUmfang.teilweise;
  }
  return ExportUmfang.vollstaendig;
}

/// Dekodiert [json], wenn es eine Auskunft aus [DataExportService] ist — sonst
/// `null`. Die Format-Kennung ist die Bedingung: ein fremdes JSON hat keine
/// Sektionen dieses Namens, saehe hier also wie eine leere Auskunft aus.
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
