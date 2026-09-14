import 'dart:convert';
import 'dart:io';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
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

  for (final language in ['de', 'en']) {
    final l10n = lookupAppLocalizations(Locale(language));
    test('analysis oversized provider response is localized in $language', () {
      expect(
        _analysisMessage(502, 'provider_response_too_large', l10n),
        l10n.foodAnalysisProviderErrorMessage,
      );
    });
    for (final entry in _budgetStatuses.entries) {
      test('analysis ${entry.key} is service availability in $language', () {
        final text = _analysisMessage(entry.value, entry.key, l10n);
        expect(text, l10n.foodAnalysisServiceUnavailableMessage);
        expect(text, isNot(l10n.foodAnalysisRateLimitError));
        expect(text, isNot(contains(_serverDetail)));
      });
    }
    test(
      'analysis ordinary rate limit and upload timeout remain specific in $language',
      () {
        expect(
          _analysisMessage(429, 'rate_limited', l10n),
          l10n.foodAnalysisRateLimitError,
        );
        expect(
          _analysisMessage(408, 'request_timeout', l10n),
          l10n.foodAnalysisTimeoutMessage,
        );
      },
    );

    for (final mode in ['chat', 'recipe', 'plan']) {
      for (final entry in {..._budgetStatuses, ..._uploadStatuses}.entries) {
        test(
          'coach $mode ${entry.key} is localized without quota lock in $language',
          () async {
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
                    locale: language,
                  );
                case 'plan':
                  await service.requestPlan(
                    'Two workouts',
                    sessionId: 'synthetic-session',
                    locale: language,
                  );
              }
            } catch (error) {
              failure = error;
            }
            expect(failure, isA<CoachChatException>());
            expect(failure, isNot(isA<CoachQuotaExceeded>()));
            final expected = _budgetStatuses.containsKey(entry.key)
                ? l10n.coachErrorUnreachable
                : entry.key == 'request_timeout'
                ? l10n.coachErrorTimeout
                : l10n.coachErrorRequestFailed;
            expect((failure as CoachChatException).message, expected);
            expect(service.serverDailyLimit, isNull);
            expect(
              requests,
              1,
              reason:
                  'No retry or history lookup after a completed HTTP failure.',
            );
          },
        );
      }
    }
  }
}
