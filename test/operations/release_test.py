"""Offline tests for the Android release lane: tooling and workflow text.

No credentials, sockets, Play or Sentry calls: HTTP goes through fakes, the
signer is stubbed, files live in temporary directories.
"""

import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release', ROOT / 'scripts/operations/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
WORKFLOW = ROOT / '.github/workflows/release.yml'
DSN = 'https://public-fixture@o0.ingest.example.invalid/1'
DEFINES = {'SUPABASE_URL': 'https://fixture.supabase.invalid', 'SUPABASE_ANON_KEY': 'anon-fixture-key',
           'SENTRY_DSN': DSN, 'GOOGLE_WEB_CLIENT_ID': 'web-client-fixture'}
ACCOUNT = json.dumps({'type': 'service_account', 'client_email': 'uploader@fixture.iam.gserviceaccount.com',
                      'private_key': '-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----\n',
                      'token_uri': 'https://oauth2.googleapis.com/token'})
ACCESS_TOKEN = 'ya29.access-token-fixture'


def run(argv, environ=None, **kwargs):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = release.main(argv, environ=environ or {}, **kwargs)
    return code, out.getvalue(), err.getvalue()


class Response:
    def __init__(self, body):
        self.body = body

    def read(self, limit=-1):
        return self.body if limit < 0 else self.body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakePlay:
    """Records requests; answers like the Play Developer API."""

    def __init__(self, version_code=401, fail=None):
        self.requests = []
        self.version_code = version_code
        self.fail = fail

    def open(self, request, timeout):
        self.requests.append(request)
        url, method = request.full_url, request.get_method()
        if self.fail and self.fail in url:
            raise urllib.error.HTTPError(url, 500, 'error', {}, io.BytesIO(ACCESS_TOKEN.encode()))
        if url == release.TOKEN_URL:
            return Response(json.dumps({'access_token': ACCESS_TOKEN, 'expires_in': 3599}).encode())
        if method == 'POST' and url.endswith('/edits'):
            return Response(b'{"id": "edit-1", "expiryTimeSeconds": "1"}')
        if '/bundles?uploadType=media' in url:
            return Response(json.dumps({'versionCode': self.version_code, 'sha256': 'x'}).encode())
        return Response(b'{}')


class VersionTest(unittest.TestCase):
    def test_name_from_pubspec_and_tag_with_the_commit_count(self):
        result = release.version('name: eatova\nversion: 1.1.0+4\n', 401)
        self.assertEqual(result, {'name': '1.1.0', 'build_number': 401, 'tag': 'v1.1.0+401'})
        self.assertEqual(release.version('version: 2.0.1\n', 7)['tag'], 'v2.0.1+7')
        for text, number in (('name: eatova\n', 1), ('version: 1.1\n', 1), ('version: 1.1.0+4\n', 0)):
            with self.assertRaises(release.ReleaseError, msg=text):
                release.version(text, number)

    def test_the_repository_pubspec_parses_and_outputs_reach_github(self):
        with tempfile.TemporaryDirectory() as base:
            output = Path(base) / 'github_output'
            code, out, _ = run(['version', '--pubspec', str(ROOT / 'pubspec.yaml'), '--build-number', '401',
                                '--github-output', str(output)])
            self.assertEqual(code, 0)
            lines = output.read_text(encoding='utf-8').splitlines()
            self.assertEqual(lines[1], 'build_number=401')
            self.assertRegex(lines[2], r'^tag=v\d+\.\d+\.\d+\+401$')
            self.assertIn('Release v', out)


class DefinesTest(unittest.TestCase):
    def check(self, data):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / 'dart_defines.json'
            path.write_text(json.dumps(data) if not isinstance(data, str) else data, encoding='utf-8')
            return run(['defines', '--file', str(path)])

    def test_a_release_without_a_sentry_dsn_is_refused(self):
        for missing in ('SENTRY_DSN', 'SUPABASE_URL', 'SUPABASE_ANON_KEY'):
            for value in (None, '', '   '):
                data = dict(DEFINES)
                if value is None:
                    del data[missing]
                else:
                    data[missing] = value
                code, out, err = self.check(data)
                self.assertEqual(code, 1, (missing, value))
                self.assertIn('release_defines_lack_' + missing, err)
                self.assertEqual(out, '')
        for broken in ('not json', '[]', '{"SENTRY_DSN": 1}'):
            self.assertEqual(self.check(broken)[0], 1, broken)

    def test_every_value_is_masked_and_never_printed_in_clear(self):
        code, out, err = self.check(DEFINES)
        self.assertEqual(code, 0)
        clear = [line for line in out.splitlines() if not line.startswith('::add-mask::')]
        for value in DEFINES.values():
            self.assertIn('::add-mask::' + value, out)
            self.assertFalse(any(value in line for line in clear), value)
        self.assertIn('Release defines: GOOGLE_WEB_CLIENT_ID, SENTRY_DSN, SUPABASE_ANON_KEY, SUPABASE_URL', out)
        self.assertEqual(err, '')
        # A mask must come before anything that could print the value.
        self.assertTrue(out.startswith('::add-mask::'))


class SigningTest(unittest.TestCase):
    ENV = {'ANDROID_UPLOAD_KEYSTORE_BASE64': base64.b64encode(b'k' * 128).decode(),
           'ANDROID_UPLOAD_KEYSTORE_PASSWORD': 'store pa\\ss=wörd',
           'ANDROID_UPLOAD_KEY_ALIAS': 'upload',
           'ANDROID_UPLOAD_KEY_PASSWORD': ' key-password-fixture'}

    def test_properties_escape_what_java_would_otherwise_change(self):
        self.assertEqual(release.properties_value('a\\b'), 'a\\\\b')
        self.assertEqual(release.properties_value(' lead'), '\\ lead')
        self.assertEqual(release.properties_value('ü'), '\\u00fc')
        self.assertEqual(release.properties_value('\U0001F600'), '\\ud83d\\ude00')
        self.assertEqual(release.properties_value('a=b:c#d!e'), 'a=b:c#d!e')
        self.assertEqual(release.properties_value('tab\tnew\n'), 'tab\\tnew\\n')

    def test_keystore_and_properties_are_written_privately_and_masked(self):
        with tempfile.TemporaryDirectory() as base:
            keystore = Path(base) / 'temp/upload.jks'
            properties = Path(base) / 'android/key.properties'
            properties.parent.mkdir()
            code, out, err = run(['signing', '--keystore', str(keystore), '--properties', str(properties)],
                                 environ=self.ENV)
            self.assertEqual(code, 0, err)
            self.assertEqual(keystore.read_bytes(), b'k' * 128)
            text = properties.read_text(encoding='ascii')
            self.assertIn('storePassword=store pa\\\\ss=w\\u00f6rd\n', text)
            self.assertIn('keyPassword=\\ key-password-fixture\n', text)
            self.assertIn('keyAlias=upload\n', text)
            self.assertIn('storeFile=' + str(keystore.resolve()).replace('\\', '/'), text)
            if os.name == 'posix':
                self.assertEqual(keystore.stat().st_mode & 0o777, 0o600)
                self.assertEqual(properties.stat().st_mode & 0o777, 0o600)
            self.assertIn('::add-mask:: key-password-fixture', out)
            for value in self.ENV.values():
                self.assertFalse(any(value in line for line in out.splitlines()
                                     if not line.startswith('::add-mask::')))
            # A second run never overwrites a key.properties it did not expect.
            self.assertEqual(run(['signing', '--keystore', str(keystore), '--properties', str(properties)],
                                 environ=self.ENV)[0], 1)

    def test_missing_or_broken_secrets_fail_with_names_only(self):
        with tempfile.TemporaryDirectory() as base:
            target = ['signing', '--keystore', str(Path(base) / 'k.jks'), '--properties', str(Path(base) / 'p')]
            env = dict(self.ENV)
            del env['ANDROID_UPLOAD_KEY_PASSWORD']
            code, _, err = run(target, environ=env)
            self.assertEqual(code, 1)
            self.assertIn('missing_signing_secrets:ANDROID_UPLOAD_KEY_PASSWORD', err)
            self.assertNotIn('store pa', err)
            env = dict(self.ENV, ANDROID_UPLOAD_KEYSTORE_BASE64='not base64!!')
            self.assertIn('keystore_not_base64', run(target, environ=env)[2])
            self.assertFalse((Path(base) / 'p').exists())


class PlayTest(unittest.TestCase):
    def upload(self, play, version_code=401, status='draft'):
        with tempfile.TemporaryDirectory() as base:
            aab = Path(base) / 'app-release.aab'
            aab.write_bytes(b'PK-fixture-bundle')
            signed = []

            def sign(data, key):
                signed.append((data, key))
                return b'signature'
            result = run(['play-upload', '--package', 'com.eatova.app', '--aab', str(aab),
                          '--version-code', str(version_code), '--status', status],
                         environ={'PLAY_SERVICE_ACCOUNT_JSON': ACCOUNT}, open_url=play.open, sign=sign,
                         clock=lambda: 1_800_000_000)
            return result, signed

    def test_the_bundle_lands_on_the_internal_track_in_one_committed_edit(self):
        play = FakePlay()
        (code, out, err), signed = self.upload(play)
        self.assertEqual(code, 0, err)
        calls = [(request.get_method(), request.full_url) for request in play.requests]
        edits = release.API + 'com.eatova.app/edits'
        self.assertEqual(calls, [
            ('POST', release.TOKEN_URL),
            ('POST', edits),
            ('POST', release.UPLOAD + 'com.eatova.app/edits/edit-1/bundles?uploadType=media'),
            ('PUT', edits + '/edit-1/tracks/internal'),
            ('POST', edits + '/edit-1:commit')])
        self.assertEqual(play.requests[2].data, b'PK-fixture-bundle')
        self.assertEqual(json.loads(play.requests[3].data),
                         {'track': 'internal', 'releases': [{'versionCodes': ['401'], 'status': 'draft'}]})
        for request in play.requests[1:]:
            self.assertEqual(request.get_header('Authorization'), 'Bearer ' + ACCESS_TOKEN)
        self.assertIsNone(play.requests[0].get_header('Authorization'))
        # The JWT: service account, Play scope, Google's token audience, 10 minutes.
        header, claims, signature = signed[0][0].decode().split('.') + ['']
        payload = json.loads(base64.urlsafe_b64decode(claims + '=' * (-len(claims) % 4)))
        self.assertEqual(payload, {'iss': 'uploader@fixture.iam.gserviceaccount.com', 'scope': release.SCOPE,
                                   'aud': release.TOKEN_URL, 'iat': 1_800_000_000, 'exp': 1_800_000_600})
        self.assertIn('-----BEGIN PRIVATE KEY-----', signed[0][1])
        self.assertNotIn(ACCESS_TOKEN, out + err)
        self.assertIn('::add-mask::uploader@fixture.iam.gserviceaccount.com', out)

    def test_a_wrong_version_code_or_a_failed_step_discards_the_edit(self):
        play = FakePlay(version_code=400)
        (code, _, err), _ = self.upload(play)
        self.assertEqual(code, 1)
        self.assertIn('play_version_code_mismatch', err)
        methods = [(request.get_method(), request.full_url.rsplit('/', 1)[-1]) for request in play.requests]
        self.assertEqual(methods[-1], ('DELETE', 'edit-1'))
        self.assertNotIn(('POST', 'edit-1:commit'), methods)
        play = FakePlay(fail='/tracks/internal')
        (code, _, err), _ = self.upload(play)
        self.assertEqual(code, 1)
        self.assertIn('play_track_http_500', err)
        self.assertNotIn(ACCESS_TOKEN, err)
        self.assertEqual(play.requests[-1].get_method(), 'DELETE')

    def test_bad_service_accounts_and_arguments_stop_before_any_request(self):
        for raw in ('', 'not json', json.dumps({'type': 'user'}),
                    json.dumps({**json.loads(ACCOUNT), 'token_uri': 'https://evil.invalid/token'}),
                    json.dumps({**json.loads(ACCOUNT), 'private_key': 'plain'})):
            play = FakePlay()
            code, _, err = run(['play-upload', '--package', 'com.eatova.app', '--aab', 'missing.aab',
                                '--version-code', '1', '--status', 'draft'],
                               environ={'PLAY_SERVICE_ACCOUNT_JSON': raw}, open_url=play.open,
                               sign=lambda *a: b's')
            self.assertEqual(code, 1, raw)
            self.assertEqual(play.requests, [])
            self.assertNotIn('fixture\n', err)
        code, _, err = run(['play-upload', '--package', 'Com.Eatova', '--aab', 'x', '--version-code', '1',
                            '--status', 'draft'], environ={'PLAY_SERVICE_ACCOUNT_JSON': ACCOUNT})
        self.assertEqual(code, 1)
        self.assertIn('invalid_upload_arguments', err)

    def test_openssl_signs_from_a_private_temporary_key_file(self):
        seen = {}

        def runner(command, input, capture_output, timeout):
            key = Path(command[-1])
            seen['command'] = command[:-1]
            seen['key'] = key.read_text(encoding='ascii')
            seen['mode'] = key.stat().st_mode & 0o777
            seen['path'] = key
            seen['input'] = input

            class Done:
                returncode, stdout = 0, b'sig'
            return Done()
        self.assertEqual(release.openssl_sign(b'data', 'PEM', runner), b'sig')
        self.assertEqual(seen['command'], ['openssl', 'dgst', '-sha256', '-sign'])
        self.assertEqual((seen['key'], seen['input']), ('PEM', b'data'))
        self.assertFalse(seen['path'].exists(), 'the key file is gone after signing')
        if os.name == 'posix':
            self.assertEqual(seen['mode'], 0o600)


def step(text, name):
    start = text.index('- name: ' + name)
    end = text.find('\n      - ', start + 1)
    return text[start:] if end < 0 else text[start:end]


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding='utf-8')
        self.code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))

    def test_manual_main_only_behind_the_release_environment(self):
        trigger = re.search(r'(?ms)^on:\n(.*?)^\S', self.text).group(1)
        self.assertEqual(re.findall(r'(?m)^  (\w+):', trigger), ['workflow_dispatch'])
        self.assertRegex(self.text, r'(?m)^permissions:\n  contents: read\n\n')
        self.assertRegex(self.text, r"(?m)^    if: github\.repository == 'mxritzgit/Eatova' && github\.ref == 'refs/heads/main'$")
        self.assertRegex(self.text, r'(?m)^    environment: release$')
        self.assertRegex(self.text, r'(?m)^  cancel-in-progress: false$')
        refuse = step(self.text, 'Refuse anything but main')
        self.assertIn('if [ "$REF" != "refs/heads/main" ]; then', refuse)
        self.assertLess(self.text.index('- name: Refuse anything but main'), self.text.index('actions/checkout@'))
        # Only the tag needs write, and only this job has it.
        self.assertEqual(re.findall(r'(?m)^ +contents: write$', self.text), ['      contents: write'])

    def test_full_history_and_the_device_build_number_rule(self):
        self.assertIn('fetch-depth: 0', self.text)
        self.assertIn('persist-credentials: false', self.text)
        version = step(self.text, 'Version and build number')
        self.assertIn('git rev-parse --is-shallow-repository', version)
        self.assertIn('python3 scripts/operations/device_build.py build-number', version)
        self.assertIn('scripts/operations/release.py version --pubspec pubspec.yaml', version)
        build = step(self.text, 'Signed app bundle')
        self.assertIn('python3 scripts/operations/device_build.py appbundle', build)
        self.assertIn('python3 scripts/check_storage_release.py --candidate "$RELEASE_SHA"', self.text)

    def test_defines_and_keystore_are_checked_before_the_build(self):
        build = self.text.index('- name: Signed app bundle')
        for name in ('Release defines', 'Upload keystore'):
            self.assertLess(self.text.index('- name: ' + name), build, name)
        self.assertIn('release.py defines --file dart_defines.json', step(self.text, 'Release defines'))
        self.assertIn('release.py signing', step(self.text, 'Upload keystore'))
        cleanup = step(self.text, 'Remove signing files')
        self.assertIn('if: ${{ always() }}', cleanup)
        for path in ('android/key.properties', 'dart_defines.json'):
            self.assertIn(path, cleanup)

    def test_sentry_symbols_only_with_a_pinned_cli_and_play_only_with_an_account(self):
        sentry = step(self.text, 'Sentry symbols')
        self.assertIn('sha256sum --check', sentry)
        self.assertIn("grep -Eq '^[0-9a-f]{64}$'", sentry, 'an unpinned checksum fails closed')
        self.assertIn('upload-proguard', sentry)
        self.assertIn('debug-files upload', sentry)
        self.assertIn('io.sentry.ProguardUuids', step(self.text, 'Sentry mapping id'))
        play = step(self.text, 'Play internal track')
        self.assertIn('if [ -z "${PLAY_SERVICE_ACCOUNT_JSON:-}" ]; then', play)
        self.assertIn('release.py play-upload --package com.eatova.app', play)
        self.assertIn('actions/upload-artifact@', step(self.text, 'Keep the release artifacts'))
        tag = step(self.text, 'Tag the release')
        self.assertIn('git/refs', tag)
        self.assertLess(self.text.index('- name: Play internal track'), self.text.index('- name: Tag the release'))

    def test_secrets_reach_step_env_only_and_are_never_echoed(self):
        for line in self.code.splitlines():
            if 'secrets.' in line:
                self.assertRegex(line, r'^\s+([A-Z0-9_]+): \$\{\{ secrets\.\1 \}\}$', line)
        names = set(re.findall(r'\$\{\{\s*secrets\.(\w+)\s*\}\}', self.text))
        self.assertEqual(names, {'RELEASE_DART_DEFINES', 'ANDROID_UPLOAD_KEYSTORE_BASE64',
                                 'ANDROID_UPLOAD_KEYSTORE_PASSWORD', 'ANDROID_UPLOAD_KEY_ALIAS',
                                 'ANDROID_UPLOAD_KEY_PASSWORD', 'SENTRY_AUTH_TOKEN', 'SENTRY_ORG',
                                 'SENTRY_PROJECT', 'PLAY_SERVICE_ACCOUNT_JSON'})
        self.assertNotRegex(self.code, r'echo[^\n]*\$\{?(RELEASE_DART_DEFINES|ANDROID_UPLOAD|SENTRY_AUTH_TOKEN|PLAY_SERVICE)')
        self.assertNotRegex(self.code, r'cat [^\n]*(key\.properties|dart_defines\.json)')
        self.assertNotIn('set -x', self.code)


if __name__ == '__main__':
    unittest.main()
