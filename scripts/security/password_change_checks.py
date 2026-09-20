"""Assert native GoTrue password gates and their exceptions with local SMTP.

The caller provides disposable internal-network clients and SQL only. Responses,
passwords and captured mailbox proofs remain in memory; evidence has check names.
"""
import base64
import json
import re
import secrets
import time
import uuid

from auth_lifecycle_checks import LifecycleProbe


class PasswordChangeProbe(LifecycleProbe):
    def __init__(self, request, admin_token, sql, mailbox, *,
                 require_current_password=True):
        super().__init__(request, admin_token, sql)
        self.mailbox = mailbox
        self.require_current_password = require_current_password

    def old_actor(self, label):
        actor = self.actor(label)
        self.age_session(actor)
        return actor

    def age_session(self, actor):
        raw = actor['session']['access_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
        session_id = str(uuid.UUID(claims['session_id']))
        self.sql("UPDATE auth.sessions SET created_at = now() - interval '25 hours' "
                 f"WHERE id = '{session_id}'::uuid;")

    def mail_code(self, label, actor):
        _, before = self.mailbox('/messages')
        self.call(f'{label}_reauthentication_requested', '/reauthenticate',
                  token=actor['session']['access_token'], method='GET')
        for _ in range(60):
            _, messages = self.mailbox('/messages')
            if len(messages) > len(before):
                break
            time.sleep(.1)
        self.require(f'{label}_exactly_one_mail', len(messages) == len(before) + 1)
        message = messages[-1]
        self.require(f'{label}_mail_bound_to_account', actor['email'] in message['to'])
        self.require(f'{label}_reauthentication_subject',
                     message['subject'] == 'Dein Eatova-Code: Passwort ändern')
        codes = re.findall(r'(?<!\d)\d{8}(?!\d)', message['html'])
        self.require(f'{label}_one_eight_digit_mail_code', len(codes) == 1)
        return codes[0]

    def update(self, label, actor, password, *, nonce=None, current_password=None,
               status=200, error_code=None):
        data = {'password': password}
        if nonce is not None:
            data['nonce'] = nonce
        if current_password is not None:
            data['current_password'] = current_password
        result = self.call(label, '/user', data, actor['session']['access_token'],
                           'PUT', status=status, error_code=error_code)
        if status == 200:
            self.require(f'{label}_identity_preserved', result['id'] == actor['id'])

    def rejected(self, label, actor, *, nonce=None, current_password=None,
                 status=None, error_code='reauthentication_not_valid'):
        attempted = secrets.token_urlsafe(24)
        self.update(label, actor, attempted, nonce=nonce, current_password=current_password,
                    status=status if status is not None else (400 if nonce is None else 422),
                    error_code=error_code)
        self.call(f'{label}_new_password_not_stored', '/token?grant_type=password',
                  {'email': actor['email'], 'password': attempted},
                  status=400, error_code='invalid_credentials')
        self.login(f'{label}_existing_password_preserved', actor['email'], actor['password'])

    def accepted(self, label, actor, *, nonce=None, current_password=None):
        password = secrets.token_urlsafe(24)
        self.update(label, actor, password, nonce=nonce, current_password=current_password)
        self.call(f'{label}_previous_password_revoked', '/token?grant_type=password',
                  {'email': actor['email'], 'password': actor['password']},
                  status=400, error_code='invalid_credentials')
        actor['password'] = password
        self.login(f'{label}_new_password_works', actor['email'], password)

    def revoke_otp_session(self, label, actor):
        normal = self.login(f'{label}_separate_normal_session',
                            actor['email'], actor['password'])
        self.call(f'{label}_local_logout', '/logout?scope=local', {},
                  actor['session']['access_token'], status=204)
        self.rejected(f'{label}_logged_out_password_update_denied', actor,
                      status=403, error_code='session_not_found')
        self.refresh(f'{label}_logged_out_refresh_denied', actor['session'],
                     status=400, error_code='refresh_token_not_found')
        self.refresh(f'{label}_local_logout_preserves_normal_session', normal)

    def recent_session_checks(self):
        recent = self.actor('recent_session')
        if self.require_current_password:
            self.rejected('recent_session_missing_current_password_denied', recent,
                          error_code='current_password_required')
            self.rejected('recent_session_wrong_current_password_denied', recent,
                          current_password='not-the-current-password',
                          error_code='current_password_invalid')
            code = self.mail_code('recent_session', recent)
            self.rejected('recent_session_mail_proof_alone_insufficient', recent,
                          nonce=code, status=400, error_code='current_password_required')
        else:
            # Explicit baseline for the previously deployed configuration.
            for name, nonce in (('missing', None), ('invalid', 'invalid')):
                self.accepted(f'legacy_recent_session_{name}_nonce_accepted', recent,
                              nonce=nonce)
        # Native current-password enforcement does not remove the nonce exception.
        self.accepted('recent_session_correct_current_without_nonce', recent,
                      current_password=recent['password'])

    def old_session_checks(self):
        old = self.old_actor('old_session')
        # Correct current password isolates the independent nonce requirement.
        self.rejected('old_session_missing_nonce_denied', old,
                      current_password=old['password'],
                      error_code='reauthentication_needed')
        self.rejected('old_session_without_either_proof_denied', old,
                      error_code='reauthentication_needed')
        if self.require_current_password:
            for name, supplied, error_code in (
                    ('missing', None, 'current_password_required'),
                    ('wrong', 'not-the-current-password', 'current_password_invalid')):
                code = self.mail_code(f'old_{name}_current', old)
                self.rejected(f'old_session_{name}_current_password_denied', old,
                              nonce=code, current_password=supplied,
                              status=400, error_code=error_code)
                # GoTrue consumes a valid nonce before checking current_password.
                self.rejected(f'old_nonce_consumed_before_{name}_current_failure', old,
                              nonce=code, current_password=old['password'])
        code = self.mail_code('old_session', old)
        wrong = ('1' if code[0] != '1' else '2') + code[1:]
        self.rejected('old_session_invalid_nonce_denied', old, nonce=wrong,
                      current_password=old['password'])

        foreign = self.old_actor('foreign_account')
        self.rejected('mail_proof_cannot_cross_accounts', foreign, nonce=code,
                      current_password=foreign['password'])

        self.accepted('old_session_correct_current_and_fresh_nonce', old,
                      nonce=code, current_password=old['password'])
        self.rejected('old_session_replayed_proof_denied', old, nonce=code,
                      current_password=old['password'])

        expired = self.old_actor('expired_proof')
        code = self.mail_code('expired_proof', expired)
        user_id = str(uuid.UUID(expired['id']))
        self.sql("UPDATE auth.users SET reauthentication_sent_at = now() - interval '11 minutes' "
                 f"WHERE id = '{user_id}'::uuid;")
        self.rejected('old_session_expired_proof_denied', expired, nonce=code,
                      current_password=expired['password'])

    def recovery_session(self, actor):
        _, before = self.mailbox('/messages')
        self.call('recovery_mail_requested', '/recover', {'email': actor['email']})
        for _ in range(60):
            _, messages = self.mailbox('/messages')
            if len(messages) > len(before):
                break
            time.sleep(.1)
        self.require('recovery_exactly_one_mail', len(messages) == len(before) + 1)
        self.require('recovery_mail_bound_to_account', actor['email'] in messages[-1]['to'])
        codes = re.findall(r'(?<!\d)\d{8}(?!\d)', messages[-1]['html'])
        self.require('recovery_one_eight_digit_mail_code', len(codes) == 1)
        actor['session'] = self.verify('real_mail_recovery_verified', 'recovery',
                                       actor['email'], codes[0])
        self.require('recovery_same_identity', actor['session']['user']['id'] == actor['id'])
        self.verify('recovery_mail_code_replay_denied', 'recovery',
                    actor['email'], codes[0], status=403, error_code='otp_expired')

    def otp_exception_checks(self):
        # The provider preserves the initiating OTP session after a password change.
        # These successful attacks are limitations, never universal-proof guarantees.
        recovery = self.actor('recovery_session')
        original = recovery['session']
        self.recovery_session(recovery)
        self.accepted('recovery_session_first_change_without_current', recovery)
        self.refresh('recovery_revokes_previous_password_session', original,
                     status=400, error_code='refresh_token_not_found')
        self.accepted('recovery_session_repeated_change_without_new_proof', recovery)
        recovery['session'] = self.refresh('recovery_session_still_refreshes', recovery['session'])
        self.accepted('refreshed_recovery_changes_without_new_proof', recovery)
        self.age_session(recovery)
        self.rejected('old_recovery_still_requires_nonce', recovery,
                      error_code='reauthentication_needed')
        self.accepted('old_recovery_fresh_nonce_without_current', recovery,
                      nonce=self.mail_code('old_recovery', recovery))
        self.revoke_otp_session('recovery_otp', recovery)

        email = f'synthetic-signup-{secrets.token_hex(3)}@example.test'
        password = secrets.token_urlsafe(24)
        self.call('signup_for_password_policy', '/signup', {'email': email, 'password': password})
        code = self.code('signup_password_policy', 'signup', email)
        session = self.verify('signup_proof_verified', 'signup', email, code)
        signup = {'id': session['user']['id'], 'email': email,
                  'password': password, 'session': session}
        self.accepted('signup_otp_session_first_change_without_current', signup)
        self.accepted('signup_otp_session_repeated_change_without_new_proof', signup)
        self.revoke_otp_session('signup_otp', signup)

        email_change = self.actor('email_change_otp')
        new_email = f'synthetic-changed-{secrets.token_hex(3)}@example.test'
        self.call('email_change_for_password_policy', '/user', {'email': new_email},
                  email_change['session']['access_token'], 'PUT')
        old_code = self.code('email_change_old', 'email_change_current',
                             email_change['email'], new_email=new_email)
        new_code = self.code('email_change_new', 'email_change_new',
                             email_change['email'], new_email=new_email)
        self.verify('email_change_old_proof_verified', 'email_change',
                    email_change['email'], old_code)
        email_change['session'] = self.verify('email_change_new_proof_verified',
                                              'email_change', new_email, new_code)
        self.require('email_change_same_identity',
                     email_change['session']['user']['id'] == email_change['id'])
        email_change['email'] = new_email
        self.accepted('email_change_otp_session_without_current', email_change)
        self.accepted('email_change_otp_repeated_change_without_new_proof', email_change)
        self.revoke_otp_session('email_change_otp', email_change)

    def oauth_first_password_checks(self):
        # Fixture only: simulate OAuth/no-password state; no external IdP is used.
        actor = self.actor('simulated_oauth')
        user_id = str(uuid.UUID(actor['id']))
        raw = actor['session']['access_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
        session_id = str(uuid.UUID(claims['session_id']))
        self.sql(f"UPDATE auth.users SET encrypted_password=NULL WHERE id='{user_id}'::uuid; "
                 "UPDATE auth.mfa_amr_claims SET authentication_method='oauth' "
                 f"WHERE session_id='{session_id}'::uuid;")
        actor['session'] = self.refresh('simulated_oauth_session_refreshed', actor['session'])
        raw = actor['session']['access_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
        self.require('simulated_oauth_claim_has_no_otp',
                     {claim['method'] for claim in claims['amr']} == {'oauth'})
        self.accepted('oauth_first_password_without_additional_proof', actor)
        if self.require_current_password:
            self.rejected('oauth_existing_password_requires_current', actor,
                          error_code='current_password_required')
        else:
            self.accepted('legacy_oauth_existing_password_without_current', actor)

    def run(self):
        self.recent_session_checks()
        self.old_session_checks()
        self.otp_exception_checks()
        self.oauth_first_password_checks()
        return self.checks
