import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

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

/// `File.createTempFile(uuid, ".jpg", cacheDir)`: the system camera writes
/// its full-size capture, EXIF included, to this name at the top of the
/// cache. A normal pick deletes it after resizing; a pick recovered after
/// the process died (see [discardLostPickerMedia]) does not.
final RegExp _cameraCaptureName = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-?\d+\.jpg$',
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
    if (_cameraCaptureName.hasMatch(sourceName)) {
      await _deleteQuietly(
        File('${parent.path}${Platform.pathSeparator}$sourceName'),
      );
      return;
    }
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

/// Android: deletes the picker files of a pick whose process died while the
/// system camera or gallery was in front.
///
/// The plugin finishes such a pick in the next process with nobody waiting:
/// it keeps the full-size photo, EXIF included, and stores its path for
/// `retrieveLostData`. The Dart code that would have deleted it died with
/// the old process, and the next pick clears only the stored path, so the
/// photo stayed in the cache through sign-out and account deletion. Called
/// at cold start, before any pick, and on every session end by the auth
/// gate.
///
/// The recovered photo is only deleted, never analysed or sent: the account
/// that took it may be gone. The lost result is read first (reading it
/// writes a resized copy), then the cache is swept for what older losses
/// left after a later pick cleared their stored path.
///
/// Best effort, never throws. [onAndroid] null means the running platform;
/// tests force it and pass their own [cacheDirectory].
Future<void> discardLostPickerMedia({
  bool? onAndroid,
  Future<Directory> Function() cacheDirectory = getTemporaryDirectory,
}) async {
  if (!(onAndroid ?? (!kIsWeb && Platform.isAndroid))) return;
  try {
    final lost = await ImagePicker().retrieveLostData();
    final paths = {
      for (final file in lost.files ?? const <XFile>[]) file.path,
      if (lost.file != null) lost.file!.path,
    };
    for (final path in paths) {
      await deleteMealPhotoTempFile(path);
    }
  } catch (_) {
    // No plugin or nothing readable: the sweep still runs.
  }
  try {
    await _sweepPickerFiles(await cacheDirectory());
  } catch (_) {
    // No cache directory: nothing to sweep.
  }
}

/// The files the picker writes to the cache: camera captures, `scaled_`
/// copies and full gallery copies in UUID directories, which go once empty.
/// A copy keeps the extension its MIME type maps to (`.dng`, `.avif`) or
/// none, and its `scaled_` copy the same name, so both are matched by where
/// the picker writes them, never by extension. Other cache files stay.
Future<void> _sweepPickerFiles(Directory cache) async {
  await for (final entry in cache.list(followLinks: false)) {
    final name = _baseName(entry.path);
    if (entry is File) {
      if (_cameraCaptureName.hasMatch(name) ||
          (name.startsWith(_scaledPrefix) && name != _scaledPrefix)) {
        await _deleteQuietly(entry);
      }
    } else if (entry is Directory && _pickerCopyDirName.hasMatch(name)) {
      try {
        // Only the picker creates UUID directories at the top of the cache,
        // one per pick, for the full copy of that pick.
        await for (final child in entry.list(followLinks: false)) {
          if (child is File) await _deleteQuietly(child);
        }
        // Non-recursive: a directory with a subdirectory or link stays.
        await entry.delete();
      } catch (_) {
        // Not empty or unlistable: left as it is.
      }
    }
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } catch (_) {
    // Already gone or not ours to delete.
  }
}
