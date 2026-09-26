import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/models/export_document.dart';

void main() {
  test(
    'sections and rows are ordered without dropping fields or nested order',
    () {
      final document = ExportDocument.parse(
        jsonEncode({
          'chat_messages': [],
          'unexpected_table': [
            {'unknown': null, 'enabled': false},
          ],
          'logged_meals': [
            {'id': 'old', 'logged_at': '2026-09-01T12:00:00Z'},
            {
              'id': 'new',
              'logged_at': '2026-09-03T12:00:00Z',
              'payload': {
                'items': [
                  {'name': 'Z'},
                  {'name': 'A'},
                ],
              },
            },
          ],
          'profiles': [
            {'name': 'Test'},
          ],
          'format': 'eatova-export/1',
          'gekappt': {
            'sektionen': ['chat_messages'],
            'grenzeProSektion': 10000,
          },
        }),
      );
      expect(document.sections.map((s) => s.key), [
        'profiles',
        'logged_meals',
        'chat_messages',
        'gekappt',
        'unexpected_table',
      ]);
      final result = jsonDecode(document.json) as Map;
      expect((result['logged_meals'] as List).map((row) => row['id']), [
        'new',
        'old',
      ]);
      expect(result['logged_meals'][0]['payload']['items'], [
        {'name': 'Z'},
        {'name': 'A'},
      ]);
      expect(result['unexpected_table'], [
        {'enabled': false, 'unknown': null},
      ]);
      expect(result['gekappt']['sektionen'], ['chat_messages']);
      expect(document.json, contains('\n  "format":'));
    },
  );

  test('mixed dates and ties have a stable deterministic order', () {
    final records = [
      {'id': 'b', 'logged_at': '2026-09-03T14:00:00+02:00'},
      {'id': 'no-date'},
      {'id': 'a', 'created_at': '2026-09-03T12:00:00Z'},
      {'id': 'old', 'date': '2026-08-01'},
    ];
    String ordered(Iterable<Map> rows) =>
        ExportDocument.parse(jsonEncode({'logged_meals': rows.toList()})).json;
    expect(ordered(records), ordered(records.reversed));
    expect(
      (jsonDecode(ordered(records))['logged_meals'] as List).map(
        (row) => row['id'],
      ),
      ['a', 'b', 'old', 'no-date'],
    );
  });

  test(
    'full readable report includes late records, metadata and unknown values',
    () {
      final document = ExportDocument.parse(
        jsonEncode({
          'format': 'eatova-export/1',
          'exportedAt': '2026-09-26T12:00:00Z',
          'userId': 'dummy-user',
          'logged_meals': List.generate(
            400,
            (i) => {'id': i, 'value': 'meal-$i'},
          ),
        }),
      );
      final report = document.report('My data', (key) => key);
      expect(document.recordCount, 400);
      expect(report, contains('userId: dummy-user'));
      expect(report, contains('logged_meals (400)'));
      expect(report, contains('/value: meal-399'));
    },
  );

  test(
    'CSV preserves multiline quotes, union columns, types and nested paths',
    () {
      final section = ExportSection('data', [
        {
          'name': 'Bowl, "large"\nwith rice',
          'weight': -2,
          'payload': {'kcal': 123},
        },
        {'name': '=HYPERLINK("example")', 'enabled': false, 'weight': null},
        {
          'name': '\t +SUM(1,2)',
          'items': [2, 1],
        },
      ]);
      final csv = section.csv;
      expect(
        csv,
        startsWith('"/enabled","/items","/name","/payload/kcal","/weight"\r\n'),
      );
      expect(csv, contains('"Bowl, ""large""\nwith rice"'));
      expect(csv, contains('"-2"'));
      expect(csv, contains('"\'=HYPERLINK(""example"")"'));
      expect(csv, contains('"\'\t +SUM(1,2)"'));
      expect(csv, contains('"[2,1]"'));
      expect(csv, contains('"false"'));
      expect(csv, contains('"null"'));
    },
  );

  test('literal path characters do not overwrite nested fields', () {
    expect(
      exportFields({
        'a/b': 1,
        'a': {'b': 2},
        '~': 3,
      }),
      {'/a~1b': 1, '/a/b': 2, '/~0': 3},
    );
    expect(ExportSection('empty', []).csv, '');
    expect(ExportSection('object', {'a': []}).count, 1);
    expect(exportFields(null), {'/': null});
    expect(
      exportFields({
        'items': [
          {'name': 'Rice'},
          {'name': 'Fish'},
        ],
      }, expandLists: true),
      {'/items/1/name': 'Rice', '/items/2/name': 'Fish'},
    );
    expect(() => ExportDocument.parse('bad data'), throwsFormatException);
    expect(() => ExportDocument.parse('[]'), throwsFormatException);
  });
}
