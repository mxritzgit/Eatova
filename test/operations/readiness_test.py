"""Offline readiness boundaries; no credentials, sockets or live data."""

import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.error

SPEC = importlib.util.spec_from_file_location(
    'readiness', Path(__file__).resolve().parents[2] / 'scripts/operations/readiness.py')
readiness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(readiness)
REF = 'a' * 20
STAGING = 'b' * 20
NOW = dt.datetime(2026, 9, 15, 12, 0, tzinfo=dt.timezone.utc)
BACKUPS = {'backups': [{'status': 'COMPLETED', 'inserted_at': '2026-09-15T10:00:00Z'}],
           'pitr_enabled': False, 'physical_backup_data': None}
BUDGETS = [{'enabled': True, 'coach_enabled': True, 'analysis_enabled': True,
            'images_enabled': True, 'daily_call_limit': 1000, 'daily_image_limit': 50,
            'daily_user_limit': 150, 'calls': 12, 'image_calls': 2,
            'usage_date': '2026-09-15'}]


class FakeAPI:
    def __init__(self):
        self.calls = []
        self.responses = {
            'project': {'id': REF, 'ref': REF, 'status': 'ACTIVE_HEALTHY'},
            'backups': copy.deepcopy(BACKUPS), 'budgets': copy.deepcopy(BUDGETS)}

    def read(self, ref, operation):
        self.calls.append((ref, operation))
        if ref == STAGING:
            return {'ref': STAGING, 'status': 'ACTIVE_HEALTHY'}
        value = self.responses[operation]
        if isinstance(value, Exception):
            raise value
        return value


class ReadinessTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()

    def run_check(self, **kwargs):
        return readiness.check(self.api, REF, NOW, 24, 80, **kwargs)

    def test_healthy_metadata_is_not_claimed_as_restored_or_monetary_budget(self):
        self.api.responses['project']['credential'] = 'sensitive-project-field'
        self.api.responses['backups']['private_data'] = 'sensitive-backup-field'
        self.api.responses['budgets'][0]['user_id'] = 'sensitive-account-field'
        report, code = self.run_check()
        self.assertEqual(code, 0)
        self.assertFalse(report['checks']['backups']['restore_verified'])
        self.assertFalse(report['checks']['budgets']['monetary_limit_verified'])
        self.assertFalse(report['notification_sent'])
        self.assertNotIn('sensitive-', json.dumps(report))
        self.assertEqual(self.api.calls, [(REF, 'project'), (REF, 'backups'), (REF, 'budgets')])

    def test_identity_mismatch_stops_all_further_reads(self):
        for identity in ({'id': STAGING}, {'id': REF, 'ref': STAGING}, {}, []):
            with self.subTest(identity=identity):
                self.api.calls.clear()
                self.api.responses['project'] = identity
                with self.assertRaises(readiness.CheckError):
                    self.run_check()
                self.assertEqual(self.api.calls, [(REF, 'project')])

    def test_project_down_is_attention(self):
        self.api.responses['project']['status'] = 'INACTIVE'
        self.assertEqual(self.run_check()[1], 1)

    def test_staging_must_be_distinct_before_network_access(self):
        with self.assertRaisesRegex(readiness.CheckError, 'staging_matches_production'):
            self.run_check(staging=REF)
        self.assertEqual(self.api.calls, [])
        report, code = self.run_check(staging=STAGING)
        self.assertEqual(code, 0)
        self.assertTrue(report['checks']['staging']['distinct_project_verified'])
        self.assertFalse(report['checks']['staging']['credential_and_data_isolation_verified'])

    def test_invalid_refs_and_thresholds_fail_before_network_access(self):
        for ref in ('../secrets', 'a' * 20 + '?redirect=', '', 'http://localhost', 'A' * 20):
            with self.subTest(ref=ref), self.assertRaises(readiness.CheckError):
                readiness.check(self.api, ref, NOW, 24, 80)
        for hours, percent in ((0, 80), (-1, 80), (8761, 80), (24, 0), (24, 100), (True, 80)):
            with self.subTest(hours=hours, percent=percent), self.assertRaises(readiness.CheckError):
                readiness.check(self.api, REF, NOW, hours, percent)
        self.assertEqual(self.api.calls, [])

    def test_empty_backup_list_is_attention_even_with_walg_enabled(self):
        self.api.responses['backups'] = {'backups': [], 'pitr_enabled': False, 'walg_enabled': True}
        report, code = self.run_check()
        self.assertEqual(code, 1)
        self.assertIsNone(report['checks']['backups']['latest_recovery_point_utc'])

    def test_incomplete_backups_do_not_prove_a_recovery_point(self):
        for status in ('PENDING', 'FAILED', 'REMOVED', 'ARCHIVED', 'CANCELLED'):
            with self.subTest(status=status):
                self.api.responses['backups']['backups'][0]['status'] = status
                self.assertEqual(self.run_check()[1], 1)

    def test_unknown_backup_status_cannot_silently_pass(self):
        self.api.responses['backups']['backups'].append({'status': 'UNRECOGNIZED'})
        self.assertEqual(self.run_check()[1], 2)

    def test_age_uses_unrounded_utc_value_at_boundary(self):
        record = self.api.responses['backups']['backups'][0]
        record['inserted_at'] = '2026-09-14T14:00:00+02:00'
        self.assertEqual(self.run_check()[1], 0)
        record['inserted_at'] = '2026-09-14T11:59:59Z'
        self.assertEqual(self.run_check()[1], 1)

    def test_future_naive_or_invalid_timestamp_never_passes(self):
        for stamp in ('2026-09-15T12:00:01Z', '2026-09-15T10:00:00', 'secret-server-body', None):
            with self.subTest(stamp=stamp):
                self.api.responses['backups']['backups'][0]['inserted_at'] = stamp
                report, code = self.run_check()
                self.assertEqual(code, 2)
                self.assertNotIn('secret-server-body', json.dumps(report))

    def test_pitr_needs_a_valid_window_and_enablement(self):
        self.api.responses['backups'] = {
            'backups': [], 'pitr_enabled': True,
            'physical_backup_data': {'earliest_physical_backup_date_unix': int(NOW.timestamp()) - 86400,
                                     'latest_physical_backup_date_unix': int(NOW.timestamp()) - 60}}
        self.assertEqual(self.run_check()[1], 0)
        self.api.responses['backups']['pitr_enabled'] = False
        self.assertEqual(self.run_check()[1], 2)
        self.assertTrue(self.run_check()[0]['checks']['backups']['physical_window_access_unverified'])
        self.api.responses['backups']['pitr_enabled'] = True
        self.api.responses['backups']['physical_backup_data'] = None
        self.assertEqual(self.run_check()[1], 1)

    def test_completed_physical_daily_backup_counts_without_pitr(self):
        self.api.responses['backups']['backups'][0]['is_physical_backup'] = True
        report, code = self.run_check()
        self.assertEqual(code, 0)
        self.assertFalse(report['checks']['backups']['pitr_enabled'])
        self.assertEqual(report['checks']['backups']['completed_backup_count'], 1)

    def test_invalid_pitr_windows_are_unknown(self):
        for first, last in ((1, None), (False, 2), (3, 2), (0, 0), (1, int(NOW.timestamp()) + 1)):
            with self.subTest(first=first, last=last):
                self.api.responses['backups']['physical_backup_data'] = {
                    'earliest_physical_backup_date_unix': first,
                    'latest_physical_backup_date_unix': last}
                self.assertEqual(self.run_check()[1], 2)

    def test_failed_backup_is_attention_even_with_fresh_completed_point(self):
        self.api.responses['backups']['backups'].append({'status': 'FAILED'})
        self.assertEqual(self.run_check()[1], 1)

    def test_budget_warning_exhaustion_and_zero_limit(self):
        row = self.api.responses['budgets'][0]
        row['calls'] = 799
        self.assertEqual(self.run_check()[1], 0)
        row['calls'] = 800
        self.assertIn('calls_warning', self.run_check()[0]['checks']['budgets']['reasons'])
        row['calls'] = 1000
        self.assertIn('calls_exhausted', self.run_check()[0]['checks']['budgets']['reasons'])
        row.update(calls=0, image_calls=0, daily_call_limit=0, daily_image_limit=0)
        reasons = self.run_check()[0]['checks']['budgets']['reasons']
        self.assertEqual(reasons, ['calls_exhausted', 'images_exhausted'])

    def test_image_budget_and_each_stop_are_observed(self):
        row = self.api.responses['budgets'][0]
        row.update(calls=100, image_calls=40)
        self.assertIn('images_warning', self.run_check()[0]['checks']['budgets']['reasons'])
        for switch in ('enabled', 'coach_enabled', 'analysis_enabled', 'images_enabled'):
            with self.subTest(switch=switch):
                row[switch] = False
                self.assertIn('stop_switch_active', self.run_check()[0]['checks']['budgets']['reasons'])
                row[switch] = True
        row['daily_user_limit'] = 0
        self.assertIn('account_call_limit_zero', self.run_check()[0]['checks']['budgets']['reasons'])

    def test_missing_duplicate_malformed_config_and_counters_are_unknown(self):
        variants = [[], BUDGETS * 2, {}, [None]]
        for key, value in [('enabled', 1), ('calls', True), ('calls', -1),
                           ('daily_call_limit', 100001), ('image_calls', 99)]:
            variant = copy.deepcopy(BUDGETS)
            variant[0][key] = value
            variants.append(variant)
        for variant in variants:
            with self.subTest(variant=variant):
                self.api.responses['budgets'] = variant
                self.assertEqual(self.run_check()[1], 2)

    def test_midnight_rollover_is_unknown_instead_of_stale_green(self):
        self.api.responses['budgets'][0]['usage_date'] = '2026-09-16'
        report, code = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(report['checks']['budgets']['reason'], 'budget_utc_day_mismatch')

    def test_denied_backup_access_does_not_claim_no_backups(self):
        self.api.responses['backups'] = readiness.CheckError('http_403')
        report, code = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(report['checks']['backups'], {'state': 'unknown', 'reason': 'http_403'})
        self.assertEqual(report['checks']['budgets']['state'], 'ok')


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.api = readiness.Management('dummy-fixture-token')
        self.api.opener = mock.MagicMock()

    def respond(self, body, status=200, headers=None):
        response = mock.MagicMock()
        response.status = status
        response.headers = headers or {}
        response.read.return_value = body
        self.api.opener.open.return_value.__enter__.return_value = response
        return response

    def test_only_fixed_read_endpoint_and_fixed_aggregate_query_are_sent(self):
        self.respond(json.dumps(BUDGETS).encode(), status=201)
        self.api.read(REF, 'budgets')
        request = self.api.opener.open.call_args.args[0]
        self.assertEqual(request.full_url,
                         'https://api.supabase.com/v1/projects/' + REF + '/database/query/read-only')
        self.assertEqual(request.method, 'POST')
        self.assertEqual(json.loads(request.data), {'query': readiness.BUDGET_QUERY})
        self.assertNotIn('ai_provider_user_usage', readiness.BUDGET_QUERY)
        self.assertNotIn('auth.users', readiness.BUDGET_QUERY)
        self.assertEqual(self.api.opener.open.call_args.kwargs['timeout'], 30)
        with self.assertRaises(readiness.CheckError):
            self.api.read(REF, 'restore')
        self.assertEqual(self.api.opener.open.call_count, 1)

    def test_response_bytes_are_capped_and_encoded_responses_rejected(self):
        response = self.respond(b'a' * (readiness.MAX_RESPONSE_BYTES + 1))
        with self.assertRaisesRegex(readiness.CheckError, 'response_too_large'):
            self.api.read(REF, 'project')
        response.read.assert_called_once_with(readiness.MAX_RESPONSE_BYTES + 1)
        response = self.respond(b'compressed', headers={'Content-Encoding': 'gzip'})
        with self.assertRaisesRegex(readiness.CheckError, 'unexpected_response_encoding'):
            self.api.read(REF, 'project')
        response.read.assert_not_called()

    def test_http_error_body_and_exception_text_are_never_returned(self):
        for error, reason in [
                (urllib.error.HTTPError('https://bad.invalid', 403, 'secret-fixture', {},
                                        io.BytesIO(b'secret-fixture')), 'http_403'),
                (OSError('secret-fixture'), 'transport_or_json_failure')]:
            with self.subTest(error=type(error).__name__):
                self.api.opener.open.side_effect = error
                with self.assertRaises(readiness.CheckError) as caught:
                    self.api.read(REF, 'project')
                self.assertEqual(str(caught.exception), reason)

    def test_redirect_is_rejected_without_creating_forwarded_request(self):
        with self.assertRaisesRegex(readiness.CheckError, 'redirect_rejected'):
            readiness.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://bad.invalid')

    def test_invalid_json_has_sanitized_failure(self):
        self.respond(b'{secret-fixture')
        with self.assertRaisesRegex(readiness.CheckError, '^transport_or_json_failure$'):
            self.api.read(REF, 'project')

    def test_duplicate_fields_cannot_override_observed_counters(self):
        self.respond(b'[{"calls":1000,"calls":0}]')
        with self.assertRaisesRegex(readiness.CheckError, '^duplicate_json_field$'):
            self.api.read(REF, 'budgets')

    def test_cli_missing_credentials_and_unexpected_errors_fail_sanitized(self):
        args = ['--expected-project-ref', REF, '--backup-max-age-hours', '24']
        for env, side_effect in [({}, None), ({'SUPABASE_ACCESS_TOKEN': 'dummy'},
                                             RuntimeError('secret-fixture'))]:
            with self.subTest(env=bool(env)), mock.patch.dict(readiness.os.environ, env, clear=True):
                output = io.StringIO()
                with mock.patch.object(readiness, 'check', side_effect=side_effect), contextlib.redirect_stdout(output):
                    self.assertEqual(readiness.main(args), 2)
                result = json.loads(output.getvalue())
                self.assertEqual(result['state'], 'unknown')
                self.assertNotIn('secret-fixture', output.getvalue())


if __name__ == '__main__':
    unittest.main()
