import 'package:eatova/src/services/local_cache.dart';

/// Fails at the transaction's read boundary, leaving the actual bytes intact.
class FailingSnapshotStore extends InMemoryKeyValueStore {
  FailingSnapshotStore([super.initial]);
  final blockedKeys = <String>{};
  final reads = <String, int>{};

  void _check(Iterable<String> keys) {
    for (final key in keys) {
      reads[key] = (reads[key] ?? 0) + 1;
      if (blockedKeys.contains(key)) {
        throw const UnreadableCacheSlot('synthetic', 'IsolateSpawnException');
      }
    }
  }

  @override
  Future<String?> getString(String key) async {
    _check([key]);
    return super.getString(key);
  }

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    final requested = keys.toList();
    _check(requested);
    return super.readSnapshot(requested);
  }
}
