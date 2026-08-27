part of 'home_store.dart';

/// State of the evening reminders. **Three** states, not two (D11): a plain
/// `bool` tracked intent only and never checked the OS, so a denied system
/// dialog left the toggle stuck on "active". Only [active] means something is
/// actually scheduled; [blocked] shows the toggle off plus a way into the
/// system settings.
enum ReminderState {
  /// User wants no reminders.
  off,

  /// User wants reminders and the OS delivers them.
  active,

  /// User wants reminders, the OS refuses them.
  blocked,
}

/// Profile part of [HomeStore]: profile/settings, onboarding and reminders
/// (PROD-1, evening streak saver). Pure file split, behaviour unchanged.
mixin _HomeStoreProfilePart on _HomeStoreBase, _HomeStoreSyncPart {
  ReminderState _reminderState = ReminderState.off;
  bool _onboardingDone = false;

  /// Whether anything actually fires in the evening. True only for
  /// [ReminderState.active] — "blocked" is not "on" (D11).
  bool get notificationsEnabled => _reminderState == ReminderState.active;

  /// Full state for the shell (text + action, see [ReminderState]).
  ReminderState get reminderState => _reminderState;

  /// Onboarding is mandatory once a real Supabase sync exists and the profile
  /// has not been completed. Never without sync (test/preview).
  bool get needsOnboarding =>
      sync != null && !_onboardingDone && !profile.onboardingCompleted;

  // --- Reminders (PROD-1) ---------------------------------------------------
  // Only content: the evening streak saver (streak_reminder_planner.dart).
  // The opt-in toggle + permission flow stay the hook for anything further.

  /// Cache on the boot path. `_cache` is only set after [_hydrateThenBoot];
  /// tests fall back to the injected [debugCache], like `_clearCache`.
  LocalCache? get _notificationCache => _cache ?? debugCache;

  /// Cold-start path for reminders.
  ///
  /// D11: the cache only holds what was true at opt-in, so re-check the OS
  /// with [NotificationPermissionProbe.hasPermission] (silent) — never
  /// `requestPermission()`, which would ambush the user with a dialog.
  Future<void> _initNotificationsFromCache() async {
    final cache = _notificationCache;
    if (cache == null) return;
    final enabled = await cache.readNotificationsEnabled() ?? false;
    if (_disposed) return;
    // No opt-in -> the OS is never asked.
    if (!enabled) return;

    await _syncWithOsGuarded(cache, context: 'notifications-cold-start');
  }

  /// init + OS re-check, fenced (F7-12 / F1-09): a PlatformException from the
  /// plugin used to escape as an unhandled zone error on every cold start.
  /// Now the user lands in [ReminderState.blocked] — they opted in, the OS
  /// layer is unusable right now — and the error goes to [CrashReporter].
  /// The opt-in flag stays untouched: nothing was proven either way.
  Future<void> _syncWithOsGuarded(
    LocalCache cache, {
    required String context,
  }) async {
    try {
      _syncNotificationLocale();
      await notificationService.init();
      await _applyOsPermission(cache);
    } catch (e, st) {
      unawaited(CrashReporter.capture(e, st, context: context));
      if (_disposed) return;
      _setReminderState(ReminderState.blocked);
    }
  }

  /// Passes the current locale to the notification service if it is
  /// localizable (see [NotificationLocalizable]). Called before EVERY `init()`
  /// so a language switch reaches the Android channel text.
  void _syncNotificationLocale() {
    final Object service = notificationService;
    if (service is NotificationLocalizable) {
      service.setLocalizations(_l10n);
    }
  }

  /// Re-reads the OS layer and brings state + cache in line. Never shows a
  /// dialog — the only place allowed to ask is [_setNotificationsEnabled].
  Future<void> _applyOsPermission(LocalCache cache) async {
    final granted = await _osDeliversNotifications();
    if (_disposed) return;

    if (granted == null) {
      // Unknown (service without probe): claim nothing, invalidate nothing.
      // No `active` (green toggle without proof), no rewrite of the opt-in,
      // no cancelAll.
      return;
    }

    if (granted) {
      _setReminderState(ReminderState.active);
      await cache.writeNotificationsEnabled(true);
      await _rescheduleStreakReminder();
      return;
    }

    // Third state: the user WANTS reminders, the OS refuses. The persisted
    // flag claims "active" and is provably wrong, so it falls — otherwise the
    // next cold start plans into the void again.
    _setReminderState(ReminderState.blocked);
    await cache.writeNotificationsEnabled(false);
    await notificationService.cancelAll();
  }

  /// Whether the OS currently delivers — three-valued, null means "not
  /// determinable". Services without [NotificationPermissionProbe] (older
  /// test doubles; both production implementations carry it) cannot answer.
  /// Unknown no longer claims anything; [_applyOsPermission] evaluates it.
  Future<bool?> _osDeliversNotifications() async {
    // Cast needed because [NotificationPermissionProbe] is deliberately NOT a
    // subtype of [NotificationService] (that would break every existing
    // `implements NotificationService` double), so Dart does not promote.
    final Object service = notificationService;
    if (service is! NotificationPermissionProbe) return null;
    return service.hasPermission();
  }

  void _setReminderState(ReminderState state) {
    if (_disposed) {
      _reminderState = state;
      return;
    }
    if (state == _reminderState) return;
    _mutate(() => _reminderState = state);
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    final cache = _notificationCache;

    if (!enabled) {
      _setReminderState(ReminderState.off);
      await cache?.writeNotificationsEnabled(false);
      await notificationService.cancelAll();
      return;
    }

    final bool granted;
    try {
      _syncNotificationLocale();
      await notificationService.init();
      // D11: ask first, THEN persist. Previously `true` sat in the cache
      // before the system dialog was even answered, and stayed on "Don't
      // allow".
      granted = await notificationService.requestPermission();
    } catch (e, st) {
      // Same fence as the cold start: blocked instead of a zone error.
      unawaited(CrashReporter.capture(e, st, context: 'notifications-opt-in'));
      if (_disposed) return;
      _setReminderState(ReminderState.blocked);
      await cache?.writeNotificationsEnabled(false);
      return;
    }
    if (_disposed) return;

    if (!granted) {
      _setReminderState(ReminderState.blocked);
      await cache?.writeNotificationsEnabled(false);
      return;
    }

    _setReminderState(ReminderState.active);
    await cache?.writeNotificationsEnabled(true);
    await _rescheduleStreakReminder();
  }

  /// Replans the evening streak reminders for the full horizon (4 weeks, see
  /// streak_reminder_planner.dart). scheduleAll is cancel-first, so always
  /// pass the full planner list — no duplicates on repeated calls. Guard:
  /// never plans without granted permission.
  Future<void> _rescheduleStreakReminder() async {
    if (_reminderState != ReminderState.active) return;
    await notificationService.scheduleAll(
      planStreakReminders(DateTime.now(), lifetimeStats, _l10n),
    );
  }

  /// Turns reminders on/off (settings toggle). Public facade for the shell.
  Future<void> setNotificationsEnabled(bool enabled) =>
      _setNotificationsEnabled(enabled);

  /// Re-reads the OS permission and corrects the state — WITHOUT a dialog.
  ///
  /// The way back out of [ReminderState.blocked]: the shell calls this on
  /// resume, after the user has been in the system settings. Nothing happens
  /// for [ReminderState.off].
  Future<void> refreshNotificationPermission() async {
    if (_reminderState == ReminderState.off) return;
    final cache = _notificationCache;
    if (cache == null) return;
    await _syncWithOsGuarded(cache, context: 'notifications-refresh');
  }

  /// Cold-start path as a public facade — boot calls it from
  /// `_hydrateThenBoot`, tests without Supabase sync call it directly.
  @visibleForTesting
  Future<void> initNotificationsFromCache() => _initNotificationsFromCache();

  // --- Settings / Onboarding ------------------------------------------------

  /// Applies the profile + flags edited in "Profil & Ziele" (the screen itself
  /// lives in the context-carrying shell).
  ///
  /// Gap D: the save goes through [_syncOrQueue] and thus the outbox — a
  /// direct Supabase write left offline edits in the cache only, and the next
  /// online boot overwrote them with the old server row. All profile ops share
  /// an entity key, so offline edits coalesce; last one wins. Not awaited —
  /// delivery is the outbox's job.
  Future<void> applySettings({
    required UserProfile newProfile,
    required bool notificationsEnabled,
  }) async {
    // `this.` is needed because the parameter shadows the getter. Compared
    // against the ACTUAL state: in [ReminderState.blocked] the getter is
    // false, so flipping to ON runs the permission flow again.
    if (notificationsEnabled != this.notificationsEnabled) {
      unawaited(_setNotificationsEnabled(notificationsEnabled));
    }
    final canPersistProfile = _hydratedFromRealSource;
    _mutate(() => profile = newProfile);
    if (sync == null) return;
    if (!canPersistProfile) {
      // Clobber guard (A1): without a real hydration source `profile` is just
      // ctor defaults. A queued default op would even retry them onto the
      // server — worse than the old direct save.
      dev.log(
          'ProfileSync.save uebersprungen: profile basiert auf Ctor-Defaults '
          '(kein Server-/Cache-Hydrate) — Clobber-Schutz',
          name: 'eatova_sync');
      return;
    }
    unawaited(_cache?.writeProfile(newProfile) ?? Future<void>.value());
    _syncOrQueue(
      'Profil-Sync',
      () => sync!.profile.save(newProfile),
      () => SyncOp.profileUpsert(newProfile),
    );
  }

  // `resetTodayData()`/`_clearTodayState()` were removed with "reset day
  // data". The `_lastKnownToday` note in home_store.dart still names
  // `_clearTodayState`; its argument (date compare, not a flag) holds anyway.

  /// Completes the mandatory onboarding.
  ///
  /// Gap D applies harder here: the server row usually exists already (signup
  /// trigger, `onboarding_completed = false`), so an offline-completed
  /// onboarding was not just forgotten — boot read the bootstrap row, dropped
  /// the entered body data and sent the user through onboarding again. Runs
  /// through the outbox now.
  Future<void> completeOnboarding(UserProfile finished) async {
    _mutate(() {
      profile = finished;
      _onboardingDone = true;
      // Data came from the user, not from ctor defaults — the state is a real
      // source from here on, and so is the op below.
      _hydratedFromRealSource = true;
    });
    if (sync == null) return;
    unawaited(_cache?.writeProfile(finished) ?? Future<void>.value());
    unawaited(_setNotificationsEnabled(true));
    _syncOrQueue(
      'Profil-Sync (Onboarding)',
      () => sync!.profile.save(finished),
      () => SyncOp.profileUpsert(finished),
    );
  }
}
