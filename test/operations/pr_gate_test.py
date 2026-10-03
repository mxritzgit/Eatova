"""PR gate verdict, wait and merge; offline, no credentials or sockets."""

import email.message
import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.error

SPEC = importlib.util.spec_from_file_location(
    'pr_gate', Path(__file__).resolve().parents[2] / 'scripts/operations/pr_gate.py')
pr_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_gate)

REPO = 'owner/repo'
HEAD = '9e65725ed75c544d3cb47885dd7f19d1ebdcba25'
TOKEN = 'token-value-never-printed'


def run(name, status='completed', conclusion='success'):
    return {'name': name, 'status': status, 'conclusion': conclusion}


def green_checks():
    return [run('Flutter tests (shard 1/4)'), run('Secret scanning (gitleaks)'),
            run('Supabase migration drift (Live-Abgleich)', conclusion='skipped')]


class Seq:
    """Answers in order; the last answer repeats."""

    def __init__(self, *answers):
        self.answers = list(answers)

    def next(self):
        return self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]


def answer(value):
    return value.next() if isinstance(value, Seq) else value


class FakeAPI:
    """Answers by path prefix; [failures] raise once each before answering."""

    def __init__(self, checks=None, workflows=None, pull=None):
        self.pull = pull or {'state': 'open', 'head': {'sha': HEAD},
                             'mergeable_state': 'clean', 'title': 'feat: x'}
        self.checks = green_checks() if checks is None else checks
        self.workflows = [run('security')] if workflows is None else workflows
        self.calls = []
        self.puts = []
        self.failures = {}

    def get(self, path):
        self.calls.append(path)
        for prefix, errors in self.failures.items():
            if path.startswith(prefix) and errors:
                raise errors.pop(0)
        if path.startswith(f'repos/{REPO}/pulls/'):
            return answer(self.pull)
        if path.startswith(f'repos/{REPO}/actions/runs?head_sha='):
            return {'total_count': len(self.workflows), 'workflow_runs': self.workflows}
        if path.startswith(f'repos/{REPO}/commits/{HEAD}/check-runs'):
            checks = answer(self.checks)
            return {'total_count': len(checks), 'check_runs': checks}
        raise AssertionError(f'unexpected GET {path}')

    def put(self, path, payload):
        self.puts.append((path, payload))
        return {'merged': True, 'sha': 'cbbc1cf38a5f00000000000000000000000000ff'}


class Clock:
    def __init__(self):
        self.now = 1000.0
        self.slept = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


class VerdictTest(unittest.TestCase):
    def test_finished_job_with_a_lagging_status_counts_as_green(self):
        # 2026-10-03, PR #127: conclusion success and completed_at set, but
        # GitHub never moved the status off in_progress.
        checks = green_checks() + [run('Secret scanning (gitleaks)', status='in_progress')]
        verdict = pr_gate.Verdict([run('security')], checks)
        self.assertEqual(verdict.state, 'green')
        self.assertEqual(verdict.lag, ['Secret scanning (gitleaks)'])
        self.assertIn('status still lagging: Secret scanning (gitleaks)', verdict.line(HEAD))

    def test_a_check_without_conclusion_is_pending(self):
        checks = green_checks() + [run('Android Release-Build (AAB + R8)', 'in_progress', None)]
        verdict = pr_gate.Verdict([run('security')], checks)
        self.assertEqual(verdict.state, 'pending')
        self.assertEqual(verdict.pending, ['Android Release-Build (AAB + R8)'])
        self.assertIn('3/4 checks finished', verdict.line(HEAD))

    def test_the_first_red_check_decides_while_others_still_run(self):
        checks = [run('Flutter tests (shard 2/4)', conclusion='failure'),
                  run('Android Debug-Build (APK)', 'queued', None)]
        verdict = pr_gate.Verdict([run('security', 'in_progress', None)], checks)
        self.assertEqual(verdict.state, 'red')
        self.assertIn('red: Flutter tests (shard 2/4): failure', verdict.line(HEAD))

    def test_cancelled_timed_out_and_action_required_are_red(self):
        for conclusion in ('cancelled', 'timed_out', 'action_required', 'stale'):
            verdict = pr_gate.Verdict([run('security')], [run('x', conclusion=conclusion)])
            self.assertEqual(verdict.state, 'red', conclusion)

    def test_skipped_and_neutral_pass_like_branch_protection(self):
        checks = [run('a', conclusion='skipped'), run('b', conclusion='neutral'), run('c')]
        self.assertEqual(pr_gate.Verdict([run('security')], checks).state, 'green')

    def test_an_unfinished_workflow_keeps_it_pending(self):
        # Jobs behind `needs:` appear only later; the workflow run knows.
        verdict = pr_gate.Verdict([run('security', 'in_progress', None)], green_checks())
        self.assertEqual(verdict.state, 'pending')
        self.assertEqual(verdict.pending, ['workflow security'])

    def test_no_workflow_yet_is_pending_not_green(self):
        self.assertEqual(pr_gate.Verdict([], []).state, 'pending')

    def test_pages_are_followed(self):
        api = FakeAPI()
        pages = {1: [run(f'c{i}') for i in range(100)], 2: [run('c100')]}
        api.get = lambda path: {'total_count': 101,
                                'check_runs': pages[int(path.rsplit('page=', 1)[1])]}
        self.assertEqual(len(pr_gate._paged(api, 'repos/x/commits/y/check-runs', 'check_runs')), 101)


class WaitTest(unittest.TestCase):
    def wait(self, api, timeout_s=600, interval_s=30):
        clock, lines = Clock(), []
        code = pr_gate.wait(api, REPO, 127, timeout_s, interval_s, lines.append,
                            clock=clock, wall=clock, sleep=clock.sleep)
        return code, lines, clock

    def test_returns_when_the_only_open_check_has_a_lagging_status(self):
        lagging = green_checks() + [run('Secret scanning (gitleaks)', status='in_progress')]
        code, lines, clock = self.wait(FakeAPI(checks=lagging))
        self.assertEqual(code, 0)
        self.assertEqual(clock.slept, [])
        self.assertIn('green', lines[-1])

    def test_polls_until_green_and_prints_each_state_once(self):
        pending = green_checks() + [run('Android Debug-Build (APK)', 'in_progress', None)]
        api = FakeAPI(checks=Seq(pending, pending, pending, green_checks()))
        code, lines, clock = self.wait(api)
        self.assertEqual(code, 0)
        self.assertEqual(clock.slept, [30, 30, 30])
        self.assertEqual(len(lines), 2, lines)

    def test_red_returns_one_without_waiting_for_the_rest(self):
        checks = [run('Flutter tests (shard 1/4)', conclusion='failure'),
                  run('Android Debug-Build (APK)', 'in_progress', None)]
        code, _, clock = self.wait(FakeAPI(checks=checks))
        self.assertEqual(code, 1)
        self.assertEqual(clock.slept, [])

    def test_rate_limit_sleeps_until_the_reset(self):
        api = FakeAPI()
        api.failures[f'repos/{REPO}/pulls/'] = [pr_gate.RateLimited(1000.0 + 300)]
        code, lines, clock = self.wait(api)
        self.assertEqual(code, 0)
        self.assertEqual(clock.slept, [301.0])
        self.assertTrue(lines[0].startswith('rate limited until'), lines)

    def test_transient_errors_are_retried(self):
        api = FakeAPI()
        api.failures[f'repos/{REPO}/actions/runs'] = [pr_gate.Transient('GET x: HTTP 502')]
        code, lines, _ = self.wait(api)
        self.assertEqual(code, 0)
        self.assertEqual(lines[0], 'transient: GET x: HTTP 502')

    def test_a_refusal_ends_the_wait(self):
        api = FakeAPI()
        api.failures[f'repos/{REPO}/pulls/'] = [pr_gate.ApiError('GET x: HTTP 401 Bad credentials')]
        code, lines, clock = self.wait(api)
        self.assertEqual(code, 1)
        self.assertEqual(clock.slept, [])
        self.assertIn('Bad credentials', lines[-1])

    def test_times_out_with_the_last_state(self):
        pending = [run('Android Debug-Build (APK)', 'in_progress', None)]
        code, lines, clock = self.wait(FakeAPI(checks=pending), timeout_s=90)
        self.assertEqual(code, 2)
        self.assertEqual(sum(clock.slept), 90)
        self.assertIn('waiting for: Android Debug-Build (APK)', lines[-1])

    def test_a_closed_pr_is_not_waited_for(self):
        api = FakeAPI(pull={'state': 'closed', 'head': {'sha': HEAD}})
        code, lines, _ = self.wait(api)
        self.assertEqual(code, 1)
        self.assertIn('is closed', lines[0])


class MergeTest(unittest.TestCase):
    def merge(self, api, head=HEAD[:10]):
        lines, clock = [], Clock()
        code = pr_gate.merge(api, REPO, 127, head, lines.append, sleep=clock.sleep)
        return code, lines

    def test_squash_merges_the_reviewed_head_with_a_lagging_status(self):
        lagging = green_checks() + [run('Secret scanning (gitleaks)', status='in_progress')]
        api = FakeAPI(checks=lagging)
        code, lines = self.merge(api)
        self.assertEqual(code, 0, lines)
        self.assertEqual(api.puts, [(f'repos/{REPO}/pulls/127/merge', {
            'merge_method': 'squash', 'sha': HEAD, 'commit_title': 'feat: x (#127)'})])
        self.assertEqual(lines[-1], 'merged #127 as cbbc1cf38a')

    def test_refuses_a_moved_head(self):
        api = FakeAPI()
        code, lines = self.merge(api, head='1234567890')
        self.assertEqual(code, 1)
        self.assertIn('head moved', lines[-1])
        self.assertEqual(api.puts, [])

    def test_refuses_a_too_short_head(self):
        code, lines = self.merge(FakeAPI(), head='9e65')
        self.assertEqual(code, 1)
        self.assertIn('7 hex digits', lines[-1])

    def test_refuses_pending_or_red_checks(self):
        for checks in ([run('a', 'in_progress', None)], [run('a', conclusion='failure')]):
            api = FakeAPI(checks=checks)
            code, lines = self.merge(api)
            self.assertEqual(code, 1)
            self.assertEqual(lines[-1], 'refused: checks are not green')
            self.assertEqual(api.puts, [])

    def test_waits_briefly_for_github_to_compute_mergeability(self):
        unknown = {'state': 'open', 'head': {'sha': HEAD}, 'mergeable_state': 'unknown',
                   'title': 'feat: x'}
        clean = dict(unknown, mergeable_state='clean')
        api = FakeAPI(pull=Seq(unknown, unknown, clean))
        code, lines = self.merge(api)
        self.assertEqual(code, 0, lines)

    def test_refuses_what_github_itself_blocks(self):
        api = FakeAPI(pull={'state': 'open', 'head': {'sha': HEAD},
                            'mergeable_state': 'blocked', 'title': 'feat: x'})
        code, lines = self.merge(api)
        self.assertEqual(code, 1)
        self.assertEqual(lines[-1], 'refused: GitHub reports mergeable_state blocked')
        self.assertEqual(api.puts, [])


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code, headers=None, body=b'{"message": "Bad credentials"}'):
    message = email.message.Message()
    for key, value in (headers or {}).items():
        message[key] = value
    return urllib.error.HTTPError('https://api.github.com/x', code, 'error', message,
                                  io.BytesIO(body))


class GitHubClientTest(unittest.TestCase):
    def client(self, outcome):
        seen = []

        def opener(request, timeout):
            seen.append(request)
            if isinstance(outcome, Exception):
                raise outcome
            return FakeResponse(json.dumps(outcome).encode())

        return pr_gate.GitHub(TOKEN, opener=opener, wall=lambda: 5000.0), seen

    def test_sends_the_token_only_as_a_header(self):
        api, seen = self.client({'ok': True})
        self.assertEqual(api.get('repos/x/pulls/1'), {'ok': True})
        self.assertEqual(seen[0].full_url, 'https://api.github.com/repos/x/pulls/1')
        self.assertEqual(seen[0].get_header('Authorization'), 'Bearer ' + TOKEN)

    def test_classifies_rate_limits(self):
        api, _ = self.client(http_error(403, {'x-ratelimit-remaining': '0',
                                              'x-ratelimit-reset': '6000'}))
        with self.assertRaises(pr_gate.RateLimited) as caught:
            api.get('repos/x/pulls/1')
        self.assertEqual(caught.exception.reset_epoch, 6000.0)
        api, _ = self.client(http_error(429, {'retry-after': '30'}))
        with self.assertRaises(pr_gate.RateLimited) as caught:
            api.get('repos/x/pulls/1')
        self.assertEqual(caught.exception.reset_epoch, 5030.0)

    def test_server_and_network_errors_are_transient(self):
        for error in (http_error(502), urllib.error.URLError('down'), TimeoutError()):
            api, _ = self.client(error)
            with self.assertRaises(pr_gate.Transient):
                api.get('repos/x/pulls/1')

    def test_other_client_errors_are_refusals_without_the_token(self):
        api, _ = self.client(http_error(401))
        with self.assertRaises(pr_gate.ApiError) as caught:
            api.get('repos/x/pulls/1')
        self.assertIn('HTTP 401 Bad credentials', str(caught.exception))
        self.assertNotIn(TOKEN, str(caught.exception))


class MainTest(unittest.TestCase):
    def test_needs_the_token_and_never_prints_it(self):
        lines = []
        self.assertEqual(pr_gate.main(['wait', '127'], env={}, out=lines.append), 2)
        self.assertIn('GITHUB_TOKEN is not set', lines[0])

        api = FakeAPI()
        api.failures[f'repos/{REPO}/pulls/'] = [pr_gate.ApiError('GET x: HTTP 401 Bad credentials')]
        lines = []
        code = pr_gate.main(['--repo', REPO, 'merge', '127', '--head', HEAD],
                            env={'GITHUB_TOKEN': TOKEN}, api_factory=lambda token: api,
                            out=lines.append)
        self.assertEqual(code, 1)
        self.assertTrue(lines and all(TOKEN not in line for line in lines), lines)


if __name__ == '__main__':
    unittest.main()
