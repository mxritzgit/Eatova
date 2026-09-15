"""Manual, synthetic GoTrue/Edge check. No production credentials or endpoints.

Requires Docker, Deno, Python 3.11+. Creates only two named disposable
containers plus their own network; removes them in finally. The Auth port is
loopback-only, Postgres has no published port and stores data on tmpfs.
"""
import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import subprocess
import time

from auth_lifecycle_checks import LifecycleFailure, LifecycleProbe
from local_auth_transport import LocalAuthClient

ROOT = Path(__file__).resolve().parents[2]
AUTH_IMAGE = 'supabase/gotrue:v2.196.0@sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232'
POSTGRES_IMAGE = 'postgres:17.6@sha256:00bc86618629af00d2937fdc5a5d63db3ff8450acf52f0636ec813c7f4902929'
secret = secrets.token_urlsafe(40)
password = secrets.token_urlsafe(24)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--require-provider-budgets', action='store_true', help='Assert a distinct verified-user budget reservation before every stubbed paid call.')
parser.add_argument('--auth-lifecycle', action='store_true', help='Also prove real refresh/revocation, signup/recovery and email-change boundaries without sending mail.')
parser.add_argument('--prove-detection', action='store_true', help='With --auth-lifecycle, repeat refresh tests with rotation disabled and require detection.')
options = parser.parse_args()
if options.prove_detection and not options.auth_lifecycle:
    parser.error('--prove-detection requires --auth-lifecycle')
PREFIX = 'eatova-r4-auth-lifecycle' if options.auth_lifecycle else 'eatova-r3-authority'
PORT = 54992 if options.auth_lifecycle else 54991
BASE = f'http://127.0.0.1:{PORT}'
EVIDENCE = ROOT / '.agents' / ('auth-lifecycle-probe' if options.auth_lifecycle else 'edge-auth-probe')
EVIDENCE.mkdir(parents=True, exist_ok=True)
# The synthetic IP emulates a gateway header, not its hosted trust policy.
request = LocalAuthClient(
    BASE, client_ip='198.51.100.23' if options.auth_lifecycle else None,
).request

def cmd(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f'command {args[0]} {args[1]} failed ({result.returncode})')
    return result.stdout.strip()

def b64(data):
    return base64.urlsafe_b64encode(json.dumps(data, separators=(',', ':')).encode()).decode().rstrip('=')

def jwt(claims, key=None, algorithm='HS256'):
    raw = b64({'alg': algorithm, 'typ': 'JWT'}) + '.' + b64(claims)
    signature = '' if algorithm == 'none' else base64.urlsafe_b64encode(hmac.new((key or secret).encode(), raw.encode(), hashlib.sha256).digest()).decode().rstrip('=')
    return raw + '.' + signature

network = PREFIX + '-network'
db = PREFIX + '-db'
auth = PREFIX + '-auth'
created = []
try:
    cmd('docker', 'network', 'create', network)
    created.append(('network', network))
    cmd('docker', 'run', '--detach', '--name', db, '--network', network, '--tmpfs', '/var/lib/postgresql/data', '--env', 'POSTGRES_PASSWORD=' + password, POSTGRES_IMAGE)
    created.append(('container', db))
    for _ in range(30):
        # The image's temporary init server accepts Unix sockets, then restarts.
        # TCP becomes ready only on the final server used by the Auth container.
        p = subprocess.run(['docker', 'exec', db, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True)
        if p.returncode == 0:
            break
        time.sleep(0.4)
    else:
        raise RuntimeError('local Postgres did not become TCP-ready')
    cmd('docker', 'exec', '-i', db, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', input='CREATE SCHEMA auth; ALTER ROLE postgres SET search_path TO auth, public;')
    env = {
        'GOTRUE_API_HOST': '0.0.0.0', 'GOTRUE_API_PORT': '9999',
        'API_EXTERNAL_URL': BASE + '/auth/v1', 'GOTRUE_SITE_URL': BASE,
        'GOTRUE_DB_DRIVER': 'postgres',
        'GOTRUE_DB_DATABASE_URL': f'postgres://postgres:{password}@{db}:5432/postgres',
        'GOTRUE_JWT_SECRET': secret, 'GOTRUE_JWT_EXP': '3600',
        'GOTRUE_JWT_AUD': 'authenticated', 'GOTRUE_JWT_ISSUER': BASE + '/auth/v1',
        'GOTRUE_JWT_ADMIN_ROLES': 'service_role',
        'GOTRUE_EXTERNAL_EMAIL_ENABLED': 'true', 'GOTRUE_MAILER_AUTOCONFIRM': 'true',
        'GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED': 'false',
        'GOTRUE_DISABLE_SIGNUP': 'false', 'GOTRUE_LOG_LEVEL': 'error',
    }
    if options.auth_lifecycle:
        env.update({
            'GOTRUE_MAILER_AUTOCONFIRM': 'false',
            'GOTRUE_PASSWORD_MIN_LENGTH': '8',
            'GOTRUE_MAILER_OTP_LENGTH': '8', 'GOTRUE_MAILER_OTP_EXP': '600',
            'GOTRUE_MAILER_SECURE_EMAIL_CHANGE_ENABLED': 'true',
            'GOTRUE_SECURITY_UPDATE_PASSWORD_REQUIRE_REAUTHENTICATION': 'true',
            'GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED': 'true',
            'GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL': '10',
            'GOTRUE_RATE_LIMIT_VERIFY': '30',
            'GOTRUE_RATE_LIMIT_HEADER': 'X-Forwarded-For',
            'GOTRUE_RATE_LIMIT_EMAIL_SENT': '60',
            'GOTRUE_SMTP_MAX_FREQUENCY': '60s',
        })
    args = ['docker', 'run', '--detach', '--name', auth, '--network', network, '--publish', f'127.0.0.1:{PORT}:9999']
    for key, value in env.items():
        args.extend(['--env', key + '=' + value])
    args.append(AUTH_IMAGE)
    cmd(*args)
    created.append(('container', auth))
    for _ in range(50):
        try:
            if request('/health')[0] == 200:
                break
        except (OSError, ValueError):
            pass
        time.sleep(0.3)
    else:
        raise RuntimeError('local GoTrue did not become healthy')
    users = []
    admin_token = jwt({'role': 'service_role', 'exp': int(time.time()) + 3600})
    for label in ['a', 'b']:
        credentials = {'email': f'synthetic-{label}@example.test', 'password': secrets.token_urlsafe(20)}
        if options.auth_lifecycle:
            status, _ = request('/admin/users', {**credentials, 'email_confirm': True}, admin_token)
            if status != 200:
                raise RuntimeError('synthetic admin setup failed: ' + str(status))
            status, body = request('/token?grant_type=password', credentials)
        else:
            status, body = request('/signup', credentials)
        if status != 200 or 'access_token' not in body:
            raise RuntimeError('synthetic signup failed: ' + str(status))
        users.append(body)
    token = users[0]['access_token']
    claims = json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '=='))
    variants = {
        'valid_a': token, 'valid_b': users[1]['access_token'],
        'expired': jwt({**claims, 'exp': int(time.time()) - 60}),
        'future_nbf': jwt({**claims, 'nbf': int(time.time()) + 3600}),
        'wrong_signature': jwt(claims, secrets.token_urlsafe(40)),
        'none_algorithm': jwt(claims, algorithm='none'),
        'wrong_audience': jwt({**claims, 'aud': 'service_role'}),
        'wrong_issuer_signed_with_project_key': jwt({**claims, 'iss': 'https://other-project.invalid/auth/v1'}),
        'nonexistent_user': jwt({**claims, 'sub': '99999999-9999-4999-8999-999999999999'}),
        'malformed': 'invalid.jwt.data',
    }
    outcomes = {name: request('/user', token=value)[0] for name, value in variants.items()}
    evidence = {'gotrue_version': '2.196.0', 'auth_image_digest': cmd('docker', 'image', 'inspect', AUTH_IMAGE, '--format', '{{index .RepoDigests 0}}'), 'postgres': '17.6', 'postgres_image_digest': cmd('docker', 'image', 'inspect', POSTGRES_IMAGE, '--format', '{{index .RepoDigests 0}}'), 'isolation': 'separate Docker network, loopback-only Auth port, ephemeral DB tmpfs, synthetic users, no external requests', 'user_endpoint_statuses': outcomes}
    evidence['provider_budgets_required'] = options.require_provider_budgets
    if options.auth_lifecycle:
        def local_sql(statement):
            return cmd('docker', 'exec', '-i', db, 'psql', '-U', 'postgres',
                       '-v', 'ON_ERROR_STOP=1', input=statement)

        probe = LifecycleProbe(request, admin_token, local_sql)
        try:
            evidence['auth_lifecycle_checks'] = probe.run()
            evidence['auth_lifecycle_passed'] = True
            variants.update(probe.denied_tokens)
            outcomes.update({name: request('/user', token=value)[0]
                             for name, value in probe.denied_tokens.items()})
        except LifecycleFailure as error:
            evidence['auth_lifecycle_checks'] = probe.checks
            evidence['auth_lifecycle_passed'] = False
            evidence['auth_lifecycle_failure'] = str(error)
            (EVIDENCE / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
            raise
    result = subprocess.run(['deno', 'run', '--allow-env', f'--allow-net=127.0.0.1:{PORT}', str(ROOT / 'scripts' / 'security' / 'edge_auth_probe.ts')], input=json.dumps({'base': BASE, 'tokens': variants, 'users': [u['user']['id'] for u in users], 'requireProviderBudgets': options.require_provider_budgets}), capture_output=True, text=True)
    evidence['handler_probe_exit'] = result.returncode
    if result.returncode == 0:
        evidence['handler_checks'] = json.loads(result.stdout)
    else:
        evidence['handler_probe_error'] = 'see sanitized harness output; no tokens retained'
        print(result.stderr[-5000:])
    (EVIDENCE / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'evidence': str(EVIDENCE / 'result.json'), 'handler_probe_exit': result.returncode, 'handler_checks': len(evidence.get('handler_checks', []))}))
    if result.returncode != 0:
        raise RuntimeError('Isolated handler assertions failed')
    if options.prove_detection:
        # Only the just-created synthetic Auth container is restarted. A second
        # run with rotation disabled must fail at the active-family assertion.
        cmd('docker', 'rm', '--force', auth)
        changed_args = [arg.replace('GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED=true',
                                    'GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED=false')
                        for arg in args]
        cmd(*changed_args)
        for _ in range(50):
            try:
                if request('/health')[0] == 200:
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.3)
        else:
            raise RuntimeError('mutated local GoTrue did not become healthy')
        mutated = LifecycleProbe(request, admin_token, local_sql)
        try:
            mutated.refresh_replay()
        except LifecycleFailure as error:
            if str(error) != 'replay_revokes_active_family failed (status=200)':
                raise
            evidence['rotation_disabled_mutation_detected'] = True
            evidence['mutation_failure_check'] = 'replay_revokes_active_family'
        else:
            raise RuntimeError('disabled refresh rotation was not detected')
        (EVIDENCE / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'auth_lifecycle_checks': len(probe.checks),
                          'rotation_disabled_mutation_detected': True}))
finally:
    for kind, name in reversed(created):
        if kind == 'container':
            subprocess.run(['docker', 'rm', '--force', name], capture_output=True)
        else:
            subprocess.run(['docker', 'network', 'rm', name], capture_output=True)
