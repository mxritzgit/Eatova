// Generates supabase/SCHEMA_STATE.md from the migration replay.
//
// WHY GENERATED (finding P7-04, review 2026-08-29). The predecessor,
// supabase/SCHEMA_STATE_2026-06-07.md, was written by hand and was sixteen
// migrations behind: it still listed `workout_sets`, `weekly_plans` and
// `caffeine_entries` as live (dropped in 20260803120000) and
// `record_workout_day(date)` as callable (dropped in 20260804120000). The CI
// drift job points readers at that document by name, so the one place people
// are sent to was the one place that had quietly stopped being true.
//
// A document that can go stale WILL go stale. This one is derived from the
// same replay the RLS guard asserts against (migration_schema.dart), and
// schema_state_doc_test.dart fails when the committed file and the migrations
// disagree — so it cannot fall behind by more than one red test.
//
// Regenerate after adding a migration, either way round:
//   SCHEMA_STATE_SCHREIBEN=1 flutter test test/migrations/schema_state_doc_test.dart
//   dart run test/migrations/schema_state_doc.dart

import 'dart:io';

import 'migration_schema.dart';

/// Where the generated document lives.
const String kSchemaStateDatei = 'supabase/SCHEMA_STATE.md';

/// Table-wide privileges of [rolle], sorted, or `—`.
String _rechte(TableState t, String rolle) {
  final privs = (t.rechte[rolle] ?? const <String>{}).toList()..sort();
  return privs.isEmpty ? '—' : privs.map((p) => '`$p`').join(', ');
}

String _zelle(String? wert) {
  if (wert == null || wert.trim().isEmpty) return '—';
  // `|` would break the markdown table, newlines would break the row.
  return '`${wert.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll('|', '¦')}`';
}

/// The whole document for [s]. Deterministic: every list is sorted, so a
/// regeneration without a schema change produces a byte-identical file.
String schemaStateMarkdown(SchemaState s) {
  final b = StringBuffer();

  b.writeln('# Supabase Schema-State (erzeugt)');
  b.writeln();
  b.writeln('<!-- ERZEUGT aus supabase/migrations/ von');
  b.writeln('     test/migrations/schema_state_doc.dart.');
  b.writeln('     NICHT von Hand bearbeiten — schema_state_doc_test.dart');
  b.writeln('     vergleicht diese Datei gegen den Replay und wird rot. -->');
  b.writeln();
  b.writeln('Dies ist der **Endzustand aller Migrationen**, nicht der Inhalt');
  b.writeln('einer einzelnen: `lifetime_stats` verliert seine Schreib-Policies');
  b.writeln('in `20260811120000` wieder, `profiles` tauscht in `20260819100000`');
  b.writeln('das Tabellenrecht gegen Spalten-Grants. Nur das Ende der Kette');
  b.writeln('sagt, was die Datenbank wirklich durchsetzt.');
  b.writeln();
  b.writeln('**Neu erzeugen** (nach jeder neuen Migration):');
  b.writeln();
  b.writeln('```');
  b.writeln('SCHEMA_STATE_SCHREIBEN=1 \\');
  b.writeln('  flutter test test/migrations/schema_state_doc_test.dart');
  b.writeln('```');
  b.writeln();
  b.writeln('**Was hier NICHT steht:** Spalten, Typen, Constraints, Indizes und');
  b.writeln('Trigger. Der Replay modelliert Tabellen, RLS, Policies, Rechte und');
  b.writeln('Funktionen — also die Zugriffsflaeche. Fuer Spalten und Constraints');
  b.writeln('ist die Migration selbst die Quelle; sie steht in jeder Zeile');
  b.writeln('unten dabei. Zwei Grenzen liegen deshalb ausserhalb dieser Tabellen:');
  b.writeln('die Zeilen*groessen* (`*_safe_ranges_check`, `20260517220000` und');
  b.writeln('`20260819140000`) und die Zeilen*zahl* je Nutzer');
  b.writeln('(`enforce_user_row_cap`-Trigger, `20260829120000`).');
  b.writeln();
  b.writeln('**Live-Abgleich:** ob die Live-DB diese Historie wirklich');
  b.writeln('angewendet hat, prueft der Job `supabase-migration-drift` in');
  b.writeln('`.github/workflows/security.yml`; die Bedienung steht in');
  b.writeln('`supabase/SCHEMA_STATE_2026-06-07.md`.');
  b.writeln();

  b.writeln('## Migrationen (${s.dateien.length})');
  b.writeln();
  for (var i = 0; i < s.dateien.length; i++) {
    b.writeln('${i + 1}. `${s.dateien[i]}`');
  }
  b.writeln();

  final tabellen = s.tabellen.keys.toList()..sort();
  b.writeln('## Tabellen in `public` (${tabellen.length})');
  b.writeln();
  b.writeln('| Tabelle | RLS | `authenticated` | `service_role` | Policies |'
      ' angelegt in |');
  b.writeln('|---|---|---|---|---|---|');
  for (final name in tabellen) {
    final t = s.tabellen[name]!;
    final policies = s.policiesVon(name).length;
    b.writeln(
      '| `$name` | ${t.rlsAktiv ? 'an' : '**AUS**'} '
      '| ${_rechte(t, 'authenticated')} | ${_rechte(t, 'service_role')} '
      '| $policies | `${t.quelle}` |',
    );
  }
  b.writeln();
  b.writeln('Weitere Rollen (`anon`, `public`) halten auf keiner Tabelle ein');
  b.writeln('Recht — sonst stuende sie hier und der RLS-Waechter waere rot.');
  b.writeln();

  b.writeln('## Spalten-Grants');
  b.writeln();
  final spaltenZeilen = <String>[];
  for (final name in tabellen) {
    final t = s.tabellen[name]!;
    final rollen = t.spaltenRechte.keys.toList()..sort();
    for (final rolle in rollen) {
      final privs = t.spaltenRechte[rolle]!.keys.toList()..sort();
      for (final priv in privs) {
        final spalten = t.spaltenRechte[rolle]![priv]!.toList()..sort();
        if (spalten.isEmpty) continue;
        spaltenZeilen.add(
          '| `$name` | `$rolle` | `$priv` | ${spalten.length} '
          '| ${spalten.map((c) => '`$c`').join(', ')} |',
        );
      }
    }
  }
  if (spaltenZeilen.isEmpty) {
    b.writeln('Keine.');
  } else {
    b.writeln('Ein Spalten-Grant ersetzt das Tabellenrecht: `authenticated`');
    b.writeln('schreibt nur die aufgezaehlten Spalten, alles andere scheitert');
    b.writeln('mit 42501.');
    b.writeln();
    b.writeln('| Tabelle | Rolle | Recht | Spalten | Namen |');
    b.writeln('|---|---|---|---|---|');
    spaltenZeilen.forEach(b.writeln);
  }
  b.writeln();

  b.writeln('## Policies (${s.policies.length})');
  b.writeln();
  b.writeln('| Tabelle | Policy | Befehl | Rollen | USING | WITH CHECK |'
      ' aus |');
  b.writeln('|---|---|---|---|---|---|---|');
  final policies = s.policies.values.toList()
    ..sort((a, b) => a.schluessel.compareTo(b.schluessel));
  for (final p in policies) {
    final rollen = p.rollen.isEmpty
        ? '**public**'
        : p.rollen.map((r) => '`$r`').join(', ');
    b.writeln(
      '| `${p.tabelle}` | `${p.name}` | `${p.befehl}` | $rollen '
      '| ${_zelle(p.using)} | ${_zelle(p.withCheck)} | `${p.quelle}` |',
    );
  }
  b.writeln();
  b.writeln('Tabellen ohne Zeile hier tragen bewusst keine Policy: RLS ist an,');
  b.writeln('also erreicht sie ausser dem Funktionseigentuemer und');
  b.writeln('`service_role` niemand.');
  b.writeln();
  b.writeln('### Warum `auth.uid()` und nicht `(select auth.uid())`');
  b.writeln();
  b.writeln('PostgreSQL empfiehlt fuer `stable` Funktionen in Policies die');
  b.writeln('Schreibweise `(select auth.uid())`: der Planer hebt sie in einen');
  b.writeln('InitPlan und wertet sie einmal statt je Zeile aus. Alle Policies');
  b.writeln('hier stehen trotzdem in der direkten Form — bewusst (Befund');
  b.writeln('P7-06, Review 2026-08-29):');
  b.writeln();
  b.writeln('* Der Gewinn faellt nur bei einem **Seq Scan** an. Jede Tabelle');
  b.writeln('  oben hat `user_id` (bzw. `id`) als **fuehrende Indexspalte**,');
  b.writeln('  und `auth.uid()` ist `stable`, taugt also selbst als');
  b.writeln('  Index-Bedingung — die Plaene, die die App erzeugt, sind');
  b.writeln('  Index-Scans.');
  b.writeln('* Der Preis waere ein `drop`/`create` **jeder** Policy in einer');
  b.writeln('  Migration: die gesamte Zugriffskontrolle der App in einem');
  b.writeln('  Schritt neu geschrieben, fuer Mikrosekunden.');
  b.writeln();
  b.writeln('Die Entscheidung ist nicht endgueltig: `normalisiereAusdruck` in');
  b.writeln('`test/migrations/migration_schema.dart` liest beide Schreibweisen');
  b.writeln('als dieselbe Bedingung, der Waechter bliebe nach einer Umstellung');
  b.writeln('also gruen.');
  b.writeln();

  final funktionen = s.funktionen.keys.toList()..sort();
  b.writeln('## Funktionen in `public` (${funktionen.length})');
  b.writeln();
  b.writeln('| Funktion | Rechte des | `search_path` | EXECUTE fuer | aus |');
  b.writeln('|---|---|---|---|---|');
  for (final name in funktionen) {
    final f = s.funktionen[name]!;
    final rollen = (f.executeRollen.toList()..sort());
    b.writeln(
      '| `$name` | ${f.securityDefiner ? '**Eigentuemers**' : 'Aufrufers'} '
      '| ${f.searchPath == null ? '—' : '`${f.searchPath}`'} '
      '| ${rollen.isEmpty ? '— (nur der Eigentuemer)' : rollen.map((r) => '`$r`').join(', ')} '
      '| `${f.quelle}` |',
    );
  }
  b.writeln();
  b.writeln('`security definer` heisst: der Rumpf laeuft mit den Rechten des');
  b.writeln('Eigentuemers und damit an RLS vorbei. Jede solche Funktion pinnt');
  b.writeln('deshalb ihren `search_path`, und jede, die `authenticated`');
  b.writeln('aufrufen darf, bindet sich selbst an `auth.uid()` — beides prueft');
  b.writeln('`test/migrations/rls_invariants_test.dart`.');

  return b.toString();
}

/// `dart run test/migrations/schema_state_doc.dart` writes the file.
void main() {
  final text = schemaStateMarkdown(leseSchema());
  File(kSchemaStateDatei).writeAsStringSync(text);
  stdout.writeln('$kSchemaStateDatei geschrieben (${text.length} Zeichen).');
}
