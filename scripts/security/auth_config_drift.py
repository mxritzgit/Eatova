"""Read-only drift audit of the managed Auth configuration.

Compares `GET /v1/projects/{ref}/config/auth` with the checked-in contract
`supabase/auth_config.expected.json` and the published mail templates in
`supabase/email_templates/`. Run only in the protected production environment
or locally by an operator. Diagnostics name pinned non-secret settings,
allow-list entries and template hashes; they never contain credentials,
unpinned response values or template bodies. Behavioral guarantees are tested
separately against disposable GoTrue in CI.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / 'supabase' / 'auth_config.expected.json'
MAX_BODY = 1024 * 1024
SHOWN_CHARS = 120

TOKEN = re.compile(r'\{\{-?\s*\.Token\s*-?\}\}')
TOKEN_VARIABLE = re.compile(r'\.Token\b')
HREF = re.compile(r'''\b(?:href|src|action)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''', re.I)
BARE_URL = re.compile(r'''(?:[a-z][a-z0-9+.-]*://|mailto:)[^\s"'<>)]*''', re.I)
# Conditions compare data and render nothing; output actions stay scanned.
CONDITION = re.compile(r'\{\{-?\s*(?:if|else\s+if)\b.*?\}\}', re.S)


class PolicyError(Exception):
    """Safe diagnostic without credentials, unpinned values or template bodies."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def load_contract(path=None):
    """Returns the expected values, with template sources read from disk."""
    try:
        contract = json.loads(Path(CONTRACT if path is None else path).read_text(encoding='utf-8'))
        templates = contract['templates']
        source = ROOT / templates['source']
        subjects = json.loads((source / 'subjects.json').read_text(encoding='utf-8'))
        # read_text normalizes CRLF checkouts to the published LF bytes.
        return {
            'settings': {key: entry['expected'] for key, entry in contract['settings'].items()},
            'uri_allow_list': list(contract['uri_allow_list']['expected']),
            'templates': {name: (subjects[name], (source / f'{name}.html').read_text(encoding='utf-8'))
                          for name in templates['names']},
            'otp': set(templates['otp']),
            'link': set(templates['confirmation_link_allowed']),
            'static_links': set(templates['allowed_static_links']),
            'source': templates['source'],
        }
    except (OSError, ValueError, KeyError, TypeError):
        raise PolicyError('Auth configuration contract could not be loaded') from None


def show(value):
    """Short, single-line rendering of a pinned non-secret scalar."""
    if value is None or isinstance(value, (bool, int, float)):
        return json.dumps(value)
    if isinstance(value, str):
        text = value if len(value) <= SHOWN_CHARS else value[:SHOWN_CHARS] + '...'
        return json.dumps(text, ensure_ascii=False)
    return f'<{type(value).__name__}>'


def same(expected, actual):
    # Exact type: True must not match 1, 60 must not match "60".
    return type(actual) is type(expected) and actual == expected


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:12]


def links(html):
    found = {next(group for group in match.groups() if group is not None)
             for match in HREF.finditer(html)}
    # The recovery purpose comparison carries URLs as data, not as links.
    found.update(BARE_URL.findall(CONDITION.sub(' ', html)))
    return found


def template_properties(name, subject, html, expected):
    """Security properties checked independently of byte equality."""
    content = f'mailer_templates_{name}_content'
    findings = []
    if '{{' in subject or '://' in subject or TOKEN_VARIABLE.search(subject):
        findings.append(f'mailer_subjects_{name}: contains a template action or link')
    if '.TokenHash' in html:
        findings.append(f'{content}: contains .TokenHash')
    if 'eatova://' in html:
        findings.append(f'{content}: contains an eatova:// link')
    if name not in expected['link'] and '.ConfirmationURL' in html:
        findings.append(f'{content}: contains .ConfirmationURL')
    if name in expected['otp']:
        if not TOKEN.search(html):
            findings.append(f'{content}: OTP template does not render {{{{ .Token }}}}')
    elif TOKEN_VARIABLE.search(html):
        findings.append(f'{content}: non-OTP template contains .Token')
    allowed = set(expected['static_links'])
    if name in expected['link']:
        allowed.add('{{ .ConfirmationURL }}')
    for link in sorted(links(html) - allowed):
        findings.append(f'{content}: link outside the allowed footer links: {show(link)}')
    return findings


def allow_list_findings(config, expected):
    if 'uri_allow_list' not in config:
        return ['uri_allow_list: missing from the live configuration']
    value = config['uri_allow_list']
    if isinstance(value, str):
        entries = [entry.strip() for entry in value.split(',')]
    elif isinstance(value, list) and all(isinstance(entry, str) for entry in value):
        entries = [entry.strip() for entry in value]
    else:
        return [f'uri_allow_list: unexpected type {show(value)}']
    live = {entry for entry in entries if entry}
    want = set(expected)
    return ([f'uri_allow_list: missing entry {show(entry)}' for entry in sorted(want - live)]
            + [f'uri_allow_list: unexpected entry {show(entry)}' for entry in sorted(live - want)])


def template_findings(config, expected):
    findings = []
    for name, (want_subject, want_html) in expected['templates'].items():
        subject_key = f'mailer_subjects_{name}'
        content_key = f'mailer_templates_{name}_content'
        subject, html = config.get(subject_key), config.get(content_key)
        for key, value in ((subject_key, subject), (content_key, html)):
            if key not in config:
                findings.append(f'{key}: missing from the live configuration')
            elif not isinstance(value, str):
                findings.append(f'{key}: unexpected type {show(value)}')
        if not isinstance(subject, str) or not isinstance(html, str):
            continue
        findings.extend(template_properties(name, subject, html, expected))
        if subject != want_subject:
            findings.append(f'{subject_key}: expected {show(want_subject)}, live {show(subject)}')
        if html != want_html:
            findings.append(f'{content_key}: differs from {expected["source"]}/{name}.html '
                            f'(live sha256 {digest(html)}, repo {digest(want_html)})')
    return findings


def drift(config, expected):
    """Returns safe one-line findings; empty when live matches the contract."""
    if not isinstance(config, dict):
        raise PolicyError('Auth configuration response is not an object')
    findings = []
    for key, want in expected['settings'].items():
        if key not in config:
            findings.append(f'{key}: missing from the live configuration')
        elif not same(want, config[key]):
            findings.append(f'{key}: expected {show(want)}, live {show(config[key])}')
    findings.extend(allow_list_findings(config, expected['uri_allow_list']))
    findings.extend(template_findings(config, expected))
    return findings


def validate(config, expected=None):
    findings = drift(config, load_contract() if expected is None else expected)
    if findings:
        raise PolicyError(f'Auth configuration drift ({len(findings)} finding(s)) against '
                          'supabase/auth_config.expected.json:\n'
                          + '\n'.join('- ' + finding for finding in findings))


def fetch(environ, opener=None):
    token = environ.get('SUPABASE_ACCESS_TOKEN', '')
    project = environ.get('SUPABASE_PROJECT_REF', '')
    if not token or '\r' in token or '\n' in token:
        raise PolicyError('Missing or invalid Supabase access credential')
    if not re.fullmatch(r'[a-z]{20}', project):
        raise PolicyError('Missing or invalid Supabase project reference')
    opener = opener or urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{project}/config/auth',
        # A browser-like UA: Cloudflare blocks default Python user agents.
        headers={'Authorization': 'Bearer ' + token,
                 'User-Agent': 'Mozilla/5.0 Eatova-Auth-Policy-Audit'},
        method='GET',
    )
    try:
        with opener.open(request, timeout=30) as response:
            if response.status != 200:
                raise PolicyError('Auth configuration request was not successful')
            body = response.read(MAX_BODY + 1)
            if len(body) > MAX_BODY:
                raise PolicyError('Auth configuration response exceeds size limit')
            return json.loads(body)
    except urllib.error.HTTPError as error:
        raise PolicyError(f'Auth configuration request failed (HTTP {error.code})') from None
    except (urllib.error.URLError, OSError, ValueError, UnicodeError):
        raise PolicyError('Auth configuration could not be read') from None


def check(environ=None, opener=None, expected=None):
    environ = os.environ if environ is None else environ
    # The contract is loaded first: a broken checkout never sends a request.
    expected = load_contract() if expected is None else expected
    validate(fetch(environ, opener), expected)
    return expected


def main(environ=None, opener=None):
    environ = os.environ if environ is None else environ
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(errors='backslashreplace')
    try:
        expected = check(environ, opener)
    except PolicyError as error:
        print(str(error), file=sys.stderr)
        if environ.get('GITHUB_ACTIONS') == 'true':
            print('::error title=Auth configuration drift::Live Auth configuration does not match '
                  'supabase/auth_config.expected.json; see the step log.', file=sys.stderr)
        summary = environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a', encoding='utf-8') as handle:
                handle.write('### Auth configuration drift: FAILED\n\n```\n' + str(error) + '\n```\n')
        return 1
    message = (f'Auth configuration matches the contract: {len(expected["settings"])} settings, '
               f'{len(expected["uri_allow_list"])} redirect allow-list entries, '
               f'{len(expected["templates"])} mail templates and subjects.')
    print(message)
    summary = environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as handle:
            handle.write('### Auth configuration drift: OK\n\n' + message + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
