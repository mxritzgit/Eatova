import 'dart:ui' as ui;

import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

Future<void> loadAccountFonts() async {
  for (final family in {
    'Archivo': [
      'Archivo-Regular.ttf',
      'Archivo-SemiBold.ttf',
      'Archivo-Bold.ttf',
    ],
    'BricolageGrotesque': ['BricolageGrotesque-Bold.ttf'],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  }.entries) {
    final loader = FontLoader(family.key);
    for (final file in family.value) {
      loader.addFont(
        rootBundle.load(
          family.key == 'MaterialIcons' ? 'fonts/$file' : 'assets/fonts/$file',
        ),
      );
    }
    await loader.load();
  }
}

Widget studioProfile({String name = 'Moritz Schneider'}) => ProfileScreen(
  name: name,
  profile: const UserProfile(
    weightKg: 78,
    targetWeightKg: 72,
    weightGoal: WeightGoal.lose025kg,
    activityLevel: ActivityLevel.moderate,
  ),
  weightLog: WeightLog(
    entries: [
      WeightLogEntry(timestamp: DateTime(2026, 9, 1), weightKg: 80),
      WeightLogEntry(timestamp: DateTime(2026, 9, 13), weightKg: 78),
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
);

void main() {
  setUpAll(loadAccountFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('expanded choices paint keyboard focus and activate with enter', (
    tester,
  ) async {
    final capture = GlobalKey();
    final choices = <ThemeMode>[];
    await pumpLocalized(
      tester,
      RepaintBoundary(
        key: capture,
        child: SettingsThemeModePill(
          mode: ThemeMode.system,
          expanded: true,
          onChanged: choices.add,
        ),
      ),
      surfaceSize: const Size(390, 844),
      padding: const EdgeInsets.all(20),
      brightness: Brightness.light,
    );
    Future<List<int>> pixels() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List().toList();
      }))!;
    }

    final before = await pixels();
    final previous = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = previous);
    Focus.of(tester.element(find.text('Dunkel'))).requestFocus();
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('Dunkel'))).hasFocus, isTrue);
    expect(await pixels(), isNot(orderedEquals(before)));
    expect(choices, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(choices, [ThemeMode.dark]);
  });

  testWidgets('daily macro segments retain their visible height', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const GoalsCard(profile: UserProfile(), dailyKcal: 900, dailySteps: 1000),
      surfaceSize: const Size(390, 844),
    );
    final t = tester.element(find.byType(GoalsCard)).t;
    final segments = find.byWidgetPredicate(
      (widget) =>
          widget is ColoredBox &&
          [t.protein, t.carbs, t.fat].contains(widget.color),
    );
    expect(segments, findsNWidgets(3));
    for (final element in segments.evaluate()) {
      expect((element.renderObject! as RenderBox).size.height, 9);
    }
  });

  for (final locale in const [Locale('de'), Locale('en')]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'account menu keeps every preference reachable ${locale.languageCode} ${brightness.name} at 200%',
        (tester) async {
          final theme = ThemeModeController();
          final language = LocaleController();
          addTearDown(theme.dispose);
          addTearDown(language.dispose);
          await pumpLocalized(
            tester,
            ThemeModeScope(
              controller: theme,
              child: LocaleScope(
                controller: language,
                child: const SettingsScreen(
                  email: 'long.personal.address@example.com',
                ),
              ),
            ),
            locale: locale,
            brightness: brightness,
            textScale: 2,
            surfaceSize: const Size(320, 568),
            scaffold: false,
            safeArea: false,
            settle: true,
          );
          final page = find.byKey(const ValueKey('screen-settings'));
          final context = tester.element(page);
          final title = find.text(context.l10n.settingsAppearanceTitle);
          final dark = find.byKey(const ValueKey('settings-theme-mode-dark'));
          await tester.ensureVisible(title);
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(dark).dy,
            greaterThan(tester.getBottomLeft(title).dy),
          );
          await tester.ensureVisible(dark);
          await tester.pumpAndSettle();
          expect(tester.getSize(dark).width, greaterThan(270));
          await tester.tap(dark);
          await tester.pumpAndSettle();
          expect(theme.mode, ThemeMode.dark);
          final english = find.byKey(const ValueKey('settings-language-en'));
          await tester.ensureVisible(english);
          await tester.pumpAndSettle();
          await tester.tap(english);
          await tester.pumpAndSettle();
          expect(language.override, const Locale('en'));
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'profile identity and health guidance stay readable ${locale.languageCode} ${brightness.name} at 200%',
        (tester) async {
          await pumpLocalized(
            tester,
            studioProfile(),
            locale: locale,
            brightness: brightness,
            textScale: 2,
            surfaceSize: const Size(320, 568),
            scaffold: false,
            safeArea: false,
            settle: true,
          );
          final identity = tester.renderObject<RenderParagraph>(
            find.text('Moritz Schneider'),
          );
          expect(identity.didExceedMaxLines, isFalse);
          expect(
            identity.getBoxesForSelection(
              const TextSelection(baseOffset: 7, extentOffset: 16),
            ),
            hasLength(1),
          );
          expect(
            identity.getTransformTo(null).getMaxScaleOnAxis(),
            closeTo(1, 0.001),
          );
          final connect = find.byKey(const ValueKey('profile-health-connect'));
          await tester.ensureVisible(connect);
          await tester.pumpAndSettle();
          final l10n = tester.element(connect).l10n;
          final hint = tester.renderObject<RenderParagraph>(
            find.text(l10n.profileHealthDeniedHint),
          );
          expect(hint.didExceedMaxLines, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
