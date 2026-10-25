// The plan as the app reads it (docs/PREMIUM.md 2.4, 3.1): the snapshot of
// `get_my_plan` and the `planLimit` object of a tier-quota denial arrive
// complete or not at all, and what the app derives from them (what is left
// today, the status sentence) follows the UTC day.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/plan_limit_hit.dart';
import 'package:eatova/src/models/plan_status.dart';

/// The example of 2.4, as `jsonDecode` hands it over.
Map<String, dynamic> _snapshot() =>
    jsonDecode('''
{
  "tier": "premium",
  "subscription": {
    "platform": "google", "product_id": "eatova_premium", "base_plan_id": "yearly",
    "status": "active", "expires_at": "2027-10-25T08:00:00Z",
    "auto_renewing": true, "environment": "production"
  },
  "limits": {
    "current": { "coach_daily": 20, "meal_analysis_daily": 30, "recipe_import_daily": 10, "recipe_picture": true },
    "free":    { "coach_daily": 3,  "meal_analysis_daily": 4,  "recipe_import_daily": 2,  "recipe_picture": false },
    "premium": { "coach_daily": 20, "meal_analysis_daily": 30, "recipe_import_daily": 10, "recipe_picture": true }
  },
  "legacy": null,
  "usage": { "day": "2026-10-25", "coach": 3, "meal_analysis": 2, "recipe_import": 0 },
  "reset_at": "2026-10-26T00:00:00Z"
}
''')
        as Map<String, dynamic>;

Map<String, dynamic> _limitHit() => <String, dynamic>{
  'feature': 'coach',
  'tier': 'free',
  'limit': 3,
  'resetAt': '2026-10-26T00:00:00.000Z',
  'premiumLimit': 20,
};

final DateTime _noon = DateTime.utc(2026, 10, 25, 12);

void main() {
  test('der Schnappschuss kommt vollstaendig an und unveraendert zurueck', () {
    final plan = PlanStatus.fromJson(_snapshot()..['added_later'] = 1)!;

    expect(plan.tier, PlanTier.premium);
    expect(plan.isPremium, isTrue);
    expect(plan.assumed, isFalse);
    expect(plan.current, kAssumedPremiumLimits);
    expect(plan.free, kAssumedFreeLimits);
    expect(plan.subscription!.platform, StorePlatform.google);
    expect(plan.subscription!.period, PremiumPeriod.yearly);
    expect(plan.subscription!.expiresAt, DateTime.utc(2027, 10, 25, 8));
    expect(plan.usage.usedFor(PlanFeature.coach), 3);
    expect(plan.resetAt, DateTime.utc(2026, 10, 26));
    expect(plan.isLegacy, isFalse);

    // The cache slot holds exactly this shape.
    final cached = jsonDecode(jsonEncode(plan.toJson()));
    expect(PlanStatus.fromJson(cached), plan);

    final legacy = _snapshot()..['legacy'] = {'until': null};
    expect(PlanStatus.fromJson(legacy)!.legacy, const LegacyPlan());
    legacy['legacy'] = {'until': '2027-01-31T00:00:00Z'};
    expect(
      PlanStatus.fromJson(legacy)!.legacy!.until,
      DateTime.utc(2027, 1, 31),
    );

    // The regular Premium limits for after `until`, kept by the cache.
    legacy['legacy'] = {
      'until': '2027-01-31T00:00:00Z',
      'premium': {
        'coach_daily': 20,
        'meal_analysis_daily': 30,
        'recipe_import_daily': 10,
      },
    };
    final withBase = PlanStatus.fromJson(legacy)!;
    expect(withBase.legacy!.premium, (
      coachDaily: 20,
      mealAnalysisDaily: 30,
      recipeImportDaily: 10,
    ));
    expect(
      PlanStatus.fromJson(jsonDecode(jsonEncode(withBase.toJson()))),
      withBase,
    );
    // Added later than the rest: malformed, it is left out, not the plan.
    legacy['legacy'] = {
      'until': '2027-01-31T00:00:00Z',
      'premium': {'coach_daily': 0},
    };
    expect(PlanStatus.fromJson(legacy)!.legacy!.premium, isNull);
  });

  test('unvollstaendige oder fremde Formen sind kein Plan', () {
    Map<String, dynamic> part(Map<String, dynamic> json, String key) =>
        json[key] as Map<String, dynamic>;
    Map<String, dynamic> limits(Map<String, dynamic> json, String key) =>
        part(part(json, 'limits'), key);

    final cases = <String, void Function(Map<String, dynamic>)>{
      'unbekannter Tarif': (j) => j['tier'] = 'gold',
      'ohne Tarif': (j) => j.remove('tier'),
      'ohne Limits': (j) => j.remove('limits'),
      'Limit 0': (j) => limits(j, 'current')['coach_daily'] = 0,
      'Limit als Text': (j) => limits(j, 'free')['meal_analysis_daily'] = '4',
      'Bild als Text': (j) => limits(j, 'premium')['recipe_picture'] = 'yes',
      'ohne Premium-Limits': (j) => part(j, 'limits').remove('premium'),
      'negative Nutzung': (j) => part(j, 'usage')['coach'] = -1,
      'Tag, den es nicht gibt': (j) => part(j, 'usage')['day'] = '2026-02-30',
      'Tag im Lokalformat': (j) => part(j, 'usage')['day'] = '25.10.2026',
      'Reset ohne Zeit': (j) => j['reset_at'] = 'tomorrow',
      'Legacy als Text': (j) => j['legacy'] = 'yes',
      'Legacy ohne until': (j) => j['legacy'] = <String, dynamic>{},
      'Legacy-Datum als Zahl': (j) => j['legacy'] = {'until': 5},
      'unbekannter Abo-Status': (j) =>
          part(j, 'subscription')['status'] = 'lifetime',
      'unbekannter Store': (j) => part(j, 'subscription')['platform'] = 'steam',
      'Abo ohne Ablauf': (j) => part(j, 'subscription').remove('expires_at'),
      'Verlaengerung als Text': (j) =>
          part(j, 'subscription')['auto_renewing'] = 'yes',
      'leeres Produkt': (j) => part(j, 'subscription')['product_id'] = '',
      'Abo als Liste': (j) => j['subscription'] = <Object>[],
    };
    for (final MapEntry(key: name, value: mutate) in cases.entries) {
      final json = _snapshot();
      mutate(json);
      expect(PlanStatus.fromJson(json), isNull, reason: name);
    }
    for (final Object? shape in <Object?>[null, 'premium', <Object>[]]) {
      expect(PlanStatus.fromJson(shape), isNull, reason: '$shape');
    }
  });

  test(
    'ein Limit-Treffer kommt nur vollstaendig an, Premium nur fuer Free',
    () {
      final hit = PlanLimitHit.fromBody(<String, dynamic>{
        'error': 'quota_exceeded',
        'planLimit': _limitHit(),
      })!;
      expect(hit.feature, PlanFeature.coach);
      expect(hit.limit, 3);
      expect(hit.resetAt, DateTime.utc(2026, 10, 26));
      expect(hit.premiumLimit, 20);
      expect(hit.offersPremium, isTrue);

      final noUpgrade = <String, void Function(Map<String, dynamic>)>{
        'Premium-Konto': (j) => j['tier'] = 'premium',
        'Premium gibt nicht mehr': (j) => j['premiumLimit'] = 3,
        'ohne Premium-Limit': (j) => j.remove('premiumLimit'),
      };
      for (final MapEntry(key: name, value: mutate) in noUpgrade.entries) {
        final json = _limitHit();
        mutate(json);
        expect(
          PlanLimitHit.fromJson(json)?.offersPremium,
          isFalse,
          reason: name,
        );
      }

      final malformed = <String, void Function(Map<String, dynamic>)>{
        'unbekannte Funktion': (j) => j['feature'] = 'chat',
        'ohne Tarif': (j) => j.remove('tier'),
        'Limit als Text': (j) => j['limit'] = '3',
        'Limit 0': (j) => j['limit'] = 0,
        'Reset ohne Zeit': (j) => j['resetAt'] = 'soon',
        'Premium-Limit als Text': (j) => j['premiumLimit'] = 'x',
      };
      for (final MapEntry(key: name, value: mutate) in malformed.entries) {
        final json = _limitHit();
        mutate(json);
        expect(PlanLimitHit.fromJson(json), isNull, reason: name);
      }
      // A burst or IP gate carries no planLimit: never an upgrade.
      expect(
        PlanLimitHit.fromBody(const {
          'error': 'rate_limited',
          'rateLimit': <String, Object>{},
        }),
        isNull,
      );
    },
  );

  test('angenommen gilt Free; was heute bleibt, zaehlt nach UTC-Tag', () {
    withClock(Clock.fixed(_noon), () {
      final assumed = PlanStatus.assumed();
      expect(assumed.assumed, isTrue);
      expect(assumed.isPremium, isFalse);
      expect(assumed.current, kAssumedFreeLimits);
      expect(
        (assumed.free, assumed.premium),
        (
          const TierLimits(
            coachDaily: 3,
            mealAnalysisDaily: 4,
            recipeImportDaily: 2,
            recipePicture: false,
          ),
          const TierLimits(
            coachDaily: 20,
            mealAnalysisDaily: 30,
            recipeImportDaily: 10,
            recipePicture: true,
          ),
        ),
      );
      expect(assumed.premiumLimitFor(PlanFeature.mealAnalysis), 30);
      expect(assumed.nextReset(), DateTime.utc(2026, 10, 26));

      final cached = PlanStatus.fromJson(_snapshot()..['tier'] = 'free')!;
      final yesterday = PlanStatus.fromJson(
        _snapshot()
          ..['usage'] = {
            'day': '2026-10-24',
            'coach': 20,
            'meal_analysis': 30,
            'recipe_import': 10,
          }
          ..['reset_at'] = '2026-10-25T00:00:00Z',
      )!;
      final overCounted = cached.withUsage(
        cached.usage.withUsed(PlanFeature.mealAnalysis, 99),
      );
      final rows = <(String, PlanStatus, PlanFeature, int)>[
        ('heute genutzt', cached, PlanFeature.coach, 17),
        ('gestern zaehlt nicht', yesterday, PlanFeature.coach, 20),
        ('nie unter null', overCounted, PlanFeature.mealAnalysis, 0),
      ];
      for (final (name, plan, feature, left) in rows) {
        expect(plan.remaining(feature), left, reason: name);
      }
      expect(yesterday.nextReset(), DateTime.utc(2026, 10, 26));
      // The day turns at 00:00 UTC, not at local midnight.
      expect(
        cached.remaining(PlanFeature.coach, DateTime.utc(2026, 10, 25, 23, 59)),
        17,
      );
      expect(
        cached.remaining(PlanFeature.coach, DateTime.utc(2026, 10, 26)),
        20,
      );
    });
  });

  test('der Abo-Satz folgt Status, Verlaengerung und Ablauf', () {
    SubscriptionInfo row(
      SubscriptionState state, {
      bool? renews,
      StorePlatform platform = StorePlatform.google,
      bool past = false,
      int? daysPast,
    }) => SubscriptionInfo(
      platform: platform,
      productId: platform == StorePlatform.apple
          ? 'eatova_premium_monthly'
          : 'eatova_premium',
      basePlanId: platform == StorePlatform.google ? 'yearly' : null,
      state: state,
      expiresAt: daysPast != null
          ? _noon.subtract(Duration(days: daysPast))
          : past
          ? _noon.subtract(const Duration(hours: 1))
          : _noon.add(const Duration(days: 30)),
      autoRenewing: renews,
    );

    final rows = <(String, SubscriptionInfo, SubscriptionLine)>[
      (
        'verlaengert',
        row(SubscriptionState.active, renews: true),
        SubscriptionLine.renewsOn,
      ),
      (
        'Apple noch ohne Angabe',
        row(SubscriptionState.active),
        SubscriptionLine.renewsOn,
      ),
      (
        'Verlaengerung aus',
        row(SubscriptionState.active, renews: false),
        SubscriptionLine.endsOn,
      ),
      ('gekuendigt', row(SubscriptionState.canceled), SubscriptionLine.endsOn),
      ('Kulanzzeit', row(SubscriptionState.grace), SubscriptionLine.grace),
      ('angehalten', row(SubscriptionState.onHold), SubscriptionLine.onHold),
      ('pausiert', row(SubscriptionState.paused), SubscriptionLine.paused),
      // A hold or pause the store never closed ends after the store's
      // longest one (hold 60 days, pause 3 months), so it sells again.
      (
        'angehalten seit 59 Tagen',
        row(SubscriptionState.onHold, daysPast: 59),
        SubscriptionLine.onHold,
      ),
      (
        'Apple angehalten seit 61 Tagen',
        row(
          SubscriptionState.onHold,
          platform: StorePlatform.apple,
          daysPast: 61,
        ),
        SubscriptionLine.expiredOn,
      ),
      (
        'pausiert seit 91 Tagen',
        row(SubscriptionState.paused, daysPast: 91),
        SubscriptionLine.paused,
      ),
      (
        'pausiert seit 93 Tagen',
        row(SubscriptionState.paused, daysPast: 93),
        SubscriptionLine.expiredOn,
      ),
      ('ausstehend', row(SubscriptionState.pending), SubscriptionLine.pending),
      (
        'abgelaufen',
        row(SubscriptionState.expired),
        SubscriptionLine.expiredOn,
      ),
      (
        'aktiv, aber vorbei',
        row(SubscriptionState.active, past: true),
        SubscriptionLine.expiredOn,
      ),
      ('erstattet', row(SubscriptionState.revoked), SubscriptionLine.revoked),
      (
        'manuell',
        row(SubscriptionState.active, platform: StorePlatform.manual),
        SubscriptionLine.manualUntil,
      ),
      (
        'manuell vorbei',
        row(
          SubscriptionState.active,
          platform: StorePlatform.manual,
          past: true,
        ),
        SubscriptionLine.expiredOn,
      ),
    ];
    for (final (name, info, line) in rows) {
      expect(info.lineAt(_noon), line, reason: name);
    }

    final apple = row(SubscriptionState.active, platform: StorePlatform.apple);
    expect(apple.period, PremiumPeriod.monthly);
    expect(row(SubscriptionState.active).period, PremiumPeriod.yearly);
    expect(
      row(SubscriptionState.active, platform: StorePlatform.manual).period,
      isNull,
    );
    expect(apple.isTestPurchase, isFalse);
    expect(row(SubscriptionState.canceled).entitledAt(_noon), isTrue);
    expect(row(SubscriptionState.onHold).entitledAt(_noon), isFalse);
  });
}
