// Visual evidence for the settings polish (2026-10-02) and the goals page in
// the settings language (2026-10-04).
//
// Mounts the settings page and the goals page it leads to (plan hero,
// groups, pickers, the read-only trend row, the target notes) with realistic
// data at the design's reference geometry (390x844, DPR 2, real fonts). The
// profile has its own capture suite.
//
// With --dart-define=DARK_REDESIGN_CAPTURE=true the PNGs land in
// build/dark-redesign/. Without it the suite still checks that every surface
// renders without exceptions and that its key controls are present.

import 'package:clock/clock.dart';
import 'package:eatova/src/app/home_store.dart' show ReminderState;
import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/screens/settings/goals_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';
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
  int pending = 2,
  SyncBlockedReason? blocked,
}) {
  final repo = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'u1', email: _mail),
  );
  addTearDown(repo.dispose);
  final language = LocaleController();
  addTearDown(language.dispose);
  // The app shell always provides the scope; without it the appearance row
  // (System / Light / Dark) drops out.
  final themeMode = ThemeModeController();
  addTearDown(themeMode.dispose);
  return ThemeModeScope(
    controller: themeMode,
    child: LocaleScope(
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

Future<void> _tapRow(WidgetTester tester, String key) async {
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
        'settings-theme-mode',
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

  testWidgets('settings: the appearance row in each of its three states', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      await _mount(tester, _settings());
      final row = find.byKey(const ValueKey('settings-theme-mode'));
      // Mid-screen, so the shot shows the row's title above the pill.
      await Scrollable.ensureVisible(tester.element(row), alignment: 0.4);
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      for (final mode in const <String>['system', 'light', 'dark']) {
        final segment = find.byKey(ValueKey('settings-theme-mode-$mode'));
        await tester.tap(segment);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(segment),
          isSemantics(isSelected: true, isButton: true),
          reason: mode,
        );
        await captureDesignShot(tester, 'settings-theme-$mode');
      }
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

  testWidgets('goals: the read-only trend row (owner case 2026-10-04)', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      // Logged 117 kg while the smoothed trend still reads 119.1.
      await _mount(
        tester,
        GoalsScreen(
          profile: _profile.copyWith(weightKg: 119, targetWeightKg: 100),
          weightTrendKg: 119.1,
          latestWeighInKg: 117,
        ),
      );
      final row = find.byKey(const ValueKey('settings-weight-trend'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('Weight trend')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Last weigh-in 117 kg'),
        ),
        findsOneWidget,
      );
      await captureDesignShot(tester, 'goals-trend');
    });
  });

  testWidgets('goals: target reached and the BMI hint', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      // 54 kg at 181 cm aiming for 55 while "losing": the goal is reached,
      // and a target BMI under 18.5 adds the soft hint.
      await _mount(
        tester,
        GoalsScreen(
          profile: _profile.copyWith(weightKg: 54, targetWeightKg: 55),
        ),
      );
      final reached = find.byKey(const ValueKey('settings-target-reached'));
      await tester.ensureVisible(reached);
      await tester.pumpAndSettle();
      expect(reached, findsOneWidget);
      await captureDesignShot(tester, 'goals-notes');
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
}

void _noop() {}
