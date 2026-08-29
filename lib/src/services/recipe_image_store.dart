import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'meal_photo_compressor.dart';

/// Local storage for user-taken recipe photos.
///
/// **Local, not Supabase Storage.** There is no bucket and no storage
/// policies, and the [SyncOp] outbox carries JSON, not megabytes. So the
/// bytes live in this device's app documents directory and the recipe says so.
///
/// **The marker.** [FitnessRecipe.imageAsset] holds `local:<name>.jpg`
/// instead of an asset path and travels unchanged through `toRow()/fromRow()`.
/// A second device finds no file and falls back to the placeholder instead of
/// loading a dead path. Rows without an image keep `''`.
///
/// **One namespace per user (Security review 2026-08-11, finding 5).** Files
/// used to lie flat in `recipe_images/` under slug-derived, guessable names,
/// so a later account on the same device could reference a predecessor's
/// photo. Now:
///
///   * Files live in `recipe_images/<uid>/`; [resolve], [save] and
///     [deleteFor] work only in the namespace bound by [setActiveUser].
///     No signed-in user means no resolution and no storage (fail-closed).
///   * New files are named from [Random.secure] — nothing guessable.
///   * An identity change during process runtime (other user OR session loss)
///     immediately purges the predecessor's namespace; AuthGate hooks this
///     for every auth transition.
///   * Legacy flat files migrate into the namespace of the first user to sign
///     in: the device was effectively one namespace, so they inherit it.
///
/// **EXIF scrubbing is mandatory** — a kitchen photo otherwise carries home
/// coordinates, permanently on disk. [save] runs every byte sequence through
/// [compressMealPhoto] and stores only the result; undecodable bytes are
/// dropped fail-closed.
///
/// **Nothing outlives its recipe (P3-04).** [deleteFor] only fires when THIS
/// device deletes and the server acknowledges at once, so a delete on a second
/// device, an offline delete delivered later and an abandoned coach adoption
/// all leave bytes behind. [reconcileRecipePhotos] compares the folder against
/// the recipes that actually exist and releases the rest.
class RecipeImageStore {
  RecipeImageStore({Future<Directory> Function()? baseDirectory})
      : _resolveBaseDirectory = baseDirectory ?? _appDocumentsFolder;

  /// Prefix separating a locally stored file from a bundle asset.
  static const String referencePrefix = 'local:';

  /// Root subfolder in the app documents directory; each user gets
  /// `recipe_images/<uid>/`.
  static const String folderName = 'recipe_images';

  final Future<Directory> Function() _resolveBaseDirectory;

  /// Root (`recipe_images/`), cached after the first resolution.
  Directory? _root;

  /// No storage location available (e.g. missing plugin channel in a widget
  /// test); the store then quietly returns null instead of retrying.
  bool _rootUnavailable = false;

  Future<Directory?>? _rootInFlight;

  /// User ID the store is bound to; null means nobody is signed in and
  /// resolve/save/deleteFor refuse (fail-closed).
  String? _activeUserId;

  /// Namespace directory, resolved and legacy-migrated, valid for
  /// [_namespaceUserId]. Afterwards [resolveSync] needs no await, so image
  /// tiles build without flicker.
  Directory? _namespace;
  String? _namespaceUserId;
  Future<Directory?>? _namespaceInFlight;
  String? _namespaceInFlightUserId;

  /// Maintenance chain: purge (identity change), legacy migration and [clear]
  /// run strictly one after another. Otherwise an A→B migration could pull the
  /// flat legacy files into B's namespace before the purge removes them.
  Future<void> _maintenance = Future<void>.value();

  Future<T> _afterMaintenance<T>(Future<T> Function() action) {
    final run = _maintenance.then((_) => action());
    // Actions catch internally; catchError keeps one failure from poisoning
    // the chain forever.
    _maintenance = run.then<void>((_) {}).catchError((Object _) {});
    return run;
  }

  /// Counts the purges ([clear], [_purgeNamespace]) of this process, raised
  /// INSIDE the maintenance chain so it is ordered against everything else on
  /// it (P3-03).
  ///
  /// A write captures the value before its awaits and compares again right
  /// before `writeAsBytes`: a changed count means the namespace it resolved
  /// has been wiped meanwhile, and the bytes must be dropped instead of
  /// recreating the folder. The identity check alone does not cover this —
  /// [clear] runs on logout WITHOUT touching [_activeUserId], and the AuthGate
  /// transition that does is not ordered against it.
  int _purgeEpoch = 0;

  /// Names [save] wrote in THIS process. [reconcileRecipePhotos] spares them:
  /// between a successful save and the recipe reaching the caller's list lie
  /// several hops (the coach adoption saves `unawaited`, the create sheet
  /// saves before the sheet pops), and in that window the photo looks orphaned
  /// while it is not. A purge empties the set with the files.
  final Set<String> _writtenThisSession = <String>{};

  // --- Process-wide instance ------------------------------------------------
  // Image tiles sit deep in the tree, partly behind a route push, so an
  // InheritedWidget cannot reach them. Hence one instance tests can swap.

  static RecipeImageStore _instance = RecipeImageStore();

  static RecipeImageStore get instance => _instance;

  @visibleForTesting
  static set instance(RecipeImageStore store) => _instance = store;

  @visibleForTesting
  static void resetInstance() => _instance = RecipeImageStore();

  // --- Identity binding -----------------------------------------------------

  /// Binds the store to [userId]; null means nobody is signed in.
  ///
  /// The namespace switch happens synchronously (before the first await), so
  /// once this returns no resolve reaches the old namespace even while the
  /// purge is still running.
  ///
  /// On an identity change during process runtime — including the transition
  /// to null (session loss, server-side revocation) — the predecessor's
  /// namespace is purged locally. Fail-closed, deliberately also when the same
  /// user signs back in. Explicit sign-out additionally runs [clear]; both
  /// paths are idempotent.
  ///
  /// A cold start with session restore goes `null -> <uid>` and purges
  /// nothing, otherwise no photo would survive a restart.
  Future<void> setActiveUser(String? userId) {
    final previous = _activeUserId;
    if (previous == userId) return Future<void>.value();
    _activeUserId = userId;
    if (_namespaceUserId != userId) {
      _namespace = null;
      _namespaceUserId = null;
    }
    // First bound user of this process: nothing to purge. The flat legacy
    // files stay until his migration inherits them.
    if (previous == null) return Future<void>.value();
    return _afterMaintenance(() => _purgeNamespace(previous));
  }

  @visibleForTesting
  String? get activeUserId => _activeUserId;

  // --- References -----------------------------------------------------------

  /// True when [imageAsset] points to a file stored here.
  static bool isLocalReference(String imageAsset) =>
      imageAsset.startsWith(referencePrefix);

  /// File name from a reference; null when it is not a local one. Sanitized
  /// again on read: a reference can come from a server row, and a `../` in it
  /// must never escape the folder.
  static String? _fileNameFor(String imageAsset) {
    if (!isLocalReference(imageAsset)) return null;
    final raw = imageAsset.substring(referencePrefix.length);
    if (raw.isEmpty) return null;
    return _sanitize(raw);
  }

  /// Name for a NEW file: 128 bits from [Random.secure] as hex. Slug-derived
  /// names were predictable, so a foreign server row could target a previous
  /// user's file (finding 5). Nothing extra to persist: the reference travels
  /// in the recipe's `image_asset`.
  static String _randomFileName() {
    final rng = Random.secure();
    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      hex.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return 'img_$hex.jpg';
  }

  /// Only `A-Z a-z 0-9 _ - .` survive; everything else becomes `_`, so no
  /// path separator or `..` segment can appear.
  static String _sanitize(String value) {
    final buffer = StringBuffer();
    for (final code in value.codeUnits) {
      final isDigit = code >= 0x30 && code <= 0x39;
      final isUpper = code >= 0x41 && code <= 0x5A;
      final isLower = code >= 0x61 && code <= 0x7A;
      final isSafePunct = code == 0x5F || code == 0x2D; // _ -
      final isDot = code == 0x2E;
      buffer.writeCharCode(
        isDigit || isUpper || isLower || isSafePunct || isDot ? code : 0x5F,
      );
    }
    // `..` would survive otherwise (dots are needed for the extension).
    final safe = buffer.toString().replaceAll('..', '__');
    return safe.isEmpty ? 'rezept' : safe;
  }

  // --- Reading --------------------------------------------------------------

  /// File for [imageAsset]; null when it is not a local reference, nobody is
  /// signed in, there is no storage location, or the bytes never arrived in
  /// this namespace.
  Future<File?> resolve(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return null;
    final namespace = await _ensureNamespace();
    if (namespace == null) return null;
    final file = File('${namespace.path}/$name');
    return await file.exists() ? file : null;
  }

  /// Like [resolve] but without await; null while the namespace is not yet
  /// resolved. Lets a tile show the right image in its first frame.
  File? resolveSync(String imageAsset) {
    final name = _fileNameFor(imageAsset);
    final namespace = _syncNamespace();
    if (name == null || namespace == null) return null;
    final file = File('${namespace.path}/$name');
    return file.existsSync() ? file : null;
  }

  /// Namespace for synchronous access, only if it belongs to the currently
  /// bound user ID, so a stale entry is inert the moment identity changes.
  Directory? _syncNamespace() {
    final uid = _activeUserId;
    if (uid == null) return null;
    if (_namespaceUserId != uid) return null;
    return _namespace;
  }

  /// True once [resolveSync]'s answer is settled: either the active user's
  /// namespace is ready, or the answer is reliably null.
  bool get baseResolved {
    if (_rootUnavailable) return true;
    final uid = _activeUserId;
    if (uid == null) return true;
    return _namespace != null && _namespaceUserId == uid;
  }

  // --- Writing --------------------------------------------------------------

  /// Stores [bytes] and returns the reference for
  /// `FitnessRecipe.imageAsset`. null means not stored (nobody signed in, no
  /// location, undecodable, write error); the caller then saves the recipe
  /// without an image rather than with a dangling reference.
  Future<String?> save({required Uint8List bytes}) async {
    final uid = _activeUserId;
    if (uid == null) return null;
    final epoch = _purgeEpoch;
    final namespace = await _ensureNamespace();
    if (namespace == null) return null;

    final Uint8List scrubbed;
    try {
      scrubbed = await _scrub(bytes);
    } catch (e) {
      // Fail-closed: no image beats an image with location data.
      dev.log('RecipeImageStore: Bild nicht dekodierbar — nicht abgelegt',
          error: e, name: 'recipe_image_store');
      return null;
    }

    final name = _randomFileName();
    // P3-03: the WRITE rides the maintenance chain and rechecks identity and
    // [_purgeEpoch]. Two awaits lie between resolving the namespace and here —
    // the namespace hop and the EXIF scrub's `compute()` — and a purge landing
    // in that window used to be undone by the lines below, which recreate the
    // folder on purpose. A logout or a lost session while a photo was being
    // saved therefore left exactly that photo on a disk that had just been
    // wiped.
    return _afterMaintenance<String?>(() async {
      if (_activeUserId != uid || _purgeEpoch != epoch) {
        dev.log(
            'RecipeImageStore: Ablage verworfen — der Namensraum wurde '
            'waehrend des Scrubs gepurgt',
            name: 'recipe_image_store');
        return null;
      }
      try {
        // The folder is created only here; reading creates nothing, else
        // `clear()` would find it back on disk right away.
        if (!await namespace.exists()) await namespace.create(recursive: true);
        final file = File('${namespace.path}/$name');
        await file.writeAsBytes(scrubbed, flush: true);
        _writtenThisSession.add(name);
        return '$referencePrefix$name';
      } catch (e, s) {
        dev.log('RecipeImageStore: Schreiben fehlgeschlagen',
            error: e, stackTrace: s, name: 'recipe_image_store');
        return null;
      }
    });
  }

  /// Strip EXIF, bake in orientation, cap the longest edge — same function as
  /// the upload path. Runs in `compute()` to keep the UI isolate free; if the
  /// isolate fails to start, scrubs synchronously (a stutter beats
  /// coordinates on disk).
  Future<Uint8List> _scrub(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } on FormatException {
      rethrow; // undecodable — the caller drops it.
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }

  // --- /rezept proposal images ----------------------------------------------
  // The AI image of a coach recipe proposal must survive a reload: the recipe
  // JSON comes back from chat_messages.recipe, the bytes live here under a
  // deterministic name per chat message id, so the card finds its image
  // without an index. Same lifetime rules as recipe photos; additionally each
  // save caps the stock at the newest [proposalImageCap] files.
  //
  // No EXIF scrub: these bytes come from the function's own image API
  // (machine-generated JPEG, no camera metadata). Adopting a proposal into a
  // recipe still runs [save] (own copy, own lifecycle).

  /// Upper bound of proposal images kept per user.
  static const int proposalImageCap = 24;

  static const String _proposalPrefix = 'proposal_';

  /// `local:` reference of the proposal image for [messageId].
  static String proposalReference(String messageId) =>
      '$referencePrefix$_proposalPrefix${_sanitize(messageId)}.jpg';

  /// Stores the proposal image. false = not stored (nobody signed in, no
  /// location, write error); the card then lives only until the next reload.
  /// Caps the stock afterwards, oldest first.
  Future<bool> saveProposalImage({
    required String messageId,
    required Uint8List bytes,
  }) async {
    final uid = _activeUserId;
    if (uid == null) return false;
    final epoch = _purgeEpoch;
    final namespace = await _ensureNamespace();
    if (namespace == null) return false;
    // Same chain and same recheck as [save] (P3-03): this path creates the
    // folder too, so it could revive a purged namespace just as well.
    return _afterMaintenance<bool>(() async {
      if (_activeUserId != uid || _purgeEpoch != epoch) {
        dev.log(
            'RecipeImageStore: Vorschlagsbild verworfen — der Namensraum '
            'wurde waehrend der Ablage gepurgt',
            name: 'recipe_image_store');
        return false;
      }
      try {
        if (!await namespace.exists()) await namespace.create(recursive: true);
        final name = '$_proposalPrefix${_sanitize(messageId)}.jpg';
        final file = File('${namespace.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        await _pruneProposalImages(namespace);
        return true;
      } catch (e, s) {
        dev.log('RecipeImageStore: Vorschlagsbild nicht abgelegt',
            error: e, stackTrace: s, name: 'recipe_image_store');
        return false;
      }
    });
  }

  /// Bytes of the proposal image for [messageId]; null when it is not in this
  /// namespace on this device.
  Future<Uint8List?> readProposalImage(String messageId) async {
    final file = await resolve(proposalReference(messageId));
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (e) {
      dev.log('RecipeImageStore: Vorschlagsbild nicht lesbar',
          error: e, name: 'recipe_image_store');
      return null;
    }
  }

  /// Deletes proposal images beyond [proposalImageCap], oldest first. Recipe
  /// photos (img_* files) stay untouched.
  Future<void> _pruneProposalImages(Directory namespace) async {
    try {
      final proposals = <File>[];
      await for (final entity in namespace.list(followLinks: false)) {
        if (entity is! File) continue;
        if (entity.uri.pathSegments.last.startsWith(_proposalPrefix)) {
          proposals.add(entity);
        }
      }
      if (proposals.length <= proposalImageCap) return;
      final dated = <(File, DateTime)>[];
      for (final file in proposals) {
        dated.add((file, (await file.stat()).modified));
      }
      dated.sort((a, b) => a.$2.compareTo(b.$2));
      for (final entry in dated.take(dated.length - proposalImageCap)) {
        try {
          await entry.$1.delete();
        } catch (_) {
          // One failure is fine: the next save reconsiders the file.
        }
      }
    } catch (e) {
      dev.log('RecipeImageStore: Vorschlags-Prune fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
  }

  // --- Cleanup --------------------------------------------------------------

  /// Deletes the image for [imageAsset] in the active user's namespace. No-op
  /// for bundle assets, empty references and without a signed-in user.
  Future<void> deleteFor(String imageAsset) async {
    final name = _fileNameFor(imageAsset);
    if (name == null) return;
    final namespace = await _ensureNamespace();
    if (namespace == null) return;
    try {
      final file = File('${namespace.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (e) {
      dev.log('RecipeImageStore: Loeschen fehlgeschlagen',
          error: e, name: 'recipe_image_store');
    }
  }

  /// Releases photos whose recipe no longer exists, and returns how many
  /// files fell (P3-04).
  ///
  /// Until now `img_*` was released ONLY by [deleteFor], and only when this
  /// device deleted the recipe AND the server acknowledged at once
  /// (`recipes_screen.dart`). A delete on a second device never reaches this
  /// one, an offline delete deliberately keeps the bytes and is never followed
  /// up, and an adoption abandoned in the coach leaves its photo lying. Each
  /// leftover is 200-400 kB of PII that nothing ever collects.
  ///
  /// [liveReferences] are the `imageAsset` values of the recipes that exist —
  /// non-local ones (bundle assets, empty) are ignored. A COMPARISON, not a
  /// cap: a cap would delete by age and take photos whose recipe still exists.
  ///
  /// **The caller vouches for the list.** An empty or half-loaded one deletes
  /// everything, so only sweep with a list the store has actually delivered
  /// (see `_RecipesScreenState._sweepOrphanPhotos`). Spared regardless:
  /// proposal images (own lifetime, see [proposalImageCap]) and everything
  /// [save] wrote in this process ([_writtenThisSession]).
  Future<int> reconcileRecipePhotos(Iterable<String> liveReferences) async {
    final uid = _activeUserId;
    if (uid == null) return 0;
    final epoch = _purgeEpoch;
    final namespace = await _ensureNamespace();
    if (namespace == null) return 0;
    final keep = <String>{};
    for (final reference in liveReferences) {
      final name = _fileNameFor(reference);
      if (name != null) keep.add(name);
    }
    // On the maintenance chain like every other bulk operation, so no purge or
    // legacy migration is running while the folder is being walked.
    return _afterMaintenance<int>(() async {
      if (_activeUserId != uid || _purgeEpoch != epoch) return 0;
      var removed = 0;
      try {
        if (!await namespace.exists()) return 0;
        await for (final entity in namespace.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          // The namespace holds exactly two kinds of file: recipe photos
          // (`img_*`, plus adopted legacy names) and proposal images. Only the
          // latter are excluded here — a third kind added later would have to
          // be excluded too, or it would count as an orphan.
          if (name.startsWith(_proposalPrefix)) continue;
          if (keep.contains(name)) continue;
          if (_writtenThisSession.contains(name)) continue;
          try {
            await entity.delete();
            removed++;
          } catch (e) {
            // One failure is fine: the next session's sweep reconsiders it.
            dev.log('RecipeImageStore: verwaistes Foto nicht loeschbar',
                error: e, name: 'recipe_image_store');
          }
        }
      } catch (e, s) {
        dev.log('RecipeImageStore: Foto-Abgleich fehlgeschlagen',
            error: e, stackTrace: s, name: 'recipe_image_store');
      }
      return removed;
    });
  }

  /// Wipes the whole root folder — all namespaces and the flat legacy files.
  ///
  /// Recipe photos are PII and must vanish on sign-out or account deletion
  /// like every other slot in `LocalCache.clear()`. Deliberately broader than
  /// the transition purge in [setActiveUser].
  Future<void> clear() {
    // Via the maintenance chain, so no concurrent migration moves a file into
    // a namespace while the folder is being deleted.
    return _afterMaintenance(() async {
      // BEFORE the awaits: a save hanging in its scrub compares this value and
      // must see the purge even if the delete below fails (P3-03).
      _purgeEpoch++;
      _writtenThisSession.clear();
      final root = await _ensureRoot();
      if (root == null) return;
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (e) {
        dev.log('RecipeImageStore: Raeumen fehlgeschlagen',
            error: e, name: 'recipe_image_store');
      }
      // [_root]/[_namespace] stay: the paths remain valid, only the folders
      // are gone. A LATER [save] recreates them — a save that was already
      // running when this ran does not (P3-03).
    });
  }

  /// Purges [uid]'s namespace and the flat legacy files. Those predate
  /// namespaces and belong to the previous device user, so they go too even if
  /// his migration never ran. Fail-closed; errors are logged, never rethrown.
  Future<void> _purgeNamespace(String uid) async {
    // Same reason as in [clear]: raised before the first await.
    _purgeEpoch++;
    _writtenThisSession.clear();
    final root = await _ensureRoot();
    if (root == null) return;
    try {
      final dir = Directory('${root.path}/${_sanitize(uid)}');
      if (await dir.exists()) await dir.delete(recursive: true);
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File) await entity.delete();
        }
      }
    } catch (e, s) {
      dev.log('RecipeImageStore: Purge fehlgeschlagen',
          error: e, stackTrace: s, name: 'recipe_image_store');
    }
  }

  // --- Storage location -----------------------------------------------------

  /// Active user's namespace, resolved and legacy-migrated. null when nobody
  /// is signed in or there is no storage location.
  Future<Directory?> _ensureNamespace() {
    final uid = _activeUserId;
    if (uid == null) return Future<Directory?>.value();
    final known = _namespace;
    if (known != null && _namespaceUserId == uid) {
      return Future<Directory?>.value(known);
    }
    if (_rootUnavailable) return Future<Directory?>.value();
    final inFlight = _namespaceInFlight;
    if (inFlight != null && _namespaceInFlightUserId == uid) return inFlight;
    final future = _openNamespace(uid);
    _namespaceInFlight = future;
    _namespaceInFlightUserId = uid;
    return future;
  }

  Future<Directory?> _openNamespace(String uid) async {
    try {
      final root = await _ensureRoot();
      if (root == null) return null;
      final namespace = Directory('${root.path}/${_sanitize(uid)}');
      // In the maintenance chain after any pending purge: a new user's
      // migration must not inherit files the switch is removing.
      await _afterMaintenance(() => _migrateLegacyInto(root, namespace));
      // Identity changed meanwhile: the result belongs to nobody.
      if (_activeUserId != uid) return null;
      _namespace = namespace;
      _namespaceUserId = uid;
      return namespace;
    } finally {
      if (_namespaceInFlightUserId == uid) {
        _namespaceInFlight = null;
        _namespaceInFlightUserId = null;
      }
    }
  }

  /// Adopts legacy files that lay flat in `recipe_images/`. The device was
  /// effectively one namespace, so the first signed-in user inherits it;
  /// existing references still resolve because only the folder changes.
  Future<void> _migrateLegacyInto(Directory root, Directory namespace) async {
    try {
      if (!await root.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          if (!await namespace.exists()) {
            await namespace.create(recursive: true);
          }
          final name = entity.uri.pathSegments.last;
          await entity.rename('${namespace.path}/$name');
        } catch (e) {
          // Not movable (collision, permissions): leave it. Flat files are
          // unreachable now — [resolve] only reads namespaces — and the next
          // identity change or [clear] removes them.
          dev.log('RecipeImageStore: Legacy-Datei nicht migriert',
              error: e, name: 'recipe_image_store');
        }
      }
    } catch (e, s) {
      dev.log('RecipeImageStore: Legacy-Migration fehlgeschlagen',
          error: e, stackTrace: s, name: 'recipe_image_store');
    }
  }

  Future<Directory?> _ensureRoot() {
    final known = _root;
    if (known != null) return Future<Directory?>.value(known);
    if (_rootUnavailable) return Future<Directory?>.value();
    return _rootInFlight ??= _openRoot();
  }

  /// Resolves the root path without creating the folder — only [save] does
  /// that; otherwise a plain read would need write access and [clear] would be
  /// undone by the next image.
  Future<Directory?> _openRoot() async {
    try {
      final dir = await _resolveBaseDirectory();
      _root = dir;
      return dir;
    } catch (e, s) {
      // No storage location (missing plugin channel in a widget test, full
      // disk). The app runs on without images; they are decoration, not data.
      dev.log('RecipeImageStore: kein Ablageort',
          error: e, stackTrace: s, name: 'recipe_image_store');
      _rootUnavailable = true;
      return null;
    } finally {
      _rootInFlight = null;
    }
  }

  /// Storage in the app documents folder, with a platform consequence
  /// (2026-08-19): on iOS Documents is part of the device backup, so images
  /// reach iCloud once the user enables it — PRIVACY.md says so. On Android
  /// backup is off app-wide, so files stay local. Moving to Caches would trade
  /// backup exposure for the OS deleting images; not done, the cards should
  /// survive a restart.
  static Future<Directory> _appDocumentsFolder() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/$folderName');
  }
}
