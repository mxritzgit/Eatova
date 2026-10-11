// Which lines are the same ingredient (2026-10-11). A missed merge costs one
// extra line; a wrong merge makes the user buy the wrong thing, so every
// product-changing word and compound keeps its own key. Staples decide the
// "Gewürze & Vorrat" section; ambiguous words go by their amount.

import 'package:eatova/src/models/shopping_amount.dart';
import 'package:eatova/src/models/shopping_ingredient_key.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Line = (String label, ShoppingUnit? unit);

String _id(_Line line) => shoppingIngredientKey(line.$1, unit: line.$2).id;

const _g = ShoppingUnit.mass;
const _tsp = ShoppingUnit.tsp;
const _piece = ShoppingUnit.piece;

void main() {
  test('Schreibweisen, Mehrzahl und Sprachen derselben Zutat sind eins', () {
    const same = <(_Line, _Line)>[
      (('Hähnchenbrustfilet, roh', _g), ('chicken breast fillet', _g)),
      (('Hähnchen-Brustfilet', _g), ('Hähnchenbrust', _g)),
      (('Hähnchenbrustfilet, gewürfelt', _g), ('Hühnerbrust', _g)),
      (('Hähnchenbrustfilet (ca. 200 g)', _g), ('Hähnchenbrust', _g)),
      // A decomposed umlaut, as some keyboards and imports write it.
      (('Ha\u0308hnchenbrust', _g), ('Hähnchenbrust', _g)),
      (('Zwiebeln', _piece), ('Zwiebel', _piece)),
      (('onions', _piece), ('Zwiebel', _piece)),
      (('1 kleine Zwiebel, sehr fein gewürfelt', _piece), ('onion', _piece)),
      (('rote Zwiebel', _piece), ('red onion', _piece)),
      (('Zwiebel, rot', _piece), ('rote Zwiebel', _piece)),
      (('Möhren', _g), ('Karotten', _g)),
      (('carrots', _g), ('Karotte', _g)),
      (('Champignons', _g), ('mushrooms', _g)),
      (('Eier', _piece), ('eggs', _piece)),
      (('Ei Größe M', _piece), ('large egg', _piece)),
      (('ganze Eier', _piece), ('whole eggs', _piece)),
      (('Eiklar', _g), ('egg whites', _g)),
      (('Äpfel', _piece), ('Apfel', _piece)),
      (('Nüsse', _g), ('Nuss', _g)),
      (('Tomaten', _g), ('tomatoes', _g)),
      (('Kirschtomaten', _g), ('cherry tomatoes', _g)),
      (('Cherry-Tomaten', _g), ('Cocktailtomaten', _g)),
      (('TK-Spinat', _g), ('TK Spinat', _g)),
      (('TK-Spinat', _g), ('frozen spinach', _g)),
      (('Spinat, TK', _g), ('TK-Spinat', _g)),
      (('frischer Spinat', _g), ('Babyspinat', _g)),
      (('gekochter Reis', _g), ('Reis, gekocht', _g)),
      (('gekochter Reis', _g), ('cooked rice', _g)),
      (('Kichererbsen, gegart', _g), ('cooked chickpeas', _g)),
      (('passierte Tomaten', _g), ('strained tomatoes', _g)),
      (('Paprikapulver edelsüß', _tsp), ('sweet paprika powder', _tsp)),
      (('Knoblauchzehe', ShoppingUnit.clove), ('garlic clove', _piece)),
      (('Knoblauchzehen, fein gehackt', _piece), ('Knoblauch', _piece)),
      (('Olivenöl', _g), ('olive oil', _g)),
      (('natives Olivenöl extra', _g), ('Olivenöl', _g)),
      (('Lachsfilet', _g), ('salmon', _g)),
      (('Lachsfilet, sehr frisch, gewürfelt', _g), ('Lachs', _g)),
      (('Thunfisch aus der Dose, im eigenen Saft', _g), ('canned tuna', _g)),
      (('Thunfisch', ShoppingUnit.can), ('canned tuna', _g)),
      (('Haferflocken, fein', _g), ('rolled oats', _g)),
      (('Vollkornreis oder Naturreis, roh', _g), ('brown rice', _g)),
      (('Vollkorn-Pasta', _g), ('whole-grain pasta', _g)),
      (('Vollkorn-Penne', _g), ('Vollkornpenne', _g)),
      (('Skyr natur', _g), ('plain skyr', _g)),
      (('Bio-Zitrone', _piece), ('Zitrone', _piece)),
      (('Zitronen', _piece), ('lemons', _piece)),
      (('Süßkartoffeln', _g), ('sweet potatoes', _g)),
      (('Frühlingszwiebeln', _piece), ('spring onions', _piece)),
      (('Lauchzwiebel', _piece), ('scallions', _piece)),
      (('Kokosmilch', ShoppingUnit.volume), ('coconut milk', null)),
      (('Kokosmilch light', ShoppingUnit.volume), ('light coconut milk', null)),
      (('griechischer Joghurt 2%', _g), ('Greek yogurt, 2%', _g)),
      (('Kartoffeln, festkochend', _g), ('waxy potatoes', _g)),
      (('grüne Bohnen', _g), ('green beans', _g)),
      (('rote Linsen, roh', _g), ('red lentils', _g)),
      (('mageres Rinderhack', _g), ('lean ground beef', _g)),
      (('minced beef', _g), ('Rinderhackfleisch', _g)),
      (('Putenhack, möglichst mager', _g), ('ground turkey, lean', _g)),
      (('geräucherter Lachs', _g), ('smoked salmon', _g)),
      (('Erdnussbutter', _g), ('Erdnuss-Butter', _g)),
      (('körniger Frischkäse', _g), ('cottage cheese', _g)),
      // Herbs: fresh by default or marked, dried by default or marked.
      (('Petersilie', null), ('frische Petersilie', null)),
      (('gehackte Petersilie', ShoppingUnit.tbsp), ('parsley', null)),
      (('Rosmarin', _tsp), ('dried rosemary', null)),
      (('Rosmarin', ShoppingUnit.sprig), ('fresh rosemary', null)),
      (('Koriander', ShoppingUnit.bunch), ('cilantro', null)),
      (('Koriander', _tsp), ('ground coriander', null)),
      // Spooned German "Paprika" is the powder.
      (('Paprika', _tsp), ('Paprikapulver', _tsp)),
      (('paprika', _tsp), ('paprika powder', _tsp)),
      (('Tomaten (Dose)', _g), ('canned tomatoes', _g)),
      (('Spinat (TK)', _g), ('TK-Spinat', _g)),
      (('Paprika', _piece), ('bell pepper', _g)),
      (('rote Paprika', _piece), ('red bell pepper', _piece)),
      (('Salz', null), ('salt', null)),
      (('Pfeffer, frisch gemahlen', null), ('black pepper', null)),
      (('pepper', null), ('ground black pepper', null)),
      (('gemahlener Kreuzkümmel', _tsp), ('Kreuzkümmel', _tsp)),
      (('Wasser', ShoppingUnit.volume), ('warmes Wasser', null)),
      // Grated or pressed ginger is the root, also by the spoon.
      (('grated ginger', _tsp), ('Ingwer', ShoppingUnit.centimetre)),
      (('Ingwer, gerieben', _tsp), ('Ingwer', ShoppingUnit.centimetre)),
      (('geriebener Ingwer', _tsp), ('fresh ginger', ShoppingUnit.tbsp)),
      (('Ingwer, gepresst', _tsp), ('Ingwer', null)),
      // Chopped tomatoes by weight or can are canned, also written after
      // the comma or "stückig"; counted ones are diced at home.
      (('stückige Tomaten', ShoppingUnit.can), ('gehackte Tomaten', _g)),
      (('Tomaten, stückig', _g), ('stückige Tomaten', _g)),
      (('Tomate(n), stückige', _g), ('chopped tomatoes', _g)),
      (('gehackte Tomaten', _g), ('Tomaten', ShoppingUnit.can)),
      (('diced tomatoes', _piece), ('tomatoes, diced', _piece)),
      (('gehackte Tomaten', _piece), ('Tomaten', _piece)),
      // Bought in a can or carton anyway.
      (('Mais', _g), ('Mais', ShoppingUnit.can)),
      (('Kichererbsen', _g), ('Kichererbsen (Dose)', _g)),
      (('Kokosmilch', ShoppingUnit.volume), ('Kokosmilch', ShoppingUnit.can)),
      // A fat level or flour type reads the same in brackets or not.
      (('Joghurt (3,5 %)', _g), ('Joghurt 3,5 %', _g)),
      (('Milch (1,5%)', null), ('Milch 1,5%', null)),
      (('griechischer Joghurt (2%)', _g), ('griechischer Joghurt 2%', _g)),
      (('Joghurt mit 1,5 % Fett', _g), ('Joghurt 1,5 %', _g)),
      (('Mehl, Type 405', _g), ('Mehl Type 405', _g)),
      (('Weizenmehl Typ 405', _g), ('Mehl (Type 405)', _g)),
      (('Mehl Tipo 00', _g), ('00 flour', _g)),
      // Chefkoch writes the name, then how it is prepared.
      (
        ('Hähnchenbrust, in mundgerechte Stücke geschnitten', _g),
        ('Hähnchenbrust', _g),
      ),
      (('Hähnchenbrustfilet, trocken getupft', _g), ('chicken breast', _g)),
      (
        ('chicken breast, cut into bite-sized pieces', _g),
        ('chicken breast', _g),
      ),
      (('chicken breast, pounded thin', _g), ('Hähnchenbrust', _g)),
      (('Hähnchenbrust mit Haut', _g), ('Hähnchenbrust', _g)),
      (('Lachsfilet, ohne Haut', _g), ('Lachs', _g)),
      (('salmon fillet, skin removed', _g), ('Lachs', _g)),
      (('Feta, zerbröselt', _g), ('crumbled feta', _g)),
      (('Avocados, entsteint', _piece), ('Avocado', _piece)),
      (('Petersilie, glatte', null), ('Petersilie', null)),
      (('Joghurt, griechischer', _g), ('griechischer Joghurt', _g)),
      (('Kartoffeln, vorwiegend festkochend', _g), ('waxy potatoes', _g)),
      (('lime, juiced', _piece), ('Limette', _piece)),
      (('Olivenöl, extra vergine', null), ('Olivenöl', null)),
      (('Gemüsebrühe, gekörnte', _tsp), ('Gemüsebrühe', _tsp)),
      (('Salz, jodiert', null), ('Salz', null)),
      (('Pfeffer, bunter', null), ('Pfeffer', null)),
      // An example or alternative after the name is not another item.
      (('Nudeln, z. B. Spaghetti', _g), ('Nudeln', _g)),
      (('pasta, e.g. penne', _g), ('Pasta', _g)),
      (('Reis, oder Quinoa', _g), ('Reis', _g)),
      // English and British names.
      (('red pepper', _piece), ('red bell pepper', _piece)),
      (('peppers', _piece), ('Paprika', _piece)),
      (('Pinienkerne', _g), ('pine nuts', _g)),
      (('Aubergine', _piece), ('eggplant', _piece)),
      // Paprika to garnish or sprinkle is the powder.
      (('Paprika, for garnish', null), ('Paprikapulver', null)),
      (('Paprika zum Bestreuen', null), ('paprika powder', null)),
    ];
    for (final (a, b) in same) {
      expect(_id(a), _id(b), reason: '$a ~ $b');
    }
  });

  test('was ein anderes Produkt ist, wird nie zusammengelegt', () {
    const different = <(_Line, _Line)>[
      // The owner's list.
      (('Kokosmilch', null), ('Milch', null)),
      (('Tomatenmark', ShoppingUnit.tbsp), ('Tomate', _piece)),
      (('Tomatenmark', _g), ('Tomaten', _g)),
      (('Kirschtomaten', _g), ('Tomaten', _g)),
      (('Süßkartoffel', _g), ('Kartoffel', _g)),
      (('Frühlingszwiebel', _piece), ('Zwiebel', _piece)),
      (('Paprikapulver', _tsp), ('Paprika', _piece)),
      (('Paprikapulver', null), ('Paprika', null)),
      (('Knoblauchpulver', _tsp), ('Knoblauch', ShoppingUnit.clove)),
      (('Erdnussbutter', _g), ('Butter', _g)),
      (('Haferflocken', _g), ('Hafermilch', ShoppingUnit.volume)),
      (('TK-Spinat', _g), ('Spinat', _g)),
      (('gekochter Reis', _g), ('Reis', _g)),
      // The same in English.
      (('coconut milk', null), ('milk', null)),
      (('tomato paste', null), ('tomatoes', null)),
      (('cherry tomatoes', null), ('tomatoes', null)),
      (('sweet potato', null), ('potato', null)),
      (('spring onion', null), ('onion', null)),
      (('garlic powder', null), ('garlic', null)),
      (('peanut butter', null), ('butter', null)),
      (('oats', null), ('oat milk', null)),
      (('frozen spinach', null), ('spinach', null)),
      (('cooked rice', null), ('rice', null)),
      // Colours, processing, packaging and parts of the animal.
      (('rote Zwiebel', _piece), ('Zwiebel', _piece)),
      (('rote Linsen', _g), ('Linsen', _g)),
      (('schwarze Bohnen', _g), ('Bohnen', _g)),
      (('grüne Bohnen', _g), ('Bohnen', _g)),
      (('rote Paprika', _piece), ('Paprika', _piece)),
      (('Thunfischsteak', _g), ('Thunfisch aus der Dose', _g)),
      (('Thunfischsteak', _g), ('Thunfisch', _g)),
      (('passierte Tomaten', _g), ('Tomaten', _g)),
      (('Tomaten', ShoppingUnit.can), ('Tomaten', _piece)),
      (('gehackte Tomaten (Dose)', _g), ('Tomaten', _g)),
      (('getrocknete Tomaten', _g), ('Tomaten', _g)),
      (('Kartoffeln, festkochend', _g), ('Kartoffeln, mehligkochend', _g)),
      (('Kartoffeln, festkochend', _g), ('Kartoffeln', _g)),
      (('griechischer Joghurt', _g), ('Joghurt', _g)),
      (('Magerquark', _g), ('Quark', _g)),
      (('Räucherlachs', _g), ('Lachs', _g)),
      (('geräucherter Lachs', _g), ('Lachs', _g)),
      (('Eiklar', _g), ('Eier', _piece)),
      (('egg whites', null), ('eggs', null)),
      (('Vollkornreis', _g), ('Reis', _g)),
      (('Basmatireis', _g), ('Reis', _g)),
      (('Hähnchenbrust', _g), ('Hähnchenschenkel', _g)),
      (('Putenhack', _g), ('Putenbrust', _g)),
      (('Rinderhack', _g), ('Rindersteak', _g)),
      (('minced beef', _g), ('beef', _g)),
      (('Hackfleisch gemischt', _g), ('Rinderhack', _g)),
      (('Kokoswasser', null), ('Wasser', null)),
      (('Sojamilch', null), ('Milch', null)),
      (('Mandelmilch', null), ('Milch', null)),
      (('Olivenöl', _g), ('Öl', _g)),
      (('Sesamöl', _g), ('Sesam', _tsp)),
      (('Zitronensaft', _tsp), ('Zitrone', _piece)),
      (('Limettensaft', _tsp), ('Limette', _piece)),
      (('Ingwer', ShoppingUnit.centimetre), ('Ingwerpulver', _tsp)),
      (('Ingwer', ShoppingUnit.centimetre), ('Ingwer', _tsp)),
      (('Koriander', ShoppingUnit.bunch), ('Koriander', _tsp)),
      (('frischer Rosmarin', null), ('Rosmarin', null)),
      (('getrocknete Petersilie', _tsp), ('Petersilie', null)),
      (('Chiliflocken', null), ('Chili', _piece)),
      (('Chili', _tsp), ('Chili', _piece)),
      (('pepper', null), ('pepper', _piece)),
      (('white pepper', null), ('black pepper', null)),
      (('Brokkoli, frisch oder TK', _g), ('TK-Brokkoli', _g)),
      // A line naming several things merges only with the same line.
      (('Sesam, Frühlingszwiebel, Xyzwurzel', null), ('Sesam', null)),
      (('Gemüse: Brokkoli und Karotten', _g), ('Gemüse', _g)),
      (('Gemüse: Brokkoli und Karotten', _g), ('Brokkoli', _g)),
      (('Lauch, Sellerie', _g), ('Lauch', _g)),
      // Ground ginger cannot be grated.
      (('grated ginger', _tsp), ('ground ginger', _tsp)),
      (('Ingwer, gerieben', _tsp), ('gemahlener Ingwer', _tsp)),
      (('geriebener Ingwer', _tsp), ('Ingwerpulver', _tsp)),
      // Counted tomatoes are fresh, however they are cut.
      (('diced tomatoes', _piece), ('diced tomatoes', ShoppingUnit.can)),
      (('gehackte Tomaten', _piece), ('gehackte Tomaten', ShoppingUnit.can)),
      (('chopped tomatoes', ShoppingUnit.cup), ('canned tomatoes', null)),
      (('Tomaten, stückig', _g), ('Tomaten', _g)),
      // Packed in oil is a product of its own, not oil.
      (('Thunfisch in Öl', _g), ('Thunfisch', _g)),
      (('Thunfisch in Öl', _g), ('Thunfisch im eigenen Saft', _g)),
      (('getrocknete Tomaten in Öl', _g), ('getrocknete Tomaten', _g)),
      (('sun-dried tomatoes in oil', _g), ('sun-dried tomatoes', _g)),
      // Fat levels and flour types, in brackets or not.
      (('Joghurt (0,1 %)', _g), ('Joghurt (3,5 %)', _g)),
      (('Joghurt (0,1 % Fett)', _g), ('Joghurt', _g)),
      (('Milch (1,5 %)', null), ('Milch (3,5 %)', null)),
      (('Griechischer Joghurt (10%)', _g), ('Griechischer Joghurt (0,2%)', _g)),
      (('Quark (20 %)', _g), ('Quark (40 %)', _g)),
      (('Mehl Type 405', _g), ('Mehl Type 1050', _g)),
      (('Mehl (Type 405)', _g), ('Mehl (Type 1050)', _g)),
      (('Dinkelmehl Type 630', _g), ('Dinkelmehl Type 1050', _g)),
      (('00 flour', _g), ('plain flour', _g)),
      // A flavour after "mit"/"with" makes another product.
      (('Frischkäse mit Kräutern', _g), ('Frischkäse', _g)),
      (('Joghurt mit Früchten', _g), ('Naturjoghurt', _g)),
      (
        ('diced tomatoes with green chiles', ShoppingUnit.can),
        ('diced tomatoes', ShoppingUnit.can),
      ),
      // Examples are not the ingredient.
      (('Fischfilet, z. B. Lachs', _g), ('Lachs', _g)),
      // A bare "Paprika" without an amount is neither for sure.
      (('Paprika', null), ('Paprika', _piece)),
      (('Paprika', null), ('Paprikapulver', null)),
      (('Paprika, for garnish', null), ('bell pepper', _piece)),
      (('Chili', null), ('Chili', _piece)),
      (('Chili', null), ('Chilipulver', null)),
    ];
    for (final (a, b) in different) {
      expect(_id(a), isNot(_id(b)), reason: '$a !~ $b');
    }
  });

  test('Vorrat: Gewürze immer, Kleinzeug nach Menge, Wasser nie', () {
    final always = <_Line>[
      ('Salz', null), ('Meersalz', null), ('Kräutersalz', _tsp),
      ('Pfeffer', null), ('schwarzer Pfeffer', null),
      ('Cayennepfeffer', ShoppingUnit.pinch), ('Paprikapulver', _tsp),
      ('Paprika edelsüß', _tsp), ('Currypulver', ShoppingUnit.tbsp),
      ('Curry', _tsp), ('Kreuzkümmel', _tsp),
      ('gemahlener Kreuzkümmel', _tsp), ('Zimt', null),
      ('Muskatnuss', ShoppingUnit.pinch), ('Chiliflocken', null),
      ('Gemüsebrühe', ShoppingUnit.volume), ('Hühnerbrühe', null),
      ('Brühwürfel', _piece), ('Backpulver', _tsp), ('Natron', _tsp),
      ('Hefe', _g), ('Trockenhefe', ShoppingUnit.pack),
      ('Vanillezucker', ShoppingUnit.pack), ('Speisestärke', _g),
      ('Oregano', _tsp), ('getrockneter Oregano', null), ('Thymian', null),
      ('Lorbeerblätter', _piece), ('italienische Kräuter', _tsp),
      ('Kräuter', _tsp), ('Gewürzmischung', null), ('Gyrosgewürz', _tsp),
      ('Knoblauchpulver', _tsp), ('Zwiebelpulver', _tsp),
      ('Garam Masala', _tsp), ('Kurkuma', _tsp),
      ('salt', null), ('pepper', null), ('black pepper', null),
      ('ground cumin', _tsp), ('chili flakes', null),
      ('red pepper flakes', null), ('vegetable stock', null),
      ('stock cube', _piece), ('baking soda', _tsp), ('yeast', _g),
      ('vanilla extract', _tsp), ('cornstarch', _g),
      ('dried oregano', null), ('bay leaves', _piece),
      ('garlic powder', null), ('onion powder', null),
      ('Italian seasoning', null), ('paprika', _tsp), ('cinnamon', null),
      // Ambiguous words by amount or marker.
      ('Paprika', _tsp), ('Chili', ShoppingUnit.pinch), ('Ingwer', _tsp),
      ('gemahlener Ingwer', null), ('Koriander', _tsp),
      ('getrocknete Petersilie', _tsp), ('getrocknetes Basilikum', null),
      ('Rosmarin', null), ('crushed chili', _tsp),
      ('Paprika, for garnish', null), ('Paprika zum Bestreuen', null),
      ('Chili zum Bestreuen', null), ('ground ginger', _tsp),
      ('Ingwer, gemahlen', _tsp),
      // Chefkoch's attribute after the comma.
      ('Gemüsebrühe, gekörnte', _tsp), ('Brühe, gekörnte', _tsp),
      ('Gemüsebrühe, instant', _tsp), ('Salz, jodiert', null),
      ('Pfeffer, bunter', null),
    ];
    final small = <_Line>[
      ('Zucker', null),
      ('brauner Zucker', _g),
      ('Mehl', _g),
      ('Honig', _tsp),
      ('Ahornsirup', null),
      ('Senf', _tsp),
      ('Dijon-Senf', _tsp),
      ('Ketchup', null),
      ('Mayonnaise', null),
      ('Tomatenmark', ShoppingUnit.tbsp),
      ('Butter', _g),
      ('Paniermehl', _g),
      ('Semmelbrösel', null),
      ('Sojasauce', null),
      ('Fischsauce', null),
      ('Worcestershiresauce', null),
      ('Zitronensaft', _tsp),
      ('Limettensaft', null),
      ('Sesam', _tsp),
      ('sugar', null),
      ('flour', null),
      ('honey', null),
      ('maple syrup', null),
      ('mustard', null),
      ('soy sauce', null),
      ('lemon juice', null),
      ('breadcrumbs', null),
      ('tomato paste', null),
    ];
    final oil = <_Line>[
      ('Olivenöl', _g),
      ('Öl', _g),
      ('Rapsöl', null),
      ('Sesamöl', null),
      ('Balsamico', null),
      ('Apfelessig', null),
      ('olive oil', null),
      ('vinegar', null),
      ('rice vinegar', null),
      ('neutral oil', null),
      ('Olivenöl, extra vergine', null),
    ];
    final none = <_Line>[
      ('Hähnchenbrust', _g),
      ('Erdnussbutter', _g),
      ('Haferflocken', _g),
      ('Paprika', _piece),
      ('Paprika', _g),
      ('Paprika', null),
      ('rote Paprika', _piece),
      ('frischer Rosmarin', null),
      ('Rosmarin', ShoppingUnit.sprig),
      ('Thymian', ShoppingUnit.bunch),
      ('Petersilie', null),
      ('Petersilie nach Geschmack', null),
      ('gehackte Petersilie', ShoppingUnit.tbsp),
      ('Basilikum', null),
      ('fresh basil', null),
      ('frische Kräuter', null),
      ('Kokoswasser', null),
      ('Mineralwasser', null),
      ('Sprudelwasser', null),
      ('sparkling water', null),
      ('Zitrone', _piece),
      ('Ingwer', ShoppingUnit.centimetre),
      ('Ingwer', null),
      ('Koriander', ShoppingUnit.bunch),
      ('Koriander', null),
      ('gehackter Koriander', ShoppingUnit.tbsp),
      ('Chili', _piece),
      ('Chili', null),
      ('Gewürzgurken', _piece),
      ('Hafermilch', null),
      ('Kokosmilch', null),
      ('Vanillejoghurt', _g),
      ('Currypaste', ShoppingUnit.tbsp),
      ('pepper', _piece),
      ('red pepper', _piece),
      ('bell pepper', null),
      ('Hähnchen optional', _g),
      ('Pfefferminze', null),
      ('grated ginger', _tsp),
      ('Ingwer, gerieben', _tsp),
      ('geriebener Ingwer', ShoppingUnit.tbsp),
      ('Thunfisch in Öl', _g),
      ('Thunfisch in Öl, abgetropft', _g),
      ('getrocknete Tomaten in Öl', _g),
      ('sun-dried tomatoes in oil', _g),
      ('Sardinen in Olivenöl', _g),
      ('tuna in extra virgin olive oil', _g),
      ('tuna in sunflower oil', _g),
      ('Chili, for garnish', null),
    ];
    final water = <_Line>[
      ('Wasser', ShoppingUnit.volume),
      ('Leitungswasser', null),
      ('warmes Wasser', null),
      ('kaltes Wasser', null),
      ('heißes Wasser', null),
      ('lauwarmes Wasser', null),
      ('Eiswasser', null),
      ('water', null),
      ('hot water', null),
      ('cold water', null),
      ('warm water', null),
      ('lukewarm water', null),
      ('ice water', null),
      ('boiling water', null),
    ];
    for (final (lines, staple) in [
      (always, ShoppingStaple.always),
      (small, ShoppingStaple.small),
      (oil, ShoppingStaple.oil),
      (none, ShoppingStaple.none),
      (water, ShoppingStaple.water),
    ]) {
      for (final (label, unit) in lines) {
        expect(
          shoppingIngredientKey(label, unit: unit).staple,
          staple,
          reason: '$label ($unit)',
        );
      }
    }
  });

  test('in einer Gewürzliste ist "Paprika" ohne Menge das Gewürz', () {
    for (final word in ['Paprika', 'Chili']) {
      expect(
        shoppingIngredientKey(word, seasoning: true).staple,
        ShoppingStaple.always,
        reason: word,
      );
      expect(shoppingIngredientKey(word).staple, ShoppingStaple.none);
      // An amount decides, not the list around it.
      expect(
        shoppingIngredientKey(word, unit: _piece, seasoning: true).staple,
        ShoppingStaple.none,
      );
    }
    // Fresh herbs stay fresh among seasonings.
    expect(
      shoppingIngredientKey('Koriander', seasoning: true).staple,
      ShoppingStaple.none,
    );
  });

  test('bekannte Zutaten und Sprache des Treffers', () {
    expect(shoppingIngredientKey('Hähnchenbrust').languages, {'de'});
    expect(shoppingIngredientKey('chicken breast').languages, {'en'});
    expect(shoppingIngredientKey('Mozzarella').languages, {'de', 'en'});
    expect(shoppingIngredientKey('Sardelle').known, isFalse);
    expect(shoppingIngredientKey('Kreuzkümmelsaat').known, isFalse);
    expect(shoppingIngredientKey('Rauchsalz').known, isTrue);
    expect(shoppingIngredientKey('Paprika', unit: _piece).ambiguous, isTrue);
    expect(shoppingIngredientKey('Paprikapulver').ambiguous, isFalse);
    expect(isShoppingModifier('optional'), isTrue);
    expect(isShoppingModifier('fein gehackt'), isTrue);
    expect(isShoppingModifier('frisch gemahlen'), isTrue);
    expect(isShoppingModifier('in Scheiben'), isTrue);
    expect(isShoppingModifier('ca. 50 g'), isTrue);
    expect(isShoppingModifier('2%'), isTrue);
    expect(isShoppingModifier('Petersilie'), isFalse);
    expect(isShoppingModifier('(2%)'), isTrue);
    expect(isShoppingModifier('Type 405'), isTrue);
    expect(
      shoppingIngredientKey('Thunfisch in Öl, abgetropft').id,
      'inoil+tuna',
    );
    expect(shoppingIngredientKey('Paprika').ambiguous, isTrue);
    expect(shoppingIngredientKey('Paprika').known, isTrue);
  });
}
