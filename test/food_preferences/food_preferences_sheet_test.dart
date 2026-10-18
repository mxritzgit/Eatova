// The diet editor in the profile (F8): card, sheet, save, discard, failure,
// screen reader states and 2x text on a 320 px phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/widgets/profile/food_preferences_sheet.dart';

import '../support/harness.dart';

Future<void> _pumpCard(
  WidgetTester tester, {
  FoodPreferences preferences = const FoodPreferences(),
  Future<void> Function(FoodPreferences)? onSave,
  double textScale = 1.0,
  Size? surfaceSize,
}) => pumpLocalized(
  tester,
  SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: FoodPreferencesCard(preferences: preferences, onSave: onSave),
  ),
  textScale: textScale,
  surfaceSize: surfaceSize,
  settle: true,
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('profile-edit-food-prefs')));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the card says what is set, without an edit button when '
      'there is no save path', (tester) async {
    await _pumpCard(tester);
    expect(find.text('Ernährungsform'), findsOneWidget);
    expect(find.text('Alles'), findsOneWidget);
    expect(find.text('Das isst du nicht'), findsOneWidget);
    expect(find.text('Nichts angegeben'), findsOneWidget);
    expect(find.text('Abneigungen'), findsNothing, reason: 'no empty row');
    expect(find.byKey(const ValueKey('profile-edit-food-prefs')), findsNothing);

    await _pumpCard(
      tester,
      preferences: const FoodPreferences(
        diet: DietPreference.pescetarian,
        avoidances: <FoodAvoidance>{FoodAvoidance.pork, FoodAvoidance.gluten},
        dislikes: 'Rosinen',
      ),
      onSave: (_) async {},
    );
    expect(find.text('Pescetarisch'), findsOneWidget);
    expect(find.text('Gluten, Schweinefleisch'), findsOneWidget);
    expect(find.text('Rosinen'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-edit-food-prefs')),
      findsOneWidget,
    );
  });

  testWidgets('change the diet, pick foods, type dislikes, save once', (
    tester,
  ) async {
    final saved = <FoodPreferences>[];
    await _pumpCard(tester, onSave: (p) async => saved.add(p));
    await _openSheet(tester);

    expect(
      find.text(
        'Der Coach berücksichtigt das, eine Garantie ist es nicht. '
        'Prüfe Zutaten bei Allergien selbst.',
      ),
      findsOneWidget,
    );
    await _tapVisible(tester, const ValueKey('food-prefs-diet-vegan'));
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-nuts'));
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-lactose'));
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-egg'));
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-egg'));
    await tester.ensureVisible(
      find.byKey(const ValueKey('food-prefs-dislikes')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('food-prefs-dislikes')),
      '  Koriander,   Pilze ',
    );
    await tester.pump();
    await _tapVisible(tester, const ValueKey('food-prefs-save'));

    expect(saved, <FoodPreferences>[
      const FoodPreferences(
        diet: DietPreference.vegan,
        avoidances: <FoodAvoidance>{FoodAvoidance.lactose, FoodAvoidance.nuts},
        dislikes: 'Koriander, Pilze',
      ),
    ]);
    expect(find.byType(FoodPreferencesSheet), findsNothing, reason: 'closed');
  });

  testWidgets('angle brackets never reach the field', (tester) async {
    final saved = <FoodPreferences>[];
    await _pumpCard(tester, onSave: (p) async => saved.add(p));
    await _openSheet(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('food-prefs-dislikes')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('food-prefs-dislikes')),
      '<b>Pilze</b>',
    );
    await tester.pump();
    await _tapVisible(tester, const ValueKey('food-prefs-save'));
    expect(saved.single.dislikes, 'bPilze/b');
  });

  testWidgets('unchanged: save closes without a write', (tester) async {
    var calls = 0;
    await _pumpCard(
      tester,
      preferences: const FoodPreferences(diet: DietPreference.vegetarian),
      onSave: (_) async => calls++,
    );
    await _openSheet(tester);
    await _tapVisible(tester, const ValueKey('food-prefs-save'));
    expect(calls, 0);
    expect(find.byType(FoodPreferencesSheet), findsNothing);
  });

  testWidgets('a change is never discarded without asking', (tester) async {
    var calls = 0;
    await _pumpCard(tester, onSave: (_) async => calls++);
    await _openSheet(tester);
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-soy'));

    await tester.tap(find.byKey(const ValueKey('food-prefs-close')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('discard-changes-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('discard-changes-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(FoodPreferencesSheet), findsOneWidget, reason: 'kept');

    await tester.tap(find.byKey(const ValueKey('food-prefs-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discard-changes-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(FoodPreferencesSheet), findsNothing);
    expect(calls, 0);
  });

  testWidgets('a failed save keeps the sheet and the draft', (tester) async {
    await _pumpCard(
      tester,
      onSave: (_) async => throw StateError('Profile storage is not ready'),
    );
    await _openSheet(tester);
    await _tapVisible(tester, const ValueKey('food-prefs-diet-vegan'));
    await _tapVisible(tester, const ValueKey('food-prefs-save'));

    expect(find.byType(FoodPreferencesSheet), findsOneWidget);
    expect(
      find.text(
        'Die Änderung konnte nicht auf diesem Gerät gespeichert werden. '
        'Bitte versuche es erneut.',
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('food-prefs-diet-vegan'))),
      isSemantics(isSelected: true),
      reason: 'draft kept',
    );
  });

  testWidgets('screen readers hear the chip and diet states', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpCard(tester, onSave: (_) async {});
    await _openSheet(tester);
    await _tapVisible(tester, const ValueKey('food-prefs-avoid-fish'));

    expect(
      tester.getSemantics(find.byKey(const ValueKey('food-prefs-avoid-fish'))),
      isSemantics(isButton: true, isSelected: true, label: 'Fisch'),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('food-prefs-avoid-egg'))),
      isSemantics(isButton: true, isSelected: false, label: 'Ei'),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('food-prefs-diet-none'))),
      isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true),
    );
    semantics.dispose();
  });

  testWidgets('2x text on a 320 px phone: no overflow, save reachable', (
    tester,
  ) async {
    final saved = <FoodPreferences>[];
    await _pumpCard(
      tester,
      preferences: const FoodPreferences(
        diet: DietPreference.pescetarian,
        avoidances: <FoodAvoidance>{
          FoodAvoidance.shellfish,
          FoodAvoidance.peanuts,
          FoodAvoidance.alcohol,
        },
        dislikes: 'Koriander, Pilze, Rosinen und Oliven',
      ),
      onSave: (p) async => saved.add(p),
      textScale: 2.0,
      surfaceSize: const Size(320, 640),
    );
    expect(tester.takeException(), isNull, reason: 'card');
    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-edit-food-prefs')),
    );
    await _openSheet(tester);
    expect(tester.takeException(), isNull, reason: 'sheet');

    await _tapVisible(tester, const ValueKey('food-prefs-avoid-shellfish'));
    await _tapVisible(tester, const ValueKey('food-prefs-save'));
    expect(tester.takeException(), isNull);
    expect(saved.single.avoidances, {
      FoodAvoidance.peanuts,
      FoodAvoidance.alcohol,
    });
  });

  testWidgets('the profile screen shows the section and hands the save on', (
    tester,
  ) async {
    final saved = <FoodPreferences>[];
    await pumpLocalized(
      tester,
      ProfileScreen(
        name: 'Moritz',
        profile: const UserProfile(
          diet: DietPreference.vegetarian,
          onboardingCompleted: true,
        ),
        weightLog: const WeightLog(),
        stats: LifetimeStats(),
        dailyConsumedKcal: 0,
        dailySteps: null,
        healthAuthState: HealthAuthState.unknown,
        healthLastFetch: null,
        onLogWeight: (_) {},
        onEditProfile: () {},
        onOpenSettings: () {},
        onConnectHealth: () {},
        onRefreshHealth: () {},
        onSaveFoodPreferences: saved.add,
      ),
      safeArea: false,
      settle: true,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-food-prefs')),
    );
    expect(find.text('Ernährung'), findsOneWidget);
    expect(find.text('Vegetarisch'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('profile-edit-food-prefs')),
    );
    await _openSheet(tester);
    await _tapVisible(tester, const ValueKey('food-prefs-diet-vegan'));
    await _tapVisible(tester, const ValueKey('food-prefs-save'));
    expect(saved.single.diet, DietPreference.vegan);
  });
}
