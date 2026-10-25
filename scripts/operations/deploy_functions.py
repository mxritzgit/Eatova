"""Plan, verify and record an Edge Function deploy (deploy-functions.yml).

  deploy_functions.py plan     --functions all|a,b --root <checkout> --output plan.json
                               [--github-output FILE]
  deploy_functions.py guard    --slugs a,b --target-sha SHA --repo <git checkout>
                               --output guard.json [--allow-below-floor]
  deploy_functions.py migrations --root <checkout> --output migrations.json
  deploy_functions.py metadata --slugs a,b --output state.json
  deploy_functions.py compare  --slug a --live <download dir> --root <checkout>
                               --output compare.json [--ignore-crlf]
  deploy_functions.py probe    --slugs a,b --output probe.json
  deploy_functions.py record   --dir <dir> --deploy-outcome <outcome> --source-sha SHA
                               --main-sha SHA --output record.json [--summary FILE]

`metadata` and `migrations` read SUPABASE_ACCESS_TOKEN and
SUPABASE_PROJECT_REF, `probe` reads SUPABASE_PROJECT_REF and
SUPABASE_ANON_KEY, all from the process environment. None of them is printed
or written: errors are fixed categories, and the record holds no project ref,
key, token or response body.

`guard` refuses a target older than a function's lowest safe rollback commit
(ROLLBACK_FLOORS) unless --allow-below-floor is given. `migrations` refuses a
target whose repository migrations are not all registered live: a function
without its migration answers its RPCs with 5xx. `compare` checks the
downloaded live source against the import graph of the checked-out function,
file by file. `record` decides the result: every function deployed, ACTIVE,
verify_jwt as its mode expects (on; off only for PUBLIC_WEBHOOKS), a new
version, live source equal to the checkout and the boot probe answered as
expected.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request

UTC = dt.timezone.utc
SLUG = re.compile(r'[a-z][a-z0-9-]{0,62}')
REF = re.compile(r'[a-z0-9]{20}')
SHA = re.compile(r'[0-9a-f]{40}')
FUNCTIONS = Path('supabase') / 'functions'
MAX_RESPONSE_BYTES = 256 * 1024
TIMEOUT_SECONDS = 30
# A probe request without an answer or with a 5xx is asked once more after
# this pause: one lost request is a network blip, not an outage (ops watch
# 2026-10-22). A lasting failure still fails.
RETRY_PAUSE_SECONDS = 5
# Same reason as the drift job in security.yml: a Cloudflare rule in front of
# the Management API rejects default library user agents (error 1010).
USER_AGENT = ('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
STATUSES = ('ACTIVE', 'REMOVED', 'THROTTLED')

# Method and the error codes of each handler's own 401 to a request without a
# user token. With the anon key the handler must answer with one of them: it
# booted and passed its configuration check (a missing secret is a 5xx before
# authentication). Without any token the gateway's verify_jwt must answer
# first, so none of them may appear; a public webhook answers that request
# itself, with one of them. The anon key is rejected locally when it equals
# the function's SUPABASE_ANON_KEY, otherwise after the Auth lookup; both codes
# count. A new function needs an entry before the workflow deploys it.
PROBES = {
    'analyze-meal': ('POST', frozenset({'missing_bearer_token', 'user_token_required', 'invalid_user_token'})),
    'coach-chat': ('POST', frozenset({'Unauthorized'})),
    'recipe-import': ('POST', frozenset({'unauthorized'})),
    'search-key': ('GET', frozenset({'missing_bearer_token', 'user_token_required', 'invalid_user_token'})),
    'store-notifications': ('POST', frozenset({'invalid_notification_auth'})),
    'subscription-verify': ('POST', frozenset({'missing_bearer_token', 'user_token_required', 'invalid_user_token'})),
}

# Functions served without the gateway's JWT check: store webhooks that
# authenticate every request themselves (Apple JWS, Google OIDC), because
# neither store can send a Supabase JWT. Only these may set verify_jwt = false
# in supabase/config.toml; the probe then expects the handler's own 401 without
# a token and the record expects verify_jwt off. Every other function keeps
# the gateway check.
PUBLIC_WEBHOOKS = frozenset({'store-notifications'})

# The oldest commit each function may be deployed from: a rollback target must
# contain it. A new function needs an entry before the workflow deploys it.
ROLLBACK_FLOORS = {
    # Free AI pool (#172): older handlers send no scope or resetAt on a budget
    # denial and fall back to the old Free numbers; analyze-meal and
    # recipe-import also keep the day slot of a capacity denial. Before #170
    # they gave every account one limit.
    'coach-chat': ('27ee6c44bc8914e525235ad2a602e9e89c53d4e2', 'free_ai_pool'),
    'analyze-meal': ('27ee6c44bc8914e525235ad2a602e9e89c53d4e2', 'free_ai_pool'),
    'recipe-import': ('27ee6c44bc8914e525235ad2a602e9e89c53d4e2', 'free_ai_pool'),
    # The last source verified live with today's schema and clients before the
    # #155 deploy (2026-10-18); #170 changed only a comment.
    'search-key': ('ea2722e6e9811e31dc92da5e152f4c68ca645701', 'last_verified_live_source'),
    # New with Premium (docs/PREMIUM.md 3.4, 3.5): the base main of their PR.
    # A target without the function fails unknown_function anyway.
    'store-notifications': ('fdd8d63f467aa4c12c13caf8c0b41cb10f5ef89f', 'first_release'),
    'subscription-verify':('fdd8d63f467aa4c12c13caf8c0b41cb10f5ef89f', 'first_release'),
}

# The query of the drift job in security.yml: registered versions, one string.
MIGRATION_QUERY = ("select coalesce(string_agg(version, ',' order by version), '') as v "
                   "from supabase_migrations.schema_migrations")
MIGRATION_VERSION = re.compile(r'[0-9]{1,32}')

COMMENT_BLOCK = re.compile(r'/\*.*?\*/', re.S)
COMMENT_LINE = re.compile(r'(?m)^\s*//.*$')
# Static import/export with a clause, a side-effect import, a dynamic import.
IMPORT_FROM = re.compile(
    r'''(?:^|[;\n])\s*(import|export)\s+(type\s+)?[^;'"`]*?\bfrom\s*(['"])([^'"\n]+)\3''')
IMPORT_BARE = re.compile(r'''(?:^|[;\n])\s*import\s*(['"])([^'"\n]+)\1''')
IMPORT_DYNAMIC = re.compile(r'''\bimport\s*\(\s*(['"])([^'"\n]+)\1\s*\)''')


class DeployError(Exception):
    """A fixed diagnostic category; never carries secrets or response bodies."""


# --------------------------------------------------------------------------
# Plan: slugs, verify_jwt guard and import graphs of the checkout.
# --------------------------------------------------------------------------

def available_functions(root):
    base = Path(root) / FUNCTIONS
    if not base.is_dir():
        raise DeployError('functions_directory_missing')
    return sorted(entry.name for entry in base.iterdir()
                  if entry.is_dir() and SLUG.fullmatch(entry.name)
                  and (entry / 'index.ts').is_file())


def parse_slugs(raw, available):
    text = (raw or '').strip()
    slugs = []
    for part in (available if text == 'all' else text.split(',')):
        slug = part.strip()
        if not slug:
            continue
        if not SLUG.fullmatch(slug):
            raise DeployError('invalid_slug')
        if slug not in available:
            raise DeployError('unknown_function:' + slug)
        # Every deployed function must be provable by the boot probe.
        if slug not in PROBES:
            raise DeployError('no_boot_probe_defined:' + slug)
        if slug not in slugs:
            slugs.append(slug)
    if not slugs:
        raise DeployError('no_functions_selected')
    return slugs


def expects_verify_jwt(slug):
    return slug not in PUBLIC_WEBHOOKS


def verify_jwt_settings(value, path=()):
    """(path, value) of every verify_jwt key anywhere in a parsed TOML document."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'verify_jwt':
                yield path + (key,), item
            yield from verify_jwt_settings(item, path + (key,))
    elif isinstance(value, list):
        for item in value:
            yield from verify_jwt_settings(item, path)


def assert_verify_jwt_kept(root, slugs=()):
    """Only a public webhook may switch the gateway's JWT check off.

    `functions deploy --workdir <root>` applies `[functions.<slug>] verify_jwt`
    of <root>/supabase/config.toml and merges a matching `[remotes.<ref>]` block
    over it, so a verify_jwt anywhere else counts too. A planned public webhook
    must declare verify_jwt = false itself: without it the CLI keeps the live
    value, or the server default for a new function.
    """
    config = Path(root) / 'supabase' / 'config.toml'
    document = {}
    if config.is_file():
        try:
            document = tomllib.loads(config.read_text(encoding='utf-8'))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError):
            raise DeployError('config_toml_unreadable') from None
    for path, value in verify_jwt_settings(document):
        public = len(path) == 3 and path[0] == 'functions' and path[1] in PUBLIC_WEBHOOKS
        if value is not True and not (public and value is False):
            raise DeployError('verify_jwt_disabled_in_config')
    functions = document.get('functions')
    for slug in slugs:
        declared = functions.get(slug) if isinstance(functions, dict) else None
        if not expects_verify_jwt(slug) and not (isinstance(declared, dict) and declared.get('verify_jwt') is False):
            raise DeployError('public_webhook_not_configured:' + slug)


def module_specifiers(text):
    """(specifier, type_only) pairs of one module."""
    text = COMMENT_LINE.sub('', COMMENT_BLOCK.sub('', text))
    found = []
    for match in IMPORT_FROM.finditer(text):
        found.append((match.group(4), match.group(2) is not None))
    for match in IMPORT_BARE.finditer(text):
        found.append((match.group(2), False))
    for match in IMPORT_DYNAMIC.finditer(text):
        found.append((match.group(2), False))
    return found


def import_graph(functions_root, slug):
    """Relative path -> {'sha256', 'type_only'} of every file the entry reaches.

    Only relative specifiers are followed; the functions are dependency-free.
    A module imported by value anywhere is not type-only.
    """
    base = Path(functions_root).resolve()
    entry = base / slug / 'index.ts'
    if not entry.is_file():
        raise DeployError('entrypoint_missing:' + slug)
    graph = {}
    pending = [(entry, False)]
    while pending:
        path, type_only = pending.pop()
        relative = path.relative_to(base).as_posix()
        known = graph.get(relative)
        # Visit a module again only to upgrade it (and its imports) to value.
        if known is not None and (type_only or not known['type_only']):
            continue
        data = path.read_bytes()
        if known is None:
            graph[relative] = {'sha256': hashlib.sha256(data).hexdigest(), 'type_only': type_only}
        else:
            known['type_only'] = False
        for specifier, type_import in module_specifiers(data.decode('utf-8')):
            if not specifier.startswith(('./', '../')):
                continue
            target = (path.parent / specifier).resolve()
            try:
                target.relative_to(base)
            except ValueError:
                raise DeployError('import_outside_functions') from None
            if not target.is_file():
                raise DeployError('unresolved_import')
            pending.append((target, type_only or type_import))
    return dict(sorted(graph.items()))


def plan(functions, root):
    slugs = parse_slugs(functions, available_functions(root))
    assert_verify_jwt_kept(root, slugs)
    base = Path(root) / FUNCTIONS
    return {
        'schema': 1,
        'slugs': slugs,
        'planned_at': dt.datetime.now(UTC).isoformat(timespec='seconds'),
        'graphs': {slug: import_graph(base, slug) for slug in slugs},
    }


# --------------------------------------------------------------------------
# Guard: the lowest safe rollback commit of each function.
# --------------------------------------------------------------------------

def git_is_ancestor(repo, ancestor, descendant, runner=subprocess.run):
    """True when [ancestor] is [descendant] or one of its ancestors."""
    if not SHA.fullmatch(ancestor or '') or not SHA.fullmatch(descendant or ''):
        raise DeployError('invalid_commit_sha')
    try:
        done = runner(['git', '-C', str(repo), 'merge-base', '--is-ancestor', ancestor, descendant],
                      capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        raise DeployError('git_unavailable') from None
    if done.returncode in (0, 1):
        return done.returncode == 0
    # 128: a commit the checkout does not have (shallow clone, unknown SHA).
    raise DeployError('git_ancestry_unknown')


def rollback_guard(slugs, target_sha, is_ancestor, allow_below_floor=False):
    """Which functions the target would roll back below their floor."""
    functions = {}
    for slug in slugs:
        if slug not in ROLLBACK_FLOORS:
            raise DeployError('no_rollback_floor_defined:' + slug)
        floor, reason = ROLLBACK_FLOORS[slug]
        functions[slug] = {'floor_sha': floor, 'reason': reason,
                           'target_contains_floor': is_ancestor(floor, target_sha) is True}
    below = [slug for slug, item in functions.items() if not item['target_contains_floor']]
    return {
        'schema': 1,
        'target_sha': target_sha,
        'functions': functions,
        'below_floor': below,
        'override': bool(below) and allow_below_floor is True,
        'allowed': not below or allow_below_floor is True,
    }


def repo_migration_versions(root):
    """Versions of the checkout's migrations, read like the drift job does."""
    base = Path(root) / 'supabase' / 'migrations'
    if not base.is_dir():
        raise DeployError('migrations_directory_missing')
    versions = []
    for entry in sorted(base.iterdir()):
        if entry.is_file() and entry.suffix == '.sql':
            version = entry.name.split('_', 1)[0]
            if not MIGRATION_VERSION.fullmatch(version):
                raise DeployError('unparseable_migration_name')
            versions.append(version)
    if not versions:
        raise DeployError('no_repository_migrations')
    return versions


def migration_drift(registered, repo_versions):
    """Repository migrations of the target that the live database lacks."""
    live = set(registered)
    missing = [version for version in repo_versions if version not in live]
    return {
        'schema': 1,
        'repo_migrations': len(repo_versions),
        'registered_migrations': len(live),
        'missing': missing,
        'registered': not missing,
    }


# --------------------------------------------------------------------------
# Compare: downloaded live source against the checkout's import graph.
# --------------------------------------------------------------------------

def live_functions_root(live_dir, slug):
    """The directory D of the download with D/<slug>/index.ts."""
    candidates = sorted({path.parent.parent for path in Path(live_dir).rglob('index.ts')
                         if path.parent.name == slug and not path.is_symlink()})
    if not candidates:
        raise DeployError('live_entrypoint_missing')
    if len(candidates) > 1:
        raise DeployError('live_layout_ambiguous')
    return candidates[0]


def same_bytes(left, right, ignore_crlf):
    if ignore_crlf:
        return left.replace(b'\r\n', b'\n') == right.replace(b'\r\n', b'\n')
    return left == right


def compare(slug, live_dir, root, ignore_crlf=False):
    functions_root = Path(root) / FUNCTIONS
    graph = import_graph(functions_root, slug)
    live_root = live_functions_root(live_dir, slug)
    live = {}
    for path in sorted(live_root.rglob('*')):
        if path.is_symlink():
            raise DeployError('live_symlink')
        if path.is_file():
            live[path.relative_to(live_root).as_posix()] = path.read_bytes()
    missing, missing_type_only, different, extra_identical, foreign = [], [], [], [], []
    for relative, entry in graph.items():
        if relative not in live:
            (missing_type_only if entry['type_only'] else missing).append(relative)
        elif not same_bytes(live[relative], (functions_root / relative).read_bytes(), ignore_crlf):
            different.append(relative)
    for relative, data in live.items():
        if relative in graph:
            continue
        checkout = functions_root / relative
        if checkout.is_file() and same_bytes(data, checkout.read_bytes(), ignore_crlf):
            extra_identical.append(relative)
        else:
            foreign.append(relative)
    return {
        'slug': slug,
        'ignore_crlf': ignore_crlf,
        'graph_files': len(graph),
        'live_files': len(live),
        'missing': missing,
        'missing_type_only': missing_type_only,
        'different': different,
        'extra_identical': extra_identical,
        'foreign': foreign,
        'identical': not (missing or different or foreign),
    }


# --------------------------------------------------------------------------
# Management API metadata and the boot probe (fixed hosts, no redirects).
# --------------------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        raise DeployError('redirect_rejected')


def opener():
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))


def valid_ref(value):
    if not isinstance(value, str) or REF.fullmatch(value) is None:
        raise DeployError('invalid_project_reference')
    return value


def secret(name):
    value = os.environ.get(name, '')
    if not value or any(character.isspace() for character in value):
        raise DeployError('missing_or_invalid_' + name.lower())
    return value


class Management:
    def __init__(self, token, project_ref, open_url=None):
        self.token = token
        self.ref = valid_ref(project_ref)
        self.open = open_url or opener().open

    def _fetch(self, request):
        """Parsed JSON of one response; errors are fixed categories."""
        try:
            with self.open(request, timeout=TIMEOUT_SECONDS) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            error.close()
            raise DeployError('management_http_' + str(error.code)) from None
        except (OSError, ValueError):
            raise DeployError('management_transport_failure') from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise DeployError('management_response_too_large')
        try:
            return json.loads(raw)
        except ValueError:
            raise DeployError('management_invalid_json') from None

    def function(self, slug):
        """Allowlisted metadata of one function; None if it does not exist."""
        if not SLUG.fullmatch(slug):
            raise DeployError('invalid_slug')
        request = urllib.request.Request(
            'https://api.supabase.com/v1/projects/' + self.ref + '/functions/' + slug,
            headers={'Authorization': 'Bearer ' + self.token, 'Accept': 'application/json',
                     'Accept-Encoding': 'identity', 'User-Agent': USER_AGENT})
        try:
            data = self._fetch(request)
        except DeployError as error:
            if str(error) == 'management_http_404':
                return None
            raise
        if not isinstance(data, dict):
            raise DeployError('management_invalid_json')
        version, status = data.get('version'), data.get('status')
        updated, verify_jwt = data.get('updated_at'), data.get('verify_jwt')
        return {
            'version': version if type(version) is int and version >= 0 else None,
            'status': status if status in STATUSES else 'other',
            # Kept as false for a public webhook; anything but a boolean is unknown.
            'verify_jwt': verify_jwt if type(verify_jwt) is bool else None,
            'updated_at': updated if type(updated) is int else None,
        }

    def registered_migrations(self):
        """Versions in supabase_migrations.schema_migrations (read-only query)."""
        request = urllib.request.Request(
            'https://api.supabase.com/v1/projects/' + self.ref + '/database/query',
            data=json.dumps({'query': MIGRATION_QUERY}).encode(), method='POST',
            headers={'Authorization': 'Bearer ' + self.token, 'Accept': 'application/json',
                     'Content-Type': 'application/json', 'Accept-Encoding': 'identity',
                     'User-Agent': USER_AGENT})
        data = self._fetch(request)
        if not (isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict)
                and isinstance(data[0].get('v'), str)):
            raise DeployError('migration_history_unreadable')
        versions = [version for version in data[0]['v'].split(',') if version]
        if not versions or not all(MIGRATION_VERSION.fullmatch(version) for version in versions):
            raise DeployError('migration_history_unreadable')
        return versions


def metadata(api, slugs):
    result = {}
    for slug in slugs:
        try:
            info = api.function(slug)
            result[slug] = {'exists': False} if info is None else {'exists': True, **info}
        except DeployError as error:
            result[slug] = {'exists': None, 'error': str(error)}
    return result


def probe_request(open_url, url, method, headers):
    """Status and the JSON body's `error` code; nothing else is kept."""
    body = b'{}' if method == 'POST' else None
    request = urllib.request.Request(url, data=body, method=method, headers={
        'Accept': 'application/json', 'Accept-Encoding': 'identity', 'User-Agent': USER_AGENT,
        **({'Content-Type': 'application/json'} if body is not None else {}), **headers})
    try:
        with open_url(request, timeout=TIMEOUT_SECONDS) as response:
            status, raw = response.status, response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        try:
            raw = error.read(MAX_RESPONSE_BYTES + 1)
        except OSError:
            raw = b''
        error.close()
    except (OSError, ValueError):
        return {'status': None, 'error_code': None}
    code = None
    if raw and len(raw) <= MAX_RESPONSE_BYTES:
        try:
            data = json.loads(raw)
            code = data.get('error') if isinstance(data, dict) else None
        except ValueError:
            code = None
    return {'status': status, 'error_code': code if isinstance(code, str) else None}


def probe(slugs, project_ref, anon_key, open_url=None, sleep=time.sleep):
    """Preflight 204, gateway 401 without a token, the handler's own answer with the anon key.

    A public webhook has no gateway check: without a token its handler must
    answer the 401, and the gateway's 401 would mean verify_jwt is still on.
    """
    valid_ref(project_ref)
    open_url = open_url or opener().open

    def ask(url, method, headers):
        answer = probe_request(open_url, url, method, headers)
        if answer['status'] is None or answer['status'] >= 500:
            sleep(RETRY_PAUSE_SECONDS)
            answer = probe_request(open_url, url, method, headers)
        return answer

    results = {}
    for slug in slugs:
        if slug not in PROBES:
            results[slug] = {'passed': False, 'reason': 'no_boot_probe_defined'}
            continue
        method, handler_codes = PROBES[slug]
        url = 'https://' + project_ref + '.supabase.co/functions/v1/' + slug
        preflight = ask(url, 'OPTIONS', {
            'Origin': 'https://deploy-probe.invalid', 'Access-Control-Request-Method': method})
        no_token = ask(url, method, {})
        anon = ask(url, method, {
            'Authorization': 'Bearer ' + anon_key, 'apikey': anon_key})
        handler_refused = no_token['status'] == 401 and no_token['error_code'] in handler_codes
        checks = {'preflight_204': preflight['status'] == 204}
        if expects_verify_jwt(slug):
            # The gateway's verify_jwt answers; a handler code would mean it is off.
            checks['gateway_401_without_token'] = no_token['status'] == 401 and not handler_refused
        else:
            checks['handler_401_without_token'] = handler_refused
        checks['handler_answers_anon_key'] = anon['status'] == 401 and anon['error_code'] in handler_codes
        results[slug] = {
            'passed': all(checks.values()),
            'checks': checks,
            'statuses': {'preflight': preflight['status'], 'no_token': no_token['status'],
                         'anon_key': anon['status']},
        }
    return results


def probe_markdown(results):
    """Statuses and verdicts only; the probe keeps no response body."""
    lines = ['### Boot probe: ' + ('OK' if results and all(
        item.get('passed') for item in results.values()) else 'FAILED'), '',
             '| Function | Preflight | Without token | Anon key | Passed |', '| --- | --- | --- | --- | --- |']
    for slug, item in sorted(results.items()):
        statuses = item.get('statuses') or {}
        lines.append('| `{}` | {} | {} | {} | {} |'.format(
            slug, statuses.get('preflight'), statuses.get('no_token'), statuses.get('anon_key'),
            mark(item.get('passed') is True)))
    return '\n'.join(lines) + '\n'


# --------------------------------------------------------------------------
# Record: one JSON document per run, and the verdict.
# --------------------------------------------------------------------------

def load(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def summary(entry):
    if not isinstance(entry, dict):
        return None
    return {key: entry.get(key) for key in (
        'identical', 'ignore_crlf', 'graph_files', 'live_files', 'missing', 'missing_type_only',
        'different', 'extra_identical', 'foreign')}


def build_record(directory, deploy_outcome, source_sha, main_sha, environ, now):
    directory = Path(directory)
    plan_data = load(directory / 'plan.json', {}) or {}
    slugs = [slug for slug in plan_data.get('slugs', []) if isinstance(slug, str) and SLUG.fullmatch(slug)]
    before = load(directory / 'before.json', {}) or {}
    after = load(directory / 'after.json', {}) or {}
    probes = load(directory / 'probe.json', {}) or {}
    guard = load(directory / 'guard.json', {}) or {}
    migrations = load(directory / 'migrations.json', {}) or {}
    functions = []
    for slug in slugs:
        old, new = before.get(slug) or {}, after.get(slug) or {}
        verified = load(directory / ('after-' + slug + '.json'))
        live_before = load(directory / ('before-' + slug + '.json'))
        probed = probes.get(slug) or {}
        old_version = old.get('version') if type(old.get('version')) is int else None
        new_version = new.get('version') if type(new.get('version')) is int else None
        verify_jwt = expects_verify_jwt(slug)
        checks = {
            # The deploy loop writes this marker only after the CLI succeeded.
            'deployed': (directory / ('deployed-' + slug)).is_file(),
            'active': new.get('status') == 'ACTIVE',
            # Read back after the deploy: on, or off for a public webhook.
            'verify_jwt': new.get('verify_jwt') is verify_jwt,
            'new_version': new_version is not None and new_version > (old_version or 0),
            'source_verified': isinstance(verified, dict) and verified.get('identical') is True,
            'boot_probe': probed.get('passed') is True,
        }
        functions.append({
            'slug': slug,
            'version_before': old_version,
            'version_after': new_version,
            'status': new.get('status'),
            'verify_jwt_expected': verify_jwt,
            'checks': checks,
            'live_source': summary(verified),
            'live_source_before': summary(live_before),
            'boot_probe': {key: probed.get(key) for key in ('checks', 'statuses')},
            'passed': all(checks.values()),
        })
    server = environ.get('GITHUB_SERVER_URL', '')
    repository = environ.get('GITHUB_REPOSITORY', '')
    run_id = environ.get('GITHUB_RUN_ID', '')
    return {
        'schema': 1,
        'result': 'success' if deploy_outcome == 'success' and functions and all(
            item['passed'] for item in functions) else 'failure',
        'source_sha': source_sha if SHA.fullmatch(source_sha or '') else None,
        'main_head_sha': main_sha if SHA.fullmatch(main_sha or '') else None,
        'rollback': bool(source_sha) and source_sha != main_sha,
        'slugs': slugs,
        'deploy_outcome': deploy_outcome if deploy_outcome in ('success', 'failure', 'cancelled', 'skipped') else 'unknown',
        'cli_version': environ.get('SUPABASE_CLI_VERSION') or None,
        'planned_at': plan_data.get('planned_at'),
        'recorded_at': now.isoformat(timespec='seconds'),
        'run_url': (server + '/' + repository + '/actions/runs/' + run_id) if server and repository and run_id.isdigit() else None,
        'run_attempt': environ.get('GITHUB_RUN_ATTEMPT') or None,
        # A deploy below a function's floor needs the explicit override.
        'below_rollback_floor': [slug for slug in guard.get('below_floor', [])
                                 if isinstance(slug, str) and SLUG.fullmatch(slug)],
        'rollback_floor_override': guard.get('override') is True,
        'migrations_registered': migrations.get('registered') if isinstance(
            migrations.get('registered'), bool) else None,
        'functions': functions,
    }


def mark(ok):
    return 'yes' if ok else '**no**'


def markdown(record):
    lines = ['### Edge Function deploy: ' + record['result'].upper(), '',
             'Source `' + str(record['source_sha']) + '`' + (' (rollback)' if record['rollback'] else ''), '']
    if record.get('rollback_floor_override'):
        lines += ['Deployed below the lowest safe rollback commit of: ' + ', '.join(
            '`' + slug + '`' for slug in record['below_rollback_floor']) + ' (override)', '']
    lines += ['| Function | Version | Deployed | Active | verify_jwt | Source | Boot probe |',
             '| --- | --- | --- | --- | --- | --- | --- |']
    for item in record['functions']:
        checks = item['checks']
        verify_jwt = mark(checks['verify_jwt']) + ('' if item['verify_jwt_expected'] else ' (off, public webhook)')
        lines.append('| `{}` | {} -> {} | {} | {} | {} | {} | {} |'.format(
            item['slug'], item['version_before'], item['version_after'], mark(checks['deployed']),
            mark(checks['active']), verify_jwt, mark(checks['source_verified']),
            mark(checks['boot_probe'])))
    return '\n'.join(lines) + '\n'


# --------------------------------------------------------------------------

def write_json(path, data):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('plan')
    p.add_argument('--functions', required=True)
    p.add_argument('--root', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--github-output')
    g = commands.add_parser('guard')
    g.add_argument('--slugs', required=True)
    g.add_argument('--target-sha', required=True)
    g.add_argument('--repo', required=True)
    g.add_argument('--output', required=True)
    g.add_argument('--allow-below-floor', action='store_true')
    n = commands.add_parser('migrations')
    n.add_argument('--root', required=True)
    n.add_argument('--output', required=True)
    m = commands.add_parser('metadata')
    m.add_argument('--slugs', required=True)
    m.add_argument('--output', required=True)
    c = commands.add_parser('compare')
    c.add_argument('--slug', required=True)
    c.add_argument('--live', required=True)
    c.add_argument('--root', required=True)
    c.add_argument('--output', required=True)
    c.add_argument('--ignore-crlf', action='store_true')
    b = commands.add_parser('probe')
    b.add_argument('--slugs', required=True)
    b.add_argument('--output', required=True)
    b.add_argument('--summary')
    r = commands.add_parser('record')
    r.add_argument('--dir', required=True)
    r.add_argument('--deploy-outcome', required=True)
    r.add_argument('--source-sha', required=True)
    r.add_argument('--main-sha', required=True)
    r.add_argument('--output', required=True)
    r.add_argument('--summary')
    args = parser.parse_args(argv)

    def slug_list(raw):
        if raw.strip() == 'all':
            return sorted(PROBES)
        slugs = [slug.strip() for slug in raw.split(',') if slug.strip()]
        if not slugs or not all(SLUG.fullmatch(slug) for slug in slugs):
            raise DeployError('invalid_slug')
        return slugs

    try:
        if args.command == 'plan':
            result = plan(args.functions, args.root)
            write_json(args.output, result)
            if args.github_output:
                with open(args.github_output, 'a', encoding='utf-8') as handle:
                    handle.write('slugs=' + ','.join(result['slugs']) + '\n')
            print('Planned: ' + ', '.join(result['slugs']))
            return 0
        if args.command == 'guard':
            if not SHA.fullmatch(args.target_sha or ''):
                raise DeployError('invalid_commit_sha')
            result = rollback_guard(
                slug_list(args.slugs), args.target_sha,
                lambda ancestor, descendant: git_is_ancestor(args.repo, ancestor, descendant),
                args.allow_below_floor)
            write_json(args.output, result)
            for slug in result['below_floor']:
                floor, reason = ROLLBACK_FLOORS[slug]
                print(('::warning::' if result['allowed'] else '::error::') + slug
                      + ': the target is older than its lowest safe rollback commit ' + floor
                      + ' (' + reason + ')' + ('; deployed on override' if result['allowed'] else ''),
                      file=sys.stderr)
            if not result['below_floor']:
                print('Every function stays at or above its lowest safe rollback commit.')
            return 0 if result['allowed'] else 1
        if args.command == 'migrations':
            versions = repo_migration_versions(args.root)
            api = Management(secret('SUPABASE_ACCESS_TOKEN'), secret('SUPABASE_PROJECT_REF'))
            result = migration_drift(api.registered_migrations(), versions)
            write_json(args.output, result)
            if result['missing']:
                print('::error::migrations: not registered live: ' + ', '.join(result['missing'])
                      + '; apply them before deploying this commit (docs/OPERATIONS.md)', file=sys.stderr)
                return 1
            print('All ' + str(len(versions)) + ' migrations of the target are registered live.')
            return 0
        if args.command == 'metadata':
            api = Management(secret('SUPABASE_ACCESS_TOKEN'), secret('SUPABASE_PROJECT_REF'))
            result = metadata(api, slug_list(args.slugs))
            write_json(args.output, result)
            return 0 if all('error' not in item for item in result.values()) else 1
        if args.command == 'compare':
            result = compare(args.slug, args.live, args.root, args.ignore_crlf)
            write_json(args.output, result)
            print(args.slug + ': ' + ('live source equals the checkout' if result['identical'] else 'live source DIFFERS'))
            return 0 if result['identical'] else 1
        if args.command == 'probe':
            result = probe(slug_list(args.slugs), secret('SUPABASE_PROJECT_REF'), secret('SUPABASE_ANON_KEY'))
            write_json(args.output, result)
            # Statuses only: the log then shows which check failed.
            print(probe_markdown(result), end='')
            if args.summary:
                with open(args.summary, 'a', encoding='utf-8') as handle:
                    handle.write(probe_markdown(result))
            return 0 if all(item['passed'] for item in result.values()) else 1
        record = build_record(args.dir, args.deploy_outcome, args.source_sha, args.main_sha,
                              os.environ, dt.datetime.now(UTC))
        write_json(args.output, record)
        if args.summary:
            with open(args.summary, 'a', encoding='utf-8') as handle:
                handle.write(markdown(record))
        print('Deploy record: ' + record['result'])
        return 0 if record['result'] == 'success' else 1
    except DeployError as error:
        print('::error::' + args.command + ': ' + str(error), file=sys.stderr)
        return 2
    except Exception:
        # Library errors must not leak exception text that may hold credentials.
        print('::error::' + args.command + ': unexpected failure', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
