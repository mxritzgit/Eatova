// Visual evidence for the settings polish (2026-10-02).
//
// Mounts the settings page, the goals page it leads to (plan hero, pickers)
// and the profile's goals card (a SettingsRow user) with realistic data at the
// design's reference geometry (390x844, DPR 2, real fonts).
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/. Without it the suite still checks that every surface
// renders without exceptions and that its key controls are present.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

final DateTime _now = DateTime(2026, 9, 28, 19);

const String _mail = 'moritz.schneider@example.com';

const UserProfile _profile = UserProfile(
  weightKg: 82,
  heightCm: 181,
  ageYears: 34,
  sex: BiologicalSex.male,
  activityLevel: ActivityLevel.moderate,
  targetWeightKg: 76,
  weightGoal: WeightGoal.lose05kg,
  dailyStepsGoal: 9000,
  onboardingCompleted: true,
);

Widget _settings({
  Locale locale = const Locale('en'),
  int pending = 2,
  SyncBlockedReason? blocked,
}) {
  final repo = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'u1', email: _mail),
  );
  addTearDown(repo.dispose);
  final language = LocaleController();
  addTearDown(language.dispose);
  return LocaleScope(
    controller: language,
    child: SettingsScreen(
      email: _mail,
      authRepository: repo,
      onOpenGoals: () {},
      onSignOut: () async {},
      onDeleteAccount: (deleteRemote, _) async => deleteRemote(),
      onExportData: () async => '{}',
      pendingSyncCount: pending,
      syncBlockedReason: blocked,
      onSyncNow: () async {},
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  pinDesignViewport(tester);
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        page,
        locale: locale,
        textScale: textScale,
        scaffold: false,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// Shoots [prefix]-00, -01 … down the page until its end is on screen.
Future<void> _shootDown(
  WidgetTester tester,
  String prefix, {
  required Finder page,
}) async {
  final scrollable = find
      .descendant(of: page, matching: find.byType(Scrollable))
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  var index = 0;
  while (true) {
    await captureDesignShot(
      tester,
      '$prefix-${index.toString().padLeft(2, '0')}',
    );
    if (position.pixels >= position.maxScrollExtent) break;
    await scrollDesignTabBy(tester, 620, scrollable: scrollable);
    index++;
    expect(tester.takeException(), isNull);
  }
}

Future<void> _tapRow(WidgetTester tester, String key, {Finder? page}) async {
  final row = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadDesignFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const settingsPage = ValueKey('screen-settings');
  const goalsPage = ValueKey('screen-goals');

  testWidgets('settings: the whole page, top to bottom (en)', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, _settings());
      expect(find.text('Settings'), findsOneWidget);
      for (final key in const <String>[
        'settings-email',
        'settings-change-password',
        'settings-change-email',
        'settings-open-goals',
        'settings-language',
        'settings-sync-status',
        'settings-export',
        'settings-about',
        'settings-sign-out',
        'settings-delete-account',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }
      await _shootDown(
        tester,
        'settings',
        page: find.byKey(settingsPage),
      );
    });
  });

  testWidgets('settings: German, the densest locale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, _settings(), locale: const Locale('de'));
      expect(find.text('Einstellungen'), findsOneWidget);
      await _shootDown(
        tester,
        'settings-de',
        page: find.byKey(settingsPage),
      );
    });
  });

  testWidgets('settings: blocked sync', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(
        tester,
        _settings(pending: 5, blocked: SyncBlockedReason.backendUnavailable),
      );
      final sync = find.byKey(const ValueKey('settings-sync-status'));
      await tester.ensureVisible(sync);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'settings-sync-blocked');
    });
  });

  testWidgets('settings: 2.0 text scale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, _settings(), textScale: 2.0);
      await captureDesignShot(tester, 'settings-scale2-00');
      final language = find.byKey(const ValueKey('settings-language'));
      await tester.ensureVisible(language);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'settings-scale2-01');
      final delete = find.byKey(const ValueKey('settings-delete-account'));
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'settings-scale2-02');
    });
  });

  testWidgets('settings: about, password and delete sheets', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, _settings());

      await _tapRow(tester, 'settings-about');
      expect(find.byKey(const ValueKey('profile-privacy-link')), findsOneWidget);
      await captureDesignShot(tester, 'settings-about');
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();

      await _tapRow(tester, 'settings-change-password');
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'settings-password');
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();

      await _tapRow(tester, 'settings-delete-account');
      expect(
        find.byKey(const ValueKey('settings-delete-confirm-field')),
        findsOneWidget,
      );
      await captureDesignShot(tester, 'settings-delete');
    });
  });

  testWidgets('goals: plan hero and groups, top to bottom', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(
        tester,
        const GoalsScreen(
          profile: _profile,
          reminderState: ReminderState.active,
        ),
      );
      expect(
        find.byKey(const ValueKey('settings-plan-eyebrow-live')),
        findsOneWidget,
      );
      await _shootDown(tester, 'goals', page: find.byKey(goalsPage));
    });
  });

  testWidgets('goals: 2.0 text scale', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(
        tester,
        const GoalsScreen(profile: _profile),
        textScale: 2.0,
      );
      await captureDesignShot(tester, 'goals-scale2-00');
      final weight = find.byKey(const ValueKey('settings-weight'));
      await tester.ensureVisible(weight);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'goals-scale2-01');
    });
  });

  testWidgets('goals: manual energy mode', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(
        tester,
        const GoalsScreen(
          profile: _profile,
          reminderState: ReminderState.blocked,
          onOpenSystemSettings: _noop,
        ),
      );
      final toggle = find.byKey(const ValueKey('settings-manual-energy'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-plan-eyebrow-manual')),
        findsOneWidget,
      );
      await captureDesignShot(tester, 'goals-manual-00');
      final scrollable = find
          .descendant(
            of: find.byKey(goalsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'goals-manual-01');
      final top = position.minScrollExtent;
      position.jumpTo(top);
      await tester.pumpAndSettle();
      await captureDesignShot(tester, 'goals-manual-hero');
    });
  });

  testWidgets('goals: the three pickers', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, const GoalsScreen(profile: _profile));
      for (final (row, option, shot) in const <(String, String, String)>[
        ('settings-sex', 'settings-sex-male', 'picker-sex'),
        ('settings-activity', 'settings-activity-moderate', 'picker-activity'),
        (
          'settings-weight-goal',
          'settings-weight-goal-lose05kg',
          'picker-weight-goal',
        ),
      ]) {
        await _tapRow(tester, row);
        expect(find.byKey(ValueKey<String>(option)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureDesignShot(tester, shot);
        await tester.tap(find.byKey(ValueKey<String>(option)));
        await tester.pumpAndSettle();
      }
    });
  });

  testWidgets('profile: the goals card built from SettingsRow', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(
        tester,
        ProfileScreen(
          name: 'Moritz Schneider',
          profile: _profile,
          weightLog: WeightLog(
            entries: [
              WeightLogEntry(timestamp: DateTime(2026, 9, 1), weightKg: 84),
              WeightLogEntry(timestamp: DateTime(2026, 9, 27), weightKg: 82),
            ],
          ),
          stats: LifetimeStats(
            mealsLogged: 124,
            weightLogs: 12,
            longestStreak: 21,
            sessionStart: DateTime(2026, 9, 1),
          ),
          dailyConsumedKcal: 1460,
          dailySteps: 6430,
          healthAuthState: HealthAuthState.denied,
          healthLastFetch: null,
          onLogWeight: (_) {},
          onEditProfile: () {},
          onOpenSettings: () {},
          onConnectHealth: () {},
          onRefreshHealth: () {},
        ),
      );
      await captureDesignShot(tester, 'profile-00');
      final edit = find.byKey(const ValueKey('profile-edit-goals'));
      if (edit.evaluate().isNotEmpty) {
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await captureDesignShot(tester, 'profile-goals-card');
    });
  });
}

void _noop() {}
