"""Manual, synthetic GoTrue/Edge check. No production credentials or endpoints.

Requires Docker, Deno, Python 3.11+. Creates only two named disposable
containers plus their own network; removes them in finally. The Auth port is
loopback-only, Postgres has no published port and stores data on tmpfs.
"""
import base64
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / '.agents' / 'edge-auth-probe'
EVIDENCE.mkdir(parents=True, exist_ok=True)
PREFIX = 'eatova-r3-authority'
PORT = 54991
BASE = f'http://127.0.0.1:{PORT}'
secret = secrets.token_urlsafe(40)
password = secrets.token_urlsafe(24)

def cmd(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f'command {args[0]} {args[1]} failed ({result.returncode})')
    return result.stdout.strip()

def request(path, data=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, data=None if data is None else json.dumps(data).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=2) as response:
            return response.status, json.loads(response.read() or b'{}')
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b'{}')

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
    cmd('docker', 'run', '--detach', '--name', db, '--network', network, '--tmpfs', '/var/lib/postgresql/data', '--env', 'POSTGRES_PASSWORD=' + password, 'postgres:17.6')
    created.append(('container', db))
    for _ in range(30):
        p = subprocess.run(['docker', 'exec', db, 'pg_isready', '-U', 'postgres'], capture_output=True)
        if p.returncode == 0:
            break
        time.sleep(0.4)
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
    args = ['docker', 'run', '--detach', '--name', auth, '--network', network, '--publish', f'127.0.0.1:{PORT}:9999']
    for key, value in env.items():
        args.extend(['--env', key + '=' + value])
    args.append('supabase/gotrue:v2.196.0')
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
    for label in ['a', 'b']:
        status, body = request('/signup', {'email': f'synthetic-{label}@example.test', 'password': secrets.token_urlsafe(20)})
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
    evidence = {'gotrue_version': '2.196.0', 'auth_image_digest': cmd('docker', 'image', 'inspect', 'supabase/gotrue:v2.196.0', '--format', '{{index .RepoDigests 0}}'), 'postgres': '17.6', 'isolation': 'separate Docker network, loopback-only Auth port, ephemeral DB tmpfs, synthetic users, no external requests', 'user_endpoint_statuses': outcomes}
    result = subprocess.run(['deno', 'run', '--allow-env', f'--allow-net=127.0.0.1:{PORT}', str(ROOT / 'scripts' / 'security' / 'edge_auth_probe.ts')], input=json.dumps({'base': BASE, 'tokens': variants, 'users': [u['user']['id'] for u in users]}), capture_output=True, text=True)
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
finally:
    for kind, name in reversed(created):
        if kind == 'container':
            subprocess.run(['docker', 'rm', '--force', name], capture_output=True)
        else:
            subprocess.run(['docker', 'network', 'rm', name], capture_output=True)
