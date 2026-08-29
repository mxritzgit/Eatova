// Replays `supabase/migrations/*.sql` in file-name order into the schema state
// they leave behind: which tables live, whether RLS is on, which policies sit
// on them with which USING/WITH CHECK, which role holds which table privilege,
// and which functions are `security definer` with a pinned `search_path`.
//
// WHY a replayer and not a grep: a migration is not the truth on its own. The
// write policies of `lifetime_stats` are created in 20260516160000 and dropped
// again in 20260811120000; `daily_logs` exists for eleven migrations and is
// then dropped; `profiles` loses its table-wide INSERT/UPDATE grant in
// 20260819100000 and gets column grants back. Only the END STATE of the whole
// history says what the database actually enforces, and only that state can be
// asserted against.
//
// SCOPE, deliberately: this models what the MIGRATIONS state. It does not know
// the Supabase platform bootstrap (the `grant all on tables` default that ships
// with a fresh project), so a privilege the migrations never mention is
// reported as absent. Every lockdown in this repo is written out explicitly
// (`revoke all … from anon`, `alter default privileges … revoke all`), so the
// assertions in rls_invariants_test.dart are about statements that are really
// there — not about a state inferred from silence.
//
// It is a text model, so it cannot prove PostgreSQL accepts the SQL. What it
// can do is fail when the meaning of a policy changes, which is exactly what no
// other check in this repo does.

import 'dart:io';

const String kMigrationsVerzeichnis = 'supabase/migrations';

/// The four table privileges a PostgREST client can actually use.
const Set<String> kCrud = {'select', 'insert', 'update', 'delete'};

/// Everything `grant all on <table>` covers.
const Set<String> kAlleTabellenrechte = {
  'select',
  'insert',
  'update',
  'delete',
  'truncate',
  'references',
  'trigger',
};

/// One RLS policy as the history leaves it.
class PolicyState {
  PolicyState({
    required this.name,
    required this.tabelle,
    required this.befehl,
    required this.rollen,
    required this.using,
    required this.withCheck,
    required this.quelle,
  });

  final String name;
  final String tabelle;

  /// `all` | `select` | `insert` | `update` | `delete` — `all` is PostgreSQL's
  /// default when the CREATE POLICY names no `for`.
  final String befehl;

  /// Roles from the `to …` clause. EMPTY means the policy names none, which in
  /// PostgreSQL is `to public` — every role, including `anon`.
  final List<String> rollen;

  /// The USING expression, verbatim between its parentheses; null if absent.
  final String? using;

  /// The WITH CHECK expression, verbatim; null if absent.
  final String? withCheck;

  /// Migration file the surviving CREATE POLICY came from.
  final String quelle;

  String get schluessel => '$tabelle.$name';
}

/// One table with its RLS flag and privileges per role.
class TableState {
  TableState(this.name, this.quelle);

  final String name;

  /// Migration file that created it.
  final String quelle;

  bool rlsAktiv = false;

  /// role -> table-wide privileges.
  final Map<String, Set<String>> rechte = {};

  /// role -> privilege -> columns, for column-level grants
  /// (`grant insert (a, b) on … to authenticated`).
  final Map<String, Map<String, Set<String>>> spaltenRechte = {};

  /// Every privilege a role holds on this table, table-wide or per column.
  Set<String> alleRechte(String rolle) => {
        ...?rechte[rolle],
        ...?spaltenRechte[rolle]?.keys,
      };
}

/// One function in schema `public`.
class FunctionState {
  FunctionState({
    required this.name,
    required this.securityDefiner,
    required this.searchPath,
    required this.rumpf,
    required this.quelle,
  });

  final String name;
  final bool securityDefiner;

  /// The pinned `set search_path = …` value, or null when the function pins
  /// none — the classic search_path hijack for a `security definer` body.
  final String? searchPath;

  /// The whole statement, whitespace-collapsed; carries the body.
  final String rumpf;

  final String quelle;

  /// Roles holding EXECUTE at the end of the history.
  final Set<String> executeRollen = {};
}

/// The end state of the whole migration history.
class SchemaState {
  final Map<String, TableState> tabellen = {};
  final Map<String, PolicyState> policies = {};
  final Map<String, FunctionState> funktionen = {};

  /// Statements the replay did not understand. NOT ignored: a security guard
  /// that silently skips what it cannot parse is worse than none, so
  /// rls_invariants_test.dart fails on a non-empty list.
  final List<String> unverstanden = [];

  /// Migration files, in the order they were applied.
  final List<String> dateien = [];

  Iterable<PolicyState> policiesVon(String tabelle) =>
      policies.values.where((p) => p.tabelle == tabelle);
}

// ---------------------------------------------------------------------------
// Statement splitting
// ---------------------------------------------------------------------------

/// Splits SQL into statements, dropping `--` and `/* */` comments but keeping
/// string literals and `$tag$ … $tag$` bodies verbatim — a function body is
/// full of semicolons and its comments discuss statements that never run.
List<String> zerlegeSql(String sql) {
  final aus = <String>[];
  final puffer = StringBuffer();
  final dollar = RegExp(r'\$[A-Za-z_][A-Za-z_0-9]*\$|\$\$');
  var i = 0;

  void schneide() {
    final s = puffer.toString().trim();
    if (s.isNotEmpty) aus.add(s);
    puffer.clear();
  }

  while (i < sql.length) {
    final c = sql[i];

    if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        i++;
      }
      puffer.write('\n');
      continue;
    }
    if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      i += 2;
      while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
        i++;
      }
      i = i + 2 > sql.length ? sql.length : i + 2;
      puffer.write(' ');
      continue;
    }
    if (c == "'") {
      puffer.write(c);
      i++;
      while (i < sql.length) {
        puffer.write(sql[i]);
        if (sql[i] == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            puffer.write(sql[i + 1]);
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (c == r'$') {
      final m = dollar.matchAsPrefix(sql, i);
      if (m != null) {
        final marke = m.group(0)!;
        final ende = sql.indexOf(marke, i + marke.length);
        final stop = ende < 0 ? sql.length : ende + marke.length;
        puffer.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
    }
    if (c == ';') {
      schneide();
      i++;
      continue;
    }
    puffer.write(c);
    i++;
  }
  schneide();
  return aus;
}

/// Collapses every run of whitespace to one blank.
String _flach(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Strips `--` and `/* */` comments. Unlike [zerlegeSql] this does NOT spare
/// string literals: it runs on a PL/pgSQL body, where an explanatory comment
/// would otherwise read like the statement it explains.
String _ohneSqlKommentare(String s) => s
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), ' ')
    .split('\n')
    .map((z) {
      final i = z.indexOf('--');
      return i < 0 ? z : z.substring(0, i);
    })
    .join('\n');

/// Content between the first `$tag$ … $tag$` pair, or null when there is none.
String? _dollarKoerper(String s) {
  final auf = RegExp(r'\$[A-Za-z_][A-Za-z_0-9]*\$|\$\$').firstMatch(s);
  if (auf == null) return null;
  final marke = auf.group(0)!;
  final zu = s.indexOf(marke, auf.end);
  if (zu < 0) return null;
  return s.substring(auf.end, zu);
}

/// What a DO block must not contain: finding label -> pattern. The label also
/// keys [kDoAusnahmen], so a waiver always names the ONE check it waives.
final Map<String, RegExp> kDoPruefungen = {
  'POLICY': RegExp(r'\b(create|alter|drop)\s+policy\b'),
  'GRANT/REVOKE': RegExp(r'\b(grant|revoke)\b'),
  'RLS-Umschaltung': RegExp(r'row\s+level\s+security'),
  'ALTER DEFAULT PRIVILEGES': RegExp(r'alter\s+default\s+privileges'),
  'CREATE/DROP TABLE': RegExp(r'\b(create|drop)\s+table\b'),
  'security definer': RegExp(r'security\s+definer'),
  // Last, and on purpose: dynamic SQL is assembled at runtime, so the checks
  // above may not see what it eventually runs.
  'dynamisches SQL': RegExp(r'\bexecute\b'),
};

/// Findings waived for ONE migration each, with the reason. File -> label ->
/// why. Everything not named here still bites, so a waiver can never turn a
/// whole file into a blind spot.
const Map<String, Map<String, String>> kDoAusnahmen = {
  '20260814120000_audit_rls_guard.sql': {
    'CREATE/DROP TABLE':
        'the words are the TAG LIST of the event trigger `ensure_rls` '
            '(`when tag in (\'CREATE TABLE\', …)`): the block reacts to a '
            'CREATE TABLE, it does not run one',
    'dynamisches SQL':
        'CREATE EVENT TRIGGER needs superuser, so it is wrapped in an '
            'exception handler; the executed text is a dollar-quoted literal '
            'creating `ensure_rls` and moves no privilege and no policy',
  },
};

/// Content of the parenthesis group opening at [auf], without the parentheses.
String? _klammerGruppe(String s, int auf) {
  var tiefe = 0;
  for (var i = auf; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      tiefe++;
    } else if (c == ')') {
      tiefe--;
      if (tiefe == 0) return s.substring(auf + 1, i);
    }
  }
  return null;
}

/// Splits a comma list at the TOP level, so `insert (a, b), update (c)` yields
/// two entries.
List<String> _kommaListe(String s) {
  final teile = <String>[];
  final puffer = StringBuffer();
  var tiefe = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(') tiefe++;
    if (c == ')') tiefe--;
    if (c == ',' && tiefe == 0) {
      teile.add(puffer.toString().trim());
      puffer.clear();
      continue;
    }
    puffer.write(c);
  }
  final rest = puffer.toString().trim();
  if (rest.isNotEmpty) teile.add(rest);
  return teile;
}

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

/// Statement heads that cannot change RLS, privileges or policies. Everything
/// NOT listed here and not handled below lands in [SchemaState.unverstanden].
const List<String> _harmlos = [
  'begin',
  'commit',
  'rollback',
  'create index',
  'create unique index',
  'drop index',
  'create trigger',
  'drop trigger',
  'create event trigger',
  'drop event trigger',
  'create extension',
  'drop extension',
  'create schema',
  'comment on',
  'insert into',
  'update public.',
  'delete from',
  'select ',
  'with ',
  'analyze',
  'vacuum',
  'set ',
  'notify',
];

final RegExp _reCreateTable =
    RegExp(r'^create table (?:if not exists )?(?:public\.)?([a-z0-9_]+)');
final RegExp _reDropTable =
    RegExp(r'^drop table (?:if exists )?(?:public\.)?([a-z0-9_]+)');
final RegExp _reRls = RegExp(
  r'^alter table (?:only )?(?:public\.)?([a-z0-9_]+) '
  r'(enable|disable|force|no force) row level security$',
);
final RegExp _reDropPolicy = RegExp(
  r'^drop policy (?:if exists )?"?([a-z0-9_]+)"? on (?:public\.)?([a-z0-9_]+)',
);
final RegExp _rePolicyKopf = RegExp(
  r'^create policy "?([a-z0-9_]+)"? on (?:public\.)?([a-z0-9_]+)'
  r'(?: as (permissive|restrictive))?'
  r'(?: for (all|select|insert|update|delete))?'
  r'(?: to (.+?))?$',
);
final RegExp _reUsing = RegExp(r'\busing\s*\(');
final RegExp _reWithCheck = RegExp(r'\bwith\s+check\s*\(');
final RegExp _reFunktionsKopf =
    RegExp(r'^create (?:or replace )?function (?:public\.)?([a-z0-9_]+)\s*\(');
final RegExp _reDropFunktion =
    RegExp(r'^drop function (?:if exists )?(?:public\.)?([a-z0-9_]+)');
final RegExp _reAlterFunktion =
    RegExp(r'^alter function (?:public\.)?([a-z0-9_]+)');
final RegExp _reSearchPath = RegExp(
  r"set search_path\s*=\s*(''|[a-z_][a-z_0-9]*(?:\s*,\s*[a-z_][a-z_0-9]*)*)",
);
final RegExp _reGrant = RegExp(
  r'^(grant|revoke) (?:grant option for )?(.+?) on (.+?) (?:to|from) (.+)$',
);
final RegExp _reDefaults = RegExp(
  r'^alter default privileges in schema public '
  r'(grant|revoke) (.+?) on (tables|sequences|functions) (?:to|from) (.+)$',
);

/// File name -> raw SQL of every migration, in the order they are applied.
Map<String, String> leseMigrationsQuellen({
  String wurzel = kMigrationsVerzeichnis,
}) {
  final verzeichnis = Directory(wurzel);
  if (!verzeichnis.existsSync()) {
    throw StateError(
      '$wurzel fehlt (aufgeloest von ${Directory.current.path})',
    );
  }
  final dateien = verzeichnis
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  return {
    for (final datei in dateien)
      datei.path.replaceAll(r'\', '/').split('/').last:
          datei.readAsStringSync(),
  };
}

/// Reads every migration and replays it. [wurzel] defaults to the repo layout.
SchemaState leseSchema({String wurzel = kMigrationsVerzeichnis}) =>
    schemaAusQuellen(leseMigrationsQuellen(wurzel: wurzel));

/// Replays SQL given in memory, applied in key order. Same code path as
/// [leseSchema]; the invariant self-tests use it to feed the rules a
/// DELIBERATELY BROKEN schema and prove they still bite.
SchemaState schemaAusQuellen(Map<String, String> quellen) {
  final zustand = SchemaState();
  final replay = _Replay(zustand);
  final namen = quellen.keys.toList()..sort();
  for (final name in namen) {
    zustand.dateien.add(name);
    for (final stmt in zerlegeSql(quellen[name]!)) {
      replay.anwenden(stmt, name);
    }
  }
  return zustand;
}

class _Replay {
  _Replay(this.zustand);

  final SchemaState zustand;

  /// role -> privileges a NEW table inherits (ALTER DEFAULT PRIVILEGES).
  final Map<String, Set<String>> _standardTabellenrechte = {};

  /// Roles that get EXECUTE on a NEW function by default.
  final Set<String> _standardExecute = {};

  void anwenden(String roh, String datei) {
    final s = _flach(roh);
    final l = s.toLowerCase();
    if (l.isEmpty) return;

    if (l.startsWith('create or replace function') ||
        l.startsWith('create function')) {
      _funktion(s, l, datei);
      return;
    }
    if (l.startsWith('drop function')) {
      final m = _reDropFunktion.firstMatch(l);
      if (m != null) zustand.funktionen.remove(m.group(1));
      return;
    }
    if (l.startsWith('alter function')) {
      _alterFunktion(l, s);
      return;
    }
    if (l.startsWith('create table')) {
      _createTable(l, datei);
      return;
    }
    if (l.startsWith('drop table')) {
      _dropTable(l);
      return;
    }
    if (l.startsWith('create policy')) {
      _createPolicy(s, l, datei);
      return;
    }
    if (l.startsWith('drop policy')) {
      final m = _reDropPolicy.firstMatch(l);
      if (m == null) {
        zustand.unverstanden.add('$datei: $s');
        return;
      }
      zustand.policies.remove('${m.group(2)}.${m.group(1)}');
      return;
    }
    if (l.startsWith('alter policy')) {
      // Never used so far; parsing it wrong would silently weaken the guard.
      zustand.unverstanden.add('$datei: $s');
      return;
    }
    if (l.startsWith('alter table')) {
      _alterTable(l, s, datei);
      return;
    }
    if (l.startsWith('alter default privileges')) {
      _standardRechte(l, s, datei);
      return;
    }
    if (l.startsWith('grant ') || l.startsWith('revoke ')) {
      _rechte(l, s, datei);
      return;
    }
    if (l == 'do' || l.startsWith('do ') || l.startsWith(r'do$')) {
      _doBlock(roh, s, datei);
      return;
    }
    if (_harmlos.any(l.startsWith)) return;
    zustand.unverstanden.add('$datei: $s');
  }

  // -- DO blocks ------------------------------------------------------------

  /// A `do $$ … $$` block is PL/pgSQL, not SQL: the replay cannot execute it,
  /// and until 2026-08-29 it was simply skipped as harmless. That made the
  /// guard blind to the one thing a migration can hide anywhere —
  /// `do $$ begin execute 'grant select on public.logged_meals to anon'; end $$`
  /// replayed GREEN (P7-02b).
  ///
  /// The block is therefore read as TEXT (comments stripped, so an explanatory
  /// `-- grant …` does not trip it) and rejected when it names anything that
  /// could move a privilege, a policy, a table or RLS — inside a string
  /// literal too, which is exactly where dynamic SQL hides it. What the replay
  /// cannot model, it must not wave through.
  void _doBlock(String roh, String s, String datei) {
    final koerper = _dollarKoerper(roh);
    if (koerper == null) {
      zustand.unverstanden.add('$datei: DO-Block ohne lesbaren Rumpf: $s');
      return;
    }
    final text = _flach(_ohneSqlKommentare(koerper)).toLowerCase();
    final waiver = kDoAusnahmen[datei] ?? const <String, String>{};

    for (final eintrag in kDoPruefungen.entries) {
      if (waiver.containsKey(eintrag.key)) continue;
      if (!eintrag.value.hasMatch(text)) continue;
      zustand.unverstanden.add(
        '$datei: DO-Block enthaelt `${eintrag.key}` — der Replay kann PL/pgSQL '
        'nicht ausfuehren und wuerde die Wirkung STILL uebergehen. '
        'Sicherheitsrelevantes gehoert als normale Anweisung in die Migration, '
        'nicht in einen DO-Block; ein begruendeter Einzelfall nach '
        'kDoAusnahmen.',
      );
      return;
    }
  }

  // -- tables ---------------------------------------------------------------

  void _createTable(String l, String datei) {
    final m = _reCreateTable.firstMatch(l);
    if (m == null) {
      zustand.unverstanden.add('$datei: $l');
      return;
    }
    final name = m.group(1)!;
    // `if not exists` on a live table changes nothing, privileges included.
    if (zustand.tabellen.containsKey(name)) return;
    final t = TableState(name, datei);
    _standardTabellenrechte.forEach((rolle, privs) {
      if (privs.isNotEmpty) t.rechte[rolle] = {...privs};
    });
    zustand.tabellen[name] = t;
  }

  void _dropTable(String l) {
    final m = _reDropTable.firstMatch(l);
    if (m == null) return;
    final name = m.group(1)!;
    zustand.tabellen.remove(name);
    // DROP TABLE takes its policies with it, CASCADE or not.
    zustand.policies.removeWhere((_, p) => p.tabelle == name);
  }

  void _alterTable(String l, String s, String datei) {
    final m = _reRls.firstMatch(l);
    if (m != null) {
      final t = zustand.tabellen[m.group(1)];
      if (t == null) {
        zustand.unverstanden.add('$datei: RLS auf unbekannter Tabelle: $s');
        return;
      }
      switch (m.group(2)) {
        case 'enable':
          t.rlsAktiv = true;
        case 'disable':
          t.rlsAktiv = false;
        default:
          break; // force / no force: no effect on the invariants below
      }
      return;
    }
    if (l.contains('row level security')) {
      // An RLS statement in a shape the regex above does not know must never
      // pass as an ordinary ALTER TABLE.
      zustand.unverstanden.add('$datei: $s');
      return;
    }
    // add column / add constraint / alter column / rename: no RLS effect.
  }

  // -- policies -------------------------------------------------------------

  void _createPolicy(String s, String l, String datei) {
    final mUsing = _reUsing.firstMatch(l);
    final mCheck = _reWithCheck.firstMatch(l);
    final schnitt = [
      if (mUsing != null) mUsing.start,
      if (mCheck != null) mCheck.start,
      s.length,
    ].reduce((a, b) => a < b ? a : b);

    final kopf = _flach(l.substring(0, schnitt));
    final m = _rePolicyKopf.firstMatch(kopf);
    if (m == null) {
      zustand.unverstanden.add('$datei: Policy-Kopf nicht lesbar: $s');
      return;
    }
    String? gruppe(RegExpMatch? treffer) => treffer == null
        ? null
        : _klammerGruppe(s, treffer.end - 1)?.trim();

    if (mUsing != null && gruppe(mUsing) == null) {
      zustand.unverstanden.add('$datei: USING-Klammer unbalanciert: $s');
      return;
    }
    if (mCheck != null && gruppe(mCheck) == null) {
      zustand.unverstanden.add('$datei: WITH-CHECK-Klammer unbalanciert: $s');
      return;
    }

    final policy = PolicyState(
      name: m.group(1)!,
      tabelle: m.group(2)!,
      befehl: m.group(4) ?? 'all',
      rollen: (m.group(5) ?? '')
          .split(',')
          .map((r) => r.trim())
          .where((r) => r.isNotEmpty)
          .toList(),
      using: gruppe(mUsing),
      withCheck: gruppe(mCheck),
      quelle: datei,
    );
    zustand.policies[policy.schluessel] = policy;
  }

  // -- functions ------------------------------------------------------------

  void _funktion(String s, String l, String datei) {
    final m = _reFunktionsKopf.firstMatch(l);
    if (m == null) {
      zustand.unverstanden.add('$datei: Funktionskopf nicht lesbar: $s');
      return;
    }
    final name = m.group(1)!;
    // Everything before the body delimiter is the function header.
    final koerperStart = RegExp(r'\bas\s+\$').firstMatch(l);
    final kopf = l.substring(0, koerperStart?.start ?? l.length);
    final sp = _reSearchPath.firstMatch(kopf);

    // `create or replace` keeps the existing ACL; a fresh function starts from
    // the default privileges.
    final alt = zustand.funktionen[name];
    final neu = FunctionState(
      name: name,
      securityDefiner: kopf.contains('security definer'),
      searchPath: sp?.group(1),
      rumpf: l,
      quelle: datei,
    );
    neu.executeRollen.addAll(alt?.executeRollen ?? _standardExecute);
    zustand.funktionen[name] = neu;
  }

  void _alterFunktion(String l, String s) {
    final m = _reAlterFunktion.firstMatch(l);
    if (m == null) return;
    final alt = zustand.funktionen[m.group(1)];
    if (alt == null) return;
    final sp = _reSearchPath.firstMatch(l);
    if (sp == null) return;
    final neu = FunctionState(
      name: alt.name,
      securityDefiner: alt.securityDefiner,
      searchPath: sp.group(1),
      rumpf: alt.rumpf,
      quelle: alt.quelle,
    );
    neu.executeRollen.addAll(alt.executeRollen);
    zustand.funktionen[alt.name] = neu;
  }

  // -- privileges -----------------------------------------------------------

  void _standardRechte(String l, String s, String datei) {
    final m = _reDefaults.firstMatch(l);
    if (m == null) {
      zustand.unverstanden.add('$datei: $s');
      return;
    }
    final gewaehren = m.group(1) == 'grant';
    final privs = _privilegien(m.group(2)!);
    final art = m.group(3)!;
    final rollen = _rollen(m.group(4)!);
    if (art == 'tables') {
      for (final rolle in rollen) {
        final ziel = _standardTabellenrechte.putIfAbsent(rolle, () => {});
        // `all` expands to EXECUTE/USAGE too; on a table those are phantoms
        // and would show up as rights the role does not really hold.
        for (final p in privs.keys.where(kAlleTabellenrechte.contains)) {
          gewaehren ? ziel.add(p) : ziel.remove(p);
        }
      }
    } else if (art == 'functions') {
      for (final rolle in rollen) {
        if (!privs.containsKey('execute')) continue;
        gewaehren
            ? _standardExecute.add(rolle)
            : _standardExecute.remove(rolle);
      }
    }
    // sequences carry no row data; out of scope on purpose.
  }

  void _rechte(String l, String s, String datei) {
    final m = _reGrant.firstMatch(l);
    if (m == null) {
      zustand.unverstanden.add('$datei: $s');
      return;
    }
    final gewaehren = m.group(1) == 'grant';
    final privs = _privilegien(m.group(2)!);
    final objekt = m.group(3)!.trim();
    final rollen = _rollen(m.group(4)!);

    if (objekt.startsWith('schema ')) return; // USAGE on the schema, no rows
    if (objekt == 'all sequences in schema public') return;

    if (objekt == 'all functions in schema public') {
      for (final f in zustand.funktionen.values) {
        _funktionsRecht(f, privs, rollen, gewaehren);
      }
      return;
    }
    if (objekt.startsWith('function ')) {
      final name = RegExp(r'^function (?:public\.)?([a-z0-9_]+)')
          .firstMatch(objekt)
          ?.group(1);
      final f = name == null ? null : zustand.funktionen[name];
      if (f != null) _funktionsRecht(f, privs, rollen, gewaehren);
      return;
    }

    final ziele = <TableState>[];
    if (objekt == 'all tables in schema public') {
      ziele.addAll(zustand.tabellen.values);
    } else {
      for (final teil in _kommaListe(objekt.replaceFirst('table ', ''))) {
        final name = teil.replaceFirst('public.', '').trim();
        final t = zustand.tabellen[name];
        if (t == null) {
          zustand.unverstanden.add('$datei: Recht auf unbekannter Tabelle: $s');
          continue;
        }
        ziele.add(t);
      }
    }

    for (final t in ziele) {
      for (final rolle in rollen) {
        // `grant all` expands to every privilege class; on a TABLE only the
        // seven table privileges apply (EXECUTE/USAGE belong to functions and
        // sequences and would otherwise show up as phantom table rights).
        final tabellenPrivs = Map<String, Set<String>?>.fromEntries(
          privs.entries.where((e) => kAlleTabellenrechte.contains(e.key)),
        );
        tabellenPrivs.forEach((priv, spalten) {
          if (gewaehren) {
            if (spalten == null) {
              t.rechte.putIfAbsent(rolle, () => {}).add(priv);
            } else {
              t.spaltenRechte
                  .putIfAbsent(rolle, () => {})
                  .putIfAbsent(priv, () => {})
                  .addAll(spalten);
            }
            return;
          }
          // REVOKE. Conservative on purpose: a named privilege clears the
          // table-wide grant, `all` clears the column grants too. In this repo
          // every revoke precedes its grant, so both readings agree; the
          // conservative one keeps a column grant VISIBLE rather than
          // silently dropping it from the model.
          t.rechte[rolle]?.remove(priv);
          if (spalten != null) {
            t.spaltenRechte[rolle]?[priv]?.removeAll(spalten);
            if (t.spaltenRechte[rolle]?[priv]?.isEmpty ?? false) {
              t.spaltenRechte[rolle]!.remove(priv);
            }
          }
        });
        if (!gewaehren &&
            kAlleTabellenrechte.every(tabellenPrivs.containsKey)) {
          t.spaltenRechte.remove(rolle);
        }
      }
    }
  }

  void _funktionsRecht(
    FunctionState f,
    Map<String, Set<String>?> privs,
    List<String> rollen,
    bool gewaehren,
  ) {
    if (!privs.containsKey('execute')) return;
    for (final rolle in rollen) {
      gewaehren ? f.executeRollen.add(rolle) : f.executeRollen.remove(rolle);
    }
  }

  /// Privilege list -> privilege -> columns (null = table-wide).
  /// `all` / `all privileges` expands to every table privilege.
  Map<String, Set<String>?> _privilegien(String liste) {
    final aus = <String, Set<String>?>{};
    for (final eintrag in _kommaListe(liste)) {
      final e = eintrag.trim();
      if (e == 'all' || e == 'all privileges') {
        for (final p in kAlleTabellenrechte) {
          aus[p] = null;
        }
        aus['execute'] = null;
        aus['usage'] = null;
        continue;
      }
      final klammer = e.indexOf('(');
      if (klammer < 0) {
        aus[e] = null;
        continue;
      }
      final name = e.substring(0, klammer).trim();
      final spalten = _klammerGruppe(e, klammer) ?? '';
      aus[name] = spalten
          .split(',')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toSet();
    }
    return aus;
  }

  List<String> _rollen(String liste) => liste
      .split(',')
      .map((r) => r.trim())
      .where((r) => r.isNotEmpty)
      .toList();
}

// ---------------------------------------------------------------------------
// Expression normalisation
// ---------------------------------------------------------------------------

/// Redundant parentheses around the WHOLE expression, removed.
String _ohneAeussereKlammern(String s) {
  var r = s;
  while (r.startsWith('(') && r.endsWith(')')) {
    final innen = _klammerGruppe(r, 0);
    if (innen == null || innen.length != r.length - 2) break;
    r = innen;
  }
  return r;
}

/// Canonical form of a policy expression: lower case, no whitespace, redundant
/// outer parentheses removed, and the two sides of a top-level `=` sorted, so
/// `auth.uid() = user_id` and `user_id=auth.uid()` compare equal.
///
/// `(select …)` loses its SELECT (P7-06, review 2026-08-29): PostgreSQL's own
/// recommendation against per-row evaluation of a `stable` function is to wrap
/// it as `(select auth.uid())`, which the planner hoists into an InitPlan. That
/// is the SAME condition, so the guard must not read the rewrite as a weakened
/// policy — otherwise the performance fix could only be bought by turning this
/// file red. The unwrap is deliberately blunt: a real subquery loses its
/// keyword too, but then the result matches no owner condition and the rules
/// above report it rather than accept it.
String normalisiereAusdruck(String ausdruck) {
  var s = ausdruck
      .toLowerCase()
      .replaceAll(RegExp(r'\(\s*select\s+'), '(')
      .replaceAll(RegExp(r'\s+'), '');
  s = _ohneAeussereKlammern(s);
  // Top-level `=` only; `auth.uid()` carries no `=`, but a future expression
  // might nest one.
  var tiefe = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '(') tiefe++;
    if (c == ')') tiefe--;
    if (c == '=' && tiefe == 0) {
      final links = _ohneAeussereKlammern(s.substring(0, i));
      final rechts = _ohneAeussereKlammern(s.substring(i + 1));
      if (links.contains('=') || rechts.contains('=')) break;
      final paar = [links, rechts]..sort();
      return '${paar[0]}=${paar[1]}';
    }
  }
  return s;
}

/// The only condition an own-row policy may carry: `auth.uid() = <owner>`.
String besitzerBedingung(String besitzerSpalte) =>
    normalisiereAusdruck('auth.uid() = $besitzerSpalte');
