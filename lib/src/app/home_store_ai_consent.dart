part of 'home_store.dart';

/// AI consent part of [HomeStore] (review 2026-10-19): the account's cached
/// consent decision in the encrypted cache. The decision itself lives in
/// [AiTrustController]; the store only lends it the account slot, which
/// sign-out and account deletion clear with every other slot.
mixin _HomeStoreAiConsentPart on _HomeStoreBase implements AiConsentCache {
  /// The account cache once the boot has opened it. A read right after the
  /// shell mounted waits for the opening instead of reporting "nothing".
  Future<LocalCache?> _aiConsentCacheReady() async {
    final ready = _cache ?? debugCache;
    if (ready != null) return ready;
    final opening = _cacheOpening;
    if (opening == null) return null;
    try {
      await opening;
    } catch (_) {
      return null;
    }
    if (_disposed) return null;
    return _cache ?? debugCache;
  }

  @override
  Future<AiConsentRecord?> readAiConsent() => _retainOwnedCache(() async {
    final cache = await _aiConsentCacheReady();
    if (cache == null) return null;
    return AiConsentRecord.fromJson(await cache.readAiConsent());
  });

  @override
  Future<void> writeAiConsent(AiConsentRecord record) =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        if (cache == null || _disposed) return;
        await cache.writeAiConsent(record.toJson());
      });
}
