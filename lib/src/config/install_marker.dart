import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/crash_reporter.dart' show CrashReporter;
import '../services/durable_cache_store.dart' show DurableCacheStore;

/// What [FreshInstallGuard.run] decided on this start.
enum InstallCheck {
  /// The marker was already there: nothing to do.
  marked,

  /// No marker, but an earlier launch left data: an update from a build
  /// without the marker. The session stays.
  upgraded,

  /// No marker and no earlier data: a fresh install. A leftover session was
  /// discarded.
  freshInstall,

  /// Fresh install whose leftover session could not be proven gone. Nothing is
  /// restored in this process; the marker stays unset so the next start
  /// retries.
  purgeIncomplete,
}

/// Storage of the install marker and the evidence of earlier launches.
abstract interface class InstallStateStore {
  Future<bool> hasMarker();

  /// Whether an earlier launch of ANY build left data in the app container.
  Future<bool> hasPriorLaunchEvidence();

  Future<void> writeMarker();
}

/// Production implementation over SharedPreferences and the cache database.
///
/// Both live in the app container, which an uninstall wipes on Android and
/// iOS alike, while the iOS Keychain survives it.
class PrefsInstallStateStore implements InstallStateStore {
  PrefsInstallStateStore({Future<String> Function()? cacheDatabasePath})
    : _cacheDatabasePath = cacheDatabasePath ?? _defaultCacheDatabasePath;

  final Future<String> Function() _cacheDatabasePath;

  static Future<String> _defaultCacheDatabasePath() async =>
      '${(await getApplicationSupportDirectory()).path}/'
      '${DurableCacheStore.databaseFileName}';

  @override
  Future<bool> hasMarker() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(FreshInstallGuard.markerKey) ?? false;
  }

  /// Two independent signals, because no single one is written by every
  /// build for every signed-in user:
  ///  * any SharedPreferences key: builds before the SQLite cache (PR #98)
  ///    kept the cache slots and `eatova.v1.dek_provisioned` there;
  ///  * the SQLite cache file: every later build opens it on each signed-in
  ///    boot (`LocalCache.create`) and moves the slots out of preferences.
  @override
  Future<bool> hasPriorLaunchEvidence() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getKeys().any((key) => key != FreshInstallGuard.markerKey)) {
      return true;
    }
    return File(await _cacheDatabasePath()).exists();
  }

  @override
  Future<void> writeMarker() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(FreshInstallGuard.markerKey, true)) {
      throw StateError('Install marker was not acknowledged');
    }
  }
}

/// P3-01: a reinstall must not sign into the previous account.
///
/// The session lives in the iOS Keychain (`first_unlock_this_device`), which
/// survives an uninstall; the logout journal and everything else live in the
/// app container, which does not. So a phone handed on, or an app reinstalled
/// to "reset" it, restored the old account silently.
///
/// The marker separates a fresh install from an update of a build that never
/// wrote it ([InstallStateStore.hasPriorLaunchEvidence]). Only the session is
/// purged: the cache DEK is app-wide, not account-bound, and the data it
/// encrypted went with the container. Deleting it would gain nothing and, on a
/// misjudged update, make the outbox undecryptable.
///
/// Android needs no purge (its secure storage lives in the wiped, backup-
/// excluded preferences); there the guard only writes the marker. A restored
/// container without its keystore (device transfer) is safe either way: the
/// session read fails and the user lands on the login screen.
abstract final class FreshInstallGuard {
  static const String markerKey = 'eatova.install.marker.v1';

  /// Never throws: it runs before `runApp`, and a boot error is worse than
  /// either outcome. Undecidable states count as a fresh install, so the
  /// failure mode is a login screen, never the previous account.
  static Future<InstallCheck> run({
    required Future<bool> Function() discardLeftoverSession,
    InstallStateStore? store,
  }) async {
    final state = store ?? PrefsInstallStateStore();
    try {
      if (await state.hasMarker()) return InstallCheck.marked;
    } catch (error, stack) {
      _report(error, stack, 'install_marker_read');
    }

    var upgraded = false;
    try {
      upgraded = await state.hasPriorLaunchEvidence();
    } catch (error, stack) {
      _report(error, stack, 'install_marker_evidence');
    }

    if (!upgraded) {
      final bool gone;
      try {
        gone = await discardLeftoverSession();
      } catch (error, stack) {
        _report(error, stack, 'install_marker_purge');
        return InstallCheck.purgeIncomplete;
      }
      // Without the marker the next start checks again.
      if (!gone) return InstallCheck.purgeIncomplete;
    }

    try {
      await state.writeMarker();
    } catch (error, stack) {
      // The next start repeats the check. The purge is idempotent, and after
      // a login the cache file counts as evidence.
      _report(error, stack, 'install_marker_write');
    }
    return upgraded ? InstallCheck.upgraded : InstallCheck.freshInstall;
  }

  static void _report(Object error, StackTrace stack, String context) {
    dev.log('Install marker: $context failed',
        error: error, stackTrace: stack, name: 'install_marker');
    unawaited(CrashReporter.capture(error, stack, context: context));
  }
}
