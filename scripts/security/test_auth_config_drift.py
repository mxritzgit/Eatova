"""Offline regression tests for the production Auth configuration drift audit."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock, patch

import auth_config_drift as drift
from auth_lifecycle_checks import REFRESH_REUSE_SECONDS

sys.path.insert(0, str(drift.ROOT / 'scripts'))
import auth_email_templates as emails  # noqa: E402

TOKEN = 'synthetic-access-credential'
SECRET = 'private-smtp-credential-sentinel'
BODY_MARKER = 'private-template-body-sentinel'

# GoTrue's default magic-link template before 2026-09-01: a one-click session.
DEFAULT_MAGIC_LINK = ('<h2>Magic Link</h2><p>Follow this link to login:</p>'
                      '<p><a href="{{ .ConfirmationURL }}">Log In</a></p>')


class Response(io.BytesIO):
    status = 200


def live_fixture(expected):
    """A live response that matches the contract, plus unpinned secrets."""
    config = dict(expected['settings'])
    config['uri_allow_list'] = ','.join(expected['uri_allow_list'])
    for name, (subject, html) in expected['templates'].items():
        config[f'mailer_subjects_{name}'] = subject
        config[f'mailer_templates_{name}_content'] = html
    config.update({'smtp_pass': SECRET, 'external_google_secret': SECRET,
                   'smtp_host': 'unpinned.example.test', 'rate_limit_otp': 30})
    return config


class Base(unittest.TestCase):
    def setUp(self):
        self.expected = drift.load_contract()
        self.config = live_fixture(self.expected)
        self.env = {'SUPABASE_ACCESS_TOKEN': TOKEN, 'SUPABASE_PROJECT_REF': 'a' * 20}

    def findings(self, config):
        return drift.drift(config, self.expected)

    def with_template(self, name, html):
        config = dict(self.config)
        config[f'mailer_templates_{name}_content'] = html
        return config

    def opener(self, body):
        return Mock(open=Mock(return_value=Response(body)))


class ContractTests(Base):
    def test_matching_live_configuration_passes(self):
        self.assertEqual(self.findings(self.config), [])
        drift.validate(self.config, self.expected)

    def test_every_pinned_setting_has_evidence_and_no_secret_is_pinned(self):
        contract = json.loads(drift.CONTRACT.read_text(encoding='utf-8'))
        secretish = re.compile(r'(secret|smtp_pass|_key$|api_key|password$)')
        for key, entry in contract['settings'].items():
            with self.subTest(key=key):
                self.assertTrue(entry.get('evidence'))
                self.assertIsInstance(entry['expected'], (bool, int, str))
                if not key.startswith('security_update_password_'):
                    self.assertIsNone(secretish.search(key), 'Diagnostics would print it')
        self.assertTrue(contract['uri_allow_list']['evidence'])
        self.assertTrue(contract['templates']['evidence'])

    def test_templates_match_the_versioned_generator(self):
        self.assertEqual(set(self.expected['templates']), set(emails.templates()))
        for name, (subject, html) in emails.templates().items():
            self.assertEqual(self.expected['templates'][name], (subject, html))
        self.assertLessEqual(self.expected['otp'] | self.expected['link'],
                             set(self.expected['templates']))

    def test_contract_agrees_with_app_constants(self):
        source = (drift.ROOT / 'lib/src/screens/settings/account_change_messages.dart').read_text(encoding='utf-8')
        constant = lambda name: int(re.search(rf'const int {name} = (\d+);', source).group(1))
        settings = self.expected['settings']
        self.assertEqual(settings['mailer_otp_length'], constant('kAccountCodeLength'))
        self.assertEqual(settings['password_min_length'], constant('kAccountMinPasswordLength'))
        self.assertEqual(settings['mailer_otp_exp'], 10 * 60)
        for name in self.expected['otp']:
            self.assertIn('10 Minuten', self.expected['templates'][name][1])
        config = (drift.ROOT / 'lib/src/config/supabase_config.dart').read_text(encoding='utf-8')
        callback = re.search(r"oauthRedirectUrl = '([^']+)'", config).group(1)
        self.assertEqual(set(self.expected['uri_allow_list']),
                         {callback, emails.DELETE_CONTEXT, emails.RESET_CONTEXT})

    def test_contract_agrees_with_the_local_lifecycle_probe(self):
        # The behavioral probe must model the configuration pinned for live.
        source = (drift.ROOT / 'scripts/security/local_edge_auth_probe.py').read_text(encoding='utf-8')
        probe = dict(re.findall(r"'GOTRUE_([A-Z_]+)': '([^']*)'", source))  # later entries win
        settings = self.expected['settings']
        mapped = {
            'mailer_autoconfirm': 'MAILER_AUTOCONFIRM', 'password_min_length': 'PASSWORD_MIN_LENGTH',
            'mailer_otp_length': 'MAILER_OTP_LENGTH', 'mailer_otp_exp': 'MAILER_OTP_EXP',
            'mailer_secure_email_change_enabled': 'MAILER_SECURE_EMAIL_CHANGE_ENABLED',
            'security_update_password_require_reauthentication':
                'SECURITY_UPDATE_PASSWORD_REQUIRE_REAUTHENTICATION',
            'refresh_token_rotation_enabled': 'SECURITY_REFRESH_TOKEN_ROTATION_ENABLED',
            'rate_limit_verify': 'RATE_LIMIT_VERIFY', 'rate_limit_email_sent': 'RATE_LIMIT_EMAIL_SENT',
            'jwt_exp': 'JWT_EXP', 'external_anonymous_users_enabled': 'EXTERNAL_ANONYMOUS_USERS_ENABLED',
        }
        for key, env in mapped.items():
            with self.subTest(key=key):
                self.assertEqual(probe[env], json.dumps(settings[key]))
        self.assertEqual(settings['security_refresh_token_reuse_interval'], REFRESH_REUSE_SECONDS)

    def test_broken_contract_fails_before_any_request(self):
        with tempfile.TemporaryDirectory() as directory:
            for content in [None, '{', '{"settings": {}}']:
                path = Path(directory) / 'contract.json'
                if content is not None:
                    path.write_text(content, encoding='utf-8')
                with self.subTest(content=content):
                    with self.assertRaisesRegex(drift.PolicyError, 'contract could not be loaded'):
                        drift.load_contract(path)
                    opener = Mock()
                    with patch.object(drift, 'CONTRACT', path):
                        with self.assertRaisesRegex(drift.PolicyError, 'contract could not be loaded'):
                            drift.check(self.env, opener)
                    opener.open.assert_not_called()


class SettingDriftTests(Base):
    def mutations(self, value):
        if isinstance(value, bool):
            return [not value, None, str(value).lower(), int(value)]
        if isinstance(value, int):
            return [value - 1, value + 1, 0, str(value), float(value), None]
        return [value + '/', value.upper(), '', None, ['list']]

    def test_each_pinned_setting_detects_changed_wrong_typed_and_missing_values(self):
        for key, value in self.expected['settings'].items():
            for invalid in self.mutations(value):
                with self.subTest(key=key, invalid=invalid):
                    findings = self.findings(dict(self.config, **{key: invalid}))
                    self.assertEqual(len(findings), 1)
                    self.assertTrue(findings[0].startswith(key + ': expected '))
            config = dict(self.config)
            del config[key]
            self.assertEqual(self.findings(config), [key + ': missing from the live configuration'])

    def test_misconfigurations_fixed_by_hand_on_2026_09_01_are_detected(self):
        cases = {
            'rate_limit_email_sent': (2, 'rate_limit_email_sent: expected 60, live 2'),
            'site_url': ('eatova://login-callback/',
                         'site_url: expected "https://eatova.de", live "eatova://login-callback/"'),
        }
        for key, (old, message) in cases.items():
            with self.subTest(key=key):
                with self.assertRaises(drift.PolicyError) as caught:
                    drift.validate(dict(self.config, **{key: old}), self.expected)
                self.assertIn(message, str(caught.exception))
        findings = self.findings(self.with_template('magic_link', DEFAULT_MAGIC_LINK))
        self.assertIn('mailer_templates_magic_link_content: contains .ConfirmationURL', findings)
        self.assertIn('mailer_templates_magic_link_content: link outside the allowed footer links: '
                      '"{{ .ConfirmationURL }}"', findings)

    def test_password_policy_regression_is_still_detected(self):
        config = dict(self.config, security_update_password_require_current_password=False)
        with self.assertRaisesRegex(drift.PolicyError, 'security_update_password_require_current_password'):
            drift.check(self.env, self.opener(json.dumps(config).encode()), self.expected)


class AllowListTests(Base):
    def test_exact_set_with_whitespace_and_list_forms(self):
        entries = self.expected['uri_allow_list']
        for value in [', '.join(reversed(entries)), ','.join(entries) + ',', list(entries)]:
            with self.subTest(value=value):
                self.assertEqual(self.findings(dict(self.config, uri_allow_list=value)), [])

    def test_extra_missing_wrong_typed_and_absent_lists_are_detected(self):
        entries = self.expected['uri_allow_list']
        cases = {
            ','.join(entries + ['eatova://**']): 'unexpected entry "eatova://**"',
            ','.join(entries + ['fitpilot://login-callback']): 'unexpected entry "fitpilot://login-callback"',
            ','.join(entries + ['https://*.eatova.de/**']): 'unexpected entry',
            ','.join(entries[1:]): 'missing entry "eatova://login-callback/"',
            ','.join(entries[:-1]): 'missing entry',
            '': 'missing entry',
            42: 'unexpected type 42',
            None: 'unexpected type null',
        }
        for value, message in cases.items():
            with self.subTest(value=value):
                findings = self.findings(dict(self.config, uri_allow_list=value))
                self.assertTrue(any(message in finding for finding in findings), findings)
        config = dict(self.config)
        del config['uri_allow_list']
        self.assertEqual(self.findings(config), ['uri_allow_list: missing from the live configuration'])


class TemplateTests(Base):
    def properties(self, name, html, subject=None):
        subject = self.expected['templates'][name][0] if subject is None else subject
        return drift.template_properties(name, subject, html, self.expected)

    def test_published_templates_satisfy_every_property(self):
        for name, (subject, html) in self.expected['templates'].items():
            with self.subTest(template=name):
                self.assertEqual(self.properties(name, html, subject), [])

    def test_magic_link_rejects_every_login_path(self):
        original = self.expected['templates']['magic_link'][1]
        injections = {
            '<a href="{{ .ConfirmationURL }}">Log In</a>': '.ConfirmationURL',
            '{{.ConfirmationURL}}': '.ConfirmationURL',
            '<a href="{{ .SiteURL }}/auth/v1/verify?token={{ .TokenHash }}&type=magiclink">x</a>': '.TokenHash',
            '<p>{{ .Token }}</p>': 'non-OTP template contains .Token',
            '<p>{{- .Token -}}</p>': 'non-OTP template contains .Token',
            '<a href="eatova://login-callback/#access_token=x">x</a>': 'eatova://',
            '<a href="https://evil.example/login">x</a>': 'link outside the allowed footer links',
            "<a href='https://eatova.de/login'>x</a>": 'link outside the allowed footer links',
            'Open https://evil.example/login now': 'link outside the allowed footer links',
            '<a href="{{ .RedirectTo }}">x</a>': 'link outside the allowed footer links',
            '{{ "https://evil.example/login" }}': 'link outside the allowed footer links',
            '{{ if eq .RedirectTo "eatova://login-callback/" }}x{{ end }}': 'contains an eatova:// link',
        }
        self.assertEqual(self.properties('magic_link', original), [])
        for injection, message in injections.items():
            with self.subTest(injection=injection):
                html = original.replace('</h1>', '</h1>' + injection, 1)
                self.assertNotEqual(html, original)
                findings = self.properties('magic_link', html)
                self.assertTrue(any(message in finding for finding in findings), findings)
                # The full check also reports the byte drift without the body.
                full = self.findings(self.with_template('magic_link', html))
                self.assertTrue(any('differs from supabase/email_templates/magic_link.html' in f
                                    for f in full))

    def test_subjects_reject_actions_and_links(self):
        for subject in ['Code {{ .Token }}', 'Login: https://evil.example', 'Use .Token']:
            with self.subTest(subject=subject):
                self.assertEqual(self.properties('magic_link', self.expected['templates']['magic_link'][1],
                                                 subject),
                                 ['mailer_subjects_magic_link: contains a template action or link'])

    def test_otp_templates_must_render_the_token_not_a_link(self):
        for name in self.expected['otp']:
            html = self.expected['templates'][name][1]
            with self.subTest(template=name, case='token removed'):
                findings = self.properties(name, html.replace('{{ .Token }}', '********'))
                self.assertIn(f'mailer_templates_{name}_content: OTP template does not render '
                              '{{ .Token }}', findings)
            with self.subTest(template=name, case='link instead of token'):
                findings = self.properties(name, html.replace(
                    '{{ .Token }}', '<a href="{{ .ConfirmationURL }}">Bestätigen</a>'))
                self.assertIn(f'mailer_templates_{name}_content: contains .ConfirmationURL', findings)
                self.assertIn(f'mailer_templates_{name}_content: OTP template does not render '
                              '{{ .Token }}', findings)

    def test_notifications_and_invite_keep_their_limits(self):
        for name in self.expected['templates']:
            if name in self.expected['otp']:
                continue
            html = self.expected['templates'][name][1]
            with self.subTest(template=name):
                self.assertTrue(self.properties(name, html.replace('</h1>', '</h1>{{ .Token }}', 1)))
                self.assertTrue(self.properties(name, html.replace('</h1>', '</h1>{{ .TokenHash }}', 1)))
        invite = self.expected['templates']['invite'][1]
        self.assertEqual(self.properties('invite', invite), [])
        self.assertIn('{{ .ConfirmationURL }}', invite)
        self.assertTrue(self.properties('confirmation', self.expected['templates']['confirmation'][1]
                                        .replace('</h1>', '</h1><a href="{{ .ConfirmationURL }}">x</a>')))

    def test_cosmetic_drift_reports_hashes_never_bodies(self):
        name = 'password_changed_notification'
        html = self.expected['templates'][name][1].replace('</h1>', '</h1>' + BODY_MARKER, 1)
        findings = self.findings(self.with_template(name, html))
        self.assertEqual(len(findings), 1)
        self.assertRegex(findings[0], r'^mailer_templates_password_changed_notification_content: differs '
                                      r'from supabase/email_templates/password_changed_notification\.html '
                                      r'\(live sha256 [0-9a-f]{12}, repo [0-9a-f]{12}\)$')
        self.assertNotIn(BODY_MARKER, findings[0])

    def test_subject_drift_missing_and_wrong_typed_templates(self):
        config = dict(self.config, mailer_subjects_recovery='Dein Eatova-Code: Passwort zurücksetzen')
        self.assertEqual(self.findings(config), [
            'mailer_subjects_recovery: expected "Dein Eatova-Sicherheitscode", '
            'live "Dein Eatova-Code: Passwort zurücksetzen"'])
        for key in ['mailer_subjects_invite', 'mailer_templates_invite_content']:
            with self.subTest(key=key):
                config = dict(self.config)
                del config[key]
                self.assertEqual(self.findings(config), [key + ': missing from the live configuration'])
                self.assertEqual(self.findings(dict(self.config, **{key: None})),
                                 [key + ': unexpected type null'])


class TransportAndRedactionTests(Base):
    def test_reads_only_selected_project_without_mutation(self):
        opener = self.opener(json.dumps(self.config).encode())
        drift.check(self.env, opener, self.expected)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.method, 'GET')
        self.assertIsNone(request.data)
        self.assertEqual(request.full_url,
                         'https://api.supabase.com/v1/projects/' + 'a' * 20 + '/config/auth')
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 30)

    def test_invalid_target_or_credential_never_sends_request(self):
        for env in [{}, dict(self.env, SUPABASE_PROJECT_REF='../other'),
                    dict(self.env, SUPABASE_ACCESS_TOKEN='secret\r\nInjected: value')]:
            opener = Mock()
            with self.assertRaises(drift.PolicyError):
                drift.check(env, opener, self.expected)
            opener.open.assert_not_called()

    def test_errors_do_not_expose_credentials_or_response_bodies(self):
        sensitive = 'private-response-content'
        for failure in [urllib.error.HTTPError('https://unused', 403, sensitive, {},
                                               io.BytesIO(sensitive.encode())),
                        urllib.error.URLError(sensitive), OSError(sensitive)]:
            opener = Mock(open=Mock(side_effect=failure))
            with self.assertRaises(drift.PolicyError) as caught:
                drift.check(self.env, opener, self.expected)
            self.assertNotIn(sensitive, str(caught.exception))
            self.assertNotIn(TOKEN, str(caught.exception))

    def test_unsuccessful_malformed_or_oversized_response_fails_closed(self):
        failed = Response(json.dumps(self.config).encode())
        failed.status = 204
        self.assertRaisesRegex(drift.PolicyError, 'not successful', drift.check, self.env,
                               Mock(open=Mock(return_value=failed)), self.expected)
        oversized = json.dumps(dict(self.config, padding='x' * drift.MAX_BODY)).encode()
        self.assertRaisesRegex(drift.PolicyError, 'exceeds size limit', drift.check, self.env,
                               self.opener(oversized), self.expected)
        for body in [b'private-response-content', b'[]', b'null', b'"text"',
                     b'x' * (drift.MAX_BODY + 1)]:
            with self.subTest(size=len(body)):
                with self.assertRaises(drift.PolicyError) as caught:
                    drift.check(self.env, self.opener(body), self.expected)
                self.assertNotIn('private-response-content', str(caught.exception))

    def test_drift_report_never_contains_secrets_bodies_or_raw_newlines(self):
        config = copy.deepcopy(self.config)
        config.update({
            'rate_limit_email_sent': 2,
            'site_url': 'https://eatova.de\n::warning::injected' + 'x' * 500,
            'mailer_templates_magic_link_content': DEFAULT_MAGIC_LINK + BODY_MARKER,
        })
        with self.assertRaises(drift.PolicyError) as caught:
            drift.check(self.env, self.opener(json.dumps(config).encode()), self.expected)
        message = str(caught.exception)
        for forbidden in [TOKEN, SECRET, BODY_MARKER, 'unpinned.example.test', 'Magic Link', '\n::warning']:
            self.assertNotIn(forbidden, message)
        self.assertIn('rate_limit_email_sent: expected 60, live 2', message)
        self.assertIn('site_url: expected "https://eatova.de", live "https://eatova.de\\n::warning::', message)
        self.assertIn('...', message)

    def test_main_fails_with_annotation_and_summary_on_drift(self):
        config = dict(self.config, rate_limit_email_sent=2, smtp_pass=SECRET)
        with tempfile.TemporaryDirectory() as directory:
            summary = os.path.join(directory, 'summary.md')
            env = dict(self.env, GITHUB_ACTIONS='true', GITHUB_STEP_SUMMARY=summary)
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = drift.main(env, self.opener(json.dumps(config).encode()))
            written = Path(summary).read_text(encoding='utf-8')
        self.assertEqual(code, 1)
        self.assertIn('::error title=Auth configuration drift::', stderr.getvalue())
        self.assertIn('- rate_limit_email_sent: expected 60, live 2', stderr.getvalue())
        self.assertIn('Auth configuration drift: FAILED', written)
        for output in [stdout.getvalue(), stderr.getvalue(), written]:
            self.assertNotIn(TOKEN, output)
            self.assertNotIn(SECRET, output)

    def test_main_reports_success_with_counts(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = drift.main(self.env, self.opener(json.dumps(self.config).encode()))
        self.assertEqual(code, 0)
        self.assertIn(f'{len(self.expected["settings"])} settings, 3 redirect allow-list entries, '
                      '13 mail templates', stdout.getvalue())

    def test_redirect_never_forwards_authorization(self):
        self.assertIsNone(drift.NoRedirect().redirect_request(
            None, None, 302, 'Found', {}, 'https://attacker.invalid'))


if __name__ == '__main__':
    unittest.main()
