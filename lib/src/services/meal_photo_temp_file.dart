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
}
