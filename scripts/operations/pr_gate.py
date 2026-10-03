"""Waits for a pull request's CI and squash-merges it (GitHub REST API).

  pr_gate.py wait  <pr> [--timeout-min 60] [--interval 30]
  pr_gate.py merge <pr> --head <reviewed head sha>

Both read GITHUB_TOKEN from the process environment (the named credential,
docs/DEVELOPMENT.md) and never print it. Authenticated, the API allows 5000
requests an hour; anonymous polling shares 60 per address and runs dry.

`wait` exits 0 when every check on the PR head is green, 1 on the first red
check or a refusal, 2 on timeout. `merge` re-checks the same verdict for the
reviewed head and squash-merges; it never waits. A merge still needs the
owner's approval (protected-main workflow).

A check counts as finished by its conclusion, not by its status. On
2026-10-03 GitHub kept a job that had finished in 8 s (conclusion success,
completed_at set, every step done) at status in_progress for good, and a
wait on the status never returned (PR #127). Such a run counts and is named
as a status lag.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = 'https://api.github.com/'
DEFAULT_REPO = 'mxritzgit/Eatova'
TIMEOUT_SECONDS = 30
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MIN_INTERVAL_SECONDS = 5
# Conclusions branch protection accepts for a required check.
PASSING = frozenset({'success', 'skipped', 'neutral'})
MERGEABLE = frozenset({'clean', 'has_hooks'})


class ApiError(Exception):
    """A refusal that waiting does not fix (bad token, unknown PR, 422)."""


class Transient(Exception):
    """Network trouble or a 5xx: the next poll may succeed."""


class RateLimited(Exception):
    def __init__(self, reset_epoch):
        super().__init__('rate limited')
        self.reset_epoch = reset_epoch


class GitHub:
    def __init__(self, token, opener=urllib.request.urlopen, wall=time.time):
        self._headers = {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'Bearer ' + token,
            'User-Agent': 'eatova-pr-gate',
            'X-GitHub-Api-Version': '2022-11-28',
        }
        self._open = opener
        self._wall = wall

    def get(self, path):
        return self._request('GET', path)

    def put(self, path, payload):
        return self._request('PUT', path, payload)

    def _request(self, method, path, payload=None):
        headers = dict(self._headers)
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(
            API + path, data=data, method=method, headers=headers)
        try:
            with self._open(request, timeout=TIMEOUT_SECONDS) as response:
                body = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise self._classify(method, path, error) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            raise Transient(f'{method} {path}: {type(error).__name__}') from None
        if len(body) > MAX_RESPONSE_BYTES:
            raise ApiError(f'{method} {path}: response too large')
        return json.loads(body)

    def _classify(self, method, path, error):
        headers = error.headers or {}
        retry_after = headers.get('retry-after')
        if error.code in (403, 429) and (
                retry_after or headers.get('x-ratelimit-remaining') == '0'):
            if retry_after:
                return RateLimited(self._wall() + float(retry_after))
            reset = headers.get('x-ratelimit-reset')
            return RateLimited(float(reset) if reset else self._wall() + 60)
        if error.code >= 500:
            return Transient(f'{method} {path}: HTTP {error.code}')
        return ApiError(f'{method} {path}: HTTP {error.code} {_message(error)}')


def _message(error):
    try:
        return str(json.loads(error.read(4096)).get('message', ''))[:200]
    except (ValueError, AttributeError, OSError):
        return ''


def _paged(api, path, key):
    items, page = [], 1
    separator = '&' if '?' in path else '?'
    while True:
        data = api.get(f'{path}{separator}per_page=100&page={page}')
        items += data[key]
        if not data[key] or len(items) >= data.get('total_count', 0):
            return items
        page += 1


class Verdict:
    def __init__(self, workflows, checks):
        named = [('workflow ' + w.get('name', '?'), w) for w in workflows]
        named += [(c.get('name', '?'), c) for c in checks]
        self.total = len(checks)
        self.finished = sum(1 for c in checks if c.get('conclusion') is not None)
        self.red = sorted(f"{name}: {run['conclusion']}" for name, run in named
                          if run.get('conclusion') not in PASSING | {None})
        self.pending = sorted(name for name, run in named
                              if run.get('conclusion') is None)
        self.lag = sorted(name for name, run in named
                          if run.get('conclusion') is not None
                          and run.get('status') != 'completed')
        if self.red:
            self.state = 'red'
        elif self.pending or not workflows:
            self.state = 'pending'
        else:
            self.state = 'green'

    def line(self, head):
        text = f'{head[:10]} {self.state}: {self.finished}/{self.total} checks finished'
        if self.red:
            text += '; red: ' + ', '.join(self.red)
        elif self.pending:
            more = len(self.pending) - 5
            text += '; waiting for: ' + ', '.join(self.pending[:5])
            text += f' (+{more})' if more > 0 else ''
        if self.lag:
            text += '; finished, status still lagging: ' + ', '.join(self.lag)
        return text


def evaluate(api, repo, head):
    workflows = _paged(api, f'repos/{repo}/actions/runs?head_sha={head}',
                       'workflow_runs')
    checks = _paged(api, f'repos/{repo}/commits/{head}/check-runs', 'check_runs')
    return Verdict(workflows, checks)


def wait(api, repo, pr, timeout_s, interval_s, out,
         clock=time.monotonic, wall=time.time, sleep=time.sleep):
    deadline = clock() + timeout_s
    last = None

    def say(line):
        nonlocal last
        if line != last:
            out(line)
            last = line

    while True:
        delay = interval_s
        try:
            pull = api.get(f'repos/{repo}/pulls/{pr}')
            if pull.get('state') != 'open':
                out(f'PR #{pr} is {pull.get("state")}, nothing to wait for')
                return 1
            head = pull['head']['sha']
            verdict = evaluate(api, repo, head)
            say(verdict.line(head))
            if verdict.state == 'green':
                return 0
            if verdict.state == 'red':
                return 1
        except RateLimited as limit:
            delay = max(limit.reset_epoch - wall(), 0) + 1
            reset = time.strftime('%H:%M:%SZ', time.gmtime(limit.reset_epoch))
            say(f'rate limited until {reset}')
        except Transient as error:
            say(f'transient: {error}')
        except ApiError as error:
            out(f'refused: {error}')
            return 1
        remaining = deadline - clock()
        if remaining <= 0:
            out(f'timeout; last state: {last}')
            return 2
        sleep(min(delay, remaining))


def merge(api, repo, pr, head, out, sleep=time.sleep):
    head = head.lower()
    if len(head) < 7:
        out('refused: --head needs at least 7 hex digits of the reviewed head')
        return 1
    pull = api.get(f'repos/{repo}/pulls/{pr}')
    if pull.get('state') != 'open':
        out(f'refused: PR #{pr} is {pull.get("state")}')
        return 1
    actual = pull['head']['sha']
    if not actual.startswith(head):
        out(f'refused: head moved to {actual[:10]}, review it first')
        return 1
    verdict = evaluate(api, repo, actual)
    out(verdict.line(actual))
    if verdict.state != 'green':
        out('refused: checks are not green')
        return 1
    # GitHub computes mergeability in the background; "unknown" means not yet.
    for _ in range(3):
        if pull.get('mergeable_state') not in (None, 'unknown'):
            break
        sleep(2)
        pull = api.get(f'repos/{repo}/pulls/{pr}')
    if pull['head']['sha'] != actual:
        out('refused: head moved while checking')
        return 1
    state = pull.get('mergeable_state')
    if state not in MERGEABLE:
        out(f'refused: GitHub reports mergeable_state {state}')
        return 1
    result = api.put(f'repos/{repo}/pulls/{pr}/merge', {
        'merge_method': 'squash',
        'sha': actual,
        'commit_title': f'{pull["title"]} (#{pr})',
    })
    if not result.get('merged'):
        out(f'refused: {result.get("message", "not merged")}')
        return 1
    out(f'merged #{pr} as {result["sha"][:10]}')
    return 0


def main(argv=None, env=None, api_factory=GitHub, out=None):
    env = os.environ if env is None else env
    out = out or (lambda line: print(line, flush=True))
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--repo', default=DEFAULT_REPO)
    commands = parser.add_subparsers(dest='command', required=True)
    waiting = commands.add_parser('wait')
    waiting.add_argument('pr', type=int)
    waiting.add_argument('--timeout-min', type=float, default=60)
    waiting.add_argument('--interval', type=float, default=30)
    merging = commands.add_parser('merge')
    merging.add_argument('pr', type=int)
    merging.add_argument('--head', required=True)
    args = parser.parse_args(argv)
    token = env.get('GITHUB_TOKEN')
    if not token:
        out('GITHUB_TOKEN is not set (named credential, docs/DEVELOPMENT.md)')
        return 2
    api = api_factory(token)
    if args.command == 'wait':
        return wait(api, args.repo, args.pr, args.timeout_min * 60,
                    max(args.interval, MIN_INTERVAL_SECONDS), out)
    try:
        return merge(api, args.repo, args.pr, args.head, out)
    except (ApiError, Transient, RateLimited) as error:
        out(f'refused: {error}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
