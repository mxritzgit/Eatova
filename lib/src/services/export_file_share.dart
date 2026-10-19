import 'dart:developer' as dev;
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Hands the data export (GDPR art. 15/20, F9) to the system share sheet as
/// a file: mail attachment, Files, Drive.
///
/// The file is written into its own folder in the temporary directory and
/// removed again once the share sheet is done (Android shares a copy from
/// share_plus' own cache, iOS has read it by then). Every share first clears
/// what an interrupted earlier one left behind, so no export of a previous
/// account outlives the next share.
class ExportFileSharer {
  ExportFileSharer({
    Future<Directory> Function()? temporaryDirectory,
    Future<ShareResult> Function(ShareParams params)? share,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _share = share ?? SharePlus.instance.share;

  final Future<Directory> Function() _temporaryDirectory;
  final Future<ShareResult> Function(ShareParams params) _share;

  /// Folder name under the temporary directory, owned by this class.
  static const String folderName = 'eatova_export';

  /// Shares [content] as [fileName] with [subject] for mail targets.
  /// Throws when the file cannot be written or the share sheet fails; a
  /// dismissed sheet is no error.
  Future<void> share(
    String content,
    String fileName, {
    required String subject,
  }) async {
    final root = await _temporaryDirectory();
    final folder = Directory(
      '${root.path}${Platform.pathSeparator}$folderName',
    );
    await _remove(folder);
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}$fileName');
    try {
      await file.writeAsString(content, flush: true);
      await _share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: _mimeTypeFor(fileName))],
          subject: subject,
        ),
      );
    } finally {
      await _remove(folder);
    }
  }

  static String _mimeTypeFor(String fileName) =>
      fileName.toLowerCase().endsWith('.json')
      ? 'application/json'
      : 'text/plain';

  static Future<void> _remove(Directory folder) async {
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (e, st) {
      dev.log(
        'Export temp folder not removed',
        error: e,
        stackTrace: st,
        name: 'export_file_share',
      );
    }
  }
}
