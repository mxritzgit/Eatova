// Gap E: the recipe tab's success toast was unbacked. `_openCreateSheet`
// claimed "saved" synchronously, then the store's queue hint replaced it, so
// the user saw two messages of which the first over-promised.
//
// This suite pins that exactly ONE message appears and that it mirrors the
// real outcome, driving the screen through the [SyncDelivery] hook contract.
//
// Second topic: `_locallyMutated` blocked every store update for the rest of
// the session after one create or delete. The store is the more reliable
// source, so that lock does active harm — see the last test.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart' hide testWidgetsRobust;

FitnessRecipe _recipe(String slug, {String title = 'Server-Bowl'}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: 'Eigenes Rezept',
      portion: '1 Teller',
      ingredients: 'Reis\nHaehnchen',
      preparation: 'Eigenes Rezept — keine Zubereitung hinterlegt.',
      professionalHint: 'Selbst angelegt.',
      imageAsset: '',
      caloriesKcal: 600,
      proteinG: 50,
      carbsG: 60,
      fatG: 15,
      estimatedGrams: 400,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

/// Mimics the home shell: forwards `store.userRecipes` and rebuilds on every
/// store notification (each mutation reassigns the list, which
/// `didUpdateWidget` relies on).
class _Host extends StatefulWidget {
  const _Host({
    this.onCreate,
    this.onDelete,
    this.initial = const <FitnessRecipe>[],
  });

  final Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreate;
  final Future<SyncDelivery> Function(String slug)? onDelete;
  final List<FitnessRecipe> initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<FitnessRecipe> _recipes = widget.initial;

  /// A new store state arrives (boot load, merge, or restore after a dropped
  /// delete op).
  void meldeStoreStand(List<FitnessRecipe> next) =>
      setState(() => _recipes = next);

  @override
  Widget build(BuildContext context) => RecipesScreen(
        onAddMeal: (MealAnalysisResult _, MealSlot __) {},
        initialUserRecipes: _recipes,
        onCreateRecipe: widget.onCreate,
        onDeleteRecipe: widget.onDelete,
      );
}

/// [_Host] in the localized harness (dark, de) — same tree as before.
Future<void> _pumpHost(WidgetTester tester, _Host host) =>
    pumpLocalized(tester, host, reducedMotion: false, safeArea: false);

/// Viewport pinning plus overflow tolerance.
void testWidgetsRobust(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prior?.call(details);
    };
    addTearDown(() => FlutterError.onError = prior);

    await callback(tester);
  });
}

/// Creates a recipe named [name] through the sheet.
Future<void> _legeRezeptAn(WidgetTester tester, {String name = 'Protein-Bowl'}) async {
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('recipe-create-name')), name);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('recipe-create-kcal')), '520');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('recipe-create-save')));
  await tester.pumpAndSettle();
}

/// Lets the delete's undo window pass in 100 ms frames (a single big pump
/// drops the follow-up snack under FakeAsync — ticker jump), then settles.
Future<void> _undoFristAblaufen(WidgetTester tester) async {
  final schritte = (kRecipeUndoWindow.inMilliseconds + 200) ~/ 100;
  for (var i = 0; i < schritte; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// All currently visible snack texts.
Iterable<String> _snackTexte(WidgetTester tester) => tester
    .widgetList<SnackBar>(find.byType(SnackBar))
    .expand((s) => _texteIn(tester, s));

Iterable<String> _texteIn(WidgetTester tester, SnackBar bar) => tester
    .widgetList<Text>(find.descendant(
      of: find.byWidget(bar),
      matching: find.byType(Text),
    ))
    .map((t) => t.data ?? '');

void main() {
  group('Luecke E — die Meldung sagt, was wirklich passiert ist', () {
    testWidgetsRobust(
        'zugestellt: die schlichte Erfolgsmeldung', (tester) async {
      await _pumpHost(tester, _Host(
        onCreate: (_) async => SyncDelivery.delivered,
      ));
      await _legeRezeptAn(tester);

      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });

    testWidgetsRobust(
        'nur eingereiht (offline): die Meldung nennt die Warteschlange, statt '
        'Zustellung zu behaupten', (tester) async {
      await _pumpHost(tester, _Host(
        onCreate: (_) async => SyncDelivery.queuedOffline,
      ));
      await _legeRezeptAn(tester);

      expect(
        find.text('„Protein-Bowl" gespeichert — wird synchronisiert, sobald '
            'du wieder online bist.'),
        findsOneWidget,
      );
      // Not the bare success message: that was the bug.
      expect(find.text('„Protein-Bowl" gespeichert.'), findsNothing);
    });

    testWidgetsRobust(
        'eingereiht, obwohl der Server antwortete: kein Offline-Versprechen',
        (tester) async {
      await _pumpHost(tester, _Host(
        onCreate: (_) async => SyncDelivery.queuedRetry,
      ));
      await _legeRezeptAn(tester);

      expect(
        find.text('„Protein-Bowl" gespeichert — die Übertragung wird '
            'automatisch wiederholt.'),
        findsOneWidget,
      );
    });

    testWidgetsRobust(
        'die Meldung wartet auf den Ausgang, statt ihn vorwegzunehmen',
        (tester) async {
      final ausgang = Completer<SyncDelivery>();
      await _pumpHost(tester, _Host(onCreate: (_) => ausgang.future));
      await _legeRezeptAn(tester);

      // Nothing to report until the store answers.
      expect(_snackTexte(tester), isEmpty);

      ausgang.complete(SyncDelivery.queuedOffline);
      await tester.pumpAndSettle();

      expect(
        find.text('„Protein-Bowl" gespeichert — wird synchronisiert, sobald '
            'du wieder online bist.'),
        findsOneWidget,
      );
    });

    testWidgetsRobust(
        'GENAU EINE Meldung — kein Erfolg, der von einem Hinweis ueberschrieben '
        'wird', (tester) async {
      await _pumpHost(tester, _Host(
        onCreate: (_) async => SyncDelivery.queuedOffline,
      ));
      await _legeRezeptAn(tester);

      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgetsRobust(
        'ohne Persistenz-Hook (Vorschau/Test) bleibt es bei der schlichten '
        'Meldung — es gibt nichts zu synchronisieren', (tester) async {
      await _pumpHost(tester, const _Host());
      await _legeRezeptAn(tester);

      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });

    testWidgetsRobust(
        'die Loeschung meldet ebenso ehrlich', (tester) async {
      await _pumpHost(tester, _Host(
        initial: <FitnessRecipe>[_recipe('user_weg', title: 'Weg-Bowl')],
        onDelete: (_) async => SyncDelivery.queuedOffline,
      ));

      await tester.tap(find.byKey(const ValueKey('recipe-tile-user_weg')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();

      // F6-03: first the undo toast — the delete is local only until the
      // window passes, so there is no outcome to report yet.
      expect(find.text('„Weg-Bowl" gelöscht.'), findsOneWidget);
      expect(find.text('Rückgängig'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);

      await _undoFristAblaufen(tester);

      expect(
        find.text('„Weg-Bowl" gelöscht — wird synchronisiert, sobald du '
            'wieder online bist.'),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('_locallyMutated — die Sperre gegen den Store-Stand', () {
    testWidgetsRobust(
        'nach einer lokalen Aenderung wird ein neuer Store-Stand TROTZDEM '
        'uebernommen (Wiedereinblendung nach verworfener Loesch-Op)',
        (tester) async {
      // _restoreDroppedDeletes scenario: the delete op is dropped for good and
      // the store brings the recipe back. With `_locallyMutated` the delete had
      // set the lock, so the screen never showed it again.
      final zurueck = _recipe('user_zurueck', title: 'Wieder-da-Bowl');
      await _pumpHost(tester, _Host(
        initial: <FitnessRecipe>[zurueck],
        onDelete: (_) async => SyncDelivery.delivered,
      ));

      await tester.tap(find.byKey(const ValueKey('recipe-tile-user_zurueck')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();
      // F6-03: the delete op only exists once the undo window has passed, so
      // a dropped op (and its restore) can only follow the commit.
      await _undoFristAblaufen(tester);
      expect(find.byKey(const ValueKey('recipe-tile-user_zurueck')),
          findsNothing,
          reason: 'Vorbedingung: lokal ist das Rezept weg');

      // The store brings it back.
      tester
          .state<_HostState>(find.byType(_Host))
          .meldeStoreStand(<FitnessRecipe>[zurueck]);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recipe-tile-user_zurueck')),
          findsOneWidget,
          reason: 'der Store ist seit Luecke A–C die verlaesslichere Quelle — '
              'seine Wiedereinblendung darf nicht an einer Sitzungs-Sperre '
              'haengenbleiben');
    });

    testWidgetsRobust(
        'ein selbst angelegtes Rezept ueberlebt die Uebernahme des '
        'Store-Stands', (tester) async {
      // Counter-check: the lock existed because a late boot state used to drop
      // the fresh recipe. The store now merges instead of replacing, so the
      // late state already carries it.
      final eigenes = <FitnessRecipe>[];
      await _pumpHost(tester, _Host(onCreate: (r) async {
        eigenes.add(r);
        return SyncDelivery.delivered;
      }));
      await _legeRezeptAn(tester, name: 'Eigen-Bowl');
      expect(eigenes, hasLength(1));

      final vomServer = _recipe('user_server', title: 'Server-Bowl');
      tester
          .state<_HostState>(find.byType(_Host))
          .meldeStoreStand(<FitnessRecipe>[eigenes.single, vomServer]);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('recipe-tile-${eigenes.single.slug}')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('recipe-tile-user_server')),
          findsOneWidget);
    });
  });
}
