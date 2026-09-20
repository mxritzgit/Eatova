import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import 'key_value_store.dart';

/// A sanitized storage error: never includes SQL, bound values or file paths.
class DurableStorageException implements Exception {
  const DurableStorageException(this.reason);
  final String reason;

  @override
  String toString() => 'DurableStorageException: $reason';
}

/// SQLite is synchronous, so the connection and every filesystem/SQL operation
/// live in a dedicated isolate. Independent connections/processes coordinate
/// through SQLite locking and version checks, not an isolate-local mutex.
class SqliteKeyValueStore implements AtomicKeyValueStore {
  SqliteKeyValueStore._();

  final _responses = ReceivePort();
  final _errors = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  late final StreamSubscription<dynamic> _responseSubscription;
  late final StreamSubscription<dynamic> _errorSubscription;
  late final StreamSubscription<dynamic> _exitSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  int _nextRequest = 0;
  bool _closed = false;

  static Future<SqliteKeyValueStore> open(String path) async {
    final store = SqliteKeyValueStore._();
    store._responseSubscription = store._responses.listen(store._receive);
    store._errorSubscription = store._errors.listen((_) => store._workerLost());
    store._exitSubscription = store._exits.listen((_) => store._workerLost());
    try {
      store._isolate = await Isolate.spawn(
        _databaseWorker,
        [path, store._responses.sendPort],
        onError: store._errors.sendPort,
        onExit: store._exits.sendPort,
        errorsAreFatal: true,
        debugName: 'eatova-database',
      );
      await store._ready.future;
      return store;
    } catch (_) {
      await store.close();
      throw const DurableStorageException('database unavailable');
    }
  }

  void _receive(dynamic message) {
    final parts = message as List;
    if (parts[0] == 'ready') {
      _commands = parts[1] as SendPort;
      _ready.complete();
      return;
    }
    if (parts[0] == 'openError') {
      if (!_ready.isCompleted) {
        _ready.completeError(
          const DurableStorageException('database unavailable'),
        );
      }
      return;
    }
    final pending = _pending.remove(parts[0] as int);
    if (pending == null) return;
    if (parts[1] == 'ok') {
      pending.complete(parts[2]);
    } else if (parts[1] == 'conflict') {
      pending.completeError(const KeyValueConflict());
    } else {
      pending.completeError(
        const DurableStorageException('database operation failed'),
      );
    }
  }

  void _workerLost() {
    if (_closed) return;
    const error = DurableStorageException('database worker stopped');
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final request in _pending.values) {
      request.completeError(error);
    }
    _pending.clear();
    _commands = null;
  }

  Future<Object?> _request(String operation, [Object? data]) {
    final commands = _commands;
    if (_closed || commands == null) {
      return Future.error(const DurableStorageException('database is closed'));
    }
    final id = _nextRequest++;
    final result = Completer<Object?>();
    _pending[id] = result;
    commands.send([id, operation, data]);
    return result.future;
  }

  static KeyValueSnapshot _snapshot(Object? response) {
    final parts = response as List;
    return KeyValueSnapshot(
      Map<String, String?>.from(parts[0] as Map),
      Map<String, int>.from(parts[1] as Map),
    );
  }

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async =>
      _snapshot(await _request('read', keys.toSet().toList()));

  /// Raw enumeration for migration and key-loss detection; values are still
  /// ciphertext. Includes tombstones so a missing value cannot cause ABA.
  Future<KeyValueSnapshot> readAll() async => _snapshot(await _request('all'));

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async => KeyValueCommit(
    Map<String, int>.from(
      (await _request('write', [
            Map<String, String?>.from(changes),
            Map<String, int>.from(expectedVersions),
          ]))
          as Map,
    ),
  );

  @override
  Future<String?> getString(String key) async =>
      (await readSnapshot([key])).values[key];

  @override
  Future<void> setString(String key, String value) async {
    await writeBatch({key: value});
  }

  @override
  Future<void> remove(String key) async {
    await writeBatch({key: null});
  }

  /// Used to assert the real connection's settings, rather than source text.
  Future<Map<String, int>> durabilitySettings() async =>
      Map<String, int>.from((await _request('settings')) as Map);

  /// Initialization only, on a dedicated connection. Holds SQLite's real
  /// write lock across keystore access and migration; a process death releases
  /// it and rolls back automatically. Never share this connection meanwhile.
  Future<T> initializeExclusively<T>(Future<T> Function() initialize) async {
    await _request('beginInitialization');
    try {
      final result = await initialize();
      await _request('commitInitialization');
      return result;
    } catch (_) {
      try {
        await _request('abortInitialization');
      } catch (_) {
        // Preserve the original failure. Closing also rolls back.
      }
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      if (_commands != null) await _request('close');
    } finally {
      _closed = true;
      _commands = null;
      _isolate?.kill(priority: Isolate.immediate);
      for (final request in _pending.values) {
        request.completeError(
          const DurableStorageException('database is closed'),
        );
      }
      _pending.clear();
      await _responseSubscription.cancel();
      await _errorSubscription.cancel();
      await _exitSubscription.cancel();
      _responses.close();
      _errors.close();
      _exits.close();
    }
  }
}

void _databaseWorker(List<Object> arguments) {
  final path = arguments[0] as String;
  final replies = arguments[1] as SendPort;
  Database? database;
  try {
    File(path).parent.createSync(recursive: true);
    final db = database = sqlite3.open(path);
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA foreign_keys = ON');
    final mode = db.select('PRAGMA journal_mode = WAL').single.values.single;
    db.execute('PRAGMA synchronous = FULL');
    // On Darwin this asks the VFS to flush the drive's write cache as well.
    db.execute('PRAGMA fullfsync = ON');
    db.execute('PRAGMA secure_delete = ON');
    if (mode != 'wal' ||
        db.select('PRAGMA synchronous').single.values.single != 2) {
      throw const DurableStorageException('durable mode unavailable');
    }
    final schemaVersion =
        db.select('PRAGMA user_version').single.values.single as int;
    if (schemaVersion > 1) {
      throw const DurableStorageException('unsupported database version');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS cache_slots ('
        'key TEXT NOT NULL PRIMARY KEY, value TEXT, '
        'revision INTEGER NOT NULL CHECK (revision > 0)) STRICT',
      );
      db.execute('PRAGMA user_version = 1');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    final commands = ReceivePort();
    var initializing = false;
    var rollbackOnly = false;
    replies.send(['ready', commands.sendPort]);
    commands.listen((dynamic message) {
      final parts = message as List;
      final id = parts[0] as int;
      try {
        final operation = parts[1] as String;
        if (operation == 'beginInitialization') {
          if (initializing) throw StateError('Initialization already active');
          db.execute('BEGIN IMMEDIATE');
          initializing = true;
          rollbackOnly = false;
          replies.send([id, 'ok', null]);
          return;
        }
        if (operation == 'commitInitialization' ||
            operation == 'abortInitialization') {
          if (!initializing) throw StateError('No initialization active');
          final commit = operation == 'commitInitialization' && !rollbackOnly;
          db.execute(commit ? 'COMMIT' : 'ROLLBACK');
          initializing = false;
          if (operation == 'commitInitialization' && !commit) {
            throw StateError('Initialization failed');
          }
          replies.send([id, 'ok', null]);
          return;
        }
        if (operation == 'close') {
          db.close();
          replies.send([id, 'ok', null]);
          return;
        }
        final Object result = switch (operation) {
          'read' => _readDatabase(
            db,
            (parts[2] as List).cast<String>(),
            !initializing,
          ),
          'all' => _readDatabase(db, null, !initializing),
          'write' => _writeDatabase(db, parts[2] as List, !initializing),
          'settings' => {
            'wal':
                db.select('PRAGMA journal_mode').single.values.single == 'wal'
                ? 1
                : 0,
            'synchronous':
                db.select('PRAGMA synchronous').single.values.single as int,
            'fullfsync':
                db.select('PRAGMA fullfsync').single.values.single as int,
          },
          _ => throw const DurableStorageException('unsupported operation'),
        };
        replies.send([id, 'ok', result]);
      } on KeyValueConflict {
        if (initializing) rollbackOnly = true;
        replies.send([id, 'conflict', null]);
      } catch (_) {
        if (initializing) rollbackOnly = true;
        replies.send([id, 'error', null]);
      }
    });
  } catch (_) {
    database?.close();
    replies.send(['openError']);
  }
}

List<Object> _readDatabase(
  Database db,
  List<String>? keys,
  bool ownTransaction,
) {
  if (ownTransaction) db.execute('BEGIN');
  try {
    final values = <String, String?>{};
    final versions = <String, int>{};
    if (keys == null) {
      for (final row in db.select(
        'SELECT key, value, revision FROM cache_slots',
      )) {
        final key = row['key'] as String;
        values[key] = row['value'] as String?;
        versions[key] = row['revision'] as int;
      }
    } else {
      final statement = db.prepare(
        'SELECT value, revision FROM cache_slots WHERE key = ?',
      );
      try {
        for (final key in keys) {
          final rows = statement.select([key]);
          values[key] = rows.isEmpty ? null : rows.single['value'] as String?;
          versions[key] = rows.isEmpty ? 0 : rows.single['revision'] as int;
        }
      } finally {
        statement.close();
      }
    }
    if (ownTransaction) db.execute('COMMIT');
    return [values, versions];
  } catch (_) {
    if (ownTransaction) db.execute('ROLLBACK');
    rethrow;
  }
}

Map<String, int> _writeDatabase(
  Database db,
  List<dynamic> arguments,
  bool ownTransaction,
) {
  final changes = Map<String, String?>.from(arguments[0] as Map);
  final expected = Map<String, int>.from(arguments[1] as Map);
  if (ownTransaction) db.execute('BEGIN IMMEDIATE');
  try {
    final read = db.prepare('SELECT revision FROM cache_slots WHERE key = ?');
    final write = db.prepare(
      'INSERT INTO cache_slots(key, value, revision) '
      'VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET '
      'value = excluded.value, revision = cache_slots.revision + 1',
    );
    final committed = <String, int>{};
    try {
      for (final entry in expected.entries) {
        final rows = read.select([entry.key]);
        final actual = rows.isEmpty ? 0 : rows.single['revision'] as int;
        if (actual != entry.value) throw const KeyValueConflict();
      }
      for (final entry in changes.entries) {
        write.execute([entry.key, entry.value]);
        committed[entry.key] =
            read.select([entry.key]).single['revision'] as int;
      }
    } finally {
      read.close();
      write.close();
    }
    if (ownTransaction) db.execute('COMMIT');
    return committed;
  } catch (_) {
    if (ownTransaction) db.execute('ROLLBACK');
    rethrow;
  }
}
