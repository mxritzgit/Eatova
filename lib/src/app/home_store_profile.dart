part of 'home_store.dart';

/// Der Zustand der abendlichen Erinnerungen. **Drei** Zustaende, nicht zwei —
/// das ist der Kern von D11 (Review 2026-08-08).
///
/// Vorher gab es nur ein `bool`, das der Nutzerabsicht folgte und nie mit der
/// OS-Ebene abgeglichen wurde. Wer im Systemdialog „Nicht zulassen" tippte,
/// sah den Schalter fuer immer auf AN mit dem Text „Aktiv. Du bekommst gezielte
/// Nudges zur passenden Zeit." — und bekam nie etwas.
///
/// Uebergabe an die Schale (settings_sheet.dart):
///  * [off] — Schalter AUS. „Aus. Schalter umlegen, um lokale Erinnerungen zu
///    aktivieren."
///  * [active] — Schalter AN. „Aktiv. Jeden Abend um 20 Uhr, wenn du noch
///    nichts geloggt hast."
///  * [blocked] — Schalter AUS (es wird nachweislich nichts zugestellt), aber
///    mit eigenem Hinweis UND einer Handlung, die weiterfuehrt: „Vom System
///    blockiert. Eatova darf keine Mitteilungen senden — erlaube sie in den
///    Systemeinstellungen." plus Button „Systemeinstellungen oeffnen". Kein
///    „Fehler", kein erneutes Umlegen des Schalters: auf Android 13+ zeigt das
///    System nach zwei Ablehnungen gar keinen Dialog mehr, der Schalter kaeme
///    also sofort wieder zurueck.
///
/// Nur [active] heisst, dass wirklich etwas geplant ist.
enum ReminderState {
  /// Der Nutzer will keine Erinnerungen.
  off,

  /// Der Nutzer will Erinnerungen UND das OS liefert sie aus.
  active,

  /// Der Nutzer will Erinnerungen, das OS verweigert sie.
  blocked,
}

/// Profil-Part von [HomeStore]: Profil/Settings, Onboarding und die
/// Erinnerungen (PROD-1, abendlicher Streak-Retter). Reine Datei-Aufteilung —
/// Verhalten und Member sind 1:1 aus home_store.dart uebernommen.
mixin _HomeStoreProfilePart on _HomeStoreBase {
  ReminderState _reminderState = ReminderState.off;
  bool _onboardingDone = false;

  /// Ob abends wirklich etwas kommt. Bewusst NUR bei [ReminderState.active]
  /// true — „blockiert" ist kein „an" (D11).
  bool get notificationsEnabled => _reminderState == ReminderState.active;

  /// Der volle Zustand fuer die Schale (Text + Handlung, s. [ReminderState]).
  ReminderState get reminderState => _reminderState;

  /// Onboarding ist Pflicht, sobald ein echter Supabase-Sync existiert und das
  /// Profil noch nicht durchlaufen wurde. Ohne Sync (Test/Preview) nie.
  bool get needsOnboarding =>
      sync != null && !_onboardingDone && !profile.onboardingCompleted;

  // --- Erinnerungen (PROD-1) ------------------------------------------------
  // Einziger Inhalt seit dem Heute-Tab-Aus: der abendliche Streak-Retter
  // (streak_reminder_planner.dart). Der Opt-in-Toggle + die Permission-Strecke
  // bleiben der Andock-Punkt fuer alles Weitere.

  /// Der Cache im Boot-Pfad. `_cache` steht erst nach [_hydrateThenBoot]; im
  /// Test (und beim frueh angestossenen Boot) faellt es auf den injizierten
  /// [debugCache] zurueck — dasselbe Muster wie `_clearCache`.
  LocalCache? get _notificationCache => _cache ?? debugCache;

  /// Kaltstart-Pfad der Erinnerungen.
  ///
  /// D11: Der Cache haelt nur, was beim Einschalten galt. Die Berechtigung kann
  /// seither in den Systemeinstellungen entzogen worden sein, ohne dass die App
  /// je davon erfahren haette. Also GEGENLESEN — und zwar mit
  /// [NotificationPermissionProbe.hasPermission] (still), NICHT mit
  /// `requestPermission()`: ein Systemdialog beim Kaltstart ueberfaellt den
  /// Nutzer und ist auf Android 13+ nach zwei Ablehnungen ohnehin wirkungslos.
  Future<void> _initNotificationsFromCache() async {
    final cache = _notificationCache;
    if (cache == null) return;
    final enabled = await cache.readNotificationsEnabled() ?? false;
    if (_disposed) return;
    // Kein Opt-in -> das OS wird gar nicht erst gefragt.
    if (!enabled) return;

    await notificationService.init();
    await _applyOsPermission(cache);
  }

  /// Liest die OS-Ebene gegen und zieht State + Cache nach. Hier laeuft
  /// bewusst NIE ein Dialog — der einzige Ort, an dem gefragt werden darf, ist
  /// die explizite Nutzergeste in [_setNotificationsEnabled].
  Future<void> _applyOsPermission(LocalCache cache) async {
    final granted = await _osDeliversNotifications();
    if (_disposed) return;

    if (granted == null) {
      // Unbekannt (Dienst ohne Probe): nichts behaupten und nichts entwerten.
      // Kein `active` (das waere ein gruener Schalter ohne Beleg — exakt die
      // D11-Klasse), kein Umschreiben des Opt-ins (der naechste Boot mit
      // probe-faehigem Dienst stellt den echten Zustand wieder her), kein
      // cancelAll (Bestehendes nicht aus Unwissen zerstoeren).
      return;
    }

    if (granted) {
      _setReminderState(ReminderState.active);
      await cache.writeNotificationsEnabled(true);
      await _rescheduleStreakReminder();
      return;
    }

    // Dritter Zustand: der Nutzer WILL Erinnerungen, das OS gibt sie nicht.
    // Das persistierte Flag bedeutet „aktiv" und ist damit nachweislich
    // falsch — es faellt, sonst plant der naechste Kaltstart wieder ins Leere.
    _setReminderState(ReminderState.blocked);
    await cache.writeNotificationsEnabled(false);
    await notificationService.cancelAll();
  }

  /// Ob das OS aktuell zustellt — dreiwertig, null heisst „nicht
  /// feststellbar". Dienste ohne [NotificationPermissionProbe] (fremde/
  /// aeltere Test-Doubles; beide Produktions-Implementierungen tragen die
  /// Probe) koennen die Frage nicht beantworten. Frueher galten sie als
  /// erlaubt — derselbe Sentinel wie D11: aus „ich weiss es nicht" wurde die
  /// persistierte Behauptung „aktiv". Unbekannt behauptet jetzt nichts mehr,
  /// die Auswertung steht in [_applyOsPermission].
  Future<bool?> _osDeliversNotifications() async {
    // Der Cast ist noetig, weil [NotificationPermissionProbe] bewusst KEIN
    // Subtyp von [NotificationService] ist (sonst braeche jedes bestehende
    // `implements NotificationService`-Double) — Dart promotet deshalb nicht.
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

    await notificationService.init();
    // D11: erst fragen, DANN persistieren. Vorher stand `true` schon im Cache
    // (und im State), bevor der Systemdialog ueberhaupt beantwortet war — bei
    // „Nicht zulassen" blieb es dort fuer immer stehen.
    final granted = await notificationService.requestPermission();
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

  /// Plant die abendlichen Streak-Reminder fuer den vollen Horizont neu
  /// (4 Wochen, s. streak_reminder_planner.dart).
  /// scheduleAll arbeitet cancel-first, daher immer die volle Planner-Liste —
  /// kein Duplikat-Risiko bei wiederholten Aufrufen (Boot, Toggle, jeder Log).
  /// Guard: ohne erteilte Berechtigung wird nie geplant.
  Future<void> _rescheduleStreakReminder() async {
    if (_reminderState != ReminderState.active) return;
    await notificationService
        .scheduleAll(planStreakReminders(DateTime.now(), lifetimeStats));
  }

  /// Schaltet Erinnerungen ein/aus (Settings-Toggle). Oeffentliche Fassade fuer
  /// die Schale.
  Future<void> setNotificationsEnabled(bool enabled) =>
      _setNotificationsEnabled(enabled);

  /// Liest die OS-Berechtigung erneut gegen und korrigiert den Zustand — OHNE
  /// Dialog.
  ///
  /// Der Rueckweg aus [ReminderState.blocked]: die Schale ruft das auf, wenn
  /// die App aus dem Hintergrund zurueckkommt (der Nutzer war gerade in den
  /// Systemeinstellungen). Ohne diesen Pfad muesste er die App neu starten,
  /// damit der Schalter wieder die Wahrheit sagt.
  ///
  /// Bei [ReminderState.off] passiert nichts — wer keine Erinnerungen will,
  /// soll durch eine Systemeinstellung nicht welche bekommen.
  Future<void> refreshNotificationPermission() async {
    if (_reminderState == ReminderState.off) return;
    final cache = _notificationCache;
    if (cache == null) return;
    await notificationService.init();
    await _applyOsPermission(cache);
  }

  /// Kaltstart-Pfad als oeffentliche Fassade — der Boot ruft ihn aus
  /// `_hydrateThenBoot`, Tests ohne Supabase-Sync direkt.
  @visibleForTesting
  Future<void> initNotificationsFromCache() => _initNotificationsFromCache();

  // --- Settings / Reset / Onboarding ---------------------------------------

  /// Wendet das im Settings-Sheet bearbeitete Profil + Flags an (das Sheet
  /// selbst lebt in der context-tragenden Schale). Spiegelt das frühere
  /// `_openSettings` ohne den UI-/Navigations-Teil.
  Future<void> applySettings({
    required UserProfile newProfile,
    required bool notificationsEnabled,
    required bool resetDay,
  }) async {
    // `this.` ist noetig, weil der Parameter den Getter verdeckt. Vergleich
    // gegen den TATSAECHLICHEN Zustand: in [ReminderState.blocked] ist
    // `notificationsEnabled` false, ein erneutes Umlegen auf AN laeuft also
    // wieder durch die Berechtigungsstrecke (statt still nichts zu tun).
    if (notificationsEnabled != this.notificationsEnabled) {
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
