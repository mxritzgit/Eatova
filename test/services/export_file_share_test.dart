// F9 (review 2026-10-19): the export leaves as a file through the system
// share sheet. The file lives only for the share: it is written into its own
// temporary folder and removed afterwards, also when sharing fails, and a
// leftover from an interrupted share never survives the next one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

import 'package:eatova/src/services/export_file_share.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('eatova_export_share_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Directory exportFolder() => Directory(
    '${temp.path}${Platform.pathSeparator}${ExportFileSharer.folderName}',
  );

  test(
    'teilt die volle Datei mit Typ und Betreff und raeumt danach auf',
    () async {
      final shared = <ShareParams>[];
      final contents = <String>[];
      final sharer = ExportFileSharer(
        temporaryDirectory: () async => temp,
        share: (params) async {
          shared.add(params);
          contents.add(await File(params.files!.single.path).readAsString());
          return const ShareResult('', ShareResultStatus.success);
        },
      );

      await sharer.share(
        '{"format":"eatova-export/1"}',
        'eatova-export-2026-10-19.json',
        subject: 'Eatova-Datenexport',
      );

      final params = shared.single;
      expect(params.subject, 'Eatova-Datenexport');
      final file = params.files!.single;
      expect(file.mimeType, 'application/json');
      expect(file.path, endsWith('eatova-export-2026-10-19.json'));
      expect(contents.single, '{"format":"eatova-export/1"}');
      expect(
        await exportFolder().exists(),
        isFalse,
        reason: 'the health data must not stay in the temp folder',
      );
    },
  );

  test(
    'der Bericht geht als Text, und ein Fehler raeumt ebenfalls auf',
    () async {
      final sharer = ExportFileSharer(
        temporaryDirectory: () async => temp,
        share: (params) async {
          expect(params.files!.single.mimeType, 'text/plain');
          throw StateError('no share sheet');
        },
      );

      await expectLater(
        sharer.share('Bericht', 'eatova-export-2026-10-19.txt', subject: 'x'),
        throwsStateError,
      );
      expect(await exportFolder().exists(), isFalse);
    },
  );

  test(
    'ein Rest eines abgebrochenen Teilens ueberlebt das naechste nicht',
    () async {
      final stale = File(
        '${exportFolder().path}${Platform.pathSeparator}eatova-export-old.json',
      );
      await stale.create(recursive: true);
      await stale.writeAsString('{"userId":"previous-account"}');

      final seen = <String>[];
      final sharer = ExportFileSharer(
        temporaryDirectory: () async => temp,
        share: (params) async {
          seen.addAll(
            exportFolder().listSync().map(
              (e) => e.path.split(RegExp(r'[\\/]')).last,
            ),
          );
          return const ShareResult('', ShareResultStatus.dismissed);
        },
      );

      await sharer.share('{}', 'eatova-export-2026-10-19.json', subject: 'x');

      expect(seen, <String>['eatova-export-2026-10-19.json']);
      expect(await stale.exists(), isFalse);
    },
  );
}
