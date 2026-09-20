"""Offline contracts for generated, hosted GoTrue templates."""
import json
from html.parser import HTMLParser
import unittest

import auth_email_templates as emails


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.disallowed = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'a':
            self.links.append(attrs.get('href', ''))
        if tag in ('script', 'iframe', 'form', 'img') or any(key.startswith('on') for key in attrs):
            self.disallowed.append(tag)


class AuthEmailTemplatesTest(unittest.TestCase):
    def test_generated_files_are_current_and_all_templates_are_versioned(self):
        expected = {'confirmation', 'recovery', 'reauthentication', 'email_change', 'magic_link', 'invite',
                    'password_changed_notification', 'email_changed_notification', 'phone_changed_notification',
                    'mfa_factor_enrolled_notification', 'mfa_factor_unenrolled_notification',
                    'identity_linked_notification', 'identity_unlinked_notification'}
        self.assertEqual(set(emails.templates()), expected)
        for name, value in emails.generated_files().items():
            self.assertEqual((emails.DESTINATION / name).read_text(encoding='utf-8'), value)
        self.assertEqual(set(json.loads((emails.DESTINATION / 'subjects.json').read_text(encoding='utf-8'))), expected)

    def test_purpose_is_per_request_https_context_and_subject_is_safe_for_legacy_apps(self):
        source = (emails.ROOT / 'lib/src/config/auth_email_purpose.dart').read_text(encoding='utf-8')
        for context in (emails.DELETE_CONTEXT, emails.RESET_CONTEXT):
            self.assertIn(context, source)
        subject, recovery = emails.templates()['recovery']
        self.assertEqual(subject, 'Dein Eatova-Sicherheitscode')
        self.assertIn('eq .RedirectTo "' + emails.DELETE_CONTEXT + '"', recovery)
        self.assertIn('eq .RedirectTo "' + emails.RESET_CONTEXT + '"', recovery)
        self.assertIn('{{ else }}Deine Identität bestätigen{{ end }}', recovery)
        self.assertNotIn('.Data', recovery, 'Shared user metadata races across concurrent email requests.')

    def test_codes_are_only_in_supported_otp_templates_and_never_in_subjects(self):
        otp = {'confirmation', 'recovery', 'reauthentication', 'email_change'}
        for name, (subject, html) in emails.templates().items():
            with self.subTest(template=name):
                self.assertNotIn('{{', subject)
                self.assertEqual(html.count('{{ .Token }}'), int(name in otp))
                if name in otp:
                    self.assertIn('10 Minuten', html)
                self.assertNotIn('.TokenHash', html)
                self.assertEqual(html.count('{{ .ConfirmationURL }}'), int(name == 'invite'))

    def test_email_links_and_markup_cannot_reactivate_passwordless_login(self):
        allowed = {'https://eatova.de/datenschutz', 'https://eatova.de/impressum', 'mailto:support@eatova.de'}
        for name, (_, html) in emails.templates().items():
            with self.subTest(template=name):
                parser = Links()
                parser.feed(html)
                self.assertFalse(parser.disallowed)
                self.assertLessEqual(set(parser.links), allowed | ({'{{ .ConfirmationURL }}'} if name == 'invite' else set()))
                self.assertIn('<html lang="de">', html)
                self.assertIn('name="viewport"', html)
                self.assertIn('role="presentation"', html)
                self.assertNotIn('eatova://', html)
                self.assertNotIn('\ufffd', html)


if __name__ == '__main__':
    unittest.main()
