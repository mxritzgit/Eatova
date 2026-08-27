// Fix-Lauf 2026-08-27, Paket I (F6-03): Löschen eines eigenen Rezepts mit
// Undo-Snack.
//
// Vorher: Mülleimer → sofort weg, kein Dialog, kein Undo — und die
// Foto-Bytes liegen nur auf diesem Gerät. Jetzt: das Rezept verschwindet
// lokal, der Snack bietet „Rückgängig"; erst nach Ablauf der Frist
// ([kRecipeUndoWindow]) wird der Store-Hook gerufen und das Bild gelöscht.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

/// Bildspeicher-Double: merkt sich nur, was gelöscht werden sollte.
class _RecordingImageStore extends RecipeImageStore {
  _RecordingImageStore()
      : super(baseDirectory: () async => Directory.systemTemp);

  final List<String> deleted = <String>[];

  @override
  bool get baseResolved => true;

  @override
  File? resolveSync(String imageAsset) => null;

  @override
  Future<File?> resolve(String imageAsset) async => null;

  @override
  Future<void> deleteFor(String imageAsset) async {
    deleted.add(imageAsset);
  }
}

FitnessRecipe _rezept(String slug, {String title = 'Weg-Bowl'}) =>
    FitnessRecipe(
      slug: slug,
      title: title,
      description: '',
      portion: '',
      ingredients: '',
      preparation: '',
      professionalHint: '',
      imageAsset: '${RecipeImageStore.referencePrefix}$slug.jpg',
      caloriesKcal: 600,
      proteinG: 50,
      carbsG: 60,
      fatG: 15,
      estimatedGrams: 400,
      categories: const <String>['Eigene'],
      userCreated: true,
    );

class _Host extends StatelessWidget {
  const _Host({
    required this.recipes,
    required this.onDelete,
    this.visible = true,
  });

  final List<FitnessRecipe> recipes;
  final Future<SyncDelivery> Function(String slug) onDelete;

  /// `false` = versteckter Tab: die Home-Shell (IndexedStack, D6) lässt den
  /// Screen gemountet und dämpft ihn per [TickerMode] — genau das wird hier
  /// nachgebildet.
  final bool visible;

  @override
  Widget build(BuildContext context) => TickerMode(
        enabled: visible,
        child: RecipesScreen(
          onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          initialUserRecipes: recipes,
          onDeleteRecipe: onDelete,
        ),
      );
}

/// [_Host] in the localized harness (dark, de) — same tree as before.
Future<void> _pumpHost(WidgetTester tester, _Host host) =>
    pumpLocalized(tester, host, reducedMotion: false, safeArea: false);

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Löscht über die Detailansicht — der einzige Einstieg.
Future<void> _loesche(WidgetTester tester, String slug) async {
  await tester.tap(find.byKey(ValueKey('recipe-tile-$slug')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
  await tester.pumpAndSettle();
}

/// Lässt die Undo-Frist verstreichen und den Commit durchlaufen.
///
/// In 100-ms-Frames statt einem einzigen großen `pump`: ein Frame, der erst
/// eine Sekunde nach `showSnackBar` kommt, lässt den Folge-Snack unter
/// FakeAsync verschwinden (Ticker-Sprung) — in der App laufen Frames
/// regelmäßig, also wird das hier nachgebildet.
Future<void> _fristAblaufen(WidgetTester tester) async {
  final schritte = (kRecipeUndoWindow.inMilliseconds + 200) ~/ 100;
  for (var i = 0; i < schritte; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

late _RecordingImageStore _store;

void main() {
  setUp(() {
    _store = _RecordingImageStore();
    RecipeImageStore.instance = _store;
  });

  tearDown(RecipeImageStore.resetInstance);

  testWidgets('Löschen blendet aus und bietet „Rückgängig" — nichts ist '
      'persistiert, solange die Frist läuft', (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');

    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsNothing);
    expect(find.text('„Weg-Bowl" gelöscht.'), findsOneWidget);
    expect(find.text('Rückgängig'), findsOneWidget);
    expect(calls, isEmpty, reason: 'Der Hook darf erst nach der Frist laufen.');
    expect(_store.deleted, isEmpty,
        reason: 'Die Foto-Bytes sind unwiederbringlich — nicht vor der Frist.');
  });

  testWidgets('„Rückgängig" holt das Rezept zurück; der Hook läuft nie',
      (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsOneWidget);

    await _fristAblaufen(tester);
    await tester.pump(const Duration(seconds: 5));

    expect(calls, isEmpty);
    expect(_store.deleted, isEmpty);
    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsOneWidget);
  });

  testWidgets('nach der Frist: Hook genau einmal, Bild weg, kein zweiter '
      'Snack bei Zustellung', (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    await _fristAblaufen(tester);

    expect(calls, ['user_weg']);
    expect(_store.deleted, ['${RecipeImageStore.referencePrefix}user_weg.jpg']);
    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsNothing);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'Zugestellt ist, was der Undo-Snack schon sagte.');
  });

  testWidgets('nur eingereiht: nach der Frist folgt die ehrliche Meldung, '
      'das Bild bleibt', (tester) async {
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (_) async => SyncDelivery.queuedOffline,
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    await _fristAblaufen(tester);

    expect(
      find.text('„Weg-Bowl" gelöscht — wird synchronisiert, sobald du '
          'wieder online bist.'),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_store.deleted, isEmpty,
        reason: 'Eine verworfene Löschung bringt das Rezept zurück — dann '
            'muss das Bild noch da sein.');
  });

  testWidgets('Undo-Snack ist Ausnahme des Gap-E-Prinzips: nach Ablauf '
      'genau eine Folge-Meldung', (tester) async {
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (_) async => SyncDelivery.queuedRetry,
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    expect(find.byType(SnackBar), findsOneWidget);
    await _fristAblaufen(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.text('„Weg-Bowl" gelöscht — die Übertragung wird automatisch '
          'wiederholt.'),
      findsOneWidget,
    );
  });

  testWidgets('Screen wird während der Frist entfernt (Logout/Route, NICHT '
      'Tab-Wechsel — der IndexedStack hält Tabs): die Löschung wird trotzdem '
      'persistiert', (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    expect(calls, isEmpty);

    // Unmount, bevor die Frist abläuft.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(calls, ['user_weg']);
  });

  testWidgets('„Eigene"-Filter fällt mit dem letzten eigenen Rezept auf '
      '„Alle" zurück und kommt per Undo wieder', (tester) async {
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (_) async => SyncDelivery.delivered,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('recipe-filter-Eigene')));
    await tester.pumpAndSettle();
    expect(find.text('1 Treffer'), findsOneWidget);

    await _loesche(tester, 'user_weg');

    expect(find.byKey(const ValueKey('recipe-filter-Eigene')), findsNothing);
    expect(find.text('Alle Rezepte'), findsOneWidget,
        reason: 'Die Überschrift zeigt den aktiven Filter.');
    expect(find.text('${fitnessRecipes.length} Treffer'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recipe-filter-Eigene')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsOneWidget);
  });

  testWidgets('versteckter Tab (TickerMode aus): Commit läuft, aber kein '
      'Folge-Snack ins Leere', (tester) async {
    final calls = <String>[];
    Future<SyncDelivery> onDelete(String slug) async {
      calls.add(slug);
      return SyncDelivery.queuedOffline;
    }

    _pinViewport(tester);
    final rezepte = [_rezept('user_weg')];
    await _pumpHost(tester, _Host(recipes: rezepte, onDelete: onDelete));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    // Tab-Wechsel: der Screen bleibt gemountet, wird aber gedämpft.
    await _pumpHost(
      tester,
      _Host(recipes: rezepte, onDelete: onDelete, visible: false),
    );
    await _fristAblaufen(tester);

    expect(calls, ['user_weg'],
        reason: 'Der Commit hängt nicht am Sichtbarsein.');
    expect(find.byType(SnackBar), findsNothing,
        reason: 'Ein queued-Hinweis auf einem versteckten Tab tauchte sonst '
            'später an falscher Stelle auf.');

    // Zurück auf den Tab: das Rezept ist weg, kein nachgeholter Snack.
    await _pumpHost(tester, _Host(recipes: rezepte, onDelete: onDelete));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-tile-user_weg')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('zweites Löschen während der Frist: der zweite Snack ersetzt '
      'den ersten, der erste Commit läuft trotzdem, Undo gilt dem zweiten',
      (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [
        _rezept('user_a', title: 'A-Bowl'),
        _rezept('user_b', title: 'B-Bowl'),
      ],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_a');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _loesche(tester, 'user_b');
    expect(find.text('„B-Bowl" gelöscht.'), findsOneWidget);
    expect(find.text('„A-Bowl" gelöscht.'), findsNothing,
        reason: 'showAppSnack ersetzt den aktuellen Snack — das Undo von A '
            'ist ab jetzt nicht mehr tippbar (dokumentiert).');

    // Frist von A läuft ab, während der Snack von B noch steht.
    for (var i = 0; i < 40 && !calls.contains('user_a'); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, ['user_a']);
    expect(find.text('Rückgängig'), findsOneWidget,
        reason: 'Vorbedingung: der Snack von B ist noch da.');

    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recipe-tile-user_b')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-tile-user_a')), findsNothing);

    await _fristAblaufen(tester);
    expect(calls, ['user_a'], reason: 'B wurde zurückgeholt, A bleibt weg.');
  });

  testWidgets('nach Ablauf gibt es nichts mehr rückgängig zu machen: der '
      'Commit läuft genau einmal, auch wenn der Screen danach verschwindet',
      (tester) async {
    final calls = <String>[];
    _pinViewport(tester);
    await _pumpHost(tester, _Host(
      recipes: [_rezept('user_weg')],
      onDelete: (slug) async {
        calls.add(slug);
        return SyncDelivery.delivered;
      },
    ));
    await tester.pumpAndSettle();

    await _loesche(tester, 'user_weg');
    await _fristAblaufen(tester);
    expect(calls, ['user_weg']);
    expect(find.text('Rückgängig'), findsNothing,
        reason: 'Der Undo-Snack ist vor dem Commit verschwunden — die Frist '
            'endet bewusst NACH seiner Dismiss-Zeit.');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls, ['user_weg'],
        reason: 'dispose() findet keine offene Löschung mehr vor.');
  });
}
