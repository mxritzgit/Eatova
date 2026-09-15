"""Read Supabase recovery/budget metadata without exporting account data.

Requires SUPABASE_ACCESS_TOKEN in the process environment and an independently
verified project ref. No notification, configuration, restore or dump operation.
"""

import argparse
import datetime as dt
import json
import os
import re
import ssl
import urllib.error
import urllib.request

UTC = dt.timezone.utc
MAX_RESPONSE_BYTES = 512 * 1024
TIMEOUT_SECONDS = 30
REF_PATTERN = re.compile(r'[a-z0-9]{20}')
BUDGET_QUERY = """
select l.enabled, l.coach_enabled, l.analysis_enabled, l.images_enabled,
       l.daily_call_limit, l.daily_image_limit, l.daily_user_limit,
       (current_timestamp at time zone 'UTC')::date::text as usage_date,
       coalesce(u.calls, 0) as calls, coalesce(u.image_calls, 0) as image_calls
from public.ai_provider_limits as l
left join public.ai_provider_daily_usage as u
  on u.usage_date = (current_timestamp at time zone 'UTC')::date
where l.singleton
limit 2
""".strip()


class CheckError(Exception):
    """An allowlisted diagnostic without server payloads or credentials."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckError('duplicate_json_field')
        result[key] = value
    return result


def valid_ref(value):
    if not isinstance(value, str) or REF_PATTERN.fullmatch(value) is None:
        raise CheckError('invalid_project_reference')
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        raise CheckError('redirect_rejected')


class Management:
    def __init__(self, token):
        if not token or any(c.isspace() for c in token):
            raise CheckError('missing_or_invalid_management_token')
        self.token = token
        # Use the fixed host, normal CA/hostname validation and no proxy/redirect
        # credential forwarding. There is deliberately no custom API URL input.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def read(self, project_ref, operation):
        valid_ref(project_ref)
        endpoints = {
            'project': ('GET', '', None),
            'backups': ('GET', '/database/backups', None),
            'budgets': ('POST', '/database/query/read-only', {'query': BUDGET_QUERY}),
        }
        if operation not in endpoints:
            raise CheckError('unsupported_read_operation')
        method, suffix, payload = endpoints[operation]
        url = 'https://api.supabase.com/v1/projects/' + project_ref + suffix
        request = urllib.request.Request(
            url, method=method,
            data=json.dumps(payload).encode() if payload else None,
            headers={'Authorization': 'Bearer ' + self.token,
                     'Content-Type': 'application/json', 'Accept': 'application/json',
                     'Accept-Encoding': 'identity'})
        try:
            with self.opener.open(request, timeout=TIMEOUT_SECONDS) as response:
                if response.status not in (200, 201):
                    raise CheckError('unexpected_http_status')
                if response.headers.get('Content-Encoding', 'identity') != 'identity':
                    raise CheckError('unexpected_response_encoding')
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise CheckError('response_too_large')
                return json.loads(raw, object_pairs_hook=unique_object)
        except CheckError:
            raise
        except urllib.error.HTTPError as error:
            # Never read/print the error body or exception string.
            error.close()
            raise CheckError('http_' + str(error.code)) from None
        except (OSError, ValueError, RecursionError):
            raise CheckError('transport_or_json_failure') from None


def integer(value, maximum=2_147_483_647):
    return type(value) is int and 0 <= value <= maximum


def timestamp(value):
    if not isinstance(value, str):
        raise CheckError('invalid_backup_timestamp')
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise CheckError('invalid_backup_timestamp') from None
    if parsed.tzinfo is None:
        raise CheckError('invalid_backup_timestamp')
    return parsed.astimezone(UTC)


def project_identity(payload, expected):
    if not isinstance(payload, dict):
        raise CheckError('invalid_project_response')
    identities = [payload[k] for k in ('id', 'ref') if k in payload]
    if not identities or any(value != expected for value in identities):
        raise CheckError('project_identity_mismatch')
    if not isinstance(payload.get('status'), str):
        raise CheckError('invalid_project_response')
    healthy = payload.get('status') == 'ACTIVE_HEALTHY'
    return {'state': 'ok' if healthy else 'attention', 'identity_verified': True,
            'active_healthy': healthy}


def backups(payload, now, max_age_hours):
    if not isinstance(payload, dict) or not isinstance(payload.get('backups'), list):
        raise CheckError('invalid_backup_response')
    if type(payload.get('pitr_enabled')) is not bool:
        raise CheckError('invalid_backup_response')
    points = []
    completed = 0
    failed = 0
    for item in payload['backups']:
        if not isinstance(item, dict) or item.get('status') not in (
                'COMPLETED', 'FAILED', 'PENDING', 'REMOVED', 'ARCHIVED', 'CANCELLED'):
            raise CheckError('invalid_backup_record')
        if item['status'] == 'COMPLETED':
            point = timestamp(item.get('inserted_at'))
            if point > now:
                raise CheckError('future_backup_timestamp')
            points.append(point)
            completed += 1
        elif item['status'] == 'FAILED':
            failed += 1
    physical = payload.get('physical_backup_data')
    physical_valid = False
    if physical is not None:
        if not isinstance(physical, dict):
            raise CheckError('invalid_physical_backup_window')
        first = physical.get('earliest_physical_backup_date_unix')
        last = physical.get('latest_physical_backup_date_unix')
        if first is not None or last is not None:
            if (not integer(first, 253402300799) or not integer(last, 253402300799)
                    or first <= 0 or first > last):
                raise CheckError('invalid_physical_backup_window')
            point = dt.datetime.fromtimestamp(last, UTC)
            if point > now:
                raise CheckError('future_backup_timestamp')
            physical_valid = True
            if payload['pitr_enabled']:
                points.append(point)
    latest = max(points) if points else None
    age = (now - latest).total_seconds() / 3600 if latest else None
    state = 'ok' if age is not None and age <= max_age_hours and failed == 0 else 'attention'
    # Daily physical backups count through their COMPLETED records even without
    # PITR. An unlisted physical window alone does not establish restore access.
    ambiguous_window = physical_valid and not payload['pitr_enabled'] and not points
    if ambiguous_window:
        state = 'unknown'
    return {'state': state, 'completed_backup_count': completed,
            'failed_backup_count': failed, 'pitr_enabled': payload['pitr_enabled'],
            'physical_window_present': physical_valid,
            'physical_window_access_unverified': ambiguous_window,
            'latest_recovery_point_utc': latest.isoformat() if latest else None,
            'age_hours': round(age, 3) if age is not None else None,
            'max_age_hours': max_age_hours, 'restore_verified': False}


def budgets(payload, now, warning_percent):
    if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
        raise CheckError('missing_or_invalid_budget_configuration')
    item = payload[0]
    switches = ('enabled', 'coach_enabled', 'analysis_enabled', 'images_enabled')
    if any(type(item.get(key)) is not bool for key in switches):
        raise CheckError('invalid_budget_configuration')
    limits = {'daily_call_limit': 100000, 'daily_image_limit': 10000,
              'daily_user_limit': 10000, 'calls': 2_147_483_647,
              'image_calls': 2_147_483_647}
    if any(not integer(item.get(key), maximum) for key, maximum in limits.items()):
        raise CheckError('invalid_budget_counter')
    if item['image_calls'] > item['calls']:
        raise CheckError('invalid_budget_counter')
    # Refuse a UTC-day rollover between observing the check time and the query.
    # A new invocation can safely retry; yesterday's zero is never a green today.
    if item.get('usage_date') != now.astimezone(UTC).date().isoformat():
        raise CheckError('budget_utc_day_mismatch')
    reasons = []
    if not all(item[key] for key in switches):
        reasons.append('stop_switch_active')
    if item['daily_user_limit'] == 0:
        reasons.append('account_call_limit_zero')
    for counter, limit, name in [('calls', 'daily_call_limit', 'calls'),
                                 ('image_calls', 'daily_image_limit', 'images')]:
        if item[counter] >= item[limit]:
            reasons.append(name + '_exhausted')
        elif item[counter] * 100 >= item[limit] * warning_percent:
            reasons.append(name + '_warning')
    return {'state': 'attention' if reasons else 'ok', 'reasons': reasons,
            **{key: item[key] for key in (*switches, *limits, 'usage_date')},
            'warning_percent': warning_percent, 'monetary_limit_verified': False}


def check(api, expected, now, max_age_hours, warning_percent, staging=None):
    valid_ref(expected)
    if staging is not None:
        valid_ref(staging)
        if staging == expected:
            raise CheckError('staging_matches_production')
    if now.tzinfo is None or not integer(max_age_hours, 8760) or max_age_hours == 0:
        raise CheckError('invalid_check_parameters')
    if not integer(warning_percent, 99) or warning_percent == 0:
        raise CheckError('invalid_check_parameters')
    report = {'checked_at_utc': now.astimezone(UTC).isoformat(), 'read_only': True,
              'notification_sent': False, 'checks': {}}
    results = report['checks']
    # Stop all subsequent reads if project identity cannot be established.
    results['project'] = project_identity(api.read(expected, 'project'), expected)
    for name, evaluate in [
            ('backups', lambda value: backups(value, now, max_age_hours)),
            ('budgets', lambda value: budgets(value, now, warning_percent))]:
        try:
            results[name] = evaluate(api.read(expected, name))
        except CheckError as error:
            results[name] = {'state': 'unknown', 'reason': str(error)}
    if staging:
        try:
            results['staging'] = project_identity(api.read(staging, 'project'), staging)
            results['staging']['distinct_project_verified'] = True
            results['staging']['credential_and_data_isolation_verified'] = False
        except CheckError as error:
            results['staging'] = {'state': 'unknown', 'reason': str(error)}
    else:
        report['staging'] = 'not_checked_no_project_supplied'
    states = [value['state'] for value in results.values()]
    code = 2 if 'unknown' in states else 1 if 'attention' in states else 0
    report['exit_code'] = code
    return report, code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-project-ref', required=True)
    parser.add_argument('--staging-project-ref')
    parser.add_argument('--backup-max-age-hours', type=int, required=True)
    parser.add_argument('--budget-warning-percent', type=int, default=80)
    args = parser.parse_args(argv)
    try:
        # Validate identities before creating a client or accessing credentials.
        valid_ref(args.expected_project_ref)
        if args.staging_project_ref:
            valid_ref(args.staging_project_ref)
            if args.staging_project_ref == args.expected_project_ref:
                raise CheckError('staging_matches_production')
        api = Management(os.environ.get('SUPABASE_ACCESS_TOKEN', ''))
        report, code = check(api, args.expected_project_ref, dt.datetime.now(UTC),
                             args.backup_max_age_hours, args.budget_warning_percent,
                             args.staging_project_ref)
    except CheckError as error:
        report, code = {'state': 'unknown', 'reason': str(error), 'exit_code': 2}, 2
    except Exception:
        # Unexpected library errors must not leak exception text with credentials.
        report, code = {'state': 'unknown', 'reason': 'check_failed', 'exit_code': 2}, 2
    print(json.dumps(report, sort_keys=True, indent=2))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
