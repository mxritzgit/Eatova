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
/// Builds on the tracking part: settled commits, the onboarding weigh-in.
mixin _HomeStoreProfilePart
    on _HomeStoreBase, _HomeStoreSyncPart, _HomeStoreTrackingPart {
  ReminderState _reminderState = ReminderState.off;
  bool _onboardingDone = false;
  Future<void>? _onboardingCompletion;
  int _notificationRevision = 0;
  int? _notificationOptInRevision;

  bool _notificationRequestIsCurrent(int revision) =>
      !_disposed &&
      !_notificationSessionEnded &&
      revision == _notificationRevision;

  /// P2-02: the auth client switches its session BEFORE the gate cancels the
  /// reminders and disposes this store, so a schedule from this store's late
  /// continuation would land after that cancel. Same owner and session test
  /// as `_ensureMutationActive`, without its cache conditions.
  bool get _accountStillSignedIn {
    final auth = sync?.client.auth;
    if (auth == null) return true;
    final owner = auth.currentUser;
    if (owner != null && owner.id != sync?.userId) return false;
    final bound = _boundSyncSessionId;
    return bound == null ||
        bound ==
            syncSessionIdFromAccessToken(
              auth.currentSession?.accessToken ?? '',
            );
  }

  /// Whether anything actually fires in the evening. True only for
  /// [ReminderState.active] — "blocked" is not "on" (D11).
  bool get notificationsEnabled => _reminderState == ReminderState.active;

  /// Full state for the shell (text + action, see [ReminderState]).
  ReminderState get reminderState => _reminderState;

  /// C4: the chosen reminder time, 20:00 until the user picks another.
  ReminderTime get reminderTime => _reminderTime;
  ReminderTime _reminderTime = ReminderTime.standard;

  /// The user picked a time in this session; a later cache read keeps it.
  bool _reminderTimeChosen = false;

  /// Today's one-time reminder card was answered, or made moot by a choice
  /// in the settings. Null until this account's cache was read: without a
  /// cache the card never shows, as "never again" could not be kept.
  bool? _reminderPromptAnswered;

  /// C4: Today offers the reminder once — after logs on two different days,
  /// only while reminders are off, and never again after any answer.
  bool get reminderPromptVisible =>
      _reminderPromptAnswered == false &&
      _reminderState == ReminderState.off &&
      !_notificationSessionEnded &&
      loggedOnTwoDays(loggedMeals, lifetimeStats);

  /// Onboarding is mandatory once a real Supabase sync exists and the profile
  /// has not been completed. Never without sync (test/preview).
  bool get needsOnboarding =>
      sync != null && !_onboardingDone && !profile.onboardingCompleted;

  // --- Reminders (PROD-1) ---------------------------------------------------
  // Only content: the evening streak saver (streak_reminder_planner.dart).
  // The opt-in toggle + permission flow stay the hook for anything further.

  /// Cache on the boot path. `_cache` is only set after `_hydrateThenBoot`;
  /// tests fall back to the injected [debugCache], like `_clearCache`.
  LocalCache? get _notificationCache => _cache ?? debugCache;

  /// Cold-start path for reminders.
  ///
  /// D11: the cache only holds what was true at opt-in, so re-check the OS
  /// with [NotificationPermissionProbe.hasPermission] (silent) — never
  /// `requestPermission()`, which would ambush the user with a dialog.
  Future<void> _initNotificationsFromCache() async {
    if (_disposed || _notificationSessionEnded) return;
    final cache = _notificationCache;
    if (cache == null) return;
    // C4: time and card answer first, so the first plan uses the chosen time.
    await _loadReminderPreferences(cache);
    // Hydration may finish after a user has already changed the preference.
    if (_disposed || _notificationSessionEnded || _notificationRevision != 0) {
      return;
    }
    final revision = _notificationRevision;
    final enabled = await cache.readNotificationsEnabled() ?? false;
    if (!_notificationRequestIsCurrent(revision)) return;
    // Opted in before the card existed: the card has nothing to offer.
    if (enabled) unawaited(_markReminderPromptAnswered());
    // No opt-in -> the OS is never asked for permission. P2-02: but what an
    // earlier account on this device scheduled is still cancelled. The gate
    // cancels on every session end it sees; this covers one it did not.
    if (!enabled) {
      try {
        await _cancelStaleSchedules();
      } catch (e, st) {
        unawaited(CrashReporter.capture(e, st,
            context: 'notifications-cold-start-cancel'));
      }
      return;
    }

    await _syncWithOsGuarded(
      cache,
      context: 'notifications-cold-start',
      revision: revision,
    );
  }

  /// init + OS re-check, fenced (F7-12 / F1-09): a PlatformException from the
  /// plugin used to escape as an unhandled zone error on every cold start.
  /// Now the user lands in [ReminderState.blocked] — they opted in, the OS
  /// layer is unusable right now — and the error goes to [CrashReporter].
  /// The opt-in flag stays untouched: nothing was proven either way.
  Future<void> _syncWithOsGuarded(
    LocalCache cache, {
    required String context,
    required int revision,
  }) async {
    try {
      _syncNotificationLocale();
      await notificationService.init();
      if (!_notificationRequestIsCurrent(revision)) return;
      await _applyOsPermission(cache, revision);
    } catch (e, st) {
      unawaited(CrashReporter.capture(e, st, context: context));
      if (!_notificationRequestIsCurrent(revision)) return;
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
  Future<void> _applyOsPermission(LocalCache cache, int revision) async {
    final granted = await _osDeliversNotifications();
    if (!_notificationRequestIsCurrent(revision)) return;

    if (granted == null) {
      // Unknown (service without probe): claim nothing, invalidate nothing.
      // No `active` (green toggle without proof), no rewrite of the opt-in,
      // no cancelAll.
      return;
    }

    if (granted) {
      _setReminderState(ReminderState.active);
      await cache.writeNotificationsEnabled(true);
      if (!_notificationRequestIsCurrent(revision)) return;
      await _rescheduleStreakReminder();
      return;
    }

    // Third state: the user WANTS reminders, the OS refuses. The persisted
    // flag claims "active" and is provably wrong, so it falls — otherwise the
    // next cold start plans into the void again.
    _setReminderState(ReminderState.blocked);
    await cache.writeNotificationsEnabled(false);
    if (!_notificationRequestIsCurrent(revision)) return;
    await _cancelReminderNudges();
  }

  /// Reminder paths cancel the nudges only, so a running rest alert survives
  /// an opt-out (spec A5). A service without the seam schedules nothing else.
  Future<void> _cancelReminderNudges() {
    final Object service = notificationService;
    if (service is NotificationScopedCancel) return service.cancelNudges();
    return notificationService.cancelAll();
  }

  /// Cold-start backstop: everything an earlier session left goes, but not
  /// a rest alert the player already resumed during this boot, and the
  /// restored workout's alerts are planned again: the backstop also clears
  /// the ones the previous process planned, and only the player plans them
  /// otherwise (spec A5: a running rest survives a process death).
  Future<void> _cancelStaleSchedules() {
    final Object service = notificationService;
    if (service is NotificationScopedCancel) {
      return service.cancelStaleSchedules(restore: _restoredRestAlerts());
    }
    return notificationService.cancelAll();
  }

  /// The alerts of this account's restored workout checkpoint.
  List<PlannedRestAlert> _restoredRestAlerts() {
    final snapshot = trainingSession;
    if (snapshot == null || !_accountStillSignedIn) return const [];
    return plannedRestAlertsFor(snapshot, _l10n);
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
    if (_disposed || _notificationSessionEnded) return;
    // A later user choice wins over every earlier permission request/probe.
    final revision = ++_notificationRevision;
    _notificationOptInRevision = enabled ? revision : null;
    // Any explicit choice answers Today's reminder card too (C4).
    unawaited(_markReminderPromptAnswered());
    final cache = _notificationCache;

    if (!enabled) {
      _setReminderState(ReminderState.off);
      await cache?.writeNotificationsEnabled(false);
      if (!_notificationRequestIsCurrent(revision)) return;
      await _cancelReminderNudges();
      return;
    }

    final bool granted;
    try {
      _syncNotificationLocale();
      await notificationService.init();
      if (!_notificationRequestIsCurrent(revision)) return;
      // D11: ask first, THEN persist. Previously `true` sat in the cache
      // before the system dialog was even answered, and stayed on "Don't
      // allow".
      granted = await notificationService.requestPermission();
    } catch (e, st) {
      // Same fence as the cold start: blocked instead of a zone error.
      unawaited(CrashReporter.capture(e, st, context: 'notifications-opt-in'));
      if (!_notificationRequestIsCurrent(revision)) return;
      _setReminderState(ReminderState.blocked);
      await cache?.writeNotificationsEnabled(false);
      return;
    } finally {
      if (_notificationOptInRevision == revision) {
        _notificationOptInRevision = null;
      }
    }
    if (!_notificationRequestIsCurrent(revision)) return;

    if (!granted) {
      _setReminderState(ReminderState.blocked);
      await cache?.writeNotificationsEnabled(false);
      return;
    }

    _setReminderState(ReminderState.active);
    await cache?.writeNotificationsEnabled(true);
    if (!_notificationRequestIsCurrent(revision)) return;
    await _rescheduleStreakReminder();
  }

  /// Replans the evening streak reminders for the full horizon (4 weeks, see
  /// streak_reminder_planner.dart). scheduleAll is cancel-first, so always
  /// pass the full planner list — no duplicates on repeated calls. Guard:
  /// never plans without granted permission.
  Future<void> _rescheduleStreakReminder() async {
    if (_disposed ||
        _notificationSessionEnded ||
        _reminderState != ReminderState.active ||
        !_accountStillSignedIn) {
      return;
    }
    await notificationService.scheduleAll(
      planStreakReminders(clock.now(), lifetimeStats, _l10n, _reminderTime),
    );
  }

  /// A re-plan outside the opt-in flows: a plugin failure is reported, never
  /// thrown at the caller (same fence as [_syncWithOsGuarded]).
  Future<void> _rescheduleGuarded(String context) async {
    try {
      await _rescheduleStreakReminder();
    } catch (e, st) {
      unawaited(CrashReporter.capture(e, st, context: context));
    }
  }

  /// Turns reminders on/off (settings toggle). Public facade for the shell.
  Future<void> setNotificationsEnabled(bool enabled) =>
      _setNotificationsEnabled(enabled);

  // --- Reminder time and Today's card (C4) ----------------------------------

  /// Reads the chosen time and the card's answer for this account.
  Future<void> _loadReminderPreferences(LocalCache cache) async {
    final stored = await cache.readReminderTime();
    final answered = await cache.readReminderPromptAnswered();
    if (_disposed || _notificationSessionEnded) return;
    final adopt =
        stored != null && !_reminderTimeChosen && stored != _reminderTime;
    final nextAnswered = (_reminderPromptAnswered ?? false) || answered;
    if (adopt || nextAnswered != _reminderPromptAnswered) {
      _mutate(() {
        if (adopt) _reminderTime = stored;
        _reminderPromptAnswered = nextAnswered;
      });
    }
    // Choices made before the cache was open are persisted now.
    if (_reminderTimeChosen && stored != _reminderTime) {
      unawaited(cache.writeReminderTime(_reminderTime));
    }
    if (_reminderPromptAnswered == true && !answered) {
      unawaited(cache.writeReminderPromptAnswered());
    }
    // Only an opt-in during the boot load can have planned before this read.
    if (adopt) await _rescheduleGuarded('notifications-time-load');
  }

  /// Records the card as answered: in memory at once, then per account.
  Future<void> _markReminderPromptAnswered() async {
    if (_disposed || _reminderPromptAnswered == true) return;
    _mutate(() => _reminderPromptAnswered = true);
    await _notificationCache?.writeReminderPromptAnswered();
  }

  /// Sets the reminder time and re-plans at once when reminders are on. Kept
  /// per account while they are off too, so turning them on keeps the choice.
  Future<void> setReminderTime(ReminderTime time) async {
    if (_disposed || _notificationSessionEnded) return;
    _reminderTimeChosen = true;
    if (time == _reminderTime) return;
    _mutate(() => _reminderTime = time);
    await _notificationCache?.writeReminderTime(time);
    await _rescheduleGuarded('notifications-time-change');
  }

  /// The card's "yes": the regular opt-in with its permission dialog. Returns
  /// the resulting state, so the shell can say honestly what happened.
  Future<ReminderState> acceptReminderPrompt() async {
    await _setNotificationsEnabled(true);
    return _reminderState;
  }

  /// The card's "no thanks": it never shows again for this account.
  Future<void> dismissReminderPrompt() => _markReminderPromptAnswered();

  /// Re-reads the OS permission and corrects the state — WITHOUT a dialog.
  ///
  /// The way back out of [ReminderState.blocked]: the shell calls this on
  /// resume, after the user has been in the system settings. Nothing happens
  /// for [ReminderState.off].
  Future<void> refreshNotificationPermission() async {
    if (_disposed ||
        _notificationSessionEnded ||
        // A permission sheet can resume the app before its result arrives.
        // Its explicit answer takes precedence over a passive, older OS read.
        _notificationOptInRevision != null ||
        _reminderState == ReminderState.off) {
      return;
    }
    final cache = _notificationCache;
    if (cache == null) return;
    await _syncWithOsGuarded(
      cache,
      context: 'notifications-refresh',
      revision: ++_notificationRevision,
    );
  }

  /// Cold-start path as a public facade — boot calls it from
  /// `_hydrateThenBoot`, tests without Supabase sync call it directly.
  @visibleForTesting
  Future<void> initNotificationsFromCache() => _initNotificationsFromCache();

  // --- Settings / Onboarding ------------------------------------------------

  /// Applies the profile + flags edited in "Profil & Ziele" (the screen itself
  /// lives in the context-carrying shell).
  ///
  /// Gap D: the save goes through `_syncOrQueue` and thus the outbox — a
  /// direct Supabase write left offline edits in the cache only, and the next
  /// online boot overwrote them with the old server row. All profile ops share
  /// an entity key and replay in order, so the last edit wins. Not awaited —
  /// delivery is the outbox's job.
  Future<void> applySettings({
    required UserProfile newProfile,
    required bool notificationsEnabled,
  }) async {
    if (sync != null && !_hydratedFromRealSource) {
      throw StateError('Profile storage is not ready');
    }
    await _commitSyncIntents([
      SyncOp.profileUpsert(newProfile),
    ], publish: () => profile = newProfile);
    // Request OS permission only after the profile save is durable. A failed
    // save leaves the form open and must not apply a draft reminder choice.
    if (notificationsEnabled != this.notificationsEnabled) {
      unawaited(_setNotificationsEnabled(notificationsEnabled));
    }
  }

  // --- Food preferences (F8, C3) -------------------------------------------

  /// Saves diet, avoided foods and dislikes from the profile's editor.
  ///
  /// Derived from the PUBLISHED profile once pending local commits settled,
  /// so a goals save in flight lands first and only these three fields
  /// change. One profile op through the outbox, like [applySettings]. The
  /// recipe shelves and the coach read [profile], so both follow at once.
  Future<void> updateFoodPreferences(FoodPreferences preferences) async {
    if (sync != null && !_hydratedFromRealSource) {
      throw StateError('Profile storage is not ready');
    }
    await _settledLocalMutations();
    final next = profile.copyWith(
      diet: preferences.diet,
      foodAvoidances: preferences.avoidances,
      foodDislikes: preferences.dislikes,
    );
    await _commitSyncIntents([
      SyncOp.profileUpsert(next),
    ], publish: () => profile = next);
  }

  /// The preferences a /recipe request carries, or null when nothing is set
  /// (the request then has no `preferences` field at all).
  FoodPreferences? get coachRecipePreferences {
    final preferences = profile.foodPreferences;
    return preferences.isEmpty ? null : preferences;
  }

  /// The coach context line for diet, avoided foods and dislikes, or null
  /// when nothing is set. German like the rest of the context (labels from
  /// [deL10n]); the dislikes are user text and travel inside the context the
  /// server frames and filters.
  @override
  String? _foodPreferencesContext() {
    final p = profile.foodPreferences;
    if (p.isEmpty) return null;
    final avoided = sortedFoodAvoidances(
      p.avoidances,
    ).map((a) => a.label(deL10n)).join(', ');
    final parts = <String>[
      if (p.diet != DietPreference.none) 'Kostform ${p.diet.label(deL10n)}',
      if (avoided.isNotEmpty) 'meidet $avoided',
      if (p.dislikes.isNotEmpty) 'mag nicht: ${p.dislikes}',
    ];
    return 'Laut Profil: ${parts.join('; ')}.';
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
  ///
  /// The entered weight also becomes the first weigh-in when the account has
  /// none (2026-10-19), in the same commit.
  Future<void> completeOnboarding(UserProfile finished) {
    final pending = _onboardingCompletion;
    if (pending != null) return pending;
    late final Future<void> completion;
    completion =
        Future<void>.sync(() async {
          _ensureMutationActive();
          if (_onboardingDone) return;
          final weighIn = _onboardingWeighIn(finished);
          await _commitSyncIntents(
            [SyncOp.profileUpsert(finished), if (weighIn != null) weighIn.op],
            publish: () {
              profile = finished;
              _onboardingDone = true;
              _hydratedFromRealSource = true;
              if (weighIn != null) {
                weightLog = weightLog.addEntry(weighIn.entry);
                lifetimeStats = lifetimeStats.incrementWeightLogs();
              }
            },
          );
        }).whenComplete(() {
          if (identical(_onboardingCompletion, completion)) {
            _onboardingCompletion = null;
          }
        });
    _onboardingCompletion = completion;
    return completion;
  }
}
