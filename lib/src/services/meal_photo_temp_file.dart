import 'dart:io';

/// Deletes the temp file camera or gallery picker leaves in the app cache —
/// call once its bytes are read and scrubbed via `compressMealPhoto`.
///
/// Privacy: nothing used to clean these up, so meal photos survived the scan,
/// sign-out and even account deletion (the OS only clears the cache under
/// memory pressure).
///
/// Only ever the plugin's COPY in the app cache, never the gallery original:
/// with `imageQuality`/`maxWidth` set, `image_picker` always re-encodes into
/// its own cache file. Desktop passes the original path through, but Eatova
/// only builds Android/iOS, so this helper is wired there only.
///
/// A failure is deliberately not an error for the caller: the in-memory path
/// has no file, a second call finds nothing, and the bytes are in memory
/// anyway.
Future<void> deleteMealPhotoTempFile(String path) async {
  if (path.isEmpty) return;
  try {
    await File(path).delete();
  } catch (_) {
    // Already deleted, no permission, other process: the scan continues.
  }
  await _deletePickerSourceCopy(path);
}

/// `image_picker_android` first copies a gallery pick in full — EXIF and GPS
/// included — to `<cache>/<uuid>/<name>`, then returns only its resized copy
/// `<cache>/scaled_<name>`. It never deletes the first copy (its
/// `deleteOnExit` does not run on Android), so that one is removed here.
const String _scaledPrefix = 'scaled_';

/// `UUID.randomUUID().toString()`: the plugin's per-pick directory.
final RegExp _pickerCopyDirName = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

final RegExp _separator = RegExp(r'[/\\]');

String _baseName(String path) =>
    path.substring(path.lastIndexOf(_separator) + 1);

Future<void> _deletePickerSourceCopy(String path) async {
  final cut = path.lastIndexOf(_separator);
  if (cut <= 0) return;
  final name = path.substring(cut + 1);
  final parent = Directory(path.substring(0, cut));
  try {
    if (_pickerCopyDirName.hasMatch(_baseName(parent.path))) {
      // The picker returned its unscaled copy itself: drop the now empty
      // directory. Non-recursive, so anything else in it stays.
      await parent.delete();
      return;
    }
    if (!name.startsWith(_scaledPrefix) || name == _scaledPrefix) return;
    final sourceName = name.substring(_scaledPrefix.length);
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory ||
          !_pickerCopyDirName.hasMatch(_baseName(entry.path))) {
        continue;
      }
      final copy = File('${entry.path}${Platform.pathSeparator}$sourceName');
      try {
        if (!await copy.exists()) continue;
        await copy.delete();
        await entry.delete();
      } catch (_) {
        // Not empty or already gone: the next pick tries again.
      }
    }
  } catch (_) {
    // Unlistable cache or not empty: never an error for the scan.
  }
}
