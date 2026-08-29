// Keeps supabase/SCHEMA_STATE.md and supabase/migrations/ in step (P7-04).
//
// The hand-written predecessor drifted sixteen migrations behind without a
// single test noticing — and the CI drift job names it to readers, so the
// stale page was the one people were pointed at. The document is generated
// now, and this file is the reason it stays generated: it rebuilds it from the
// replay and compares. A new migration therefore makes exactly one test red,
// with the command to fix it in the failure message.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'migration_schema.dart';
import 'schema_state_doc.dart';

void main() {
  test('supabase/SCHEMA_STATE.md ist auf dem Stand aller Migrationen', () {
    final erwartet = schemaStateMarkdown(leseSchema());
    final datei = File(kSchemaStateDatei);

    // Escape hatch AND regeneration path in one: with the variable set the
    // test writes instead of comparing, so nobody has to copy a diff by hand.
    if (Platform.environment['SCHEMA_STATE_SCHREIBEN'] == '1') {
      datei.writeAsStringSync(erwartet);
      return;
    }

    expect(datei.existsSync(), isTrue,
        reason: '$kSchemaStateDatei fehlt (aufgeloest von '
            '${Directory.current.path})');
    expect(
      datei.readAsStringSync().replaceAll('\r\n', '\n'),
      erwartet.replaceAll('\r\n', '\n'),
      reason: 'Das Dokument beschreibt nicht mehr das, was die Migrationen '
          'hinterlassen. Neu erzeugen mit:\n'
          '  SCHEMA_STATE_SCHREIBEN=1 flutter test '
          'test/migrations/schema_state_doc_test.dart',
    );
  });

  test('das Dokument nennt die Tabellen, die es wirklich gibt', () {
    // Without this the golden above would also be happy with an empty
    // generator: it only compares the file against its own output.
    final schema = leseSchema();
    final text = schemaStateMarkdown(schema);
    expect(schema.tabellen, isNotEmpty);
    for (final name in schema.tabellen.keys) {
      expect(text, contains('| `$name` |'), reason: name);
    }
    for (final weg in ['workout_sets', 'weekly_plans', 'caffeine_entries']) {
      expect(text, isNot(contains('| `$weg` |')),
          reason: '$weg wurde in 20260803120000 gedroppt — genau der Fehler, '
              'den das alte handgepflegte Dokument trug');
    }
  });
}
