"""Real local GoTrue lifecycle checks; never accepts production endpoints.

The caller owns disposable GoTrue/Postgres and passes its loopback-only request
and SQL functions. Admin-generated codes replace delivery; no mailbox is used.
Only check names/statuses leave this module, never credentials or responses.
"""
import base64
import json
import math
import secrets
import time
import uuid

REFRESH_REUSE_SECONDS = 10


class LifecycleFailure(RuntimeError):
    """Only a fixed check name and numeric status may enter the message."""


class LifecycleProbe:
    def __init__(self, request, admin_token, sql):
        self.request = request
        self.admin_token = admin_token
        self.sql = sql
        self.checks = []
        self.denied_tokens = {}

    def require(self, name, condition, status=None):
        if not condition:
            raise LifecycleFailure(f'{name} failed (status={status})')
        self.checks.append({'name': name, 'status': status, 'passed': True})

    def call(self, name, path, data=None, token=None, method=None,
             status=200, error_code=None):
        actual, body = self.request(path, data, token, method)
        matches = actual == status
        if error_code is not None:
            matches = matches and body.get('error_code') == error_code
        self.require(name, matches, actual)
        return body

    def admin(self, name, path, data=None, method=None):
        return self.call(name, path, data, self.admin_token, method)

    def actor(self, label):
        email = f'synthetic-{label}-{secrets.token_hex(3)}@example.test'
        password = secrets.token_urlsafe(24)
        user = self.admin(f'{label}_create', '/admin/users', {
            'email': email, 'password': password, 'email_confirm': True,
        })
        session = self.login(label, email, password)
        return {'id': user['id'], 'email': email, 'password': password,
                'session': session}

    def login(self, label, email, password):
        return self.call(f'{label}_password_login', '/token?grant_type=password',
                         {'email': email, 'password': password})

    def refresh(self, name, session, status=200, error_code=None):
        return self.call(name, '/token?grant_type=refresh_token',
                         {'refresh_token': session['refresh_token']},
                         status=status, error_code=error_code)

    def code(self, label, kind, email, **fields):
        response = self.admin(f'{label}_code_generated', '/admin/generate_link',
                              {'type': kind, 'email': email, **fields})
        code = response['email_otp']
        self.require(f'{label}_eight_digit_code',
                     len(code) == 8 and code.isascii() and code.isdigit())
        return code

    def verify(self, label, kind, email, code, **expected):
        return self.call(label, '/verify', {
            'type': kind, 'email': email, 'token': code,
        }, **expected)

    def wait_refresh_grace(self, label, actor_id, *, timeout=45):
        """Observe expiry on the server clock, without changing token rows.

        Host sleep is not proof that a Docker VM's database clock advanced.
        This barrier only reads synthetic timestamps; each later HTTP denial
        assertion still executes exactly once.
        """
        user_id = str(uuid.UUID(actor_id))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            raw = self.sql(
                "SELECT json_build_object('count', count(*), "
                "'revoked_count', count(*) FILTER (WHERE revoked), "
                "'min_age_seconds', min(extract(epoch FROM "
                "clock_timestamp() - updated_at))) "
                "FROM auth.refresh_tokens "
                f"WHERE user_id = '{user_id}';")
            try:
                state = json.loads(raw)
                count = state['count']
                revoked = state['revoked_count']
                age = state['min_age_seconds']
                valid = (type(count) is int and count > 0 and
                         type(revoked) is int and 0 <= revoked <= count and
                         type(age) in (int, float) and math.isfinite(age))
            except (ValueError, TypeError, KeyError):
                valid = False
            self.require(f'{label}_valid_server_state', valid)
            if age > REFRESH_REUSE_SECONDS + 1:
                self.checks.append({'name': label, 'passed': True,
                                    'minimum_server_age_seconds': age,
                                    'token_count': count, 'revoked_count': revoked})
                return
            time.sleep(.25)
        raise LifecycleFailure(f'{label} server-clock deadline exceeded')

    def refresh_replay(self):
        actor = self.actor('rotation')
        original = actor['session']
        first = self.refresh('refresh_rotates', original)
        self.require('refresh_token_changed',
                     first['refresh_token'] != original['refresh_token'])
        retry = self.refresh('immediate_parent_retry_allowed', original)
        self.require('parent_retry_returns_active_token',
                     retry['refresh_token'] == first['refresh_token'])
        latest = self.refresh('second_refresh_rotates', first)
        self.require('second_refresh_token_changed',
                     latest['refresh_token'] != first['refresh_token'])
        # Read the server's real clock; do not backdate tokens or retry denials.
        self.wait_refresh_grace('ancestor_reuse_grace_expired', actor['id'])
        self.refresh('old_ancestor_replay_denied', original, status=400,
                     error_code='refresh_token_already_used')
        # Revoking the family updates its timestamps; GoTrue applies the reuse
        # window to those tokens too. Assert denial after that grace interval.
        self.wait_refresh_grace('family_revocation_grace_expired', actor['id'])
        self.refresh('replay_revokes_active_family', latest, status=400,
                     error_code='refresh_token_already_used')
        return self.checks

    def run(self):
        self.refresh_replay()

        actor = self.actor('logout')
        first = actor['session']
        second = self.login('parallel', actor['email'], actor['password'])
        other = self.actor('other_account')
        self.call('local_logout', '/logout?scope=local', {},
                  first['access_token'], status=204)
        self.refresh('local_logout_refresh_denied', first, status=400,
                     error_code='refresh_token_not_found')
        self.call('local_logout_user_endpoint_denied', '/user',
                  token=first['access_token'], status=403,
                  error_code='session_not_found')
        self.denied_tokens['logged_out_session'] = first['access_token']
        second = self.refresh('local_logout_preserves_parallel_session', second)
        self.call('global_logout', '/logout?scope=global', {},
                  second['access_token'], status=204)
        self.refresh('global_logout_refresh_denied', second, status=400,
                     error_code='refresh_token_not_found')
        self.refresh('logout_preserves_other_account', other['session'])

        actor = self.actor('ban')
        self.admin('admin_bans_synthetic_user', f"/admin/users/{actor['id']}",
                   {'ban_duration': '1h'}, 'PUT')
        self.call('ban_denies_existing_access_token', '/user',
                  token=actor['session']['access_token'], status=403,
                  error_code='user_banned')
        self.call('ban_denies_password_login', '/token?grant_type=password', {
            'email': actor['email'], 'password': actor['password'],
        }, status=400, error_code='user_banned')
        self.refresh('ban_denies_refresh', actor['session'], status=400,
                     error_code='user_banned')
        self.denied_tokens['banned_user'] = actor['session']['access_token']
        actor = self.actor('deleted')
        active = actor['session']
        self.admin('admin_deletes_synthetic_user', f"/admin/users/{actor['id']}",
                   {}, 'DELETE')
        self.call('deleted_user_denies_access', '/user',
                  token=active['access_token'], status=403,
                  error_code='user_not_found')
        self.refresh('deleted_user_denies_refresh', active, status=400,
                     error_code='refresh_token_not_found')
        self.denied_tokens['deleted_user'] = active['access_token']

        email = f'synthetic-signup-{secrets.token_hex(3)}@example.test'
        password = secrets.token_urlsafe(6)  # Exactly eight ASCII characters.
        self.call('seven_character_password_denied', '/signup', {
            'email': email, 'password': 'short12',
        }, status=422, error_code='weak_password')
        signup = self.call('signup_requires_confirmation', '/signup', {
            'email': email, 'password': password,
        })
        self.require('unconfirmed_signup_has_no_session',
                     'access_token' not in signup and
                     not signup.get('email_confirmed_at'))
        self.call('unconfirmed_password_login_denied', '/token?grant_type=password',
                  {'email': email, 'password': password}, status=400,
                  error_code='email_not_confirmed')
        code = self.code('signup', 'signup', email)
        self.verify('signup_wrong_code_denied', 'signup', email,
                    '0' * 8 if code != '0' * 8 else '1' * 8,
                    status=403, error_code='otp_expired')
        verified = self.verify('signup_code_confirms_account', 'signup', email, code)
        self.require('signup_establishes_expected_identity',
                     verified['user']['id'] == signup['id'])
        self.verify('signup_code_replay_denied', 'signup', email, code,
                    status=403, error_code='otp_expired')
        self.login('confirmed', email, password)
        duplicate = self.call('confirmed_duplicate_signup_is_neutral', '/signup', {
            'email': email, 'password': password,
        })
        self.require('duplicate_signup_has_no_session_and_empty_identities',
                     'access_token' not in duplicate and
                     duplicate.get('identities') == [])

        recovery = self.actor('recovery')
        self.call('existing_recovery_request_neutral', '/recover',
                  {'email': recovery['email']})
        self.call('absent_recovery_request_neutral', '/recover',
                  {'email': 'synthetic-absent@example.test'})
        code = self.code('recovery', 'recovery', recovery['email'])
        self.verify('recovery_code_is_account_bound', 'recovery', email, code,
                    status=403, error_code='otp_expired')
        session = self.verify('recovery_code_establishes_session', 'recovery',
                              recovery['email'], code)
        self.require('recovery_returns_expected_identity',
                     session['user']['id'] == recovery['id'])
        self.verify('recovery_code_replay_denied', 'recovery', recovery['email'],
                    code, status=403, error_code='otp_expired')
        new_password = secrets.token_urlsafe(24)
        self.call('recovery_can_set_new_password', '/user',
                  {'password': new_password}, session['access_token'], 'PUT')
        self.call('recovered_account_old_password_denied',
                  '/token?grant_type=password', {
                      'email': recovery['email'], 'password': recovery['password'],
                  }, status=400, error_code='invalid_credentials')
        self.login('recovered_account', recovery['email'], new_password)
        self.refresh('password_recovery_revokes_old_sessions',
                     recovery['session'], status=400,
                     error_code='refresh_token_not_found')

        code = self.code('expired_recovery', 'recovery', recovery['email'])
        actor_id = str(uuid.UUID(recovery['id']))
        self.sql("UPDATE auth.users SET recovery_sent_at = now() - interval '11 minutes' "
                 f"WHERE id = '{actor_id}'::uuid;")
        self.verify('expired_recovery_code_denied', 'recovery', recovery['email'],
                    code, status=403, error_code='otp_expired')

        # Capture the provider's existing policy, not an invented strict nonce
        # policy: a fresh session may update its password without a valid nonce.
        actor = self.actor('password_reauth')
        self.call('fresh_session_nonce_exception_observed', '/user', {
            'password': secrets.token_urlsafe(24), 'nonce': 'invalid',
        }, actor['session']['access_token'], 'PUT')
        raw = actor['session']['access_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
        session_id = str(uuid.UUID(claims['session_id']))
        self.sql("UPDATE auth.sessions SET created_at = now() - interval '25 hours' "
                 f"WHERE id = '{session_id}'::uuid;")
        self.call('old_session_password_change_requires_reauth', '/user', {
            'password': secrets.token_urlsafe(24),
        }, actor['session']['access_token'], 'PUT', status=400,
                  error_code='reauthentication_needed')

        actor = self.actor('email_change')
        new_email = f'synthetic-new-{secrets.token_hex(3)}@example.test'
        self.call('email_change_requested', '/user', {'email': new_email},
                  actor['session']['access_token'], 'PUT')
        old_code = self.code('email_old', 'email_change_current', actor['email'],
                             new_email=new_email)
        new_code = self.code('email_new', 'email_change_new', actor['email'],
                             new_email=new_email)
        partial = self.verify('one_email_code_is_insufficient', 'email_change',
                              actor['email'], old_code)
        self.require('first_email_code_does_not_create_session',
                     'access_token' not in partial)
        still_old = self.call('first_email_code_keeps_old_address', '/user',
                              token=actor['session']['access_token'])
        self.require('old_address_preserved_until_both_codes',
                     still_old['email'] == actor['email'])
        self.verify('first_email_code_cannot_be_replayed', 'email_change',
                    actor['email'], old_code, status=403,
                    error_code='otp_expired')
        changed = self.verify('second_email_code_completes_change', 'email_change',
                              new_email, new_code)
        self.require('email_change_keeps_identity_and_changes_address',
                     changed['user']['id'] == actor['id'] and
                     changed['user']['email'] == new_email)
        self.call('old_email_login_denied', '/token?grant_type=password', {
            'email': actor['email'], 'password': actor['password'],
        }, status=400, error_code='invalid_credentials')
        self.login('new_email', new_email, actor['password'])

        # Last: a real IP limiter would also block subsequent legitimate OTPs.
        for _ in range(65):
            status, body = self.request('/verify', {
                'type': 'recovery', 'email': 'synthetic-absent@example.test',
                'token': '00000000',
            })
            if status == 429:
                self.require('direct_verify_requests_are_rate_limited',
                             body.get('error_code') == 'over_request_rate_limit',
                             status)
                break
            self.require('bad_otp_has_no_session_before_rate_limit',
                         status == 403 and 'access_token' not in body, status)
        else:
            raise LifecycleFailure('direct_verify_requests_are_rate_limited failed')
        return self.checks
