"""Auth fixture timing must establish server expiry before one denial attempt."""
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts' / 'security'))
from auth_lifecycle_checks import LifecycleFailure, LifecycleProbe  # noqa: E402

ACTOR_ID = '11111111-1111-4111-8111-111111111111'


class HostClock:
    def __init__(self, advance):
        self.now = 0
        self.advance = advance

    def monotonic(self):
        return self.now

    def sleep(self, _duration):
        self.now += self.advance


def state(age, *, revoked=3):
    return json.dumps({'count': 3, 'revoked_count': revoked, 'min_age_seconds': age})


class AuthLifecycleTimingTest(unittest.TestCase):
    def test_host_sleep_does_not_substitute_for_server_grace(self):
        sql = Mock(side_effect=[state(1), state(5), state(11.01)])
        request = Mock()
        probe = LifecycleProbe(request, 'unused-synthetic-admin', sql)
        host = HostClock(12)
        with patch('auth_lifecycle_checks.time.monotonic', host.monotonic), \
                patch('auth_lifecycle_checks.time.sleep', host.sleep):
            probe.wait_refresh_grace('fixture_grace', ACTOR_ID)
        self.assertEqual(host.now, 24)
        self.assertEqual(sql.call_count, 3)
        self.assertEqual(probe.checks[-1]['minimum_server_age_seconds'], 11.01)
        request.assert_not_called()
        for call in sql.call_args_list:
            self.assertIn('clock_timestamp() - updated_at', call.args[0])
            self.assertIn(ACTOR_ID, call.args[0])
            self.assertTrue(call.args[0].startswith('SELECT '))

    def test_stalled_server_clock_fails_at_bounded_deadline(self):
        sql = Mock(return_value=state(1))
        request = Mock()
        probe = LifecycleProbe(request, 'unused-synthetic-admin', sql)
        host = HostClock(20)
        with patch('auth_lifecycle_checks.time.monotonic', host.monotonic), \
                patch('auth_lifecycle_checks.time.sleep', host.sleep):
            with self.assertRaisesRegex(LifecycleFailure, 'server-clock deadline exceeded'):
                probe.wait_refresh_grace('fixture_grace', ACTOR_ID)
        self.assertEqual(sql.call_count, 3)
        request.assert_not_called()

    def test_missing_or_invalid_server_state_fails_closed(self):
        for response in ['{}', state(None), state(float('nan')),
                         json.dumps({'count': 0, 'revoked_count': 0, 'min_age_seconds': None})]:
            with self.subTest(response=response):
                sql = Mock(return_value=response)
                probe = LifecycleProbe(Mock(), 'unused-synthetic-admin', sql)
                with self.assertRaisesRegex(LifecycleFailure, 'valid_server_state failed'):
                    probe.wait_refresh_grace('fixture_grace', ACTOR_ID)
                self.assertEqual(sql.call_count, 1)

    def test_unexpected_acceptance_is_never_retried_until_green(self):
        request = Mock(side_effect=[
            (200, {'refresh_token': 'first'}),
            (200, {'refresh_token': 'first'}),
            (200, {'refresh_token': 'latest'}),
            (400, {'error_code': 'refresh_token_already_used'}),
            (200, {'refresh_token': 'unexpected-success'}),
        ])
        probe = LifecycleProbe(request, 'unused-synthetic-admin', Mock())
        probe.actor = Mock(return_value={'id': ACTOR_ID,
                                        'session': {'refresh_token': 'original'}})
        probe.wait_refresh_grace = Mock()
        with self.assertRaisesRegex(LifecycleFailure,
                                    r'replay_revokes_active_family failed \(status=200\)'):
            probe.refresh_replay()
        self.assertEqual(request.call_count, 5)
        self.assertEqual(probe.wait_refresh_grace.call_count, 2)
        self.assertEqual(request.call_args.args[1], {'refresh_token': 'latest'})


if __name__ == '__main__':
    unittest.main()
