part of 'home_store.dart';

/// The Coach's last known daily quota in the encrypted account cache
/// (2026-10-22), so a cold start knows the limit and a used-up day before
/// the server answers. The store only lends the slot; [CoachChatService]
/// decides what goes in. Sign-out and account deletion clear it with every
/// other slot.
mixin _HomeStoreCoachQuotaPart on _HomeStoreBase, _HomeStoreAiConsentPart
    implements CoachQuotaMemory {
  @override
  Future<Map<String, dynamic>?> readCoachQuota() => _retainOwnedCache(() async {
    // The same "cache once open" wait as the AI consent slot.
    final cache = await _aiConsentCacheReady();
    return cache?.readCoachQuota();
  });

  @override
  Future<void> writeCoachQuota(Map<String, dynamic> record) =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        if (cache == null || _disposed) return;
        await cache.writeCoachQuota(record);
      });
}
