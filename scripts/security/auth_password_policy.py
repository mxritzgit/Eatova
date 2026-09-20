"""Read-only audit of the managed Auth password-change prerequisites.

Run only in the protected production environment. No response bodies or
credentials are included in diagnostics. Behavioral guarantees and provider
exceptions are tested separately against disposable GoTrue in CI.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request


REQUIRED = {
    'security_update_password_require_current_password': True,
    'security_update_password_require_reauthentication': True,
    'mailer_notifications_password_changed_enabled': True,
}


class PolicyError(Exception):
    """Safe diagnostic that does not contain configuration response values."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate(config):
    if not isinstance(config, dict):
        raise PolicyError('Auth configuration response is not an object')
    mismatches = [key for key, expected in REQUIRED.items()
                  if config.get(key) is not expected]
    if mismatches:
        raise PolicyError('Auth password policy mismatch: ' + ', '.join(mismatches))


def check(environ=None, opener=None):
    environ = os.environ if environ is None else environ
    token = environ.get('SUPABASE_ACCESS_TOKEN', '')
    project = environ.get('SUPABASE_PROJECT_REF', '')
    if not token or '\r' in token or '\n' in token:
        raise PolicyError('Missing or invalid Supabase access credential')
    if not re.fullmatch(r'[a-z]{20}', project):
        raise PolicyError('Missing or invalid Supabase project reference')
    opener = opener or urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{project}/config/auth',
        headers={'Authorization': 'Bearer ' + token,
                 'User-Agent': 'Mozilla/5.0 Eatova-Auth-Policy-Audit'},
        method='GET',
    )
    try:
        with opener.open(request, timeout=30) as response:
            if response.status != 200:
                raise PolicyError('Auth configuration request was not successful')
            body = response.read(1024 * 1024 + 1)
            if len(body) > 1024 * 1024:
                raise PolicyError('Auth configuration response exceeds size limit')
            config = json.loads(body)
    except urllib.error.HTTPError as error:
        raise PolicyError(f'Auth configuration request failed (HTTP {error.code})') from None
    except (urllib.error.URLError, OSError, ValueError, UnicodeError):
        raise PolicyError('Auth configuration could not be read') from None
    validate(config)


def main():
    try:
        check()
    except PolicyError as error:
        print(str(error), file=sys.stderr)
        return 1
    print('Auth password policy matches: current password, reauthentication, change notification')
    return 0


if __name__ == '__main__':
    sys.exit(main())
