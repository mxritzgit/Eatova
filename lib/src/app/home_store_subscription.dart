part of 'home_store.dart';

/// Premium part of [HomeStore] (2026-10-25): the account's cache slots
/// `plan_status`, `paywall_prompt`, `legacy_notice` and `upsell_shown`. The
/// plan itself lives in [SubscriptionController]; the store only lends it the
/// account slots, which sign-out and account deletion clear with every other
/// slot.
mixin _HomeStoreSubscriptionPart on _HomeStoreBase, _HomeStoreAiConsentPart
    implements PlanStatusCache {
  @override
  Future<PlanStatus?> readPlanStatus() => _retainOwnedCache(() async {
    // The same "cache once open" wait as the AI consent slot.
    final cache = await _aiConsentCacheReady();
    if (cache == null) return null;
    return PlanStatus.fromJson(await cache.readPlanStatus());
  });

  @override
  Future<void> writePlanStatus(PlanStatus status) =>
      _retainOwnedCache(() async {
        // Only what the server said; the assumed defaults are no record.
        if (status.assumed) return;
        final cache = await _aiConsentCacheReady();
        if (cache == null || _disposed) return;
        await cache.writePlanStatus(status.toJson());
      });

  @override
  Future<Map<PlanFeature, DateTime>> readUpsellDays() =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        final days = <PlanFeature, DateTime>{};
        if (cache == null) return days;
        for (final MapEntry(:key, :value)
            in (await cache.readUpsellShown()).entries) {
          final feature = PlanFeature.fromWire(key);
          final day = DateTime.tryParse(value);
          if (feature != null && day != null) days[feature] = utcDay(day);
        }
        return days;
      });

  @override
  Future<void> writeUpsellDays(Map<PlanFeature, DateTime> days) =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        if (cache == null || _disposed) return;
        await cache.writeUpsellShown(<String, String>{
          for (final MapEntry(:key, :value) in days.entries)
            key.wire: utcDay(value).toIso8601String(),
        });
      });

  /// The onboarding paywall's answer; null when none is waiting or was
  /// given (accounts onboarded before Premium, or by an older build).
  Future<PaywallPromptState?> readPaywallPrompt() =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        if (cache == null) return null;
        return PaywallPromptState.fromWire(await cache.readPaywallPrompt());
      });

  Future<void> writePaywallPrompt(PaywallPromptState state) =>
      _retainOwnedCache(() async {
        final cache = await _aiConsentCacheReady();
        if (cache == null || _disposed) return;
        await cache.writePaywallPrompt(state.wire);
      });

  /// The `legacy_until` whose notice was dismissed; a later date shows the
  /// notice again.
  Future<DateTime?> readLegacyNotice() => _retainOwnedCache(() async {
    final cache = await _aiConsentCacheReady();
    return cache?.readLegacyNotice();
  });

  Future<void> writeLegacyNotice(DateTime until) => _retainOwnedCache(() async {
    final cache = await _aiConsentCacheReady();
    if (cache == null || _disposed) return;
    await cache.writeLegacyNotice(until);
  });
}
