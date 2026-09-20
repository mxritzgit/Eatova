"""Offline regression tests for the production Auth configuration audit."""
import io
import json
import unittest
import urllib.error
from unittest.mock import Mock

import auth_password_policy as policy


class Response(io.BytesIO):
    status = 200


class PasswordPolicyTests(unittest.TestCase):
    def setUp(self):
        self.env = {'SUPABASE_ACCESS_TOKEN': 'synthetic-access-credential',
                    'SUPABASE_PROJECT_REF': 'a' * 20}

    def opener(self, body):
        return Mock(open=Mock(return_value=Response(body)))

    def test_reads_only_selected_project_without_mutation(self):
        opener = self.opener(json.dumps(policy.REQUIRED).encode())
        policy.check(self.env, opener)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.method, 'GET')
        self.assertIsNone(request.data)
        self.assertEqual(request.full_url,
                         'https://api.supabase.com/v1/projects/' + 'a' * 20 + '/config/auth')
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 30)

    def test_disabled_missing_and_wrong_typed_controls_fail_closed(self):
        for key in policy.REQUIRED:
            for invalid in [False, None, 'true', 1]:
                with self.subTest(key=key, invalid=invalid):
                    config = dict(policy.REQUIRED, **{key: invalid})
                    with self.assertRaisesRegex(policy.PolicyError, key):
                        policy.validate(config)
            config = dict(policy.REQUIRED)
            del config[key]
            with self.assertRaisesRegex(policy.PolicyError, key):
                policy.validate(config)

    def test_legacy_configuration_detected(self):
        config = dict(policy.REQUIRED,
                      security_update_password_require_current_password=False)
        with self.assertRaises(policy.PolicyError):
            policy.check(self.env, self.opener(json.dumps(config).encode()))

    def test_invalid_target_or_credential_never_sends_request(self):
        for env in [{}, dict(self.env, SUPABASE_PROJECT_REF='../other'),
                    dict(self.env, SUPABASE_ACCESS_TOKEN='secret\r\nInjected: value')]:
            opener = Mock()
            with self.assertRaises(policy.PolicyError):
                policy.check(env, opener)
            opener.open.assert_not_called()

    def test_errors_do_not_expose_credentials_or_response_bodies(self):
        sensitive = 'private-response-content'
        for failure in [urllib.error.HTTPError('https://unused', 403, sensitive, {},
                                               io.BytesIO(sensitive.encode())),
                        urllib.error.URLError(sensitive), OSError(sensitive)]:
            opener = Mock(open=Mock(side_effect=failure))
            with self.assertRaises(policy.PolicyError) as caught:
                policy.check(self.env, opener)
            self.assertNotIn(sensitive, str(caught.exception))
            self.assertNotIn(self.env['SUPABASE_ACCESS_TOKEN'], str(caught.exception))

    def test_malformed_or_oversized_response_fails_closed(self):
        for body in [b'private-response-content', b'[]', b'null', b'x' * (1024 * 1024 + 1)]:
            with self.subTest(size=len(body)):
                with self.assertRaises(policy.PolicyError):
                    policy.check(self.env, self.opener(body))

    def test_redirect_never_forwards_authorization(self):
        self.assertIsNone(policy.NoRedirect().redirect_request(
            None, None, 302, 'Found', {}, 'https://attacker.invalid'))


if __name__ == '__main__':
    unittest.main()
