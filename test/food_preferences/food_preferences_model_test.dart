// Food preferences (F8, C3): the model, its wire forms and the compatibility
// of older cache blobs and outbox ops.

import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/services/sync_operation_payload.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

const UserProfile _profile = UserProfile(
  weightKg: 82,
  diet: DietPreference.vegan,
  foodAvoidances: <FoodAvoidance>{FoodAvoidance.nuts, FoodAvoidance.lactose},
  foodDislikes: 'Koriander, Pilze',
  onboardingCompleted: true,
);

void main() {
  group('normalizeFoodDislikes matches profiles_food_dislikes_check', () {
    test('controls become spaces, angle brackets go, whitespace collapses', () {
      expect(
        normalizeFoodDislikes('  Pilze\n\tKoriander\u0085  <b>Oliven</b> '),
        'Pilze Koriander bOliven/b',
      );
    });

    test('lone surrogates are dropped, real emoji stay', () {
      expect(normalizeFoodDislikes('Pilze \ud800x'), 'Pilze x');
      expect(normalizeFoodDislikes('\u{1F344} Pilze'), '\u{1F344} Pilze');
    });

    test('the cap counts code points, like char_length', () {
      final emoji = '\u{1F344}' * (kFoodDislikesMaxChars + 5);
      final cut = normalizeFoodDislikes(emoji);
      expect(cut.runes.length, kFoodDislikesMaxChars);
      expect(cut.length, kFoodDislikesMaxChars * 2, reason: 'no split pair');
      expect(normalizeFoodDislikes('a' * 200).length, kFoodDislikesMaxChars);
      expect(
        normalizeFoodDislikes('${'a' * 119} b'),
        'a' * 119,
        reason: 'no trailing space after the cut',
      );
    });

    test('a normalized text stays the same', () {
      const clean = 'Koriander, Pilze & Oliven (grün)';
      expect(normalizeFoodDislikes(clean), clean);
      expect(normalizeFoodDislikes(normalizeFoodDislikes(' a  b ')), 'a b');
    });
  });

  group('codes', () {
    test('the wire is the enum name, in display order, without duplicates', () {
      expect(
        foodAvoidancesToWire(<FoodAvoidance>[
          FoodAvoidance.alcohol,
          FoodAvoidance.lactose,
          FoodAvoidance.alcohol,
        ]),
        <String>['lactose', 'alcohol'],
      );
    });

    test('reading is lenient: unknown codes and non-lists drop', () {
      expect(
        parseFoodAvoidances(<Object?>['nuts', 'insects', 3, null, 'nuts']),
        <FoodAvoidance>{FoodAvoidance.nuts},
      );
      expect(parseFoodAvoidances('nuts'), isEmpty);
      expect(parseFoodAvoidances(null), isEmpty);
    });

    test('every code has a label in both languages', () async {
      for (final locale in <String>['de', 'en']) {
        final l10n = await AppLocalizations.delegate.load(Locale(locale));
        final labels = FoodAvoidance.values.map((a) => a.label(l10n)).toSet();
        expect(labels, hasLength(FoodAvoidance.values.length), reason: locale);
      }
    });
  });

  group('FoodPreferences', () {
    test('equality ignores set order; isEmpty means nothing set', () {
      expect(
        const FoodPreferences(
          avoidances: <FoodAvoidance>{FoodAvoidance.egg, FoodAvoidance.soy},
        ),
        const FoodPreferences(
          avoidances: <FoodAvoidance>{FoodAvoidance.soy, FoodAvoidance.egg},
        ),
      );
      expect(const FoodPreferences().isEmpty, isTrue);
      expect(
        const FoodPreferences(diet: DietPreference.vegetarian).isEmpty,
        isFalse,
      );
      expect(const FoodPreferences(dislikes: 'Pilze').isEmpty, isFalse);
    });

    test('the profile hands its three fields over as one value', () {
      expect(
        _profile.foodPreferences,
        const FoodPreferences(
          diet: DietPreference.vegan,
          avoidances: <FoodAvoidance>{
            FoodAvoidance.lactose,
            FoodAvoidance.nuts,
          },
          dislikes: 'Koriander, Pilze',
        ),
      );
    });

    test('copyWith keeps the fields unless given, and normalizes dislikes', () {
      final moved = _profile.copyWith(weightKg: 80);
      expect(moved.foodAvoidances, _profile.foodAvoidances);
      expect(moved.foodDislikes, _profile.foodDislikes);
      final edited = _profile.copyWith(
        foodDislikes: '  Oliven\n',
        foodAvoidances: {},
      );
      expect(edited.foodDislikes, 'Oliven');
      expect(edited.foodAvoidances, isEmpty);
      expect(edited.diet, DietPreference.vegan);
    });
  });

  group('cache and outbox JSON', () {
    test('round trip keeps the preferences', () {
      final json = userProfileToJson(_profile);
      expect(json['food_avoidances'], <String>['lactose', 'nuts']);
      expect(json['food_dislikes'], 'Koriander, Pilze');
      final back = userProfileFromJson(json)!;
      expect(back.foodPreferences, _profile.foodPreferences);
      expect(back.weightKg, 82);
    });

    test('an older blob without the keys loads with nothing set', () {
      final old = userProfileToJson(_profile)
        ..remove('food_avoidances')
        ..remove('food_dislikes');
      final back = userProfileFromJson(old)!;
      expect(back.foodAvoidances, isEmpty);
      expect(back.foodDislikes, '');
      expect(back.diet, DietPreference.vegan, reason: 'the rest is intact');
      expect(back.weightKg, 82);
    });

    test('a blob from a newer build drops unknown codes, keeps the rest', () {
      final newer = userProfileToJson(_profile)
        ..['food_avoidances'] = <String>['nuts', 'insects']
        ..['food_dislikes'] = 'Pilze\n<x>';
      final back = userProfileFromJson(newer)!;
      expect(back.foodAvoidances, <FoodAvoidance>{FoodAvoidance.nuts});
      expect(back.foodDislikes, 'Pilze x');
    });
  });

  group('the profile op on the wire', () {
    test('a new op carries both keys, normalized', () {
      final row =
          encodeSyncOperationPayload(SyncOp.profileUpsert(_profile))['row']
              as Map;
      expect(row['food_avoidances'], <String>['lactose', 'nuts']);
      expect(row['food_dislikes'], 'Koriander, Pilze');
      final cleared =
          encodeSyncOperationPayload(
                SyncOp.profileUpsert(
                  _profile.copyWith(foodAvoidances: {}, foodDislikes: ''),
                ),
              )['row']
              as Map;
      expect(cleared['food_avoidances'], isEmpty, reason: 'clearing is a key');
      expect(cleared['food_dislikes'], '');
    });

    test(
      'an op an older build queued leaves the keys out (server keeps them)',
      () {
        // A deep copy, as the outbox reads it back from storage.
        final queued =
            jsonDecode(jsonEncode(SyncOp.profileUpsert(_profile).toJson()))
                as Map<String, dynamic>;
        final profile = (queued['payload'] as Map)['profile'] as Map;
        profile
          ..remove('food_avoidances')
          ..remove('food_dislikes');
        final replayed = SyncOp.tryFromJson(queued)!;
        final row = encodeSyncOperationPayload(replayed)['row'] as Map;
        expect(row.containsKey('food_avoidances'), isFalse);
        expect(row.containsKey('food_dislikes'), isFalse);
        expect(row['weight_kg'], 82, reason: 'the rest still travels');
      },
    );
  });
}
