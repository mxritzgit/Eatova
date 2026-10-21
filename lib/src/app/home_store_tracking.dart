part of 'home_store.dart';

/// Tracking part of [HomeStore]: weight logging (manual, and the scale
/// import from Apple Health or Health Connect), the health connection per
/// account, the health snapshot (steps) and the server-side streak day
/// (record_tracking_day).
mixin _HomeStoreTrackingPart on _HomeStoreBase, _HomeStoreSyncPart {
  // healthAuthState lives in _HomeStoreBase next to dailySteps: the logout
  // path in _HomeStoreSyncPart must reset it on user switch (B3), and sync
  // does not depend on this mixin, so it could never see a field declared
  // here.
  DateTime? healthLastFetch;
  bool healthSyncing = false;
  bool _healthConnectedByUser = false;

  /// When this account first connected Health Connect, which answers back to
  /// 30 days before the first grant ([_healthConnectReadableDays]).
  DateTime? _healthConnectedSince;

  /// Daily activity: steps plus estimated burned kcal per local calendar day
  /// (key: [localDayKey]).
  ///
  /// Today's entry is upserted on every verified health refresh, so the last
  /// refresh of a day is its final value; past days are topped up once per
  /// session by [_maybeBackfillDailyActivity].
  ///
  /// Mutation REPLACES the map: the shell's slice selectors compare by
  /// identity (G11 pattern, see eatova_home_page).
  Map<String, ({int steps, int kcal})> dailyActivity =
      <String, ({int steps, int kcal})>{};

  /// Days this session already attempted a backfill for, so revisiting an
  /// archive day does not cost a health query on every tap.
  final Set<String> _dailyActivityBackfillAttempted = <String>{};

  /// Older entries drop out of the map on upsert; a forever-growing blob is
  /// not worth more than a year of history.
  static const Duration _dailyActivityRetention = Duration(days: 400);

  /// The server answered the weight-log load in this session; the boot flag
  /// lives in [HomeStore].
  bool get _serverAnsweredWeightLog;

  /// Apple Health's first permission sheet waits for this account's answer
  /// to Today's intro card, see [healthIntroVisible].
  _HealthIntro _healthIntro = _HealthIntro.unknown;

  /// This account's answer to the scale import (review 2026-10-22), kept in
  /// the encrypted cache (`health_weight_import`).
  _WeightImport _weightImport = _WeightImport.unknown;

  /// The newest weigh-in a read returned: after a long pause the next read
  /// reaches back to it ([_weightImportFrom]).
  DateTime? _weightImportSince;

  /// Readings already imported or deleted ([_weightSampleKey]): neither
  /// comes in (again), also after a restart or an edit of the weigh-in.
  Set<String> _weightImportSeen = <String>{};

  /// New weigh-ins the last read found while the account has not answered;
  /// Today's question offers them ([healthWeightImportOfferVisible]).
  int _weightImportOffer = 0;
  bool _weightImportRunning = false;

  /// A read waited for the weight log's server answer: against a log still
  /// loading (fresh sign-in, cold start) every weigh-in would look new.
  bool _weightImportDeferred = false;

  /// Every read covers at least this window, so a scale that syncs late
  /// still lands, de-duplicated against the log.
  static const Duration _weightImportLookback = Duration(days: 30);

  /// After a longer pause the read reaches back to the last one, at most
  /// this far.
  static const Duration _weightImportMaxLookback = Duration(days: 90);

  /// One read imports at most this many; the rest follow with the next.
  static const int _weightImportMaxPerRead = 60;

  // --- Health ---------------------------------------------------------------

  /// Called once the account's encrypted cache has been resolved at boot.
  Future<void> restoreHealthConnection() async {
    final service = health;
    if (_disposed || _healthSessionEnded) return;
    // Read before the first await: the boot calls this right after the cache
    // hydration, so a completed profile here was cached by an earlier session
    // of this account on this device (signing out clears the cache).
    final cachedAccount = _hydratedFromRealSource && profile.onboardingCompleted;
    final generation = _healthGeneration;
    if (service is! HealthConnectAccess) {
      // Before the intro: its answer lets the shell connect and read.
      await _loadWeightImport();
      if (_disposed || generation != _healthGeneration) return;
      await _loadHealthIntro(connectedWhenUnset: cachedAccount);
      return;
    }
    final cache = _cache ?? debugCache;
    if (cache != null) {
      if (_healthConnectedByUser) {
        await _persistHealthConnectOptIn();
      } else {
        final enabled = await cache.readHealthConnectEnabled();
        if (_disposed || generation != _healthGeneration) return;
        if (enabled) {
          (service as HealthConnectAccess).restoreConnection();
          _healthConnectedByUser = true;
          final since = await cache.readHealthConnectSince();
          if (_disposed || generation != _healthGeneration) return;
          // An opt-in an older build stored: the grant is at least as old as
          // today, and from now on the date is known.
          if (since == null) {
            await _persistHealthConnectOptIn();
          } else {
            _healthConnectedSince = since;
          }
        }
      }
    }
    if (_disposed || generation != _healthGeneration) return;
    // Today's Health Connect card (2026-10-22); not in tests and previews.
    if (sync != null) {
      await _loadWeightImport();
      if (_disposed || generation != _healthGeneration) return;
      await _loadHealthIntro(connectedWhenUnset: _healthConnectedByUser);
      if (_disposed || generation != _healthGeneration) return;
    }
    await refreshHealthSteps();
  }

  // --- Health intro per account (reviews 2026-10-19 and 2026-10-22) ----------

  /// Whether the shell may ask HealthKit without a tap: only once this
  /// account connected Apple Health itself. The grant belongs to the device,
  /// so a second account would otherwise read the first person's steps and
  /// weight, and write its weigh-ins into their Apple Health. Without sync
  /// (tests, previews) there is no account to wait for.
  bool get healthAutoConnectAllowed {
    if (sync == null) return true;
    if (_needsOnboardingForHealth) return false;
    return _healthIntro == _HealthIntro.connected;
  }

  /// Whether this account connected its health source itself.
  bool get _healthAccountOptedIn => health is HealthConnectAccess
      ? _healthConnectedByUser
      : sync == null || _healthIntro == _HealthIntro.connected;

  /// Whether the store may read from or write to the health source. Health
  /// Connect's service checks the per-account opt-in on every read and
  /// writes nothing; HealthKit's grant belongs to the device, so its reads
  /// and writes wait for this account's own connect.
  bool get _healthAccessAllowed =>
      health is HealthConnectAccess || _healthAccountOptedIn;

  /// Today's card that explains the health source before its permission
  /// prompt: until this account connects or says "Not now". On Health
  /// Connect only while the device offers it and the account is not
  /// connected yet.
  bool get healthIntroVisible =>
      _healthIntro == _HealthIntro.pending &&
      !_needsOnboardingForHealth &&
      !_healthSessionEnded &&
      switch (health.authState) {
        HealthAuthState.unsupported || HealthAuthState.unavailable => false,
        _ => true,
      } &&
      !(health is HealthConnectAccess && _healthConnectedByUser);

  /// Health Connect is this account's connected step source: a day without
  /// steps then says so on Today instead of dropping the row. Accounts that
  /// never connected or declined see the intro card or nothing.
  bool get healthConnectLinked =>
      health is HealthConnectAccess && _healthConnectedByUser;

  /// Provided by the profile part ([HomeStore.needsOnboarding]).
  bool get _needsOnboardingForHealth;

  /// Reads this account's intro state. Unset means no build since
  /// 2026-10-19 asked this account on this device: [connectedWhenUnset]
  /// keeps an existing connection (HealthKit: the account was cached here
  /// before, when HealthKit connected on its own; Health Connect: its own
  /// opt-in), anything else gets the card. Written back either way, so the
  /// next cold start no longer mistakes a new account for an old one.
  Future<void> _loadHealthIntro({required bool connectedWhenUnset}) async {
    final cache = _cache ?? debugCache;
    final generation = _healthGeneration;
    final stored = await cache?.readHealthPrompt();
    if (_disposed || generation != _healthGeneration) return;
    // A card answered or offered during the read wins.
    if (_healthIntro != _HealthIntro.unknown) return;
    final next = switch (stored) {
      'pending' => _HealthIntro.pending,
      'dismissed' => _HealthIntro.dismissed,
      'connected' => _HealthIntro.connected,
      _ => connectedWhenUnset ? _HealthIntro.connected : _HealthIntro.pending,
    };
    _mutate(() => _healthIntro = next);
    if (stored == null) {
      await cache?.writeHealthPrompt(
        next == _HealthIntro.connected ? 'connected' : 'pending',
      );
    }
  }

  /// The onboarding is finishing: the health source waits for Today's card
  /// instead of asking unprompted. Called inside the onboarding's publish,
  /// so the very notify that ends the onboarding already closes the shell's
  /// unprompted path. Only while the source was never asked in this session.
  void _deferHealthToIntro() {
    if (_disposed ||
        _healthSessionEnded ||
        health.authState != HealthAuthState.unknown ||
        _healthIntro == _HealthIntro.connected ||
        (health is HealthConnectAccess && _healthConnectedByUser)) {
      return;
    }
    _healthIntro = _HealthIntro.pending;
    unawaited((_cache ?? debugCache)?.writeHealthPrompt('pending'));
  }

  /// The card's connect action: asks the health source, which records the
  /// answer.
  Future<void> acceptHealthIntro() => connectHealth();

  /// A connect is this account's own answer: from here HealthKit may be
  /// asked as before, also on the next cold start, and Health Connect's card
  /// is gone. Runs inside the mutation that marks the connect in flight, so
  /// the shell cannot start a second one.
  void _recordHealthIntroAnswered() {
    if (_healthIntro == _HealthIntro.connected) return;
    _healthIntro = _HealthIntro.connected;
    unawaited((_cache ?? debugCache)?.writeHealthPrompt('connected'));
  }

  /// "Not now": the card goes and the source is not asked unprompted again;
  /// the profile's Health card still connects.
  Future<void> dismissHealthIntro() async {
    if (_disposed || _healthSessionEnded) return;
    _mutate(() => _healthIntro = _HealthIntro.dismissed);
    await (_cache ?? debugCache)?.writeHealthPrompt('dismissed');
  }

  Future<void> connectHealth() async {
    if (_disposed || _healthSessionEnded || healthSyncing) return;
    final generation = _healthGeneration;
    _mutate(() {
      healthSyncing = true;
      _recordHealthIntroAnswered();
    });
    final state = await health.requestAuthorization();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() => healthAuthState = state);
    if (state == HealthAuthState.granted) {
      if (health is HealthConnectAccess) {
        _healthConnectedByUser = true;
        await _persistHealthConnectOptIn();
        if (_disposed || generation != _healthGeneration) return;
      }
      _dailyActivityBackfillAttempted.clear();
      healthSyncing = false;
      await refreshHealthSteps();
    } else {
      _mutate(() {
        healthSyncing = false;
        if (health is HealthConnectAccess) {
          dailySteps = 0;
          healthLastFetch = null;
        }
      });
    }
  }

  /// Keeps this account's Health Connect opt-in for the next cold start,
  /// with the date of its first connect.
  Future<void> _persistHealthConnectOptIn() async {
    _healthConnectedSince ??= clock.now();
    await (_cache ?? debugCache)?.writeHealthConnectEnabled(
      true,
      since: _healthConnectedSince,
    );
  }

  Future<void> refreshHealthSteps() async {
    await _refreshHealthSteps(allowDayCatchUp: true);
    _retryDeferredDailyActivity();
  }

  /// Reads window days again whose backfill ran outside the foreground; the
  /// energy-check part implements it.
  void _retryDeferredDailyActivity();

  Future<void> _refreshHealthSteps({required bool allowDayCatchUp}) async {
    if (_disposed || _healthSessionEnded || healthSyncing) return;
    if (!_healthAccessAllowed) return;
    final generation = _healthGeneration;
    final requestedDay = DateUtils.dateOnly(clock.now().toLocal());
    _mutate(() => healthSyncing = true);
    if (_disposed || generation != _healthGeneration) return;
    final snapshot = await health.readSnapshot();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() {
      healthSyncing = false;
      // B3: the service re-verifies the permission on every refresh and can
      // fall back from granted to unverified/denied, so adopt its state in
      // BOTH branches instead of only upgrading on success.
      healthAuthState = health.authState;
      if (snapshot != null) {
        final fetchedAt = snapshot.fetchedAt.toLocal();
        dailySteps = snapshot.stepsToday;
        healthLastFetch = fetchedAt;
        // Pin to the SNAPSHOT's day, not "today": a refresh at the midnight
        // second still belongs to the query time.
        _recordDailyActivity(fetchedAt, snapshot.stepsToday);
      } else if (health is HealthConnectAccess) {
        dailySteps = 0;
        healthLastFetch = null;
      }
      // iOS retains its last measured value when read access is unverified.
    });
    if (_disposed || generation != _healthGeneration) return;
    // Health Connect reads only after this account's own opt-in, so a grant
    // first seen here (allowed in the Health Connect settings after a denied
    // prompt) is that opt-in: keep it for the next cold start.
    if (health is HealthConnectAccess &&
        healthAuthState == HealthAuthState.granted &&
        !_healthConnectedByUser) {
      _healthConnectedByUser = true;
      await _persistHealthConnectOptIn();
      if (_disposed || generation != _healthGeneration) return;
    }
    // Scale weigh-ins since the last read (2026-10-22).
    if (_healthReadable) await _syncHealthWeights();
    if (_disposed || generation != _healthGeneration) return;
    // A midnight refresh may have hit the in-flight guard. Catch up once;
    // a failed or repeatedly delayed provider must not create a retry loop.
    final today = clock.now().toLocal();
    if (allowDayCatchUp &&
        !_isSameFoodDate(requestedDay, today) &&
        stepsForFoodDate(today) == null) {
      await _refreshHealthSteps(allowDayCatchUp: false);
    }
  }

  Future<void> openHealthSettings() async {
    final service = health;
    if (_disposed ||
        _healthSessionEnded ||
        healthSyncing ||
        service is! HealthConnectAccess) {
      return;
    }
    final generation = _healthGeneration;
    _mutate(() => healthSyncing = true);
    await (service as HealthConnectAccess).openSettings();
    if (_disposed || generation != _healthGeneration) return;
    _mutate(() {
      healthSyncing = false;
      healthAuthState = health.authState;
    });
  }

  /// Burned kcal for [date]: live from [dailySteps] today, the pinned value
  /// from [dailyActivity] for past days. 0 means "no entry".
  ///
  /// Every step counts (kcal review 2026-08-21): the daily goal uses a PAL
  /// ladder WITHOUT walking (`ActivityLevel.palFactor`), so the full step sum
  /// is not double counting.
  @override
  int burnedKcalForFoodDate(DateTime date) {
    final localDate = date.toLocal();
    if (_isSameFoodDate(localDate, clock.now().toLocal())) {
      final steps = stepsForFoodDate(localDate);
      if (steps == null) return 0;
      return estimateKcalBurnedFromSteps(
        steps: steps,
        weightKg: profile.weightKg,
        heightCm: profile.heightCm,
        sex: profile.sex,
      );
    }
    return dailyActivity[localDayKey(localDate)]?.kcal ?? 0;
  }

  /// Step count for [date] — live today, pinned for past days. `null` means
  /// "no step source", which hides the steps card instead of claiming 0.
  ///
  /// Only a snapshot from this local day proves today's value. Permission
  /// alone cannot distinguish an unavailable reading from a measured zero.
  int? stepsForFoodDate(DateTime date) {
    final localDate = date.toLocal();
    if (_isSameFoodDate(localDate, clock.now().toLocal())) {
      if (_healthSessionEnded ||
          (health is HealthConnectAccess &&
              healthAuthState != HealthAuthState.granted)) {
        return null;
      }
      final fetched = healthLastFetch?.toLocal();
      return fetched != null && _isSameFoodDate(fetched, localDate)
          ? dailySteps
          : null;
    }
    return dailyActivity[localDayKey(localDate)]?.steps;
  }

  /// Upserts the calendar day of [day] with [steps]; kcal are frozen using
  /// the CURRENT profile (the estimate is coarser than the weight drift).
  /// Must run inside a _mutate block; the cache write is fire-and-forget.
  void _recordDailyActivity(DateTime day, int steps) =>
      _recordDailyActivities({day: steps});

  /// [_recordDailyActivity] for several days: one new map and ONE encrypted
  /// cache write for all of them.
  void _recordDailyActivities(Map<DateTime, int> days) {
    // YYYY-MM-DD sorts lexicographically = chronologically, so the cutoff is
    // a string compare, not date parsing.
    final cutoff = localDayKey(clock.now().subtract(_dailyActivityRetention));
    Map<String, ({int steps, int kcal})>? next;
    for (final MapEntry(key: day, value: steps) in days.entries) {
      if (steps < 0) continue;
      final key = localDayKey(day);
      final value = (
        steps: steps,
        kcal: estimateKcalBurnedFromSteps(
          steps: steps,
          weightKg: profile.weightKg,
          heightCm: profile.heightCm,
          sex: profile.sex,
        ),
      );
      // Unchanged -> no new map: slice selectors compare by identity, so a
      // resume without new steps must cost neither a rebuild nor an AES-GCM
      // cache write (guarded by home_page_rebuild_test).
      if ((next ?? dailyActivity)[key] == value) continue;
      next ??= <String, ({int steps, int kcal})>{
        for (final e in dailyActivity.entries)
          if (e.key.compareTo(cutoff) >= 0) e.key: e.value,
      };
      next[key] = value;
    }
    if (next == null) return;
    dailyActivity = next;
    unawaited(
      _cache?.writeDailyActivity(dailyActivity) ?? Future<void>.value(),
    );
  }

  /// Backfills the full day total for a PAST day from the health store, once
  /// per day and session. An EXISTING entry is refreshed too: it may stem
  /// from a refresh before day end, while the history knows the full sum. If
  /// the service returns nothing, the stored value stays untouched.
  ///
  /// Returns false when the read was deferred: outside the foreground Health
  /// Connect fails and HealthKit skips the read, so an empty answer proves
  /// nothing and the day stays open for a later foreground read.
  Future<bool> _maybeBackfillDailyActivity(DateTime day) async {
    if (_disposed ||
        _healthSessionEnded ||
        _isSameFoodDate(day, clock.now()) ||
        !_healthAccessAllowed) {
      return true;
    }
    final generation = _healthGeneration;
    final key = localDayKey(day);
    if (!_dailyActivityBackfillAttempted.add(key)) return true;
    final background = _appInBackground;
    final steps = await health.readStepsOnDay(day);
    if (_disposed || generation != _healthGeneration) return true;
    if (steps == null && (background || _appInBackground)) {
      _dailyActivityBackfillAttempted.remove(key);
      return false;
    }
    if (steps == null || steps < 0) return true;
    _mutate(() => _recordDailyActivity(day, steps));
    return true;
  }

  /// Past days Health Connect can answer: without READ_HEALTH_DATA_HISTORY,
  /// which Eatova neither declares nor requests, it returns nothing older
  /// than 30 days before the first grant. Each further day cost a read for
  /// an empty answer.
  static const int _healthConnectReadableDays = 30;

  /// How many days back Health Connect answers: to 30 days before this
  /// account's first connect. The app's grant may be older (another
  /// account), never younger, so this never asks too far. Without a known
  /// date (tests) today stands in.
  int _healthConnectReadableBack(DateTime today) {
    final since = _healthConnectedSince;
    final connected = since == null || since.isAfter(today)
        ? today
        : startOfDay(since.toLocal());
    return daysBetween(today, connected) + _healthConnectReadableDays;
  }

  /// Fills the step values of the trends page's range: every past day of the
  /// last [days] without a stored value is read from the health store, one
  /// after another and once per day and session. On Android only the days
  /// Health Connect answers ([_healthConnectReadableBack]). The found days
  /// land in [dailyActivity] together, in one notify and one encrypted cache
  /// write, instead of one each. Skipped without a usable health connection,
  /// where every read would come back empty.
  Future<void> backfillStepsForTrends(int days) async {
    if (!_healthReadable) return;
    final generation = _healthGeneration;
    final today = startOfDay(clock.now());
    final readable = _healthConnectReadableBack(today) + 1;
    final span = health is HealthConnectAccess && days > readable
        ? readable
        : days;
    final found = <DateTime, int>{};
    for (var n = 1; n < span; n++) {
      if (_disposed || generation != _healthGeneration) return;
      if (_healthSessionEnded || !_healthReadable) break;
      final day = addDays(today, -n);
      final key = localDayKey(day);
      if (dailyActivity.containsKey(key) ||
          !_dailyActivityBackfillAttempted.add(key)) {
        continue;
      }
      final background = _appInBackground;
      final steps = await health.readStepsOnDay(day);
      if (_disposed || generation != _healthGeneration) return;
      if (steps == null && (background || _appInBackground)) {
        // Deferred outside the foreground, not answered: read it next time.
        _dailyActivityBackfillAttempted.remove(key);
        break;
      }
      if (steps != null && steps >= 0) found[day] = steps;
    }
    if (found.isEmpty || _healthSessionEnded) return;
    _mutate(() => _recordDailyActivities(found));
  }

  bool get _healthReadable => switch (health.authState) {
    HealthAuthState.granted ||
    HealthAuthState.unverified ||
    HealthAuthState.noData => _healthAccessAllowed,
    HealthAuthState.unknown ||
    HealthAuthState.denied ||
    HealthAuthState.unsupported ||
    HealthAuthState.unavailable ||
    HealthAuthState.updateRequired ||
    HealthAuthState.error => false,
  };

  /// A known non-resumed state; an unknown one (tests) counts as foreground.
  /// Needs the widgets binding, which the app always has; a store test that
  /// reaches the backfill initializes it.
  static bool get _appInBackground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  // --- Scale import (review 2026-10-22) -------------------------------------

  /// Today's one-time question: the health source holds weigh-ins Eatova
  /// does not have, and this account has not said whether they come in by
  /// themselves. After the intro card, never before the account connected.
  bool get healthWeightImportOfferVisible =>
      _weightImport == _WeightImport.undecided &&
      _weightImportOffer > 0 &&
      _healthAccountOptedIn &&
      !healthIntroVisible &&
      !_needsOnboardingForHealth &&
      !_healthSessionEnded;

  /// The profile's switch: null while it does not apply (not connected, no
  /// weight source), else whether scale weigh-ins come in by themselves.
  bool? get healthWeightImportEnabled =>
      health is HealthWeightSource &&
          _healthAccountOptedIn &&
          _weightImport != _WeightImport.unknown
      ? _weightImport == _WeightImport.auto
      : null;

  /// The source's name in the import's texts; product names stay as they are.
  String get _healthSourceName =>
      health is HealthConnectAccess ? 'Health Connect' : 'Apple Health';

  Future<void> _loadWeightImport() async {
    final cache = _cache ?? debugCache;
    final generation = _healthGeneration;
    final stored = await cache?.readHealthWeightImport();
    if (_disposed || generation != _healthGeneration) return;
    // An answer given during the read wins.
    if (_weightImport != _WeightImport.unknown) return;
    final seen = stored?['seen'];
    _mutate(() {
      _weightImport = switch (stored?['mode']) {
        'auto' => _WeightImport.auto,
        'off' => _WeightImport.off,
        _ => _WeightImport.undecided,
      };
      _weightImportSince = DateTime.tryParse('${stored?['since'] ?? ''}');
      // A weigh-in deleted during the read stays remembered.
      _weightImportSeen = <String>{
        ..._weightImportSeen,
        if (seen is List)
          for (final key in seen)
            if (key is String) key,
      };
    });
  }

  /// Writes the import state; not before it was read, which would drop a
  /// stored answer.
  Future<void> _persistWeightImport() async {
    if (_weightImport == _WeightImport.unknown) return;
    final mode = switch (_weightImport) {
      _WeightImport.auto => 'auto',
      _WeightImport.off => 'off',
      _WeightImport.unknown || _WeightImport.undecided => null,
    };
    await (_cache ?? debugCache)?.writeHealthWeightImport(<String, dynamic>{
      'mode': ?mode,
      if (_weightImportSince != null)
        'since': _weightImportSince!.toUtc().toIso8601String(),
      'seen': _weightImportSeen.toList(),
    });
  }

  /// Today's "Import automatically" and the profile's switch: from now on
  /// weigh-ins from the health source come in by themselves, starting with
  /// the ones found now. Health Connect asks for its weight grant first.
  Future<void> enableHealthWeightImport() async {
    final service = health;
    if (_disposed ||
        _healthSessionEnded ||
        service is! HealthWeightSource ||
        !_healthAccountOptedIn) {
      return;
    }
    final generation = _healthGeneration;
    final allowed = await (service as HealthWeightSource).ensureWeightAccess();
    if (_disposed || generation != _healthGeneration) return;
    if (!allowed) {
      _emitSnack(
        _l10n.healthWeightImportNoAccess(_healthSourceName),
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    _mutate(() {
      _weightImport = _WeightImport.auto;
      _weightImportOffer = 0;
    });
    await _persistWeightImport();
    await _syncHealthWeights();
  }

  /// "Not now" and the switch off: weigh-ins stay in the health source;
  /// nothing already imported goes.
  Future<void> disableHealthWeightImport() async {
    if (_disposed || _healthSessionEnded) return;
    _mutate(() {
      _weightImport = _WeightImport.off;
      _weightImportOffer = 0;
    });
    await _persistWeightImport();
  }

  /// The weight log's server answer arrived: runs the read held back for it.
  void _resumeDeferredHealthWeights() {
    if (!_weightImportDeferred) return;
    _weightImportDeferred = false;
    unawaited(_syncHealthWeights());
  }

  /// Reads the weigh-ins since the last read: imports the new ones once the
  /// account opted in, or counts them for Today's question while it has not
  /// answered. A failed read or commit consumes nothing; the next refresh
  /// tries again.
  Future<void> _syncHealthWeights() async {
    final service = health;
    if (_disposed ||
        _healthSessionEnded ||
        _weightImportRunning ||
        service is! HealthWeightSource ||
        !_healthAccountOptedIn ||
        (_weightImport != _WeightImport.auto &&
            _weightImport != _WeightImport.undecided)) {
      return;
    }
    // Judged against the server's log: against one still loading, Eatova's
    // own write-backs and earlier imports would look new.
    if (sync != null && !_serverAnsweredWeightLog) {
      _weightImportDeferred = true;
      return;
    }
    final generation = _healthGeneration;
    _weightImportRunning = true;
    try {
      final now = clock.now();
      final samples = await (service as HealthWeightSource).readWeightSamples(
        _weightImportFrom(now),
        now,
      );
      if (_disposed || generation != _healthGeneration || samples == null) {
        return;
      }
      final fresh = _newHealthWeights(samples);
      if (_weightImport == _WeightImport.undecided) {
        if (fresh.length != _weightImportOffer) {
          _mutate(() => _weightImportOffer = fresh.length);
        }
        return;
      }
      // Switched off during the read.
      if (_weightImport != _WeightImport.auto) return;
      final batch = fresh.length > _weightImportMaxPerRead
          ? fresh.sublist(fresh.length - _weightImportMaxPerRead)
          : fresh;
      final announced = batch.isEmpty
          ? false
          : await _importHealthWeights(batch);
      if (_disposed || generation != _healthGeneration) return;
      final newest = samples.isEmpty ? null : samples.last.measuredAt;
      final since = _weightImportSince;
      if (newest != null && (since == null || newest.isAfter(since))) {
        _weightImportSince = newest;
      }
      final keep = now
          .subtract(_weightImportMaxLookback)
          .millisecondsSinceEpoch;
      _weightImportSeen = <String>{
        for (final key in _weightImportSeen)
          if ((int.tryParse(key.split(':').first) ?? 0) >= keep) key,
        for (final sample in batch) _weightSampleKey(sample),
      };
      await _persistWeightImport();
      if (batch.isNotEmpty && !announced && !_disposed) {
        _emitSnack(
          _l10n.healthWeightImported(batch.length, _healthSourceName),
          icon: Icons.monitor_weight_outlined,
        );
      }
    } catch (error, stack) {
      if (_disposed || generation != _healthGeneration) return;
      _reportSyncError(
        'health-weight-import',
        error,
        stack,
        message: _l10n.commonLocalSaveFailed,
      );
    } finally {
      _weightImportRunning = false;
    }
  }

  /// Where a read starts: at least [_weightImportLookback] back, so late
  /// syncs land; after a longer pause back to the last read, at most
  /// [_weightImportMaxLookback].
  DateTime _weightImportFrom(DateTime now) {
    final window = now.subtract(_weightImportLookback);
    final since = _weightImportSince;
    if (since == null || !since.isBefore(window)) return window;
    final cap = now.subtract(_weightImportMaxLookback);
    return since.isBefore(cap) ? cap : since;
  }

  /// The weigh-ins of [samples] Eatova does not have: valid (20..400 kg; a
  /// value outside is a unit or sensor error) and not the same reading (same
  /// local day, under 0.1 kg apart) as a weigh-in in the log, an earlier
  /// import or deleted weigh-in ([_weightImportSeen]) or one earlier in the
  /// batch. That also drops Eatova's own write-back and a value the user
  /// typed in from the scale.
  List<WeightSample> _newHealthWeights(List<WeightSample> samples) {
    bool sameReading(DateTime a, double kgA, DateTime b, double kgB) =>
        DateUtils.isSameDay(a.toLocal(), b.toLocal()) &&
        (kgA - kgB).abs() < 0.1 - 1e-9;
    final known = <WeightSample>[
      for (final e in weightLog.entries)
        WeightSample(kg: e.weightKg, measuredAt: e.timestamp),
      ..._seenReadings,
    ];
    final fresh = <WeightSample>[];
    for (final s in samples) {
      if (!isValidWeightLogKg(s.kg) ||
          known.any((k) => sameReading(k.measuredAt, k.kg, s.measuredAt, s.kg))) {
        continue;
      }
      fresh.add(s);
      known.add(s);
    }
    return fresh;
  }

  static String _weightSampleKey(WeightSample s) =>
      '${s.measuredAt.millisecondsSinceEpoch}:${(s.kg * 100).round()}';

  /// The readings behind [_weightImportSeen]; a malformed key is skipped.
  Iterable<WeightSample> get _seenReadings sync* {
    for (final key in _weightImportSeen) {
      final parts = key.split(':');
      final ms = parts.length == 2 ? int.tryParse(parts[0]) : null;
      final kg = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (ms == null || kg == null) continue;
      yield WeightSample(
        kg: kg / 100,
        measuredAt: DateTime.fromMillisecondsSinceEpoch(ms),
      );
    }
  }

  /// A deleted weigh-in stays deleted: the scale's sample behind it (or one
  /// the user typed in from the scale) is not imported again. Its undo takes
  /// the reading back out.
  void _rememberDeletedReading(WeightLogEntry entry, {required bool deleted}) {
    final key = _weightSampleKey(
      WeightSample(kg: entry.weightKg, measuredAt: entry.timestamp),
    );
    _weightImportSeen = deleted
        ? <String>{..._weightImportSeen, key}
        : (<String>{..._weightImportSeen}..remove(key));
    unawaited(_persistWeightImport());
  }

  /// Imports [samples] through the weight sync path, as one local commit
  /// with the profile they re-anchor. Each keeps its measurement time (a
  /// future one becomes now): a Monday reading belongs to Monday's trend
  /// day. Nothing is written back, which would echo the sample. Returns
  /// whether a notice about this commit already shows (the changed daily
  /// goal, or the once-per-session "syncs later" hint it raised).
  Future<bool> _importHealthWeights(List<WeightSample> samples) async {
    await _settledLocalMutations();
    final now = clock.now();
    final ops = <SyncOp>[];
    final entries = <WeightLogEntry>[];
    for (final sample in samples) {
      final kg = WeightLog.sanitizeKg(sample.kg);
      if (kg == null) continue;
      final ts = sample.measuredAt.isAfter(now) ? now : sample.measuredAt;
      final op = SyncOp.weightInsert(id: uuidV4(), weightKg: kg, recordedAt: ts);
      ops.add(op);
      entries.add(WeightLogEntry(timestamp: ts, weightKg: kg, id: op.entityId));
    }
    if (ops.isEmpty) return false;
    WeightLog withImports(WeightLog log) =>
        entries.fold(log, (next, entry) => next.addEntry(entry));
    final before = profile;
    final reanchored = _reanchoredProfile(before, withImports(weightLog));
    final syncHintShown = _syncHintShown;
    await _commitSyncIntents(
      [...ops, if (reanchored != null) SyncOp.profileUpsert(reanchored)],
      publish: () {
        weightLog = withImports(weightLog);
        for (var i = 0; i < entries.length; i++) {
          lifetimeStats = lifetimeStats.incrementWeightLogs();
        }
        if (reanchored != null) profile = reanchored;
      },
    );
    final raisedSyncHint = _syncHintShown && !syncHintShown;
    if (reanchored == null ||
        raisedSyncHint ||
        reanchored.manualEnergy ||
        reanchored.dailyKcalGoal == before.dailyKcalGoal) {
      return raisedSyncHint;
    }
    _announceReanchor(before, reanchored);
    return true;
  }

  // --- Body data (profile) --------------------------------------------------

  /// Manual weigh-in: logs locally, syncs, and writes back to HealthKit.
  /// [at] dates it (the sheet's time row); null is now, and a moment in the
  /// future becomes now.
  Future<void> logWeight(double kg, {DateTime? at}) =>
      _logWeightInternal(kg, recordedAt: at);

  /// Core of [logWeight]. Last barrier before cache, HealthKit and server
  /// (F7-02): the sheet rejects out-of-range input, but any other caller
  /// still passes through here, and `weight_log_safe_range_check` would
  /// reject the row with 23514 while the local log already showed it. The
  /// scale import keeps its own path ([_importHealthWeights]): it discards
  /// such values instead of clamping them.
  Future<void> _logWeightInternal(double rawKg, {DateTime? recordedAt}) async {
    final kg = WeightLog.sanitizeKg(rawKg);
    if (kg == null) throw const FormatException('Invalid weight');
    // The re-anchored profile is derived from the PUBLISHED profile, so a
    // goals save still in flight must land first.
    await _settledLocalMutations();
    final now = clock.now();
    final ts = recordedAt == null || recordedAt.isAfter(now) ? now : recordedAt;
    final op = SyncOp.weightInsert(id: uuidV4(), weightKg: kg, recordedAt: ts);
    final entry = WeightLogEntry(timestamp: ts, weightKg: kg, id: op.entityId);
    final before = profile;
    final reanchored = _reanchoredProfile(before, weightLog.addEntry(entry));
    final syncHintShown = _syncHintShown;
    // One local commit: the weigh-in and the profile it moves never diverge.
    await _commitSyncIntents(
      [op, if (reanchored != null) SyncOp.profileUpsert(reanchored)],
      publish: () {
        weightLog = weightLog.addEntry(entry);
        lifetimeStats = lifetimeStats.incrementWeightLogs();
        if (reanchored != null) profile = reanchored;
      },
    );
    HapticFeedback.lightImpact();
    // Only into this account's own health store, never another person's.
    if (_healthAccessAllowed) unawaited(health.writeWeight(kg, ts));
    // The once-per-session "saved here, syncs later" hint this commit may just
    // have raised outranks the goal notice, which would replace it for good.
    final raisedSyncHint = _syncHintShown && !syncHintShown;
    if (reanchored != null && !raisedSyncHint) {
      _announceReanchor(before, reanchored);
    }
  }

  // --- Correcting weigh-ins (review 2026-10-19) ------------------------------

  /// Corrects the value and the moment of the weigh-in with row id [id]. The
  /// trend re-anchors through the same path as a new weigh-in, in the same
  /// local commit, so a corrected typo moves the plan back. A moment in the
  /// future becomes now. Eatova's own Apple Health sample follows.
  Future<void> updateWeighIn(
    String id, {
    required double kg,
    required DateTime at,
  }) async {
    final clean = WeightLog.sanitizeKg(kg);
    if (clean == null) throw const FormatException('Invalid weight');
    await _settledLocalMutations();
    final previous = weightLog.entryWithId(id);
    if (previous == null) throw StateError('Weigh-in no longer exists');
    final now = clock.now();
    final ts = at.isAfter(now) ? now : at;
    if (previous.weightKg == clean && previous.timestamp.isAtSameMomentAs(ts)) {
      return;
    }
    final entry = WeightLogEntry(timestamp: ts, weightKg: clean, id: id);
    await _commitWeighInChange(
      SyncOp.weightUpsert(id: id, weightKg: clean, recordedAt: ts),
      (log) => log.putEntry(entry),
      announce: true,
    );
    HapticFeedback.lightImpact();
    unawaited(_moveOwnHealthWeight(previous, entry));
  }

  /// Deletes the weigh-in with row id [id], with an undo. The delete is
  /// terminal for the id; the undo restores the value under a new one.
  Future<void> deleteWeighIn(String id) async {
    await _settledLocalMutations();
    final removed = weightLog.entryWithId(id);
    if (removed == null) return;
    await _commitWeighInChange(
      SyncOp.weightDelete(id),
      (log) => log.removeEntry(id),
    );
    _rememberDeletedReading(removed, deleted: true);
    HapticFeedback.lightImpact();
    // Awaited only by an undo; a failure means no sample to write back.
    final healthSample = _deleteOwnHealthWeight(
      removed.timestamp,
    ).catchError((Object _, StackTrace _) => false);
    Future<void>? restore;
    // The undo outranks a goal notice: a changed goal shows in the plan.
    _showUndoSnackBar(
      _l10n.weighInDeleted,
      () => unawaited(
        (restore ??= _restoreWeighIn(removed, healthSample)).catchError((
          Object error,
          StackTrace stack,
        ) {
          _reportSyncError('undo', error, stack);
        }),
      ),
    );
  }

  /// Undo of [deleteWeighIn]: the same value and moment under a new id,
  /// without counting another weigh-in. Eatova's Health sample comes back
  /// only if the delete took one.
  Future<void> _restoreWeighIn(
    WeightLogEntry removed,
    Future<bool> healthSample,
  ) async {
    await _settledLocalMutations();
    final op = SyncOp.weightUpsert(
      id: uuidV4(),
      weightKg: removed.weightKg,
      recordedAt: removed.timestamp,
    );
    final entry = WeightLogEntry(
      timestamp: removed.timestamp,
      weightKg: removed.weightKg,
      id: op.entityId,
    );
    await _commitWeighInChange(op, (log) => log.putEntry(entry), announce: true);
    _rememberDeletedReading(removed, deleted: false);
    if (await healthSample &&
        !_disposed &&
        !_healthSessionEnded &&
        _healthAccessAllowed) {
      unawaited(health.writeWeight(removed.weightKg, removed.timestamp));
    }
  }

  /// One local commit for a weigh-in change and the profile it re-anchors,
  /// as [_logWeightInternal] does for a new one. [announce] names a changed
  /// live goal unless the commit just raised the "syncs later" hint.
  Future<void> _commitWeighInChange(
    SyncOp op,
    WeightLog Function(WeightLog log) apply, {
    bool announce = false,
  }) async {
    final before = profile;
    final reanchored = _reanchoredProfile(before, apply(weightLog));
    final syncHintShown = _syncHintShown;
    await _commitSyncIntents(
      [op, if (reanchored != null) SyncOp.profileUpsert(reanchored)],
      publish: () {
        weightLog = apply(weightLog);
        if (reanchored != null) profile = reanchored;
      },
    );
    final raisedSyncHint = _syncHintShown && !syncHintShown;
    if (announce && reanchored != null && !raisedSyncHint) {
      _announceReanchor(before, reanchored);
    }
  }

  /// Eatova's Health sample of an edited weigh-in moves with it. A weigh-in
  /// imported from another source has none of Eatova's, so Health keeps the
  /// source's sample as it is.
  Future<void> _moveOwnHealthWeight(
    WeightLogEntry previous,
    WeightLogEntry next,
  ) async {
    if (!await _deleteOwnHealthWeight(previous.timestamp)) return;
    if (_disposed || _healthSessionEnded) return;
    await health.writeWeight(next.weightKg, next.timestamp);
  }

  /// Whether Eatova's own Health sample at [at] was deleted; false without
  /// the capability (Android, tests) or without such a sample.
  Future<bool> _deleteOwnHealthWeight(DateTime at) async {
    final service = health;
    if (_disposed ||
        _healthSessionEnded ||
        !_healthAccessAllowed ||
        service is! HealthWeightCorrection) {
      return false;
    }
    return (service as HealthWeightCorrection).deleteOwnWeight(at);
  }

  /// The first weigh-in from the onboarding weight (review 2026-10-19), so
  /// the trend and the weekly check start on day one. Only while the server
  /// answered an empty weight log in this session: an account that already
  /// has weigh-ins, or one whose log is unknown offline, gets none.
  ({SyncOp op, WeightLogEntry entry})? _onboardingWeighIn(UserProfile done) {
    if (sync != null && !_serverAnsweredWeightLog) return null;
    if (weightLog.entries.isNotEmpty) return null;
    final kg = WeightLog.sanitizeKg(done.weightKg.toDouble());
    if (kg == null || !isValidWeightLogKg(kg)) return null;
    final now = clock.now();
    final op = SyncOp.weightInsert(id: uuidV4(), weightKg: kg, recordedAt: now);
    return (
      op: op,
      entry: WeightLogEntry(timestamp: now, weightKg: kg, id: op.entityId),
    );
  }

  // --- Weight trend re-anchoring (docs/WEIGHT-TREND.md) ---------------------

  /// Whether the server answered both the profile and the weight-log load in
  /// this session; the boot flags live in [HomeStore].
  bool get _serverAnsweredProfileAndWeightLog;

  /// [p] with its weight moved to the rounded [WeightLog.planWeightKg] of
  /// [log] and, in live mode, its goals recomputed; null when nothing moves.
  ///
  /// Skipped before onboarding completes, before the server answered profile
  /// AND weight log in this session (a full row from a cache could overwrite a
  /// newer one), and without a fresh, in-range trend — the profile then keeps
  /// its own weight.
  UserProfile? _reanchoredProfile(UserProfile p, WeightLog log) {
    if (!p.onboardingCompleted) return null;
    if (sync != null &&
        !(_hydratedFromRealSource && _serverAnsweredProfileAndWeightLog)) {
      return null;
    }
    final kg = log.planWeightKg(clock.now())?.round();
    if (kg == null || kg == p.weightKg) return null;
    return const KcalCalculator().applyLiveGoals(p.copyWith(weightKg: kg));
  }

  /// Names a live kcal goal the re-anchor changed. Manual goals do not move,
  /// and a macro-only shift is not worth a message.
  void _announceReanchor(UserProfile before, UserProfile after) {
    if (_disposed || after.manualEnergy) return;
    if (after.dailyKcalGoal == before.dailyKcalGoal) return;
    _emitSnack(
      _l10n.commonDailyGoalReanchored(after.dailyKcalGoal),
      icon: Icons.monitor_weight_outlined,
    );
  }

  /// Catches the profile up with weigh-ins it has not seen yet: the first
  /// boot after this feature, or weigh-ins from another device.
  Future<void> _reanchorToWeightTrend() async {
    await _settledLocalMutations();
    if (_disposed || _trainingSessionEnded) return;
    final before = profile;
    final reanchored = _reanchoredProfile(before, weightLog);
    if (reanchored == null) return;
    await _commitSyncIntents(
      [SyncOp.profileUpsert(reanchored)],
      publish: () => profile = reanchored,
      notifyQueued: false,
    );
    _announceReanchor(before, reanchored);
  }

  /// Waits until no local mutation is queued. A commit chains onto the tail
  /// at call time, so once the tail is stable, a value computed from the
  /// published state and committed without another await cannot overtake or
  /// overwrite a mutation in flight.
  Future<void> _settledLocalMutations() async {
    var tail = _localMutationTail;
    while (true) {
      await tail;
      if (identical(tail, _localMutationTail)) return;
      tail = _localMutationTail;
    }
  }
}

/// Where this account stands with Today's health intro card, kept per
/// account in the encrypted cache (`health_prompt`). For HealthKit it is the
/// account's opt-in, since the OS grant belongs to the device.
enum _HealthIntro {
  /// Not read from the cache yet.
  unknown,

  /// The card shows; the source is not asked unprompted.
  pending,

  /// The account connected (or, for HealthKit, was connected before the
  /// per-account rule); HealthKit may be asked and read as before.
  connected,

  /// "Not now": no card, and no unprompted ask either.
  dismissed,
}

/// This account's answer to the scale import (review 2026-10-22).
enum _WeightImport {
  /// Not read from the cache yet.
  unknown,

  /// Not answered: new weigh-ins are counted for Today's question only.
  undecided,

  /// Weigh-ins come in by themselves.
  auto,

  /// "Not now" or switched off: weigh-ins stay in the health source.
  off,
}
