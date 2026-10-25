import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/subscription.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/models/plan_limit_hit.dart';
import 'package:eatova/src/models/plan_status.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/billing/purchase_flow.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:eatova/src/widgets/kcal/meal_describe_sheet.dart';
import 'package:eatova/src/widgets/shared/plan_limit_notice.dart';

import '../../describe/ui/describe_fakes.dart';
import '../../support/harness.dart';
import '../../support/subscription_fakes.dart';

// Upgrade hints at a limit (docs/PREMIUM.md 1.2, 4.5): a tier quota shows the
// notice without a retry, "Mehr mit Premium" only on a Free account's first
// hit of the day, a wait-only text on the second hit and on Premium. A burst,
// IP or global 429 has no planLimit and keeps today's texts.

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));

/// The next reset after [kPlanDay].
final DateTime _reset = DateTime.utc(2026, 10, 26);

/// The hourly gate lifts within the day.
final DateTime _burstReset = DateTime.utc(2026, 10, 25, 13);

enum _Case { freeFirst, freeAgain, premium, burst }

Key _key(String value) => ValueKey(value);

/// The denial of [feature] in [c]; null for the burst gate.
PlanLimitHit? _hit(_Case c, PlanFeature feature) {
  final free = feature == PlanFeature.mealAnalysis ? 4 : 2;
  final premium = feature == PlanFeature.mealAnalysis ? 30 : 10;
  return switch (c) {
    _Case.freeFirst || _Case.freeAgain => PlanLimitHit(
      feature: feature,
      tier: PlanTier.free,
      limit: free,
      resetAt: _reset,
      premiumLimit: premium,
    ),
    _Case.premium => PlanLimitHit(
      feature: feature,
      tier: PlanTier.premium,
      limit: premium,
      resetAt: _reset,
    ),
    _Case.burst => null,
  };
}

/// The signed-in account of [c]; a second hit finds today's offer taken.
Future<SubscriptionController> _account(_Case c, PlanFeature feature) async {
  final controller = await subscriptionController(
    log: FakeSubscriptionLog(
      plan: planOf(c == _Case.premium ? PlanTier.premium : PlanTier.free),
    ),
  );
  if (c == _Case.freeAgain) controller.takeUpsell(feature);
  return controller;
}

/// The plan notice's text for [c], or null where today's text stays.
String? _limitText(BuildContext context, _Case c, PlanFeature feature) {
  final hit = _hit(c, feature);
  if (hit == null) return null;
  final time = planLimitClockLabel(context, hit.resetAt);
  final meal = feature == PlanFeature.mealAnalysis;
  if (c == _Case.freeFirst) {
    return meal
        ? _de.planLimitMealPremium(hit.limit, time, hit.premiumLimit!)
        : _de.planLimitImportPremium(hit.limit, time, hit.premiumLimit!);
  }
  return meal
      ? _de.planLimitMeal(hit.limit, time)
      : _de.planLimitImport(hit.limit, time);
}

/// [child] in the localized app below a scope bound to [controller]; the
/// opener records where the Premium screen was opened from. Keyed by the
/// account, so each table row starts with a fresh sheet.
Future<List<PremiumSource>> _pump(
  WidgetTester tester,
  SubscriptionController controller,
  Widget child,
) async {
  final opened = <PremiumSource>[];
  await pumpLocalized(
    tester,
    withSubscription(
      controller,
      KeyedSubtree(key: ObjectKey(controller), child: child),
      opener: (_, source) async => opened.add(source),
    ),
    safeArea: false,
  );
  return opened;
}

/// Frames without `pumpAndSettle`, whose loading card never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The upgrade, its source on tap, and the absent retry, for [c].
Future<void> _expectUpgrade(
  WidgetTester tester,
  _Case c,
  List<PremiumSource> opened,
  PremiumSource source,
) async {
  final upgrade = find.byKey(_key('plan-limit-upgrade'));
  if (c != _Case.freeFirst) {
    expect(upgrade, findsNothing, reason: '$c');
    return;
  }
  expect(upgrade, findsOneWidget, reason: '$c');
  await tester.ensureVisible(upgrade);
  await tester.tap(upgrade);
  await tester.pump();
  expect(opened, <PremiumSource>[source], reason: '$c');
}

MealDescribeSheet _describeSheet(FakeDescriber describer) => MealDescribeSheet(
  initialSlot: MealSlot.lunch,
  describer: describer,
  matcher: FakeMatcher(),
  onAdd: (_, _) => 'id',
  onUpdateMeal: (_, _) {},
  speechInput: FakeSpeech(),
  screenAwake: FakeAwake(),
  dictationLanguageStore: MemoryLanguageStore(),
);

class _FailingImport implements RecipeImportService {
  _FailingImport(this.error);

  final Object error;

  @override
  Future<RecipeImportResult> extract(String text, {required String locale}) =>
      Future<RecipeImportResult>.error(error);
}

void main() {
  testWidgets('Foto-Scan: Tageslimit statt "Erneut versuchen"', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final c in _Case.values) {
        final controller = await _account(c, PlanFeature.mealAnalysis);
        final answer = Completer<MealAnalysisResult>();
        final opened = await _pump(
          tester,
          controller,
          MealAnalysisSheet(
            slot: MealSlot.lunch,
            resultFuture: answer.future,
            previewImage: null,
            onAdd: (_, _) => 'id',
            onUpdateMeal: (_, _) {},
            failureMessage: _de.foodAnalysisFailedMessage,
            retry: () => Completer<MealAnalysisResult>().future,
          ),
        );
        await _frames(tester);
        answer.completeError(
          MealAnalysisRateLimited(
            resetAt: _hit(c, PlanFeature.mealAnalysis)?.resetAt ?? _burstReset,
            planLimit: _hit(c, PlanFeature.mealAnalysis),
          ),
        );
        await _frames(tester);

        final context = tester.element(find.byKey(_key('analyse-error')));
        final text = _limitText(context, c, PlanFeature.mealAnalysis);
        expect(
          find.text(
            text ??
                _de.foodAnalysisRateLimitUntilMessage(
                  planLimitClockLabel(context, _burstReset),
                ),
          ),
          findsOneWidget,
          reason: '$c',
        );
        expect(
          find.byKey(_key('analyse-retry')),
          c == _Case.burst ? findsOneWidget : findsNothing,
          reason: '$c',
        );
        expect(find.byKey(_key('analyse-manual-entry')), findsOneWidget);
        await _expectUpgrade(tester, c, opened, PremiumSource.mealAnalysis);
      }
    });
  });

  testWidgets('Beschreiben: Hinweis im Retry-Platz, "Text bearbeiten" bleibt', (
    tester,
  ) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final c in _Case.values) {
        final controller = await _account(c, PlanFeature.mealAnalysis);
        final describer = FakeDescriber()
          ..error = MealAnalysisRateLimited(
            resetAt: _hit(c, PlanFeature.mealAnalysis)?.resetAt ?? _burstReset,
            planLimit: _hit(c, PlanFeature.mealAnalysis),
          );
        final opened = await _pump(
          tester,
          controller,
          _describeSheet(describer),
        );
        await tester.enterText(
          find.byKey(_key('meal-describe-input')),
          'Zwei Brötchen mit Käse',
        );
        await tester.pump();
        await tester.tap(find.byKey(_key('meal-describe-submit')));
        await tester.pumpAndSettle();

        final context = tester.element(find.byKey(_key('meal-describe-error')));
        final text = _limitText(context, c, PlanFeature.mealAnalysis);
        expect(
          find.text(
            text ??
                _de.foodDescribeRateLimitUntil(
                  planLimitClockLabel(context, _burstReset),
                ),
          ),
          findsOneWidget,
          reason: '$c',
        );
        expect(find.byKey(_key('meal-describe-retry')), findsNothing);
        expect(find.byKey(_key('meal-describe-edit-text')), findsOneWidget);
        await _expectUpgrade(tester, c, opened, PremiumSource.mealAnalysis);
      }
    });
  });

  testWidgets('Rezept-Import: Hinweis, und der Knopf bietet keinen Retry', (
    tester,
  ) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final c in _Case.values) {
        final controller = await _account(c, PlanFeature.recipeImport);
        final opened = await _pump(
          tester,
          controller,
          RecipeImportSheet(
            service: _FailingImport(
              RecipeImportException(
                RecipeImportFailure.rateLimited,
                planLimit: _hit(c, PlanFeature.recipeImport),
                resetAt: _reset,
              ),
            ),
            onSave: (_) async => SyncDelivery.delivered,
            sessionIsCurrent: () => true,
            initialText: 'Pasta mit Tomaten',
          ),
        );
        await tester.pumpAndSettle();

        final analyze = tester.widget<PrimaryActionButton>(
          find.byKey(_key('recipe-import-analyze')),
        );
        final text = _limitText(
          tester.element(find.byKey(_key('recipe-import-analyze'))),
          c,
          PlanFeature.recipeImport,
        );
        expect(
          find.text(text ?? _de.recipeImportRateLimited),
          findsOneWidget,
          reason: '$c',
        );
        if (c == _Case.burst) {
          expect(analyze.label, _de.recipeImportRetry);
          expect(analyze.onTap, isNotNull);
        } else {
          expect(analyze.label, _de.recipeImportAnalyze, reason: '$c');
          expect(analyze.onTap, isNull, reason: '$c');
        }
        await _expectUpgrade(tester, c, opened, PremiumSource.recipeImport);
      }
    });
  });

  testWidgets('Premium aus dem Hinweis hebt das Limit sofort auf: '
      '"Erneut versuchen" statt eines zweiten Angebots', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final scan in <bool>[true, false]) {
        final controller = await _account(
          _Case.freeFirst,
          PlanFeature.mealAnalysis,
        );
        final denial = MealAnalysisRateLimited(
          resetAt: _reset,
          planLimit: _hit(_Case.freeFirst, PlanFeature.mealAnalysis),
        );
        var retries = 0;
        final answer = Completer<MealAnalysisResult>();
        final describer = FakeDescriber()..error = denial;
        await _pump(
          tester,
          controller,
          scan
              ? MealAnalysisSheet(
                  slot: MealSlot.lunch,
                  resultFuture: answer.future,
                  previewImage: null,
                  onAdd: (_, _) => 'id',
                  onUpdateMeal: (_, _) {},
                  failureMessage: _de.foodAnalysisFailedMessage,
                  retry: () {
                    retries++;
                    return Completer<MealAnalysisResult>().future;
                  },
                )
              : _describeSheet(describer),
        );
        if (scan) {
          await _frames(tester);
          answer.completeError(denial);
        } else {
          await tester.enterText(
            find.byKey(_key('meal-describe-input')),
            'Zwei Brötchen mit Käse',
          );
          await tester.pump();
          await tester.tap(find.byKey(_key('meal-describe-submit')));
        }
        await _frames(tester);
        final why = scan ? 'Foto-Scan' : 'Beschreiben';
        expect(find.byKey(_key('plan-limit-upgrade')), findsOneWidget);

        // The purchase from that notice verifies.
        controller.onPurchaseEvent(
          PurchaseVerified(active: true, plan: planOf(PlanTier.premium)),
        );
        await _frames(tester);

        final retry = find.byKey(
          _key(scan ? 'analyse-retry' : 'meal-describe-retry'),
        );
        expect(retry, findsOneWidget, reason: why);
        expect(find.byKey(_key('plan-limit-upgrade')), findsNothing);
        expect(find.text(_de.premiumSuccessBody), findsOneWidget, reason: why);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await _frames(tester);
        expect(scan ? retries : describer.calls.length, scan ? 1 : 2);
      }
    });
  });

  testWidgets('ein veraltetes Premium hebt eine Free-Ablehnung nicht auf, '
      'auch waehrend und nach einem gescheiterten Nachladen', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final surface in <String>['Foto-Scan', 'Beschreiben', 'Import']) {
        // The subscription ended while the app was open: the server already
        // denies under Free, the app still holds the Premium plan.
        final log = FakeSubscriptionLog(plan: planOf(PlanTier.premium));
        final controller = await subscriptionController(log: log);
        log
          ..plan = planOf(PlanTier.free)
          ..gate = Completer<void>();
        final import = surface == 'Import';
        final hit = _hit(
          _Case.freeFirst,
          import ? PlanFeature.recipeImport : PlanFeature.mealAnalysis,
        );
        final denial = MealAnalysisRateLimited(resetAt: _reset, planLimit: hit);
        final answer = Completer<MealAnalysisResult>();
        await _pump(tester, controller, switch (surface) {
          'Foto-Scan' => MealAnalysisSheet(
            slot: MealSlot.lunch,
            resultFuture: answer.future,
            previewImage: null,
            onAdd: (_, _) => 'id',
            onUpdateMeal: (_, _) {},
            failureMessage: _de.foodAnalysisFailedMessage,
            retry: () => Completer<MealAnalysisResult>().future,
          ),
          'Beschreiben' => _describeSheet(FakeDescriber()..error = denial),
          _ => RecipeImportSheet(
            service: _FailingImport(
              RecipeImportException(
                RecipeImportFailure.rateLimited,
                planLimit: hit,
                resetAt: _reset,
              ),
            ),
            onSave: (_) async => SyncDelivery.delivered,
            sessionIsCurrent: () => true,
            initialText: 'Pasta mit Tomaten',
          ),
        });
        await _frames(tester);
        if (surface == 'Foto-Scan') answer.completeError(denial);
        if (surface == 'Beschreiben') {
          await tester.enterText(
            find.byKey(_key('meal-describe-input')),
            'Zwei Brötchen mit Käse',
          );
          await tester.pump();
          await tester.tap(find.byKey(_key('meal-describe-submit')));
        }
        await _frames(tester);

        void expectHeld(String phase) {
          final why = '$surface, $phase';
          expect(
            find.byKey(_key('plan-limit-notice')),
            findsOneWidget,
            reason: why,
          );
          expect(find.text(_de.premiumSuccessTitle), findsNothing, reason: why);
          expect(find.byKey(_key('analyse-retry')), findsNothing, reason: why);
          expect(
            find.byKey(_key('meal-describe-retry')),
            findsNothing,
            reason: why,
          );
          if (import) {
            final analyze = tester.widget<PrimaryActionButton>(
              find.byKey(_key('recipe-import-analyze')),
            );
            expect(analyze.onTap, isNull, reason: why);
          }
        }

        // The tier differs, so the plan is read again; it hangs.
        expect(log.fetchCalls, 2, reason: surface);
        expect(controller.isPremium, isTrue, reason: surface);
        expectHeld('Nachladen haengt');

        log.failReads = true;
        log.gate!.complete();
        await _frames(tester);
        expect(controller.isPremium, isTrue, reason: surface);
        expectHeld('Nachladen gescheitert');
      }
    });
  });

  testWidgets('"Heute noch n KI-Analysen" ab 2 verbleibenden, auch aus der '
      'Antwort eines Scans, nur fuer das fragende Konto', (tester) async {
    await withClock(Clock.fixed(kPlanDay), () async {
      for (final (used, shown) in <(int, bool)>[(2, true), (1, false)]) {
        final controller = await subscriptionController(
          log: FakeSubscriptionLog(
            plan: planOf(PlanTier.free, analysesUsed: used),
          ),
        );
        await _pump(tester, controller, _describeSheet(FakeDescriber()));
        expect(
          find.text(_de.planRemainingAnalyses(2)),
          shown ? findsOneWidget : findsNothing,
          reason: '$used genutzt',
        );
      }

      // A successful scan reports the bucket (`rateLimit.userDay`) to the
      // account that asked; after an account switch, to nobody.
      for (final switched in <bool>[false, true]) {
        final asker = await subscriptionController(
          log: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
        );
        final other = await subscriptionController(
          userId: 'user-b',
          log: FakeSubscriptionLog(plan: planOf(PlanTier.free)),
        );
        final binding = SubscriptionBinding()..bind(asker);
        final answer = Completer<MealAnalysisResult>();
        await pumpLocalized(
          tester,
          SubscriptionScope(
            binding: binding,
            child: KeyedSubtree(
              key: ObjectKey(asker),
              child: MealAnalysisSheet(
                slot: MealSlot.lunch,
                resultFuture: answer.future,
                previewImage: null,
                onAdd: (_, _) => 'id',
                onUpdateMeal: (_, _) {},
                failureMessage: _de.foodAnalysisFailedMessage,
              ),
            ),
          ),
          safeArea: false,
        );
        if (switched) binding.bind(other);
        answer.complete(
          parseAnalyzeMealResponse(
            200,
            jsonEncode(<String, Object?>{
              'result': <String, Object?>{
                'mealName': 'Bowl',
                'caloriesKcal': 520,
                'estimatedGrams': 300,
                'kcalPer100G': 173,
                'proteinG': 25,
                'carbsG': 55,
                'fatG': 20,
                'confidence': 'medium',
                'items': <Object?>[],
              },
              'rateLimit': <String, Object?>{
                'userDay': <String, Object?>{'limit': 4, 'remaining': 2},
              },
            }),
          ),
        );
        await _frames(tester);
        const left = PlanFeature.mealAnalysis;
        expect(
          asker.plan.remaining(left),
          switched ? 4 : 2,
          reason: switched ? 'nach Kontowechsel' : 'gleiches Konto',
        );
        expect(
          other.plan.remaining(left),
          4,
          reason: switched ? 'nach Kontowechsel' : 'gleiches Konto',
        );
      }
    });
  });
}
