"""Assert Eatova's accepted GoTrue password policy against real local SMTP.

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
    def __init__(self, request, admin_token, sql, mailbox):
        super().__init__(request, admin_token, sql)
        self.mailbox = mailbox

    def old_actor(self, label):
        actor = self.actor(label)
        raw = actor['session']['access_token'].split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
        session_id = str(uuid.UUID(claims['session_id']))
        self.sql("UPDATE auth.sessions SET created_at = now() - interval '25 hours' "
                 f"WHERE id = '{session_id}'::uuid;")
        return actor

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

    def update(self, label, actor, password, *, nonce=None, status=200,
               error_code=None):
        data = {'password': password}
        if nonce is not None:
            data['nonce'] = nonce
        result = self.call(label, '/user', data, actor['session']['access_token'],
                           'PUT', status=status, error_code=error_code)
        if status == 200:
            self.require(f'{label}_identity_preserved', result['id'] == actor['id'])

    def rejected(self, label, actor, *, nonce=None, error_code='reauthentication_not_valid'):
        attempted = secrets.token_urlsafe(24)
        self.update(label, actor, attempted, nonce=nonce,
                    status=400 if nonce is None else 422, error_code=error_code)
        self.call(f'{label}_new_password_not_stored', '/token?grant_type=password',
                  {'email': actor['email'], 'password': attempted},
                  status=400, error_code='invalid_credentials')
        self.login(f'{label}_existing_password_preserved', actor['email'], actor['password'])

    def run(self):
        # Intentionally accepted: recent-session proof is not a server boundary.
        recent = self.actor('recent_session')
        for name, nonce in (('missing', None), ('invalid', 'invalid')):
            password = secrets.token_urlsafe(24)
            self.update(f'recent_session_{name}_nonce_accepted', recent, password,
                        nonce=nonce)
            self.login(f'recent_session_{name}_nonce_effect', recent['email'], password)

        old = self.old_actor('old_session')
        self.rejected('old_session_missing_nonce_denied', old,
                      error_code='reauthentication_needed')
        code = self.mail_code('old_session', old)
        wrong = ('1' if code[0] != '1' else '2') + code[1:]
        self.rejected('old_session_invalid_nonce_denied', old, nonce=wrong)

        foreign = self.old_actor('foreign_account')
        self.rejected('mail_proof_cannot_cross_accounts', foreign, nonce=code)

        password = secrets.token_urlsafe(24)
        self.update('old_session_fresh_mail_proof_accepted', old, password, nonce=code)
        self.call('old_session_previous_password_revoked', '/token?grant_type=password',
                  {'email': old['email'], 'password': old['password']},
                  status=400, error_code='invalid_credentials')
        old['password'] = password
        self.login('old_session_fresh_mail_proof_effect', old['email'], password)
        self.rejected('old_session_replayed_proof_denied', old, nonce=code)

        expired = self.old_actor('expired_proof')
        code = self.mail_code('expired_proof', expired)
        user_id = str(uuid.UUID(expired['id']))
        self.sql("UPDATE auth.users SET reauthentication_sent_at = now() - interval '11 minutes' "
                 f"WHERE id = '{user_id}'::uuid;")
        self.rejected('old_session_expired_proof_denied', expired, nonce=code)
        return self.checks
