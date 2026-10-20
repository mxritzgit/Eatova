"""The hourly ops watch, checked as text: no credentials, sockets or runs.

Text, not a YAML parser: the CI runner's python3 has no PyYAML guarantee.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ops-watch.yml'


def step(text, name):
    """The text of one step, from its name to the next step."""
    start = text.index('- name: ' + name)
    end = text.find('\n      - ', start + 1)
    return text[start:] if end < 0 else text[start:end]


class OpsWatchWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding='utf-8')
        self.code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))

    def test_hourly_and_manual_only_never_on_pull_requests(self):
        trigger = re.search(r'(?ms)^on:\n(.*?)^\S', self.text).group(1)
        self.assertEqual(re.findall(r'(?m)^  (\w+):', trigger), ['schedule', 'workflow_dispatch'])
        self.assertIn("    - cron: '17 * * * *'", trigger)

    def test_read_only_main_only_in_its_environment(self):
        self.assertRegex(self.text, r'(?m)^permissions:\n  contents: read\n\n')
        self.assertIsNone(re.search(r'(?m)^[ \t]+permissions:', self.text), 'no job-level permissions')
        self.assertNotRegex(self.code, r'\bwrite\b')
        self.assertRegex(self.text, r'(?m)^    environment: ops-watch$')
        self.assertRegex(self.text, r"(?m)^    if: github\.repository == 'mxritzgit/Eatova' && github\.ref == 'refs/heads/main'$")
        self.assertRegex(self.text, r'(?m)^  cancel-in-progress: false$')
        self.assertRegex(self.text, r'(?m)^    timeout-minutes: 10$')
        self.assertIn('persist-credentials: false', self.text)

    def test_budget_warning_at_80_and_boot_probe_of_every_function(self):
        readiness = step(self.text, 'Readiness (project and AI budget)')
        probe = step(self.text, 'Boot probe (all functions)')
        self.assertIn('python3 scripts/operations/readiness.py', readiness)
        self.assertIn('--budget-warning-percent 80', readiness)
        self.assertIn('set -euo pipefail', readiness)
        self.assertIn('deploy_functions.py probe --slugs all', probe)
        # The probe runs even when the budget already failed the job.
        self.assertIn('if: ${{ !cancelled() }}', probe)
        for text in (readiness, probe):
            self.assertNotIn('|| true', text)
            self.assertNotIn('continue-on-error', text)
        # Backups only with an agreed RPO; never a hard-coded threshold.
        self.assertIn('BACKUP_MAX_AGE_HOURS: ${{ vars.OPS_WATCH_BACKUP_MAX_AGE_HOURS }}', readiness)
        self.assertNotRegex(readiness, r'--backup-max-age-hours \d')

    def test_no_paid_call_and_no_user_data(self):
        for forbidden in ('coach-chat/', 'analyze-meal/', 'Authorization: Bearer', 'curl ', 'service_role',
                          'functions invoke', 'select '):
            self.assertNotIn(forbidden, self.code)

    def test_secrets_reach_step_env_only_and_are_never_echoed(self):
        names = set(re.findall(r'\$\{\{\s*secrets\.(\w+)\s*\}\}', self.text))
        self.assertEqual(names, {'SUPABASE_ACCESS_TOKEN', 'SUPABASE_PROJECT_REF', 'SUPABASE_ANON_KEY'})
        for line in self.code.splitlines():
            if 'secrets.' in line:
                self.assertRegex(line, r'^\s+(SUPABASE_[A-Z_]+): \$\{\{ secrets\.\1 \}\}$', line)
        self.assertNotRegex(self.text, r'echo[^\n]*\$\{?(SUPABASE_ACCESS_TOKEN|SUPABASE_ANON_KEY|SUPABASE_PROJECT_REF)')


if __name__ == '__main__':
    unittest.main()
