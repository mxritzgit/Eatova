import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/coach_quota_reset.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

const _budgetStatuses = {
  'ai_budget_exhausted': 429,
  'ai_disabled': 503,
  'ai_budget_unavailable': 503,
};
const _uploadStatuses = {
  'request_timeout': 408,
  'request_aborted': 499,
  'request_body_unavailable': 400,
};
const _fallback = 'SYNTHETIC_CONNECTION_FALLBACK';
const _serverDetail = 'Synthetic private server detail.';

Set<String> _constructedCodes(String path, String type) => RegExp(
  '''new\\s+$type\\(\\s*['"]([a-z_]+)['"]''',
).allMatches(File(path).readAsStringSync()).map((m) => m.group(1)!).toSet();

String _analysisMessage(int status, String code, AppLocalizations l10n) {
  try {
    parseAnalyzeMealResponse(
      status,
      jsonEncode({'error': code, 'message': _serverDetail}),
    );
  } on MealAnalysisException catch (error) {
    return mealAnalysisErrorMessage(error, _fallback, l10n);
  }
  fail('An error response must not become an analysis result.');
}

void main() {
  test('shared budget and coach upload codes all have explicit wire cases', () {
    // The older Analyze source scanner intentionally covers its local HttpError
    // constructors. These shared/dynamic error classes need their own contract.
    expect(
      _constructedCodes(
        'supabase/functions/_shared/provider_budget.ts',
        'ProviderBudgetError',
      ),
      _budgetStatuses.keys.toSet(),
    );
    expect(
      _constructedCodes(
        'supabase/functions/coach-chat/handler.ts',
        'RequestBodyError',
      ),
      _uploadStatuses.keys.toSet(),
    );
  });

  // One language: every expectation is read from the same bundle, so a second
  // language repeats each case. English, because the services default to
  // German and only a non-default bundle shows that they use the one given.
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('analysis error codes map to their own message without server detail',
      () {
    expect(
      _analysisMessage(502, 'provider_response_too_large', l10n),
      l10n.foodAnalysisProviderErrorMessage,
    );
    for (final entry in _budgetStatuses.entries) {
      final text = _analysisMessage(entry.value, entry.key, l10n);
      expect(text, l10n.foodAnalysisServiceUnavailableMessage, reason: entry.key);
      expect(text, isNot(l10n.foodAnalysisRateLimitError), reason: entry.key);
      expect(text, isNot(contains(_serverDetail)), reason: entry.key);
    }
    // The ordinary rate limit and the upload timeout stay specific.
    expect(
      _analysisMessage(429, 'rate_limited', l10n),
      l10n.foodAnalysisRateLimitError,
    );
    expect(
      _analysisMessage(408, 'request_timeout', l10n),
      l10n.foodAnalysisTimeoutMessage,
    );
  });

  // The shared Free pool (scope 'free') names its reset as a local clock
  // time; every other scope keeps the service-availability text.
  final freeReset = DateTime.utc(2026, 10, 26);
  Map<String, Object?> budgetBody(String? scope) => {
    'error': 'ai_budget_exhausted',
    'scope': ?scope,
    'resetAt': freeReset.toIso8601String(),
    'message': _serverDetail,
  };

  test('analysis: the spent Free pool names its reset, never a quota', () {
    for (final scope in <String?>['free', 'all', 'account', null]) {
      Object? failure;
      try {
        parseAnalyzeMealResponse(429, jsonEncode(budgetBody(scope)));
      } catch (error) {
        failure = error;
      }
      // No MealAnalysisRateLimited: no plan-limit notice, no upgrade.
      expect(failure, isNot(isA<MealAnalysisRateLimited>()), reason: scope);
      expect(
        mealAnalysisErrorMessage(failure!, _fallback, l10n),
        scope == 'free'
            ? l10n.planFreePoolExhaustedMeal(mealAnalysisClockLabel(freeReset))
            : l10n.foodAnalysisServiceUnavailableMessage,
        reason: scope,
      );
    }
  });

  test('coach: the spent Free pool names its reset, without quota lock',
      () async {
    for (final scope in <String?>['free', 'account']) {
      final client = SupabaseClient(
        'https://edge.test.invalid',
        'synthetic-anon-key',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({...budgetBody(scope), 'session_id': 'synthetic'}),
            429,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.dispose);
      final service = CoachChatService(client, 'synthetic-user')..l10n = l10n;
      Object? failure;
      try {
        await service.send('Dinner advice', sessionId: 'synthetic-session');
      } catch (error) {
        failure = error;
      }
      expect(failure, isNot(isA<CoachQuotaExceeded>()), reason: scope);
      expect(
        (failure as CoachChatException).message,
        scope == 'free'
            ? l10n.planFreePoolExhausted(coachQuotaClockLabel('en', freeReset))
            : l10n.coachErrorUnreachable,
        reason: scope,
      );
      expect(service.serverDailyLimit, isNull, reason: scope);
    }
  });

  // Chat, recipe and plan reach the edge function through separate paths, so
  // each is checked against every budget and upload code.
  for (final mode in ['chat', 'recipe', 'plan']) {
    test('coach $mode: budget and upload codes are localized without quota '
        'lock', () async {
      for (final entry in {..._budgetStatuses, ..._uploadStatuses}.entries) {
        var requests = 0;
        final client = SupabaseClient(
          'https://edge.test.invalid',
          'synthetic-anon-key',
          httpClient: MockClient((request) async {
            requests++;
            expect(request.url.path, endsWith('/functions/v1/coach-chat'));
            return http.Response(
              jsonEncode({
                'error': entry.key,
                'message': _serverDetail,
                'reply': _serverDetail,
              }),
              entry.value,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.dispose);
        final service = CoachChatService(client, 'synthetic-user')
          ..l10n = l10n;
        Object? failure;
        try {
          switch (mode) {
            case 'chat':
              await service.send(
                'Dinner advice',
                sessionId: 'synthetic-session',
              );
            case 'recipe':
              await service.requestRecipe(
                'Dinner',
                sessionId: 'synthetic-session',
                locale: 'en',
              );
            case 'plan':
              await service.requestPlan(
                'Two workouts',
                sessionId: 'synthetic-session',
                locale: 'en',
              );
          }
        } catch (error) {
          failure = error;
        }
        expect(failure, isA<CoachChatException>(), reason: entry.key);
        expect(failure, isNot(isA<CoachQuotaExceeded>()), reason: entry.key);
        final expected = _budgetStatuses.containsKey(entry.key)
            ? l10n.coachErrorUnreachable
            : entry.key == 'request_timeout'
            ? l10n.coachErrorTimeout
            : l10n.coachErrorRequestFailed;
        expect(
          (failure as CoachChatException).message,
          expected,
          reason: entry.key,
        );
        expect(service.serverDailyLimit, isNull, reason: entry.key);
        expect(
          requests,
          1,
          reason:
              '${entry.key}: no retry or history lookup after a completed '
              'HTTP failure.',
        );
      }
    });
  }
}
