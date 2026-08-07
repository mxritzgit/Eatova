part of 'home_store.dart';

/// Profil-Part von [HomeStore]: Profil/Settings, Onboarding und die
/// Erinnerungen (PROD-1, abendlicher Streak-Retter). Reine Datei-Aufteilung —
/// Verhalten und Member sind 1:1 aus home_store.dart uebernommen.
mixin _HomeStoreProfilePart on _HomeStoreBase {
  bool _notificationsEnabled = false;
  bool _onboardingDone = false;

  bool get notificationsEnabled => _notificationsEnabled;

  /// Onboarding ist Pflicht, sobald ein echter Supabase-Sync existiert und das
  /// Profil noch nicht durchlaufen wurde. Ohne Sync (Test/Preview) nie.
  bool get needsOnboarding =>
      sync != null && !_onboardingDone && !profile.onboardingCompleted;

  // --- Erinnerungen (PROD-1) ------------------------------------------------
  // Einziger Inhalt seit dem Heute-Tab-Aus: der abendliche Streak-Retter
  // (streak_reminder_planner.dart). Der Opt-in-Toggle + die Permission-Strecke
  // bleiben der Andock-Punkt fuer alles Weitere.

  Future<void> _initNotificationsFromCache() async {
    final cache = _cache;
    if (cache == null) return;
    final enabled = await cache.readNotificationsEnabled() ?? false;
    if (_disposed) return;
    if (!enabled) return;
    _mutate(() => _notificationsEnabled = true);
    await notificationService.init();
    // Boot mit aktiviertem Opt-in: Reminder-Fenster frisch aufziehen (die
    // Permission wurde beim Einschalten bereits erteilt, kein Re-Prompt).
    await _rescheduleStreakReminder();
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    if (!_disposed) {
      _mutate(() => _notificationsEnabled = enabled);
    } else {
      _notificationsEnabled = enabled;
    }
    unawaited(
        _cache?.writeNotificationsEnabled(enabled) ?? Future<void>.value());
    if (enabled) {
      await notificationService.init();
      final granted = await notificationService.requestPermission();
      // Nur nach erteilter Permission planen — ohne sie wuerde zonedSchedule
      // ins Leere laufen (bzw. auf Android 13+ still verpuffen).
      if (granted) await _rescheduleStreakReminder();
    } else {
      await notificationService.cancelAll();
    }
  }

  /// Plant die abendlichen Streak-Reminder fuer die naechsten 7 Tage neu.
  /// scheduleAll arbeitet cancel-first, daher immer die volle Planner-Liste —
  /// kein Duplikat-Risiko bei wiederholten Aufrufen (Boot, Toggle, jeder Log).
  /// Guard: ohne Opt-in wird nie geplant.
  Future<void> _rescheduleStreakReminder() async {
    if (!_notificationsEnabled) return;
    await notificationService
        .scheduleAll(planStreakReminders(DateTime.now(), lifetimeStats));
  }

  /// Schaltet Erinnerungen ein/aus (Settings-Toggle). Oeffentliche Fassade fuer
  /// die Schale.
  Future<void> setNotificationsEnabled(bool enabled) =>
      _setNotificationsEnabled(enabled);

  // --- Settings / Reset / Onboarding ---------------------------------------

  /// Wendet das im Settings-Sheet bearbeitete Profil + Flags an (das Sheet
  /// selbst lebt in der context-tragenden Schale). Spiegelt das frühere
  /// `_openSettings` ohne den UI-/Navigations-Teil.
  Future<void> applySettings({
    required UserProfile newProfile,
    required bool notificationsEnabled,
    required bool resetDay,
  }) async {
    if (notificationsEnabled != _notificationsEnabled) {
      unawaited(_setNotificationsEnabled(notificationsEnabled));
    }
    final canPersistProfile = _hydratedFromRealSource;
    _mutate(() {
      profile = newProfile;
      if (resetDay) {
        _clearTodayState();
      }
    });
    final s = sync;
    if (s != null) {
      if (canPersistProfile) {
        unawaited(_cache?.writeProfile(newProfile) ?? Future<void>.value());
      }
      try {
        if (canPersistProfile) {
          await s.profile.save(newProfile);
        } else {
          dev.log(
              'ProfileSync.save uebersprungen: profile basiert auf Ctor-Defaults '
              '(kein Server-/Cache-Hydrate) — Clobber-Schutz',
              name: 'eatova_sync');
        }
      } catch (e, st) {
        // Kein Outbox-Netz fuer den Profil-Save: freundliche Meldung OHNE
        // Exception-Details (frueher stand hier der rohe Postgrest-Text im
        // Snack), Roh-Fehler geht an dev.log/CrashReporter.
        dev.log('Profil-Sync failed', error: e, name: 'eatova_sync');
        unawaited(CrashReporter.capture(e, st, context: 'profil-settings'));
        if (!_disposed) {
          _emitSnack(profileSyncErrorMessage(e),
              icon: Icons.error_outline_rounded,
              accent: danger,
              duration: kSnackError);
        }
      }
    }
    if (resetDay && !_disposed) {
      _emitSnack('Tagesdaten zurückgesetzt.',
          icon: Icons.restart_alt_rounded, accent: orange);
    }
  }

  void _clearTodayState() {
    dailyConsumedKcal = 0;
    dailySteps = 0;
    macroProgress = MacroProgress.empty;
    loggedMeals = <LoggedMeal>[];
    selectedFoodDate = DateUtils.dateOnly(DateTime.now());
  }

  void resetTodayData() {
    _mutate(_clearTodayState);
    _emitSnack('Tagesdaten zurückgesetzt.',
        icon: Icons.restart_alt_rounded, accent: orange);
  }

  Future<void> completeOnboarding(UserProfile finished) async {
    _mutate(() {
      profile = finished;
      _onboardingDone = true;
      _hydratedFromRealSource = true;
    });
    final s = sync;
    if (s == null) return;
    unawaited(_cache?.writeProfile(finished) ?? Future<void>.value());
    unawaited(_setNotificationsEnabled(true));
    try {
      await s.profile.save(finished);
    } catch (e, st) {
      // Wie in applySettings: klassifizierte, freundliche Meldung statt des
      // rohen Exception-Texts; Diagnose laeuft ueber dev.log/CrashReporter.
      dev.log('Profil-Sync (Onboarding) failed', error: e, name: 'eatova_sync');
      unawaited(CrashReporter.capture(e, st, context: 'profil-onboarding'));
      if (!_disposed) {
        _emitSnack(profileSyncErrorMessage(e),
            icon: Icons.error_outline_rounded,
            accent: danger,
            duration: kSnackError);
      }
    }
  }
}
