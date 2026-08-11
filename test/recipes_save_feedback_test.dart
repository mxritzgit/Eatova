// Luecke E — die Erfolgsmeldung des Rezepte-Tabs hatte keine Deckung.
//
// `_openCreateSheet` rief `onCreateRecipe?.call(recipe)` und zeigte
// UNMITTELBAR danach, synchron und unbedingt, „„X" gespeichert." — egal was
// Store und Netz taten. Lokal stimmte die Aussage (seit Luecke A liegt das
// Rezept im Cache), aber der Store schob bei einem gescheiterten Write seinen
// eigenen Warteschlangen-Hinweis nach, und `showAppSnack` raeumt den vorigen
// Toast dabei ab: der Nutzer sah „gespeichert." kurz aufblitzen und dann
// „Offline — …". Zwei Meldungen, von denen die erste zu viel versprach.
//
// Diese Suite haelt fest, dass GENAU EINE Meldung kommt und dass sie den
// tatsaechlichen Ausgang spiegelt. Sie treibt den Screen ueber den echten
// Hook-Vertrag ([SyncDelivery]); wer den Ausgang liefert (der Store) ist in
// home_store_outbox_test.dart geprueft.
//
// Zweites Thema: `_locallyMutated` sperrte fuer den REST DER SITZUNG jede
// Uebernahme des Store-Stands, sobald der Nutzer einmal etwas angelegt oder
// geloescht hatte. Nach den Fixes A–C ist der Store die verlaesslichere Quelle
// — und die Sperre richtet aktiven Schaden an, siehe letzter Test.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';

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

/// Bildet die Home-Schale nach: sie reicht `store.userRecipes` durch und baut
/// den Screen neu, sobald der Store notifyt (der weist die Liste bei jeder
/// Mutation NEU zu — daran haengt `didUpdateWidget`).
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

  /// Ein neuer Store-Stand kommt herein (Boot-Load, Merge, Wiedereinblendung
  /// nach verworfener Loesch-Op).
  void meldeStoreStand(List<FitnessRecipe> next) =>
      setState(() => _recipes = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
            initialUserRecipes: _recipes,
            onCreateRecipe: widget.onCreate,
            onDeleteRecipe: widget.onDelete,
          ),
        ),
      );
}

/// Viewport-Pinning + Overflow-Toleranz wie in recipe_create_sheet_test.dart.
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

/// Legt ueber das Sheet ein Rezept namens [name] an.
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

/// Alle gerade sichtbaren Snack-Texte.
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
      await tester.pumpWidget(_Host(
        onCreate: (_) async => SyncDelivery.delivered,
      ));
      await _legeRezeptAn(tester);

      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });

    testWidgetsRobust(
        'nur eingereiht (offline): die Meldung nennt die Warteschlange, statt '
        'Zustellung zu behaupten', (tester) async {
      await tester.pumpWidget(_Host(
        onCreate: (_) async => SyncDelivery.queuedOffline,
      ));
      await _legeRezeptAn(tester);

      expect(
        find.text('„Protein-Bowl" gespeichert — wird synchronisiert, sobald '
            'du wieder online bist.'),
        findsOneWidget,
      );
      // Und eben NICHT die blanke Erfolgsmeldung: sie war der ganze Bug.
      expect(find.text('„Protein-Bowl" gespeichert.'), findsNothing);
    });

    testWidgetsRobust(
        'eingereiht, obwohl der Server antwortete: kein Offline-Versprechen',
        (tester) async {
      await tester.pumpWidget(_Host(
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
      await tester.pumpWidget(_Host(onCreate: (_) => ausgang.future));
      await _legeRezeptAn(tester);

      // Solange der Store nicht geantwortet hat, gibt es nichts zu melden —
      // frueher stand hier schon „gespeichert.".
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
      await tester.pumpWidget(_Host(
        onCreate: (_) async => SyncDelivery.queuedOffline,
      ));
      await _legeRezeptAn(tester);

      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgetsRobust(
        'ohne Persistenz-Hook (Vorschau/Test) bleibt es bei der schlichten '
        'Meldung — es gibt nichts zu synchronisieren', (tester) async {
      await tester.pumpWidget(const _Host());
      await _legeRezeptAn(tester);

      expect(find.text('„Protein-Bowl" gespeichert.'), findsOneWidget);
    });

    testWidgetsRobust(
        'die Loeschung meldet ebenso ehrlich', (tester) async {
      await tester.pumpWidget(_Host(
        initial: <FitnessRecipe>[_recipe('user_weg', title: 'Weg-Bowl')],
        onDelete: (_) async => SyncDelivery.queuedOffline,
      ));

      await tester.tap(find.byKey(const ValueKey('recipe-tile-user_weg')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();

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
      // Szenario aus _restoreDroppedDeletes: der Nutzer loescht ein Rezept,
      // die Loesch-Op faellt endgueltig aus, der Store blendet den Eintrag
      // wieder ein und meldet „der Eintrag ist wieder da". Mit `_locallyMutated`
      // hat die Loeschung die Sperre gesetzt — der Screen zeigte das Rezept
      // danach NIE wieder, obwohl der Snack das Gegenteil behauptete.
      final zurueck = _recipe('user_zurueck', title: 'Wieder-da-Bowl');
      await tester.pumpWidget(_Host(
        initial: <FitnessRecipe>[zurueck],
        onDelete: (_) async => SyncDelivery.delivered,
      ));

      await tester.tap(find.byKey(const ValueKey('recipe-tile-user_zurueck')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recipe-tile-user_zurueck')),
          findsNothing,
          reason: 'Vorbedingung: lokal ist das Rezept weg');

      // Der Store holt es zurueck.
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
      // Die Gegenprobe zur Sperre: sie existierte, weil ein nachgereichter
      // Boot-Stand das frisch angelegte Rezept sonst wegwarf. Seit Luecke C
      // MERGT der Store statt zu ersetzen — der nachgereichte Stand traegt das
      // eigene Rezept also selbst.
      final eigenes = <FitnessRecipe>[];
      await tester.pumpWidget(_Host(onCreate: (r) async {
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
