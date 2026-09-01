// RLS GUARD (Befund P7-02, Review 2026-08-29).
//
// The app talks to Postgres DIRECTLY through PostgREST, so Row Level Security
// is the ONLY access control over user data — there is no backend layer that
// could catch a mistake. Until this file existed, nothing in CI could see an
// RLS regression: no job starts a Postgres, the drift job only compares the
// version NUMBERS in the file names against
// `supabase_migrations.schema_migrations`, and the three existing migration
// tests read one migration each for numeric limits. `grep -rn "row level
// security" test/` had zero hits.
//
// Concretely: turning `using (user_id = auth.uid())` in
// 20260516160000_app_data_schema.sql into `using (true)` left all 2816 tests
// and all seven required checks green, and the live drift job still reported
// "Keine Migration-Drift". That migrations get edited AFTER they were applied
// is not hypothetical — PR #51 rewrote the comments in every single one.
//
// WHAT THIS FILE IS. It replays the whole migration history (see
// migration_schema.dart) into the state it leaves behind and asserts the
// invariants of that state. It reads text, so it cannot prove PostgreSQL
// accepts the SQL — that is the job of the `rls-postgres` job in
// .github/workflows/security.yml, which applies the same migrations to a real
// Postgres and tries genuine cross-user access. This file is the fast half:
// it runs inside `flutter test`, i.e. inside the required check, on every PR.
//
// WHY THE LITERALS BELOW ARE HAND-WRITTEN. [_erwartet] (tables) and
// [_erwarteteFunktionen] (functions) are a second, independent source of
// truth, not derived from the migrations. Derived, the guard would be
// tautological: a new table without RLS, or a function freshly granted to
// `anon`, would define its own expectation and pass. The same pattern already
// carries test/profile_export_sheet_test.dart:40. Adding a table or a
// function therefore means adding it here, on purpose.
//
// WHY EVERY RULE IS A FUNCTION. Each invariant returns its violations as
// strings, so the "Wirksamkeit" group at the bottom can run the SAME rule
// against a deliberately broken schema and prove it still reports. A guard
// whose detection quietly stops working is no better than no guard.

import 'package:flutter_test/flutter_test.dart';

import 'migration_schema.dart';

// ---------------------------------------------------------------------------
// The expectation — hand-written, deliberately not derived
// ---------------------------------------------------------------------------

/// What one table in schema `public` is allowed to be.
class Erwartung {
  const Erwartung({
    required this.besitzerSpalte,
    required this.clientBefehle,
    required this.grund,
    this.spaltenRechte = const {},
  });

  /// Server-only table: no owner column, no policy, no client privilege.
  const Erwartung.nurServer({required this.grund})
      : besitzerSpalte = null,
        clientBefehle = const {},
        spaltenRechte = const {};

  /// The column carrying the row owner; every policy must compare it against
  /// `auth.uid()`.
  final String? besitzerSpalte;

  /// What `authenticated` may do directly via PostgREST. Everything not listed
  /// must have neither a policy nor a grant.
  final Set<String> clientBefehle;

  /// Column grants `authenticated` holds: privilege -> the EXACT column set.
  /// Empty means the table carries no column grant at all — anything else is a
  /// finding, and so is a single extra column in a listed privilege.
  final Map<String, Set<String>> spaltenRechte;

  final String grund;

  bool get nurServer => besitzerSpalte == null;
}

/// The `profiles` columns `ProfileSync.save` writes, from 20260819100000 plus
/// `manual_energy` (20260828100000). This list is the point of the whole
/// column-grant exercise: everything NOT in it — `email`, `display_name`,
/// `avatar_url`, `created_at`, `updated_at`,
/// `daily_kcal_goal_before_live_reset` — is set by a trigger, a default or the
/// server alone, and a client that could write it would be mass assignment.
const Set<String> _profilSchreibSpalten = {
  'id',
  'weight_kg',
  'height_cm',
  'age_years',
  'sex',
  'activity_level',
  'target_weight_kg',
  'daily_steps_goal',
  'daily_kcal_goal',
  'daily_water_goal_ml',
  'daily_sleep_goal_minutes',
  'protein_goal_g',
  'carbs_goal_g',
  'fat_goal_g',
  'weight_goal',
  'diet_preference',
  'onboarding_completed',
  'manual_energy',
};

const Set<String> _voll = {'select', 'insert', 'update', 'delete'};

/// The tables `supabase/migrations/` must leave behind — no more, no fewer.
const Map<String, Erwartung> _erwartet = {
  'profiles': Erwartung(
    besitzerSpalte: 'id',
    clientBefehle: {'select', 'insert', 'update'},
    spaltenRechte: {
      'insert': _profilSchreibSpalten,
      'update': _profilSchreibSpalten,
    },
    grund: 'Profil und Ziele; die App schreibt sie direkt. Besitzerspalte ist '
        'die PK `id` (= auth.users.id), nicht user_id. KEIN delete (P7-05, '
        'Review 2026-08-29): Kontoloeschen laeuft ueber rpc(delete_account) '
        'und den `on delete cascade` von auth.users; das ungenutzte Recht '
        'konnte nur die server-eigene Spalte '
        'daily_kcal_goal_before_live_reset unwiederbringlich vernichten.',
  ),
  'logged_meals': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: _voll,
    grund: 'Ernaehrungstagebuch — die zentrale Nutzerdatentabelle.',
  ),
  'favorite_meals': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: _voll,
    grund: 'Favoriten, vom Client gepflegt.',
  ),
  'weight_log': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: _voll,
    grund: 'Gewichtsverlauf, Gesundheitsdatum.',
  ),
  'user_recipes': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: _voll,
    grund: 'Eigene Rezepte, vom Client angelegt und geloescht.',
  ),
  'chat_sessions': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: _voll,
    grund: 'Coach-Unterhaltungen; Anlegen/Umbenennen/Loeschen laeuft ueber '
        'RPCs, die Policies decken den direkten Weg mit ab.',
  ),
  'lifetime_stats': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: {'select'},
    grund: 'Server-Wahrheit seit 20260811120000: geschrieben nur ueber die '
        'security-definer-RPCs, sonst koennte ein manipulierter Client seine '
        'Zaehler frei setzen.',
  ),
  'chat_messages': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: {'select'},
    grund: 'Server-Wahrheit: schreibbar nur ueber die Edge Function. Ein '
        'schreibbarer Verlauf waere ein faelschbarer Kontext fuer die naechste '
        'Coach-Anfrage.',
  ),
  'chat_quota_usage': Erwartung(
    besitzerSpalte: 'user_id',
    clientBefehle: {'select'},
    grund: 'Das Ratenlimit selbst — schreibbar hiesse zuruecksetzbar.',
  ),
  'edge_rate_limits': Erwartung.nurServer(
    grund: 'Kein user_id, nur ein SHA-256 des Subjekts; ausschliesslich die '
        'security-definer-RPC und service_role fassen sie an.',
  ),
  'lifetime_stats_requests': Erwartung.nurServer(
    grund: 'Idempotenz-Journal von increment_lifetime_stats; RLS an und '
        'BEWUSST ohne Policy — nur der Funktionseigentuemer schreibt.',
  ),
};

/// What one function in schema `public` is allowed to be.
///
/// P12-01/P12-02: until this list existed, the guard knew nothing about
/// function privileges. `grant execute on function public.refund_chat_quota
/// (uuid) to anon;` — the RPC that hands a paid coach slot BACK — replayed
/// green here AND passed the real-Postgres job, because
/// [regelFremdeRollen] only walks tables and [regelDefinerAuthUid] only ever
/// looks at `authenticated`. The same held for dropping `security definer`
/// from a function: nothing in this file read the flag except as a
/// precondition for the two rules below.
class FunktionsErwartung {
  /// Callable by the app: `authenticated` plus the Edge Functions.
  const FunktionsErwartung.client({required this.definer, required this.grund})
      : executeRollen = const {'authenticated', 'service_role'};

  /// Server only — Edge Functions, triggers and cron. `authenticated` must
  /// NOT be able to call it, `anon` never.
  const FunktionsErwartung.nurServer({
    required this.definer,
    required this.grund,
  }) : executeRollen = const {'service_role'};

  /// `security definer` runs the body with the OWNER's rights, i.e. past RLS.
  /// Pinned in both directions: losing it breaks the function (it then hits
  /// the caller's grants), gaining it hands a caller the owner's reach.
  final bool definer;

  /// Roles holding EXECUTE at the end of the history — exactly, no more.
  final Set<String> executeRollen;

  final String grund;
}

/// The functions `supabase/migrations/` must leave behind — no more, no
/// fewer. Hand-written for the same reason as [_erwartet]: derived from the
/// migrations, a newly granted role would define its own expectation.
const Map<String, FunktionsErwartung> _erwarteteFunktionen = {
  // -- callable by the app -------------------------------------------------
  'create_chat_session': FunktionsErwartung.client(
      definer: true, grund: 'Coach: neue Unterhaltung anlegen.'),
  'delete_account': FunktionsErwartung.client(
      definer: true,
      grund: 'Kontoloeschung; loescht aus auth.users, wozu der Aufrufer '
          'selbst kein Recht hat — genau dafuer ist sie definer.'),
  'delete_chat_session': FunktionsErwartung.client(
      definer: true, grund: 'Coach: Unterhaltung loeschen.'),
  'ensure_default_chat_session': FunktionsErwartung.client(
      definer: true, grund: 'Coach: Standard-Unterhaltung sicherstellen.'),
  'get_chat_quota_today': FunktionsErwartung.client(
      definer: true,
      grund: 'liest das eigene Tageskontingent — nur lesend, das Buchen '
          'macht claim_chat_quota auf dem Server.'),
  'increment_lifetime_stats': FunktionsErwartung.client(
      definer: true,
      grund: 'der einzige Schreibweg auf lifetime_stats; die Tabelle selbst '
          'ist fuer den Client nur lesbar.'),
  'list_chat_sessions': FunktionsErwartung.client(
      definer: true, grund: 'Coach: eigene Unterhaltungen auflisten.'),
  'record_tracking_day': FunktionsErwartung.client(
      definer: true, grund: 'Streak-Fortschreibung des eigenen Tages.'),
  'rename_chat_session': FunktionsErwartung.client(
      definer: true, grund: 'Coach: Unterhaltung umbenennen.'),

  // -- server only ---------------------------------------------------------
  'claim_chat_quota': FunktionsErwartung.nurServer(
      definer: true,
      grund: 'bucht einen der fuenf Gratis-Slots. Client-aufrufbar hiesse: '
          'fremde Kontingente verbrennen oder das eigene umgehen.'),
  'refund_chat_quota': FunktionsErwartung.nurServer(
      definer: true,
      grund: 'gibt einen gebuchten Slot zurueck — client-aufrufbar waeren die '
          'fuenf Anfragen pro Tag unbegrenzt.'),
  'consume_edge_rate_limit': FunktionsErwartung.nurServer(
      definer: true, grund: 'das Rate-Limit selbst.'),
  'consume_edge_rate_limits': FunktionsErwartung.nurServer(
      definer: true, grund: 'Stapelform desselben Rate-Limits.'),
  'prune_chat_quota_usage': FunktionsErwartung.nurServer(
      definer: true,
      grund: 'Aufbewahrung; client-aufrufbar waere sie ein Reset-Knopf fuer '
          'das Tageskontingent.'),
  'prune_edge_rate_limits': FunktionsErwartung.nurServer(
      definer: true, grund: 'Aufbewahrung des Rate-Limit-Journals.'),
  'enforce_user_row_cap': FunktionsErwartung.nurServer(
      definer: true,
      grund: 'Trigger-Rumpf der Zeilen-Obergrenzen (P7-03). EXECUTE wird nur '
          'beim CREATE TRIGGER geprueft, der Trigger feuert also ohne '
          'Client-Recht.'),
  'handle_new_user_profile': FunktionsErwartung.nurServer(
      definer: true, grund: 'Bootstrap-Trigger auf auth.users.'),
  'handle_new_user_stats': FunktionsErwartung.nurServer(
      definer: true, grund: 'Bootstrap-Trigger auf auth.users.'),
  'touch_chat_session': FunktionsErwartung.nurServer(
      definer: true, grund: 'Trigger auf chat_messages.'),
  'set_updated_at': FunktionsErwartung.nurServer(
      definer: false,
      grund: 'reiner updated_at-Trigger; definer waere hier unnoetige '
          'Reichweite.'),
  'rls_auto_enable': FunktionsErwartung.nurServer(
      definer: false,
      grund: 'Event-Trigger-Rumpf aus 20260814120000; laeuft als der '
          'Superuser, der den Event-Trigger anlegt.'),
};

/// Roles that may hold a privilege on a table at all. Anything else — `anon`,
/// `public`, a newly invented role — is a finding.
const Set<String> _erlaubteRollen = {'authenticated', 'service_role'};

/// Privileges no client role may ever hold: TRUNCATE ignores RLS completely,
/// TRIGGER and REFERENCES attach foreign code or constraints to the table.
const Set<String> _verboteneRechte = {'truncate', 'references', 'trigger'};

/// Expressions that let every row through.
const Set<String> _konstantWahr = {'true', '1=1', "'1'='1'", "'t'", 'not false'};

// ---------------------------------------------------------------------------
// The rules. Each returns its violations; empty means clean.
// ---------------------------------------------------------------------------

List<String> regelReplayVollstaendig(SchemaState s) => [
      for (final u in s.unverstanden)
        'Anweisung nicht verstanden, der Waechter ist an dieser Stelle BLIND: '
            '$u',
    ];

List<String> regelTabellenMenge(SchemaState s, Map<String, Erwartung> soll) {
  final ist = s.tabellen.keys.toSet();
  return [
    for (final t in (ist.difference(soll.keys.toSet()).toList()..sort()))
      'Tabelle `$t` steht in den Migrationen, aber in keiner Erwartung — '
          'ohne Eintrag prueft dieser Waechter sie nicht',
    for (final t in (soll.keys.toSet().difference(ist).toList()..sort()))
      'Tabelle `$t` wird erwartet, existiert nach den Migrationen aber nicht '
          '(mehr)',
  ];
}

List<String> regelRlsAktiv(SchemaState s) => [
      for (final name in (s.tabellen.keys.toList()..sort()))
        if (!s.tabellen[name]!.rlsAktiv)
          'Tabelle `$name` hat KEIN `enable row level security` — jede Zeile '
              'ist fuer jeden angemeldeten Nutzer sichtbar',
    ];

List<String> regelPolicyRollen(SchemaState s) => [
      for (final p in _sortiert(s))
        if (p.rollen.isEmpty)
          'Policy `${p.schluessel}` (${p.quelle}) nennt keine Rolle — in '
              'PostgreSQL heisst das `to public`, also auch `anon`'
        else if (p.rollen.toSet().difference({'authenticated'}).isNotEmpty)
          'Policy `${p.schluessel}` (${p.quelle}) gilt fuer '
              '${p.rollen.join(', ')}; erlaubt ist nur `authenticated`',
    ];

List<String> regelPolicyBedingungen(SchemaState s, Map<String, Erwartung> soll) {
  const wo = {'using': 'USING', 'check': 'WITH CHECK'};
  final funde = <String>[];
  for (final p in _sortiert(s)) {
    final erwartung = soll[p.tabelle];
    final ausdruecke = {'using': p.using, 'check': p.withCheck};
    ausdruecke.forEach((art, roh) {
      if (roh == null) return;
      final norm = normalisiereAusdruck(roh);
      if (_konstantWahr.contains(norm)) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): ${wo[art]} ist konstant '
          'wahr (`$roh`) — sie gibt JEDE Zeile der Tabelle frei',
        );
        return;
      }
      if (!norm.contains('auth.uid()')) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): ${wo[art]} `$roh` nennt '
          'auth.uid() nicht und bindet die Zeile damit an keinen Nutzer',
        );
        return;
      }
      if (erwartung?.besitzerSpalte == null) return;
      final ziel = besitzerBedingung(erwartung!.besitzerSpalte!);
      if (norm != ziel) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): ${wo[art]} `$roh` ist nicht '
          '`auth.uid() = ${erwartung.besitzerSpalte}`',
        );
      }
    });
  }
  return funde;
}

List<String> regelPolicyBefehle(SchemaState s, Map<String, Erwartung> soll) {
  final funde = <String>[];
  for (final name in (s.tabellen.keys.toList()..sort())) {
    final erwartung = soll[name];
    if (erwartung == null) continue; // regelTabellenMenge reports this
    final policies = s.policiesVon(name).toList();

    if (erwartung.nurServer) {
      for (final p in policies) {
        funde.add(
          'Server-Tabelle `$name` traegt die Policy `${p.name}` '
          '(${p.quelle}) — sie darf keine haben (${erwartung.grund})',
        );
      }
      continue;
    }

    final abgedeckt = policies.map((p) => p.befehl).toSet();
    for (final fehlt in erwartung.clientBefehle.difference(abgedeckt)) {
      if (abgedeckt.contains('all')) continue;
      funde.add(
        'Tabelle `$name`: erwartet wird eine `$fehlt`-Policy, es gibt keine — '
        'mit Grant, aber ohne Policy schlaegt jeder $fehlt fehl',
      );
    }
    for (final zuviel in abgedeckt.difference(erwartung.clientBefehle)) {
      funde.add(
        'Tabelle `$name`: Policy fuer `$zuviel`, obwohl der Client dort nur '
        '${erwartung.clientBefehle.join('/')} darf (${erwartung.grund})',
      );
    }

    // WITH CHECK is what stops a user WRITING a row onto someone else. USING
    // alone only limits which rows are visible/targetable.
    for (final p in policies) {
      final schreibt = p.befehl == 'insert' || p.befehl == 'update' ||
          p.befehl == 'all';
      final liest = p.befehl == 'select' || p.befehl == 'delete' ||
          p.befehl == 'update' || p.befehl == 'all';
      if (schreibt && p.withCheck == null) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}) ist eine ${p.befehl}-Policy '
          'ohne `with check` — ohne sie darf der Nutzer eine Zeile auf eine '
          'FREMDE user_id schreiben',
        );
      }
      if (liest && p.using == null) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}) ist eine ${p.befehl}-Policy '
          'ohne `using`',
        );
      }
      if (p.befehl == 'insert' && p.using != null) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): eine INSERT-Policy hat kein '
          'USING — PostgreSQL weist das zurueck',
        );
      }
      if ((p.befehl == 'select' || p.befehl == 'delete') &&
          p.withCheck != null) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): ${p.befehl} kennt kein '
          '`with check`',
        );
      }
      if (p.befehl == 'update' &&
          p.using != null &&
          p.withCheck != null &&
          normalisiereAusdruck(p.using!) !=
              normalisiereAusdruck(p.withCheck!)) {
        funde.add(
          'Policy `${p.schluessel}` (${p.quelle}): USING und WITH CHECK sind '
          'verschieden (`${p.using}` vs `${p.withCheck}`) — die Zeile liesse '
          'sich aus dem eigenen Besitz heraus verschieben',
        );
      }
    }
  }
  return funde;
}

List<String> regelClientRechte(SchemaState s, Map<String, Erwartung> soll) {
  final funde = <String>[];
  for (final name in (s.tabellen.keys.toList()..sort())) {
    final erwartung = soll[name];
    if (erwartung == null) continue;
    final t = s.tabellen[name]!;
    final ist = t.alleRechte('authenticated');
    final crud = ist.intersection(kCrud);
    if (crud.difference(erwartung.clientBefehle).isNotEmpty) {
      funde.add(
        'Tabelle `$name`: `authenticated` hat '
        '${(crud.toList()..sort()).join('/')}, erlaubt ist '
        '${erwartung.clientBefehle.isEmpty ? 'nichts' : (erwartung.clientBefehle.toList()..sort()).join('/')} '
        '(${erwartung.grund})',
      );
    }
    if (erwartung.clientBefehle.difference(crud).isNotEmpty) {
      funde.add(
        'Tabelle `$name`: `authenticated` fehlt '
        '${(erwartung.clientBefehle.difference(crud).toList()..sort()).join('/')} '
        '— ohne Grant scheitert der Zugriff mit 42501, ganz gleich welche '
        'Policy daneben steht',
      );
    }
    final verboten = ist.intersection(_verboteneRechte);
    if (verboten.isNotEmpty) {
      funde.add(
        'Tabelle `$name`: `authenticated` haelt '
        '${(verboten.toList()..sort()).join('/')} — TRUNCATE umgeht RLS '
        'vollstaendig, TRIGGER/REFERENCES haengen fremden Code an die Tabelle',
      );
    }
  }
  return funde;
}

/// P7-02b: [regelClientRechte] only ever compared privilege NAMES, so
/// `grant update (email, display_name) on public.profiles to authenticated` —
/// mass assignment, the exact class 20260819100000 was written to close — went
/// through green: `update` was expected, and which COLUMNS it covered was
/// never looked at. This rule compares the column sets themselves.
List<String> regelSpaltenRechte(SchemaState s, Map<String, Erwartung> soll) {
  final funde = <String>[];
  for (final name in (s.tabellen.keys.toList()..sort())) {
    final erwartung = soll[name];
    if (erwartung == null) continue; // regelTabellenMenge reports this
    final ist = s.tabellen[name]!.spaltenRechte['authenticated'] ??
        const <String, Set<String>>{};
    final privs = <String>{...ist.keys, ...erwartung.spaltenRechte.keys}
        .toList()
      ..sort();
    for (final priv in privs) {
      final istSpalten = ist[priv] ?? const <String>{};
      final sollSpalten = erwartung.spaltenRechte[priv] ?? const <String>{};
      final zuviel = istSpalten.difference(sollSpalten).toList()..sort();
      final fehlt = sollSpalten.difference(istSpalten).toList()..sort();
      if (zuviel.isNotEmpty) {
        funde.add(
          'Tabelle `$name`: `authenticated` darf `$priv` auf '
          '${zuviel.join(', ')} — diese Spalte(n) stehen in keiner Erwartung. '
          'Genau so sieht Mass Assignment aus: die Rolle schreibt ein Feld, '
          'das die App nie schreibt (${erwartung.grund})',
        );
      }
      if (fehlt.isNotEmpty) {
        funde.add(
          'Tabelle `$name`: `authenticated` fehlt `$priv` auf '
          '${fehlt.join(', ')} — ohne Spalten-Grant scheitert der Upsert der '
          'App mit 42501',
        );
      }
    }
  }
  return funde;
}

/// P7-07: exactly one of the 35 migrations opened its own transaction
/// (20260803120000). Supabase already runs each file in one, so the inner
/// `commit;` ENDS the outer one — everything after it would run
/// unprotected, and a failure could no longer roll the file back. Harmless
/// there because nothing follows the commit, but it must not come back.
List<String> regelKeineTransaktionsklammer(Map<String, String> quellen) {
  const klammern = {
    'begin',
    'start transaction',
    'commit',
    'end',
    'rollback',
  };
  final funde = <String>[];
  for (final datei in (quellen.keys.toList()..sort())) {
    if (kTransaktionsklammerErlaubt.containsKey(datei)) continue;
    for (final stmt in zerlegeSql(quellen[datei]!)) {
      final l = stmt.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
      if (klammern.contains(l) || l.startsWith('savepoint ')) {
        funde.add(
          '$datei: `$l;` — eine Migration laeuft bereits in der Transaktion '
          'des Migrationslaufs. Ein eigenes `commit` beendet DIESE, sodass '
          'alles danach ungeschuetzt laeuft und der Lauf die Datei nicht mehr '
          'zuruecknehmen kann.',
        );
      }
    }
  }
  return funde;
}

/// Migrations that may carry their own transaction, with the reason. Grows
/// only for a documented, historical case — new migrations must not appear.
const Map<String, String> kTransaktionsklammerErlaubt = {
  '20260803120000_drop_removed_feature_tables.sql':
      'historical (P7-07, review 2026-08-29): applied and registered long ago, '
          'and nothing follows its `commit;`, so the damage is in the past. '
          'Migrations are immutable once applied, so the file stays as it is.',
};

List<String> regelFremdeRollen(SchemaState s) {
  final funde = <String>[];
  for (final name in (s.tabellen.keys.toList()..sort())) {
    final t = s.tabellen[name]!;
    final rollen = {...t.rechte.keys, ...t.spaltenRechte.keys}
      ..removeWhere((r) => t.alleRechte(r).isEmpty);
    for (final rolle in (rollen.difference(_erlaubteRollen).toList()..sort())) {
      funde.add(
        'Tabelle `$name`: Rolle `$rolle` haelt '
        '${(t.alleRechte(rolle).toList()..sort()).join('/')} — `anon` ist der '
        'unangemeldete Besucher, jede Zeile hier ist oeffentlich',
      );
    }
  }
  return funde;
}

List<String> regelDefinerSearchPath(SchemaState s) => [
      for (final name in (s.funktionen.keys.toList()..sort()))
        if (s.funktionen[name]!.securityDefiner &&
            s.funktionen[name]!.searchPath == null)
          'Funktion `public.$name` (${s.funktionen[name]!.quelle}) ist '
              '`security definer` ohne gepinnten `search_path` — ein Aufrufer '
              'kann eine eigene Tabelle voranstellen und den Rumpf mit '
              'Eigentuemerrechten auf sie umlenken',
    ];

List<String> regelDefinerAuthUid(SchemaState s) => [
      for (final name in (s.funktionen.keys.toList()..sort()))
        if (s.funktionen[name]!.securityDefiner &&
            s.funktionen[name]!.executeRollen.contains('authenticated') &&
            !s.funktionen[name]!.rumpf.contains('auth.uid()'))
          'Funktion `public.$name` (${s.funktionen[name]!.quelle}) ist '
              '`security definer`, fuer `authenticated` ausfuehrbar und nennt '
              'auth.uid() nie — sie laeuft mit Eigentuemerrechten an RLS '
              'vorbei, ohne den Aufrufer an seine Zeilen zu binden',
    ];

/// P12-01: the function counterpart of [regelTabellenMenge]. A function
/// nobody entered here is a function whose EXECUTE grants nobody checks.
List<String> regelFunktionsMenge(
  SchemaState s,
  Map<String, FunktionsErwartung> soll,
) {
  final ist = s.funktionen.keys.toSet();
  return [
    for (final f in (ist.difference(soll.keys.toSet()).toList()..sort()))
      'Funktion `public.$f` steht in den Migrationen, aber in keiner '
          'Erwartung — ohne Eintrag prueft niemand, WER sie aufrufen darf',
    for (final f in (soll.keys.toSet().difference(ist).toList()..sort()))
      'Funktion `public.$f` wird erwartet, existiert nach den Migrationen '
          'aber nicht (mehr)',
  ];
}

/// P12-01/P12-02: who may EXECUTE, and whether the function is `security
/// definer`. Both are set comparisons, so a grant to `anon` and a lost
/// `definer` are findings in the same place.
List<String> regelFunktionsRechte(
  SchemaState s,
  Map<String, FunktionsErwartung> soll,
) {
  final funde = <String>[];
  for (final name in (s.funktionen.keys.toList()..sort())) {
    final erwartung = soll[name];
    if (erwartung == null) continue; // regelFunktionsMenge reports this
    final f = s.funktionen[name]!;
    final ist = f.executeRollen;
    final zuviel = (ist.difference(erwartung.executeRollen).toList()..sort());
    final fehlt = (erwartung.executeRollen.difference(ist).toList()..sort());
    if (zuviel.isNotEmpty) {
      funde.add(
        'Funktion `public.$name` (${f.quelle}): ${zuviel.join('/')} darf sie '
        'ausfuehren, erlaubt ist nur '
        '${(erwartung.executeRollen.toList()..sort()).join('/')} '
        '(${erwartung.grund})',
      );
    }
    if (fehlt.isNotEmpty) {
      funde.add(
        'Funktion `public.$name` (${f.quelle}): ${fehlt.join('/')} fehlt das '
        'EXECUTE — der Aufruf scheitert mit 42501',
      );
    }
    if (f.securityDefiner != erwartung.definer) {
      funde.add(
        'Funktion `public.$name` (${f.quelle}) ist '
        '${f.securityDefiner ? '' : 'NICHT '}`security definer`, erwartet ist '
        '${erwartung.definer ? '' : 'KEIN '}definer — ohne das Schluesselwort '
        'laeuft der Rumpf mit den Rechten des AUFRUFERS und faellt an den '
        'Tabellen-Grants um; mit ihm reicht ein Aufrufer an RLS vorbei '
        '(${erwartung.grund})',
      );
    }
  }
  return funde;
}

List<PolicyState> _sortiert(SchemaState s) =>
    s.policies.values.toList()..sort((a, b) => a.schluessel.compareTo(b.schluessel));

// ---------------------------------------------------------------------------

void main() {
  late SchemaState schema;
  late Map<String, String> quellen;

  setUpAll(() {
    quellen = leseMigrationsQuellen();
    schema = schemaAusQuellen(quellen);
  });

  group('Der Waechter sieht die ganze Historie', () {
    test('alle Migrationen werden eingelesen', () {
      // What this floor really guards is the RESOLUTION: a wrong working
      // directory or a broken filter leaves the replay with (almost) nothing
      // and every rule below trivially green. It is NOT the guard against a
      // deleted migration — the floor sits below the current count on
      // purpose, and schema_state_doc_test.dart owns that mutation: the
      // generated document lists every file by name (T12, measured).
      expect(
        schema.dateien.length,
        greaterThanOrEqualTo(36),
        reason: 'supabase/migrations/ wurde nicht (vollstaendig) gefunden — '
            'aufgeloest von ${Uri.base.toFilePath()}',
      );
    });

    test('jede Anweisung wurde verstanden', () {
      expect(
        regelReplayVollstaendig(schema),
        isEmpty,
        reason: 'Ein Waechter, der eine Anweisung still ueberspringt, ist an '
            'genau dieser Stelle wieder blind. Entweder die Anweisung '
            'gehoert nicht in eine Migration, oder migration_schema.dart '
            'muss sie kennen lernen.',
      );
    });

    test('die Tabellenmenge deckt sich mit der Erwartung', () {
      expect(
        regelTabellenMenge(schema, _erwartet),
        isEmpty,
        reason: 'Die Liste _erwartet ist die zweite, unabhaengige Wahrheit. '
            'Eine neue Tabelle MUSS hier eingetragen werden — sonst prueft '
            'niemand, ob sie RLS hat.',
      );
    });
  });

  group('Row Level Security', () {
    test('jede Tabelle hat RLS aktiviert', () {
      expect(regelRlsAktiv(schema), isEmpty);
    });

    test('jede Policy nennt ausdruecklich `authenticated`', () {
      expect(
        regelPolicyRollen(schema),
        isEmpty,
        reason: 'Eine Policy ohne `to` gilt in PostgreSQL fuer PUBLIC und '
            'damit auch fuer `anon`.',
      );
    });

    test('jede Policy bindet die Zeile an auth.uid()', () {
      expect(
        regelPolicyBedingungen(schema, _erwartet),
        isEmpty,
        reason: 'Das ist der Kern: `using (true)` statt '
            '`using (user_id = auth.uid())` gibt die Tabelle jedem '
            'angemeldeten Nutzer frei.',
      );
    });

    test('Befehle, `using` und `with check` sind vollstaendig', () {
      expect(
        regelPolicyBefehle(schema, _erwartet),
        isEmpty,
        reason: 'Ohne `with check` darf ein Nutzer eine Zeile auf eine fremde '
            'user_id schreiben, auch wenn er sie nicht lesen kann.',
      );
    });
  });

  group('Tabellenrechte', () {
    test('`authenticated` hat genau die Rechte, die die Policies decken', () {
      expect(regelClientRechte(schema, _erwartet), isEmpty);
    });

    test('keine andere Rolle als authenticated/service_role hat ein Recht', () {
      expect(
        regelFremdeRollen(schema),
        isEmpty,
        reason: 'PostgreSQL prueft Rechte VOR RLS. Ein Recht fuer `anon` '
            'macht die Tabelle unabhaengig von jeder Policy erreichbar.',
      );
    });

    test('die Spalten-Grants decken genau die Spalten der Erwartung', () {
      expect(
        regelSpaltenRechte(schema, _erwartet),
        isEmpty,
        reason: 'Ein Spalten-Grant ist die zweite Haelfte des Mass-Assignment-'
            'Schutzes: `update` allein sagt nichts darueber, WELCHE Spalte '
            'der Client schreiben darf.',
      );
    });
  });

  group('Migrationshygiene', () {
    test('keine Migration klammert sich in eine eigene Transaktion', () {
      expect(
        regelKeineTransaktionsklammer(quellen),
        isEmpty,
        reason: 'Der Migrationslauf haelt bereits eine Transaktion; ein '
            'eigenes `commit;` beendet sie mitten in der Datei.',
      );
    });

    test('die Ausnahmelisten ueberleben ihre Dateien nicht', () {
      // An allowlist entry for a file that is gone would silently widen the
      // rule for a name someone could reuse; a mistyped label would waive
      // nothing and hide that fact.
      for (final datei in [
        ...kTransaktionsklammerErlaubt.keys,
        ...kDoAusnahmen.keys,
      ]) {
        expect(quellen.containsKey(datei), isTrue, reason: datei);
      }
      for (final eintrag in kDoAusnahmen.entries) {
        for (final label in eintrag.value.keys) {
          expect(kDoPruefungen.keys, contains(label), reason: eintrag.key);
        }
      }
    });
  });

  group('security definer', () {
    test('die Funktionsmenge deckt sich mit der Erwartung', () {
      expect(
        regelFunktionsMenge(schema, _erwarteteFunktionen),
        isEmpty,
        reason: 'Eine neue Funktion MUSS hier eingetragen werden — sonst '
            'prueft niemand, wer sie ausfuehren darf.',
      );
    });

    test('jede Funktion hat genau die EXECUTE-Rechte der Erwartung', () {
      expect(
        regelFunktionsRechte(schema, _erwarteteFunktionen),
        isEmpty,
        reason: 'PostgreSQL vergibt EXECUTE, nicht RLS. Ein `grant execute … '
            'to anon` auf einer definer-Funktion ist ein Weg an jeder Policy '
            'vorbei, und ein verlorenes `security definer` laesst den Rumpf '
            'an den Grants des Aufrufers scheitern.',
      );
    });

    test('jede definer-Funktion pinnt den search_path', () {
      expect(regelDefinerSearchPath(schema), isEmpty);
    });

    test('jede fuer `authenticated` freigegebene definer-Funktion nennt '
        'auth.uid()', () {
      expect(regelDefinerAuthUid(schema), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Wirksamkeit: dieselben Regeln gegen ein absichtlich kaputtes Schema.
  //
  // Ohne diese Gruppe waere nur bewiesen, dass die Regeln heute nichts finden
  // — was auch eine Regel schafft, die gar nichts prueft.
  // -------------------------------------------------------------------------
  group('Wirksamkeit — dieselben Regeln gegen ein kaputtes Schema', () {
    const gesund = '''
create table if not exists public.notizen (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  text text not null
);
alter table public.notizen enable row level security;
create policy "notizen_select_own"
  on public.notizen for select to authenticated
  using (user_id = auth.uid());
create policy "notizen_insert_own"
  on public.notizen for insert to authenticated
  with check (user_id = auth.uid());
create policy "notizen_update_own"
  on public.notizen for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "notizen_delete_own"
  on public.notizen for delete to authenticated
  using (user_id = auth.uid());
grant select, insert, update, delete on public.notizen to authenticated;
''';

    const soll = {
      'notizen': Erwartung(
        besitzerSpalte: 'user_id',
        clientBefehle: _voll,
        grund: 'Testtabelle',
      ),
    };

    SchemaState bau(String sql) => schemaAusQuellen({'00_test.sql': sql});

    test('der gesunde Ausgangsfall ist sauber', () {
      final s = bau(gesund);
      expect(regelReplayVollstaendig(s), isEmpty);
      expect(regelTabellenMenge(s, soll), isEmpty);
      expect(regelRlsAktiv(s), isEmpty);
      expect(regelPolicyRollen(s), isEmpty);
      expect(regelPolicyBedingungen(s, soll), isEmpty);
      expect(regelPolicyBefehle(s, soll), isEmpty);
      expect(regelClientRechte(s, soll), isEmpty);
      expect(regelFremdeRollen(s), isEmpty);
    });

    test('`using (true)` statt der Besitzerbedingung faellt auf', () {
      final s = bau(
        gesund.replaceFirst(
          'for select to authenticated\n  using (user_id = auth.uid())',
          'for select to authenticated\n  using (true)',
        ),
      );
      expect(
        regelPolicyBedingungen(s, soll),
        contains(contains('konstant wahr')),
      );
    });

    test('eine spaetere Migration, die die Policy aufweicht, faellt auf', () {
      // The real risk: the create looks right, a LATER file replaces it.
      final s = schemaAusQuellen({
        '00_test.sql': gesund,
        '01_regression.sql': '''
drop policy if exists "notizen_select_own" on public.notizen;
create policy "notizen_select_own"
  on public.notizen for select to authenticated
  using (user_id is not null);
''',
      });
      expect(
        regelPolicyBedingungen(s, soll),
        contains(contains('nennt auth.uid() nicht')),
      );
    });

    test('ein fehlendes `with check` an der UPDATE-Policy faellt auf', () {
      final s = bau(
        gesund.replaceFirst(
          'using (user_id = auth.uid()) with check (user_id = auth.uid())',
          'using (user_id = auth.uid())',
        ),
      );
      expect(
        regelPolicyBefehle(s, soll),
        contains(contains('ohne `with check`')),
      );
    });

    test('ein aufgeweichtes `with check` neben strengem `using` faellt auf',
        () {
      final s = bau(
        gesund.replaceFirst(
          'using (user_id = auth.uid()) with check (user_id = auth.uid())',
          'using (user_id = auth.uid()) with check (auth.uid() is not null)',
        ),
      );
      expect(regelPolicyBedingungen(s, soll), isNotEmpty);
      expect(
        regelPolicyBefehle(s, soll),
        contains(contains('USING und WITH CHECK sind verschieden')),
      );
    });

    test('eine Policy ohne Rollenangabe faellt auf', () {
      final s = bau(
        gesund.replaceAll(' for select to authenticated', ' for select'),
      );
      expect(regelPolicyRollen(s), contains(contains('nennt keine Rolle')));
    });

    test('eine Policy fuer `anon` faellt auf', () {
      final s = bau(gesund.replaceAll('to authenticated', 'to anon'));
      expect(regelPolicyRollen(s), contains(contains('anon')));
    });

    test('ein fehlendes `enable row level security` faellt auf', () {
      final s = bau(
        gesund.replaceFirst(
          'alter table public.notizen enable row level security;',
          '',
        ),
      );
      expect(regelRlsAktiv(s), contains(contains('KEIN `enable row')));
    });

    test('ein spaeteres `disable row level security` faellt auf', () {
      final s = schemaAusQuellen({
        '00_test.sql': gesund,
        '01_regression.sql':
            'alter table public.notizen disable row level security;',
      });
      expect(regelRlsAktiv(s), isNotEmpty);
    });

    test('eine neue Tabelle ohne Eintrag in der Erwartung faellt auf', () {
      final s = bau('$gesund\ncreate table public.geheim (id uuid);');
      expect(
        regelTabellenMenge(s, soll),
        contains(contains('in keiner Erwartung')),
      );
    });

    test('ein Recht fuer `anon` faellt auf', () {
      final s = bau('${gesund}grant select on public.notizen to anon;');
      expect(regelFremdeRollen(s), contains(contains('anon')));
    });

    test('ein Schreibrecht ohne Policy-Deckung faellt auf', () {
      const nurLesen = {
        'notizen': Erwartung(
          besitzerSpalte: 'user_id',
          clientBefehle: {'select'},
          grund: 'Testtabelle, nur lesbar',
        ),
      };
      final s = bau(gesund);
      expect(regelClientRechte(s, nurLesen), isNotEmpty);
      expect(regelPolicyBefehle(s, nurLesen), isNotEmpty);
    });

    test('TRUNCATE fuer `authenticated` faellt auf', () {
      final s = bau('${gesund}grant truncate on public.notizen to authenticated;');
      expect(regelClientRechte(s, soll), contains(contains('TRUNCATE')));
    });

    // -----------------------------------------------------------------------
    // P12-01/P12-02: EXECUTE-Rechte und das definer-Schluesselwort.
    //
    // Beide Mutationen liefen vor dieser Gruppe GRUEN durch — und zwar
    // durch BEIDE Waechter, denn rls_cross_user.sql probiert `anon` nur an
    // Tabellen und kennt refund_chat_quota gar nicht.
    // -----------------------------------------------------------------------
    group('EXECUTE-Rechte und `security definer`', () {
      /// One server-only definer RPC, as the migrations shape them.
      const nurServer = '''
create or replace function public.geheim(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as \$\$
begin
  perform 1;
end;
\$\$;
revoke all on function public.geheim(uuid) from public, anon, authenticated;
grant execute on function public.geheim(uuid) to service_role;
''';

      const soll = {
        'geheim': FunktionsErwartung.nurServer(
          definer: true,
          grund: 'Testfunktion, nur der Server ruft sie',
        ),
      };

      test('der gesunde Ausgangsfall ist sauber', () {
        final s = bau(nurServer);
        expect(regelFunktionsMenge(s, soll), isEmpty);
        expect(regelFunktionsRechte(s, soll), isEmpty);
      });

      test('ein EXECUTE fuer `anon` faellt auf', () {
        final s = schemaAusQuellen({
          '00_test.sql': nurServer,
          '01_sabotage.sql':
              'grant execute on function public.geheim(uuid) to anon;',
        });
        expect(
          regelFunktionsRechte(s, soll),
          contains(contains('anon')),
          reason: 'regelFremdeRollen laeuft nur ueber TABELLEN — an einer '
              'Funktion hat sie nie hingesehen',
        );
        expect(regelFremdeRollen(s), isEmpty,
            reason: 'belegt genau das: die alte Regel bleibt hier gruen');
      });

      test('ein EXECUTE fuer `authenticated` faellt auf', () {
        final s = schemaAusQuellen({
          '00_test.sql': nurServer,
          '01_sabotage.sql': 'grant execute on function public.geheim(uuid) '
              'to authenticated;',
        });
        expect(
          regelFunktionsRechte(s, soll),
          contains(contains('authenticated')),
        );
      });

      test('ein verlorenes `security definer` faellt auf', () {
        final s = bau(nurServer.replaceFirst('security definer\n', ''));
        expect(
          regelFunktionsRechte(s, soll),
          contains(contains('NICHT `security definer`')),
        );
      });

      test('ein NEU vergebenes `security definer` faellt ebenso auf', () {
        const trigger = '''
create or replace function public.harmlos()
returns trigger
language plpgsql
security definer
set search_path = public
as \$\$
begin
  return new;
end;
\$\$;
grant execute on function public.harmlos() to service_role;
''';
        final s = bau(trigger);
        expect(
          regelFunktionsRechte(s, {
            'harmlos': const FunktionsErwartung.nurServer(
              definer: false,
              grund: 'reiner Trigger, braucht keine Eigentuemerrechte',
            ),
          }),
          contains(contains('erwartet ist KEIN definer')),
        );
      });

      test('eine neue Funktion ohne Eintrag in der Erwartung faellt auf', () {
        final s = bau(nurServer);
        expect(
          regelFunktionsMenge(s, const <String, FunktionsErwartung>{}),
          contains(contains('in keiner Erwartung')),
        );
      });

      test('ein `auth.uid()` NUR im Kommentar zaehlt nicht', () {
        // The trap that made regelDefinerAuthUid green on a server RPC handed
        // to `authenticated`: the body only MENTIONED auth.uid() in prose.
        final s = bau('''
create or replace function public.getarnt(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as \$\$
begin
  -- historisch: hier stand einmal auth.uid()
  perform 1;
end;
\$\$;
grant execute on function public.getarnt(uuid) to authenticated;
''');
        expect(
          regelDefinerAuthUid(s),
          contains(contains('getarnt')),
          reason: 'der Rumpf nennt auth.uid() nur in einem Kommentar',
        );
      });

      test('ein echtes `auth.uid()` im Rumpf loest NICHT aus', () {
        final s = bau('''
create or replace function public.eigen()
returns void
language plpgsql
security definer
set search_path = public
as \$\$
begin
  perform 1 from public.n where user_id = auth.uid();
end;
\$\$;
grant execute on function public.eigen() to authenticated;
''');
        expect(regelDefinerAuthUid(s), isEmpty);
      });
    });

    test('eine definer-Funktion ohne search_path faellt auf', () {
      final s = bau('''
create or replace function public.leck()
returns void
language plpgsql
security definer
as \$\$
begin
  perform 1;
end;
\$\$;
''');
      expect(regelDefinerSearchPath(s), contains(contains('leck')));
    });

    test('eine unbekannte Anweisung macht den Waechter NICHT still', () {
      final s = bau('alter policy "notizen_select_own" on public.notizen '
          'using (true);');
      expect(regelReplayVollstaendig(s), isNotEmpty);
    });

    // -----------------------------------------------------------------------
    // P7-02b, Luecke 1: der DO-Block. `'do '` stand in _harmlos, also lief
    // GENAU diese Migration bis 2026-08-29 gruen durch.
    // -----------------------------------------------------------------------
    group('DO-Bloecke sind kein blinder Fleck mehr', () {
      test('eine Policy aus einem DO-Block heraus faellt auf', () {
        final s = schemaAusQuellen({
          '00_test.sql': gesund,
          '01_sabotage.sql': r'''
do $$
begin
  execute 'create policy "notizen_alle" on public.notizen for select '
       || 'to authenticated using (true)';
end $$;
''',
        });
        expect(
          regelReplayVollstaendig(s),
          contains(contains('DO-Block enthaelt `POLICY`')),
        );
      });

      test('ein Grant an `anon` aus einem DO-Block heraus faellt auf', () {
        final s = schemaAusQuellen({
          '00_test.sql': gesund,
          '01_sabotage.sql': r'''
do $$
begin
  execute 'grant select on public.notizen to anon';
end $$;
''',
        });
        expect(
          regelReplayVollstaendig(s),
          contains(contains('GRANT/REVOKE')),
        );
      });

      test('dynamisches SQL im DO-Block faellt auch ohne Stichwort auf', () {
        // The evasion the keyword scan alone cannot see: the text is only
        // assembled at runtime.
        final s = bau(r'''
do $$
begin
  execute 'gr' || 'ant select on public.notizen to anon';
end $$;
''');
        expect(
          regelReplayVollstaendig(s),
          contains(contains('dynamisches SQL')),
        );
      });

      test('die Bestandsform — Constraint-Probe ohne Dynamik — bleibt gruen',
          () {
        final s = bau('''
$gesund
do \$\$
begin
  if not exists (select 1 from pg_constraint where conname = 'notizen_len') then
    alter table public.notizen add constraint notizen_len
      check (char_length(text) <= 500);
  end if;
end \$\$;
''');
        expect(regelReplayVollstaendig(s), isEmpty);
      });

      test('ein erklaerender Kommentar im DO-Block loest nicht aus', () {
        // Same trap as everywhere else: the block explains itself in prose.
        final s = bau(r'''
do $$
begin
  -- grant select on public.notizen to anon  (frueher, heute verboten)
  perform 1;
end $$;
''');
        expect(regelReplayVollstaendig(s), isEmpty);
      });
    });

    // -----------------------------------------------------------------------
    // P7-02b, Luecke 2: Spalten-Grants wurden nur nach Privilegienname
    // verglichen — die Mass-Assignment-Klasse lief gruen durch.
    // -----------------------------------------------------------------------
    group('Spalten-Grants werden wirklich verglichen', () {
      const spaltenSoll = {
        'notizen': Erwartung(
          besitzerSpalte: 'user_id',
          clientBefehle: _voll,
          spaltenRechte: {
            'update': {'text'},
          },
          grund: 'Testtabelle: nur `text` ist vom Client schreibbar',
        ),
      };

      /// Same table, but UPDATE narrowed to one column — the shape
      /// 20260819100000 gave `profiles`.
      final spaltenGesund = gesund.replaceFirst(
        'grant select, insert, update, delete on public.notizen '
            'to authenticated;',
        'grant select, insert, delete on public.notizen to authenticated;\n'
            'grant update (text) on public.notizen to authenticated;',
      );

      test('der eingeschraenkte Ausgangsfall ist sauber', () {
        final s = bau(spaltenGesund);
        expect(regelClientRechte(s, spaltenSoll), isEmpty);
        expect(regelSpaltenRechte(s, spaltenSoll), isEmpty);
      });

      test('eine zusaetzlich freigegebene Spalte faellt auf', () {
        // The sabotage of the review: `grant update (email, display_name) …`
        // — the privilege name is unchanged, only its column set grows.
        final s = schemaAusQuellen({
          '00_test.sql': spaltenGesund,
          '01_sabotage.sql':
              'grant update (user_id) on public.notizen to authenticated;',
        });
        expect(
          regelClientRechte(s, spaltenSoll),
          isEmpty,
          reason: 'genau deshalb braucht es die neue Regel: die alte sieht '
              'nur den Privilegiennamen `update` und bleibt gruen',
        );
        expect(
          regelSpaltenRechte(s, spaltenSoll),
          contains(contains('user_id')),
        );
      });

      test('ein weggefallener Spalten-Grant faellt ebenso auf', () {
        final s = bau(gesund.replaceFirst(
          'grant select, insert, update, delete on public.notizen '
              'to authenticated;',
          'grant select, insert, delete on public.notizen to authenticated;',
        ));
        expect(regelSpaltenRechte(s, spaltenSoll),
            contains(contains('fehlt `update`')));
      });

      test('eine Tabelle ohne erwartete Spalten-Grants darf keine haben', () {
        final s = schemaAusQuellen({
          '00_test.sql': gesund,
          '01_sabotage.sql':
              'grant update (user_id) on public.notizen to authenticated;',
        });
        expect(regelSpaltenRechte(s, soll), contains(contains('user_id')));
      });
    });

    group('Transaktionsklammern in Migrationen', () {
      test('ein eigenes begin/commit faellt auf', () {
        expect(
          regelKeineTransaktionsklammer({'01_x.sql': 'begin;\nselect 1;\ncommit;'}),
          hasLength(2),
        );
      });

      test('plpgsql-`begin`/`end` im Funktionsrumpf faellt NICHT auf', () {
        expect(
          regelKeineTransaktionsklammer({
            '01_x.sql': r'''
create or replace function public.f() returns void
language plpgsql set search_path = public as $$
begin
  perform 1;
end;
$$;
do $$ begin perform 1; end $$;
''',
          }),
          isEmpty,
        );
      });

      test('die dokumentierte Bestandsdatei bleibt ausgenommen', () {
        expect(
          regelKeineTransaktionsklammer({
            '20260803120000_drop_removed_feature_tables.sql':
                'begin;\ndrop table if exists public.x cascade;\ncommit;',
          }),
          isEmpty,
        );
      });
    });
  });

  group('Ausdrucksnormalisierung', () {
    test('Seitentausch und Leerzeichen sind bedeutungslos', () {
      expect(
        normalisiereAusdruck('auth.uid() = user_id'),
        normalisiereAusdruck('user_id=auth.uid()'),
      );
      expect(
        normalisiereAusdruck('( auth.uid() = id )'),
        besitzerBedingung('id'),
      );
    });

    test('eine andere Spalte ist eine andere Bedingung', () {
      expect(
        normalisiereAusdruck('auth.uid() = owner_id'),
        isNot(besitzerBedingung('user_id')),
      );
    });

    // P7-06: the InitPlan spelling PostgreSQL recommends for a `stable`
    // function must read as the SAME condition, or the guard would forbid the
    // performance fix instead of checking it.
    test('`(select auth.uid())` ist dieselbe Bedingung wie `auth.uid()`', () {
      expect(
        normalisiereAusdruck('(select auth.uid()) = user_id'),
        besitzerBedingung('user_id'),
      );
      expect(
        normalisiereAusdruck('user_id = ( select auth.uid() )'),
        besitzerBedingung('user_id'),
      );
    });

    test('die InitPlan-Schreibweise macht `true` nicht unsichtbar', () {
      final s = schemaAusQuellen({
        '00_test.sql': '''
create table public.n (id uuid, user_id uuid);
alter table public.n enable row level security;
create policy "n_select_own" on public.n for select to authenticated
  using ((select true));
grant select on public.n to authenticated;
''',
      });
      const soll = {
        'n': Erwartung(
          besitzerSpalte: 'user_id',
          clientBefehle: {'select'},
          grund: 'Testtabelle',
        ),
      };
      expect(
        regelPolicyBedingungen(s, soll),
        contains(contains('konstant wahr')),
      );
    });
  });
}
