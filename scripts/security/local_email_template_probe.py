"""Prove recovery mail purpose/OTP against isolated real GoTrue and SMTP.

Requires Docker and Python 3.11+. Only synthetic credentials are used. Postgres
and a memory-only SMTP sink share an internal Docker network; no ports are
published. No real SMTP server, live backend, or email recipient is contacted.
"""
import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
from urllib.parse import urlencode

from password_change_checks import PasswordChangeProbe


ROOT = Path(__file__).resolve().parents[2]
AUTH_IMAGE = 'supabase/gotrue:v2.197.0@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b'
POSTGRES_IMAGE = 'postgres:17.6@sha256:00bc86618629af00d2937fdc5a5d63db3ff8450acf52f0636ec813c7f4902929'
PYTHON_IMAGE = 'python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea'
DELETE_CONTEXT = 'https://eatova.de/auth/email/account-deletion'
RESET_CONTEXT = 'https://eatova.de/auth/email/password-reset'
UNKNOWN_CONTEXT = 'https://eatova.de/auth/email/unknown'


def command(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', check=False)
    if result.returncode:
        # Never include argument/env values, SMTP contents or response bodies.
        raise RuntimeError(f'{args[0]} {args[1]} failed ({result.returncode})')
    return result.stdout.strip()


def signed_admin(secret):
    def encode(data):
        return base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip('=')
    raw = encode({'alg': 'HS256', 'typ': 'JWT'}) + '.' + encode(
        {'role': 'service_role', 'exp': int(time.time()) + 3600})
    signature = hmac.new(secret.encode(), raw.encode(), hashlib.sha256).digest()
    return raw + '.' + base64.urlsafe_b64encode(signature).decode().rstrip('=')


class ContainerClient:
    """HTTP stays inside the disposable network; bodies never enter CLI args."""
    def __init__(self, runner, target, port):
        self.runner, self.target, self.port = runner, target, port

    def request(self, path, data=None, token=None, method=None):
        source = """
import json, sys, urllib.request, urllib.error
value = json.load(sys.stdin)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
headers = {'Content-Type': 'application/json', 'X-Forwarded-For': '198.51.100.24'}
if value['token']: headers['Authorization'] = 'Bearer ' + value['token']
request = urllib.request.Request(value['url'], headers=headers,
    data=None if value['data'] is None else json.dumps(value['data']).encode(),
    method=value['method'])
try: response = opener.open(request, timeout=3)
except urllib.error.HTTPError as error: response = error
with response:
    body = response.read(1024 * 1024)
    print(json.dumps([response.code, json.loads(body or b'{}')]))
"""
        if not re.fullmatch(r'eatova-mail-purpose-[a-f0-9]{8}-(auth|sink)', self.target):
            raise ValueError('Unexpected local container target')
        if not path.startswith('/') or path.startswith('//'):
            raise ValueError('Unexpected local request path')
        payload = {'url': f'http://{self.target}:{self.port}' + path,
                   'data': data, 'token': token, 'method': method}
        return json.loads(command('docker', 'exec', '-i', self.runner,
                                  'python', '-c', source, input=json.dumps(payload)))


def wait_healthy(client):
    for _ in range(80):
        try:
            if client.request('/health')[0] == 200:
                return
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(.25)
    raise RuntimeError('Disposable service did not become healthy')


def run(template_directory=None, *, require_reauthentication=True,
        require_current_password=True, expected_current_password=True):
    template_directory = template_directory or ROOT / "supabase" / "email_templates"
    prefix = 'eatova-mail-purpose-' + secrets.token_hex(4)
    network, db, sink, auth = (prefix + name for name in ('-net', '-db', '-sink', '-auth'))
    base = f'http://{auth}:9999'
    client = ContainerClient(sink, auth, 9999)
    mailbox = ContainerClient(sink, sink, 8025)
    secret, password = secrets.token_urlsafe(40), secrets.token_urlsafe(24)
    created = []
    evidence = {'gotrue': '2.197.0', 'postgres': '17.6',
                'password_policy': 'current-password' if expected_current_password else 'legacy-session',
                'isolation': 'internal Docker network; no published ports; SMTP memory only; synthetic users',
                'checks': []}
    try:
        command('docker', 'network', 'create', '--internal', network)
        created.append(('network', network))
        command('docker', 'run', '--detach', '--name', db, '--network', network,
                '--tmpfs', '/var/lib/postgresql/data', '--env', 'POSTGRES_PASSWORD=' + password,
                POSTGRES_IMAGE)
        created.append(('container', db))
        for _ in range(60):
            ready = subprocess.run(['docker', 'exec', db, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(.25)
        else:
            raise RuntimeError('Disposable Postgres was not ready')
        command('docker', 'exec', '-i', db, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1',
                input='CREATE SCHEMA auth; ALTER ROLE postgres SET search_path TO auth, public;')
        command('docker', 'run', '--detach', '--name', sink, '--network', network,
                '--mount', f'type=bind,source={ROOT / "scripts" / "security"},target=/scripts,readonly',
                '--mount', f'type=bind,source={template_directory},target=/templates,readonly',
                PYTHON_IMAGE, 'python', '/scripts/local_mail_sink.py')
        created.append(('container', sink))
        wait_healthy(mailbox)
        env = {
            'GOTRUE_API_HOST': '0.0.0.0', 'GOTRUE_API_PORT': '9999',
            'API_EXTERNAL_URL': base + '/auth/v1', 'GOTRUE_SITE_URL': base,
            'GOTRUE_URI_ALLOW_LIST': ','.join((DELETE_CONTEXT, RESET_CONTEXT, UNKNOWN_CONTEXT)),
            'GOTRUE_DB_DRIVER': 'postgres',
            'GOTRUE_DB_DATABASE_URL': f'postgres://postgres:{password}@{db}:5432/postgres',
            'GOTRUE_JWT_SECRET': secret, 'GOTRUE_JWT_EXP': '3600',
            'GOTRUE_JWT_AUD': 'authenticated', 'GOTRUE_JWT_ADMIN_ROLES': 'service_role',
            'GOTRUE_EXTERNAL_EMAIL_ENABLED': 'true', 'GOTRUE_MAILER_AUTOCONFIRM': 'false',
            'GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED': 'false',
            'GOTRUE_DISABLE_SIGNUP': 'false', 'GOTRUE_LOG_LEVEL': 'error',
            'GOTRUE_MAILER_OTP_LENGTH': '8', 'GOTRUE_MAILER_OTP_EXP': '600',
            'GOTRUE_SECURITY_UPDATE_PASSWORD_REQUIRE_REAUTHENTICATION':
                str(require_reauthentication).lower(),
            'GOTRUE_SECURITY_UPDATE_PASSWORD_REQUIRE_CURRENT_PASSWORD':
                str(require_current_password).lower(),
            'GOTRUE_RATE_LIMIT_EMAIL_SENT': '100', 'GOTRUE_RATE_LIMIT_VERIFY': '100',
            # Credential-effect assertions intentionally make many logins.
            # The separate lifecycle probe verifies the actual IP limiter.
            'GOTRUE_RATE_LIMIT_TOKEN_REFRESH': '6000', 'GOTRUE_RATE_LIMIT_OTP': '6000',
            'GOTRUE_RATE_LIMIT_HEADER': 'X-Forwarded-For',
            'GOTRUE_SMTP_HOST': sink, 'GOTRUE_SMTP_PORT': '1025',
            'GOTRUE_SMTP_ADMIN_EMAIL': 'sender@example.test', 'GOTRUE_SMTP_SENDER_NAME': 'Eatova local probe',
            'GOTRUE_SMTP_MAX_FREQUENCY': '1ms',
            'GOTRUE_MAILER_TEMPLATES_RECOVERY': f'http://{sink}:8025/recovery.html',
            'GOTRUE_MAILER_SUBJECTS_RECOVERY': 'Dein Eatova-Sicherheitscode',
            'GOTRUE_MAILER_TEMPLATES_REAUTHENTICATION': f'http://{sink}:8025/reauthentication.html',
            'GOTRUE_MAILER_SUBJECTS_REAUTHENTICATION': 'Dein Eatova-Code: Passwort ändern',
        }
        args = ['docker', 'run', '--detach', '--name', auth, '--network', network]
        for key, value in env.items():
            args.extend(['--env', key + '=' + value])
        command(*args, AUTH_IMAGE)
        created.append(('container', auth))
        wait_healthy(client)
        admin = signed_admin(secret)
        email = 'synthetic-purpose@example.test'
        status, user = client.request('/admin/users', {'email': email,
            'password': secrets.token_urlsafe(24), 'email_confirm': True}, admin)
        if status != 200 or not user.get('id'):
            raise RuntimeError(f'Synthetic user setup failed ({status})')
        user_id = user['id']
        cases = [('deletion', DELETE_CONTEXT, 'Kontolöschung bestätigen'),
                 ('reset', RESET_CONTEXT, 'Passwort zurücksetzen'),
                 ('legacy', None, 'Deine Identität bestätigen'),
                 ('unknown', UNKNOWN_CONTEXT, 'Deine Identität bestätigen'),
                 ('deletion_again', DELETE_CONTEXT, 'Kontolöschung bestätigen')]
        previous_count = 0
        for name, context, heading in cases:
            path = '/recover' + ('?' + urlencode({'redirect_to': context}) if context else '')
            status, _ = client.request(path, {'email': email})
            if status != 200:
                raise RuntimeError(f'{name}: recover rejected ({status})')
            for _ in range(60):
                _, messages = mailbox.request('/messages')
                if len(messages) > previous_count:
                    break
                time.sleep(.1)
            else:
                raise RuntimeError(f'{name}: no locally captured mail')
            if len(messages) != previous_count + 1:
                raise RuntimeError(f'{name}: unexpected SMTP message count')
            previous_count = len(messages)
            message = messages[-1]
            html = message['html']
            checks = {
                'purpose_heading': re.search(r'<h1\b[^>]*>' + re.escape(heading) + r'</h1>', html) is not None,
                'no_confirmation_link': '/verify?' not in html and 'token_hash=' not in html and '{{' not in html,
                'neutral_subject': message['subject'] == 'Dein Eatova-Sicherheitscode',
                'one_eight_digit_code': len(re.findall(r'(?<!\d)\d{8}(?!\d)', html)) == 1,
                'recipient': email in message['to'],
            }
            if not all(checks.values()):
                failed = [key for key, ok in checks.items() if not ok]
                raise RuntimeError(f'{name}: failed checks {failed}')
            token = re.findall(r'(?<!\d)\d{8}(?!\d)', html)[0]
            status, verified = client.request('/verify', {'email': email, 'token': token, 'type': 'recovery'})
            checks['otp_authenticates_original_user'] = (status == 200 and
                verified.get('user', {}).get('id') == user_id and isinstance(verified.get('access_token'), str))
            if not checks['otp_authenticates_original_user']:
                raise RuntimeError(f'{name}: real OTP verification failed ({status})')
            evidence['checks'].append({'context': name, **checks})
        def sql(statement):
            return command('docker', 'exec', '-i', db, 'psql', '-U', 'postgres',
                           '-v', 'ON_ERROR_STOP=1', input=statement)

        evidence['password_checks'] = PasswordChangeProbe(
            client.request, admin, sql, mailbox.request,
            require_current_password=expected_current_password).run()
        evidence['passed'] = True
        out = ROOT / '.agents' / ('email-template-probe' if expected_current_password
                                  else 'email-template-probe-legacy')
        out.mkdir(parents=True, exist_ok=True)
        (out / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'passed': True, 'contexts': len(cases), 'checks': len(cases) * 6,
                          'password_checks': len(evidence['password_checks']),
                          'evidence': str(out / 'result.json')}))
    finally:
        for kind, name in reversed(created):
            if kind == 'container':
                subprocess.run(['docker', 'rm', '--force', name], capture_output=True)
            else:
                subprocess.run(['docker', 'network', 'rm', name], capture_output=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prove-detection', action='store_true',
                        help='Require detection of template, current-password and reauthentication regressions.')
    parser.add_argument('--legacy-policy', action='store_true',
                        help='Test the former current-password-disabled configuration without changing live Auth.')
    options = parser.parse_args()
    policy = {'require_current_password': not options.legacy_policy,
              'expected_current_password': not options.legacy_policy}
    run(**policy)
    if options.prove_detection:
        original = (ROOT / 'supabase' / 'email_templates' / 'recovery.html').read_text(encoding='utf-8')
        if DELETE_CONTEXT not in original:
            raise RuntimeError('Mutation target is missing')
        # Only an owned temporary template is changed, never the source tree.
        with tempfile.TemporaryDirectory(prefix='eatova-mail-purpose-mutation-') as directory:
            (Path(directory) / 'recovery.html').write_text(
                original.replace(DELETE_CONTEXT, DELETE_CONTEXT + '-mutated'), encoding='utf-8')
            try:
                run(Path(directory), **policy)
            except RuntimeError as error:
                if str(error) != "deletion: failed checks ['purpose_heading']":
                    raise
            else:
                raise RuntimeError('Missing deletion purpose routing was not detected')
        try:
            run(require_reauthentication=False, **policy)
        except RuntimeError as error:
            if str(error) != 'old_session_missing_nonce_denied failed (status=200)':
                raise
        else:
            raise RuntimeError('Disabled password reauthentication was not detected')
        if not options.legacy_policy:
            try:
                run(require_current_password=False)
            except RuntimeError as error:
                if str(error) != 'recent_session_missing_current_password_denied failed (status=200)':
                    raise
            else:
                raise RuntimeError('Disabled current-password requirement was not detected')
        evidence_path = ROOT / '.agents' / ('email-template-probe-legacy' if options.legacy_policy
                                           else 'email-template-probe') / 'result.json'
        evidence = json.loads(evidence_path.read_text(encoding='utf-8'))
        evidence['purpose_mutation_detected'] = True
        evidence['password_reauthentication_mutation_detected'] = True
        if not options.legacy_policy:
            evidence['current_password_mutation_detected'] = True
        evidence_path.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'purpose_mutation_detected': True,
                          'password_reauthentication_mutation_detected': True,
                          'current_password_mutation_detected': not options.legacy_policy}))
