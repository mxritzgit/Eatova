import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/food_preferences.dart';

// Review 2026-10-19: what the user avoids must reach the recipe suggestions.
// Every catalog recipe carries reviewed `avoidanceTags`. This file is the
// second bookkeeping beside that data: keywords per code, in both languages,
// read from ingredients and preparation (folded like the search). A future
// recipe with "Lachs" but no fish tag fails here, and so does a tag nobody can
// find a reason for in the text. Tips in `professionalHint` do not count.

/// Keywords per code: a hit in the recipe text demands the tag. Conservative
/// on purpose (see the catalog's doc): soy sauce carries wheat and brewing
/// alcohol, curry paste shrimp paste or fish sauce, curry powder often
/// celery and mustard, pesto nuts, ready-made falafel flour.
final Map<FoodAvoidance, List<RegExp>> _keywords = {
  FoodAvoidance.lactose: _all([
    r'(?<!kokos)milch', 'butter', 'kaese', 'feta', 'quark', 'skyr',
    r'(?<!soja)joghurt', 'parmesan', 'halloumi', 'sahne', 'mozzarella',
    'pesto',
    // English
    r'(?<!coconut )milk', 'cheese', r'(?<!soy )yogh?urt', r'\bcream\b',
  ]),
  FoodAvoidance.gluten: _all([
    'weizen', 'dinkel', 'roggen', 'gerste', 'hafer', 'nudel', 'pasta',
    'penne', 'spaghetti', 'couscous', 'brot', 'tortilla', 'crouton',
    'granola', 'muesli', 'sojasauce', r'mehl\b', 'falafel', 'bulgur',
    // English
    'wheat', 'spelt', r'\brye\b', 'barley', r'\boats?\b', 'noodle', 'bread',
    'soy sauce', r'flour\b',
  ]),
  FoodAvoidance.nuts: _all([
    r'(?<!erd|muskat|kokos)nuss', r'(?<!erd)nuesse', 'mandel', 'cashew',
    'pistazie', 'pekan', 'macadamia', 'pinienkern', 'pesto', 'granola',
    'muesli',
    // English
    r'(?<!pea|coco|dough)nuts?\b', 'almond', 'pistachio', 'pecan',
  ]),
  FoodAvoidance.peanuts: _all([
    'erdnuss', 'erdnuesse', r'\bnuesse\b', 'granola', 'muesli',
    // English
    'peanut', r'\bnuts\b',
  ]),
  FoodAvoidance.egg: _all([
    r'\bei(ern?)?\b', 'eiklar', 'eigelb', 'eiweiss', 'ruehrei', 'omelett',
    'mayo',
    // English
    r'\beggs?\b', 'omelet', 'yolk',
  ]),
  FoodAvoidance.soy: _all([
    'soja', 'tofu', 'tempeh', 'edamame', 'miso',
    // English
    r'\bsoy',
  ]),
  FoodAvoidance.fish: _all([
    'fisch', 'lachs', 'kabeljau', 'sardelle', 'anchovis', 'forelle',
    'hering', 'makrele', 'zander', 'currypaste',
    // English
    r'(?<!shell)fish', 'salmon', r'\btuna\b', r'\bcod\b', 'anchov', 'trout',
    'herring', 'mackerel', 'sardine', 'curry paste',
  ]),
  FoodAvoidance.shellfish: _all([
    'garnele', 'krabbe', 'scampi', 'hummer', 'muschel', 'tintenfisch',
    'calamar', 'currypaste',
    // English
    'shrimp', 'prawn', r'\bcrab', 'lobster', 'mussel', r'\bclams?\b', 'squid',
    'octopus', 'curry paste',
  ]),
  FoodAvoidance.sesame: _all(['sesam', 'tahin', 'hummus', 'falafel']),
  FoodAvoidance.celery: _all([
    'sellerie', 'bruehe', 'curry',
    // English
    'celery', 'broth', 'bouillon',
  ]),
  FoodAvoidance.mustard: _all([
    'senf', 'curry',
    // English
    'mustard',
  ]),
  FoodAvoidance.pork: _all([
    'schwein', 'speck', 'schinken', 'salami', 'chorizo', 'bacon', 'gelatine',
    'pancetta',
    // English
    'pork', r'\bham\b', 'prosciutto', r'\blard\b',
  ]),
  FoodAvoidance.alcohol: _all([
    r'(?<!sch)wein', r'\bbier', r'\brum\b', 'likoer', r'\bsake\b', 'mirin',
    'sojasauce', 'alkohol', 'schnaps', 'sherry',
    // English
    // "beer" is a word of its own: German "Beeren" are berries.
    r'\bwine', r'\bbeers?\b', 'liqueur', 'soy sauce', 'alcohol', 'brandy',
    'vodka',
  ]),
};

List<RegExp> _all(List<String> patterns) => [
  for (final p in patterns) RegExp(p),
];

/// What a recipe's own text says, folded like the recipe search.
String _text(FitnessRecipe recipe) =>
    foldRecipeSearchText('${recipe.ingredients}\n${recipe.preparation}');

/// The codes whose keywords hit [recipe]'s text, each with the hits.
Map<FoodAvoidance, List<String>> _derived(FitnessRecipe recipe) {
  final text = _text(recipe);
  return {
    for (final MapEntry(key: code, value: patterns) in _keywords.entries)
      if (patterns.any((p) => p.hasMatch(text)))
        code: [
          for (final p in patterns)
            if (p.firstMatch(text) case final m?) m.group(0)!,
        ],
  };
}

const _catalogs = {'de': recipeCatalogDe, 'en': recipeCatalogEn};

FitnessRecipe _bySlug(String slug) =>
    recipeCatalogDe.firstWhere((r) => r.slug == slug);

FitnessRecipe _own({Set<FoodAvoidance>? tags}) => FitnessRecipe(
  slug: 'user_lachs',
  title: 'Mein Lachs',
  description: '',
  portion: '',
  ingredients: '200 g Lachs',
  preparation: '',
  professionalHint: '',
  imageAsset: '',
  caloriesKcal: 500,
  proteinG: 40,
  carbsG: 10,
  fatG: 30,
  estimatedGrams: 200,
  categories: const ['Eigene'],
  avoidanceTags: tags,
  userCreated: true,
);

void main() {
  group('Katalog-Tags', () {
    test(
      'jedes Katalogrezept ist geprüft, DE und EN tragen dieselben Tags',
      () {
        for (final MapEntry(key: lang, value: catalog) in _catalogs.entries) {
          for (final recipe in catalog) {
            expect(
              recipe.avoidanceTags,
              isNotNull,
              reason: '$lang/${recipe.slug}: ungeprüft (avoidanceTags fehlt)',
            );
          }
        }
        for (var i = 0; i < recipeCatalogDe.length; i++) {
          expect(
            recipeCatalogEn[i].avoidanceTags,
            recipeCatalogDe[i].avoidanceTags,
            reason: recipeCatalogDe[i].slug,
          );
        }
      },
    );

    test('jedes Schlüsselwort im Text hat seinen Tag (beide Sprachen)', () {
      for (final MapEntry(key: lang, value: catalog) in _catalogs.entries) {
        for (final recipe in catalog) {
          final derived = _derived(recipe);
          for (final MapEntry(key: code, value: hits) in derived.entries) {
            expect(
              recipe.avoidanceTags,
              contains(code),
              reason:
                  '$lang/${recipe.slug} nennt $hits, trägt aber keinen '
                  '${code.name}-Tag',
            );
          }
        }
      }
    });

    test('jeder Tag hat einen Grund im Text (beide Sprachen)', () {
      for (final MapEntry(key: lang, value: catalog) in _catalogs.entries) {
        for (final recipe in catalog) {
          final derived = _derived(recipe).keys.toSet();
          for (final code in recipe.avoidanceTags!) {
            expect(
              derived,
              contains(code),
              reason:
                  '$lang/${recipe.slug}: Tag ${code.name} ohne '
                  'Schlüsselwort im Text',
            );
          }
        }
      }
    });

    test('Stichproben der geprüften Daten', () {
      expect(_bySlug('lachs_mit_sukartoffel_and_spargel').avoidanceTags, {
        FoodAvoidance.fish,
        FoodAvoidance.mustard,
      });
      expect(
        _bySlug('skyr_bowl_mit_beeren_and_granola').avoidanceTags,
        containsAll([FoodAvoidance.nuts, FoodAvoidance.peanuts]),
      );
      expect(
        _bySlug('schweinefilet_mit_kartoffeln_and_brokkoli').avoidanceTags,
        contains(FoodAvoidance.pork),
      );
      // The optional anchovy counts.
      expect(
        _bySlug('hahnchen_caesar_salat').avoidanceTags,
        contains(FoodAvoidance.fish),
      );
      expect(_bySlug('hahnchen_mit_reis_and_brokkoli').avoidanceTags, isEmpty);
    });

    test('die Schlüsselwörter fangen ein neues Lachsrezept und lassen '
        'Kokosmilch, Schweinefilet und mehligkochend in Ruhe', () {
      expect(_derived(_own()).keys, contains(FoodAvoidance.fish));
      final tricky = _own().copyWith(
        ingredients:
            '100 ml Kokosmilch\n200 g Schweinefilet\n'
            '300 g Kartoffeln, mehligkochend\n1 Prise Muskatnuss\n'
            '300 g potatoes, floury\n100 ml coconut milk\n1 Eisbergsalat',
      );
      final codes = _derived(tricky).keys.toSet();
      expect(codes, {FoodAvoidance.pork});
    });
  });

  group('Modell', () {
    test('eigene Rezepte werden nie gefiltert und bekommen keinen Hinweis', () {
      final own = _own(tags: const {FoodAvoidance.fish});
      expect(own.avoidedFoods(const {FoodAvoidance.fish}), isEmpty);
      expect(own.fitsAvoidances(const {FoodAvoidance.fish}), isTrue);
    });

    test(
      'ein ungeprüftes Katalogrezept gilt als enthält-alles (fail-safe)',
      () {
        final unreviewed = recipeCatalogDe.first.copyWith().toUnreviewed();
        expect(unreviewed.avoidanceTags, isNull);
        expect(unreviewed.fitsAvoidances(const {}), isTrue);
        expect(
          unreviewed.avoidedFoods(const {
            FoodAvoidance.pork,
            FoodAvoidance.egg,
          }),
          [FoodAvoidance.egg, FoodAvoidance.pork],
        );
      },
    );

    test('Treffer kommen in Anzeige-Reihenfolge, nur die gemiedenen', () {
      final curry = _bySlug('hahnchen_curry_mit_reis');
      expect(
        curry.avoidedFoods(const {
          FoodAvoidance.mustard,
          FoodAvoidance.fish,
          FoodAvoidance.pork,
        }),
        [FoodAvoidance.fish, FoodAvoidance.mustard],
      );
      expect(curry.fitsAvoidances(const {FoodAvoidance.pork}), isTrue);
      expect(curry.fitsAvoidances(const {}), isTrue);
    });

    test('copyWith behält die Tags', () {
      final lachs = _bySlug('lachs_mit_sukartoffel_and_spargel');
      expect(lachs.copyWith(title: 'x').avoidanceTags, lachs.avoidanceTags);
    });
  });
}

extension on FitnessRecipe {
  /// The same catalog recipe without its reviewed tags.
  FitnessRecipe toUnreviewed() => FitnessRecipe(
    slug: slug,
    title: title,
    description: description,
    portion: portion,
    ingredients: ingredients,
    preparation: preparation,
    professionalHint: professionalHint,
    imageAsset: imageAsset,
    caloriesKcal: caloriesKcal,
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    estimatedGrams: estimatedGrams,
    categories: categories,
  );
}
