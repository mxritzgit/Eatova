import 'package:eatova/src/services/key_value_store.dart';

/// Inject faults at the real snapshot/transaction seam while preserving the
/// underlying store's CAS and all-or-nothing behavior.
class AtomicStoreFaults implements AtomicKeyValueStore, RawSlotProbe {
  AtomicStoreFaults(this.inner);
  final KeyValueStore inner;
  Future<void> Function(List<String> keys)? beforeRead;
  Future<void> Function(Map<String, String?> changes)? beforeWrite;

  AtomicKeyValueStore get _atomic {
    final store = inner;
    if (store is! AtomicKeyValueStore) {
      throw UnsupportedError('Atomic fixture required');
    }
    return store;
  }

  @override
  Future<KeyValueSnapshot> readSnapshot(Iterable<String> keys) async {
    final requested = keys.toList(growable: false);
    await beforeRead?.call(requested);
    return _atomic.readSnapshot(requested);
  }

  @override
  Future<KeyValueCommit> writeBatch(
    Map<String, String?> changes, {
    Map<String, int> expectedVersions = const {},
  }) async {
    await beforeWrite?.call(changes);
    return _atomic.writeBatch(changes, expectedVersions: expectedVersions);
  }

  @override
  Future<String?> getString(String key) async {
    await beforeRead?.call([key]);
    return inner.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    await writeBatch({key: value});
  }

  @override
  Future<void> remove(String key) async {
    await writeBatch({key: null});
  }

  @override
  Future<RawSlotState> rawSlotState(String key) async {
    final store = inner;
    if (store is RawSlotProbe) return (store as RawSlotProbe).rawSlotState(key);
    return await store.getString(key) == null
        ? RawSlotState.empty
        : RawSlotState.brokenContent;
  }
}
