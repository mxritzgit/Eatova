"""Steps of the Android release lane (release.yml) that must not print secrets.

  release.py version     --pubspec pubspec.yaml --build-number N [--github-output FILE]
  release.py defines     --file dart_defines.json
  release.py signing     --keystore PATH --properties android/key.properties
  release.py play-upload --package ID --aab PATH --version-code N --status draft|completed

`version` reads the version name from pubspec.yaml and names the tag
v<name>+<build>. `defines` checks the release defines (SUPABASE_URL,
SUPABASE_ANON_KEY and SENTRY_DSN must be set; a release without crash
reporting is refused) and masks every value in the log. `signing` writes the
upload keystore and android/key.properties from ANDROID_UPLOAD_KEYSTORE_BASE64,
ANDROID_UPLOAD_KEYSTORE_PASSWORD, ANDROID_UPLOAD_KEY_ALIAS and
ANDROID_UPLOAD_KEY_PASSWORD. `play-upload` sends the AAB to the internal
track with the service account in PLAY_SERVICE_ACCOUNT_JSON (Google Play
Developer API, edits; the RS256 signature comes from the openssl CLI).

Secrets come only from the process environment and are never printed; errors
are fixed categories without response bodies.
"""

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION_LINE = re.compile(r'(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$')
PACKAGE = re.compile(r'[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+')
REQUIRED_DEFINES = ('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SENTRY_DSN')
SIGNING_SECRETS = ('ANDROID_UPLOAD_KEYSTORE_BASE64', 'ANDROID_UPLOAD_KEYSTORE_PASSWORD',
                   'ANDROID_UPLOAD_KEY_ALIAS', 'ANDROID_UPLOAD_KEY_PASSWORD')
TOKEN_URL = 'https://oauth2.googleapis.com/token'
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/'
UPLOAD = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/'
MAX_RESPONSE_BYTES = 256 * 1024
TIMEOUT_SECONDS = 60
UPLOAD_TIMEOUT_SECONDS = 600


class ReleaseError(Exception):
    """A fixed diagnostic category; never carries secrets or response bodies."""


# --------------------------------------------------------------------------
# Version, defines and signing files.
# --------------------------------------------------------------------------

def version(pubspec_text, build_number):
    """Version name from pubspec, and the tag v<name>+<build>."""
    match = VERSION_LINE.search(pubspec_text)
    if match is None:
        raise ReleaseError('pubspec_version_missing')
    if type(build_number) is not int or build_number <= 0:
        raise ReleaseError('invalid_build_number')
    name = match.group(1)
    return {'name': name, 'build_number': build_number, 'tag': 'v' + name + '+' + str(build_number)}


def check_defines(text):
    """The keys of valid release defines; refuses missing values, above all SENTRY_DSN."""
    try:
        data = json.loads(text)
    except ValueError:
        raise ReleaseError('release_defines_not_json') from None
    if not isinstance(data, dict) or not all(isinstance(value, str) for value in data.values()):
        raise ReleaseError('release_defines_not_a_string_map')
    for key in REQUIRED_DEFINES:
        if not data.get(key, '').strip():
            raise ReleaseError('release_defines_lack_' + key)
    return data


def mask_lines(values):
    """GitHub log masks for every derived value; short ones would mask words."""
    return ['::add-mask::' + value for value in values
            if len(value) >= 8 and '\n' not in value and '\r' not in value]


def properties_value(value):
    """Escapes a value for java.util.Properties.load (ISO 8859-1, backslash escapes)."""
    out = []
    for index, character in enumerate(value):
        if character == '\\':
            out.append('\\\\')
        elif character in '\n\r\t\f':
            out.append({'\n': '\\n', '\r': '\\r', '\t': '\\t', '\f': '\\f'}[character])
        elif character == ' ' and index == 0:
            out.append('\\ ')
        elif ord(character) < 0x20 or ord(character) > 0x7e:
            out.extend('\\u%04x' % unit for unit in _utf16_units(character))
        else:
            out.append(character)
    return ''.join(out)


def _utf16_units(character):
    encoded = character.encode('utf-16-be')
    return [int.from_bytes(encoded[i:i + 2], 'big') for i in range(0, len(encoded), 2)]


def write_signing(environ, keystore, properties):
    """Upload keystore and key.properties from the environment; never prints them."""
    missing = [name for name in SIGNING_SECRETS if not environ.get(name)]
    if missing:
        raise ReleaseError('missing_signing_secrets:' + ','.join(missing))
    try:
        keystore_bytes = base64.b64decode(''.join(environ['ANDROID_UPLOAD_KEYSTORE_BASE64'].split()),
                                          validate=True)
    except (binascii.Error, ValueError):
        raise ReleaseError('keystore_not_base64') from None
    if len(keystore_bytes) < 64:
        raise ReleaseError('keystore_too_small')
    keystore, properties = Path(keystore), Path(properties)
    if properties.exists():
        raise ReleaseError('key_properties_already_present')
    keystore.parent.mkdir(parents=True, exist_ok=True)
    _private_write(keystore, keystore_bytes)
    lines = [
        'storePassword=' + properties_value(environ['ANDROID_UPLOAD_KEYSTORE_PASSWORD']),
        'keyPassword=' + properties_value(environ['ANDROID_UPLOAD_KEY_PASSWORD']),
        'keyAlias=' + properties_value(environ['ANDROID_UPLOAD_KEY_ALIAS']),
        # Absolute: build.gradle.kts resolves storeFile with file().
        'storeFile=' + properties_value(str(keystore.resolve()).replace('\\', '/')),
    ]
    _private_write(properties, ('\n'.join(lines) + '\n').encode('ascii'))
    return [environ[name] for name in SIGNING_SECRETS[1:]]


def _private_write(path, data):
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'wb') as handle:
        handle.write(data)


# --------------------------------------------------------------------------
# Play: service account token and the internal track (edits API).
# --------------------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        raise ReleaseError('redirect_rejected')


def opener():
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))


def service_account(raw):
    try:
        data = json.loads(raw)
    except ValueError:
        raise ReleaseError('service_account_not_json') from None
    if not isinstance(data, dict) or data.get('type') != 'service_account':
        raise ReleaseError('not_a_service_account')
    email, key = data.get('client_email'), data.get('private_key')
    if not isinstance(email, str) or not email.endswith('.iam.gserviceaccount.com'):
        raise ReleaseError('service_account_email_invalid')
    if not isinstance(key, str) or '-----BEGIN PRIVATE KEY-----' not in key:
        raise ReleaseError('service_account_key_invalid')
    if data.get('token_uri', TOKEN_URL) != TOKEN_URL:
        raise ReleaseError('service_account_token_uri_unexpected')
    return email, key


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def openssl_sign(data, key_pem, runner=subprocess.run):
    """RS256 with the openssl CLI; the key lives only in a private temp file."""
    with tempfile.TemporaryDirectory() as directory:
        key_path = Path(directory) / 'key.pem'
        _private_write(key_path, key_pem.encode('ascii'))
        try:
            done = runner(['openssl', 'dgst', '-sha256', '-sign', str(key_path)],
                          input=data, capture_output=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            raise ReleaseError('signing_unavailable') from None
    if done.returncode != 0 or not done.stdout:
        raise ReleaseError('signing_failed')
    return done.stdout


def assertion(email, key_pem, now, sign):
    header = b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
    claims = b64url(json.dumps({'iss': email, 'scope': SCOPE, 'aud': TOKEN_URL, 'iat': now,
                                'exp': now + 600}, separators=(',', ':')).encode())
    signing_input = header + '.' + claims
    return signing_input + '.' + b64url(sign(signing_input.encode('ascii'), key_pem))


class Play:
    def __init__(self, open_url):
        self.open = open_url
        self.token = None

    def call(self, method, url, body=None, content_type='application/json', timeout=TIMEOUT_SECONDS,
             name='request'):
        headers = {'Accept': 'application/json', 'Accept-Encoding': 'identity'}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        if body is not None:
            headers['Content-Type'] = content_type
        request = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with self.open(request, timeout=timeout) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            error.close()
            raise ReleaseError('play_' + name + '_http_' + str(error.code)) from None
        except (OSError, ValueError):
            raise ReleaseError('play_' + name + '_transport_failure') from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ReleaseError('play_' + name + '_response_too_large')
        if not raw:
            return {}
        try:
            data = json.loads(raw)
        except ValueError:
            raise ReleaseError('play_' + name + '_invalid_json') from None
        if not isinstance(data, dict):
            raise ReleaseError('play_' + name + '_invalid_json')
        return data

    def authenticate(self, email, key_pem, now, sign):
        form = urllib.parse.urlencode({
            'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion': assertion(email, key_pem, now, sign)}).encode('ascii')
        data = self.call('POST', TOKEN_URL, form, 'application/x-www-form-urlencoded', name='token')
        token = data.get('access_token')
        if not isinstance(token, str) or not token or any(c.isspace() for c in token):
            raise ReleaseError('play_token_missing')
        self.token = token


def upload_internal(play, package, aab_bytes, version_code, status):
    """One edit: upload the bundle, put it on the internal track, commit."""
    base = API + package + '/edits'
    edit = play.call('POST', base, b'{}', name='edit').get('id')
    if not isinstance(edit, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', edit):
        raise ReleaseError('play_edit_id_invalid')
    try:
        bundle = play.call('POST', UPLOAD + package + '/edits/' + edit + '/bundles?uploadType=media',
                           aab_bytes, 'application/octet-stream', UPLOAD_TIMEOUT_SECONDS, name='bundle')
        if bundle.get('versionCode') != version_code:
            raise ReleaseError('play_version_code_mismatch')
        track = {'track': 'internal', 'releases': [
            {'versionCodes': [str(version_code)], 'status': status}]}
        play.call('PUT', base + '/' + edit + '/tracks/internal', json.dumps(track).encode(), name='track')
        play.call('POST', base + '/' + edit + ':commit', b'{}', name='commit')
    except ReleaseError:
        try:
            play.call('DELETE', base + '/' + edit, name='discard')
        except ReleaseError:
            pass
        raise
    return {'edit_committed': True, 'track': 'internal', 'status': status, 'version_code': version_code}


# --------------------------------------------------------------------------

def main(argv=None, environ=None, open_url=None, sign=openssl_sign, clock=time.time):
    environ = os.environ if environ is None else environ
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    v = commands.add_parser('version')
    v.add_argument('--pubspec', required=True)
    v.add_argument('--build-number', required=True, type=int)
    v.add_argument('--github-output')
    d = commands.add_parser('defines')
    d.add_argument('--file', required=True)
    s = commands.add_parser('signing')
    s.add_argument('--keystore', required=True)
    s.add_argument('--properties', required=True)
    p = commands.add_parser('play-upload')
    p.add_argument('--package', required=True)
    p.add_argument('--aab', required=True)
    p.add_argument('--version-code', required=True, type=int)
    p.add_argument('--status', required=True, choices=('draft', 'completed'))
    args = parser.parse_args(argv)
    try:
        if args.command == 'version':
            result = version(Path(args.pubspec).read_text(encoding='utf-8'), args.build_number)
            if args.github_output:
                with open(args.github_output, 'a', encoding='utf-8') as handle:
                    for key in ('name', 'build_number', 'tag'):
                        handle.write(key + '=' + str(result[key]) + '\n')
            print('Release ' + result['tag'])
            return 0
        if args.command == 'defines':
            data = check_defines(Path(args.file).read_text(encoding='utf-8'))
            # Masks first, so no later step can print a single define in clear.
            for line in mask_lines(data.values()):
                print(line)
            print('Release defines: ' + ', '.join(sorted(data)))
            return 0
        if args.command == 'signing':
            for line in mask_lines(write_signing(environ, args.keystore, args.properties)):
                print(line)
            print('Upload keystore and key.properties written.')
            return 0
        if not PACKAGE.fullmatch(args.package) or args.version_code <= 0:
            raise ReleaseError('invalid_upload_arguments')
        email, key = service_account(environ.get('PLAY_SERVICE_ACCOUNT_JSON', ''))
        print('::add-mask::' + email)
        play = Play(open_url or opener().open)
        play.authenticate(email, key, int(clock()), sign)
        result = upload_internal(play, args.package, Path(args.aab).read_bytes(), args.version_code,
                                 args.status)
        print('Play internal track: version ' + str(result['version_code']) + ' as ' + result['status'])
        return 0
    except ReleaseError as error:
        print('::error::' + args.command + ': ' + str(error), file=sys.stderr)
        return 1
    except Exception:
        # Library errors must not leak exception text that may hold secrets.
        print('::error::' + args.command + ': unexpected failure', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
