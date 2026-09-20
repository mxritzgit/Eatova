/// Async storage seam. Successful durable implementations acknowledge only
/// after their transaction has committed.
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// A consistent read of values and their optimistic concurrency versions.
/// Missing keys have version zero; deleted keys retain a tombstone version.
class KeyValueSnapshot {
  KeyValueSnapshot(Map<String, String?> values, Map<String, int> versions)
    : values = Map.unmodifiable(values),
      versions = Map.unmodifiable(versions);

  final Map<String, String?> values;
  final Map<String, int> versions;
}

class KeyValueCommit {
  KeyValueCommit(Map<String, int> versions)
    : versions = Map.unmodifiable(versions);

  final Map<String, int> versions;
}

/// No write in the rejected batch was applied. The caller must reread and
/// rebase its intent, never retry an obsolete snapshot blindly.
class KeyValueConflict implements Exception {
  const KeyValueConflict();

  @override
  String toString() => 'KeyValueConflict: storage changed before commit';
}

abstract interface class AtomicKeyValueStore implements KeyValueStore {
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys);

  /// Null deletes a value but advances its version. Expected versions may
  /// include unchanged keys, allowing session and claim fencing in the same
  /// transaction. Failure never leaves a partially applied batch.
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  });
}

enum RawSlotState { empty, brokenContent, unreadableForNow }

/// Distinguishes empty storage from bytes a transforming store cannot read.
abstract class RawSlotProbe {
  Future<RawSlotState> rawSlotState(String key);
}

/// Test implementation with the same batch/CAS contract as the disk store.
class InMemoryKeyValueStore implements AtomicKeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
    : _data = {...?initial},
      _versions = {for (final key in initial?.keys ?? <String>[]) key: 1};

  final Map<String, String> _data;
  final Map<String, int> _versions;

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> getString(String key) async => _data[key];

  @override
  Future<void> setString(String key, String value) async {
    await writeBatch({key: value});
  }

  @override
  Future<void> remove(String key) async {
    await writeBatch({key: null});
  }

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async =>
      KeyValueSnapshot(
        {for (final key in keys) key: _data[key]},
        {for (final key in keys) key: _versions[key] ?? 0},
      );

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    for (final entry in expectedVersions.entries) {
      if ((_versions[entry.key] ?? 0) != entry.value) {
        throw const KeyValueConflict();
      }
    }
    final versions = <String, int>{};
    for (final entry in changes.entries) {
      final value = entry.value;
      if (value == null) {
        _data.remove(entry.key);
      } else {
        _data[entry.key] = value;
      }
      versions[entry.key] = _versions[entry.key] =
          (_versions[entry.key] ?? 0) + 1;
    }
    return KeyValueCommit(versions);
  }
}
