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
// WHY THE LITERAL BELOW IS HAND-WRITTEN. [_erwartet] is a second, independent
// source of truth, not derived from the migrations. Derived, the guard would
// be tautological: a new table without RLS would define its own expectation
// and pass. The same pattern already carries
// test/profile_export_sheet_test.dart:40. Adding a table therefore means
// adding it here, on purpose.
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
  });

  /// Server-only table: no owner column, no policy, no client privilege.
  const Erwartung.nurServer({required this.grund})
      : besitzerSpalte = null,
        clientBefehle = const {};

  /// The column carrying the row owner; every policy must compare it against
  /// `auth.uid()`.
  final String? besitzerSpalte;

  /// What `authenticated` may do directly via PostgREST. Everything not listed
  /// must have neither a policy nor a grant.
  final Set<String> clientBefehle;

  final String grund;

  bool get nurServer => besitzerSpalte == null;
}

const Set<String> _voll = {'select', 'insert', 'update', 'delete'};

/// The tables `supabase/migrations/` must leave behind — no more, no fewer.
const Map<String, Erwartung> _erwartet = {
  'profiles': Erwartung(
    besitzerSpalte: 'id',
    clientBefehle: _voll,
    grund: 'Profil und Ziele; die App schreibt sie direkt. Besitzerspalte ist '
        'die PK `id` (= auth.users.id), nicht user_id.',
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

List<PolicyState> _sortiert(SchemaState s) =>
    s.policies.values.toList()..sort((a, b) => a.schluessel.compareTo(b.schluessel));

// ---------------------------------------------------------------------------

void main() {
  late SchemaState schema;

  setUpAll(() {
    schema = leseSchema();
  });

  group('Der Waechter sieht die ganze Historie', () {
    test('alle Migrationen werden eingelesen', () {
      expect(
        schema.dateien.length,
        greaterThanOrEqualTo(35),
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
  });

  group('security definer', () {
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
  });
}
