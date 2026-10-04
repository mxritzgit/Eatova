"""Device build numbers and commands; offline, runs no flutter and no git."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    'device_build',
    Path(__file__).resolve().parents[2] / 'scripts/operations/device_build.py')
device_build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(device_build)


def fake_git(count='742', status=''):
    def runner(cmd, **kwargs):
        if cmd[1:] == ['rev-list', '--count', 'HEAD']:
            out = count
        elif cmd[1] == 'status':
            out = status
        else:
            raise AssertionError(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=out + '\n')
    return runner


class DeviceBuildTest(unittest.TestCase):
    def test_build_number_is_the_commit_count(self):
        self.assertEqual(device_build.build_number(fake_git('742')), 742)

    def test_an_empty_history_is_refused(self):
        with self.assertRaises(ValueError):
            device_build.build_number(fake_git('0'))

    def test_run_passes_defines_build_number_and_extra_args(self):
        self.assertEqual(
            device_build.command('run', 742, ['-d', 'iPhone'], 'flutter'),
            ['flutter', 'run', '--release',
             '--dart-define-from-file=dart_defines.json',
             '--build-number=742', '-d', 'iPhone'])

    def test_store_targets_build(self):
        self.assertEqual(device_build.command('ipa', 9, [])[:3],
                         ['flutter', 'build', 'ipa'])
        self.assertEqual(device_build.command('appbundle', 9, [])[:3],
                         ['flutter', 'build', 'appbundle'])

    def test_unknown_target_prints_usage(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(device_build.main(['web'], call=lambda *a, **k: 0), 64)
        self.assertIn('device_build.py run', err.getvalue())

    def test_missing_defines_stop_before_flutter(self):
        calls = []
        err = io.StringIO()
        with mock.patch.object(device_build, 'ROOT', Path('/does/not/exist')), \
                contextlib.redirect_stderr(err):
            code = device_build.main(['run'], runner=fake_git(),
                                     call=lambda *a, **k: calls.append(a) or 0)
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])

    def test_main_runs_flutter_with_the_commit_count(self):
        calls = []
        err = io.StringIO()
        with mock.patch.object(Path, 'is_file', return_value=True), \
                mock.patch.dict('os.environ', {'FLUTTER': 'flutter'}), \
                contextlib.redirect_stderr(err):
            code = device_build.main(
                ['run', '-d', 'phone'], runner=fake_git('800', ' M lib/a.dart'),
                call=lambda cmd, **k: calls.append(cmd) or 0)
        self.assertEqual(code, 0)
        self.assertEqual(calls[0][-3:], ['--build-number=800', '-d', 'phone'])
        self.assertIn('uncommitted changes', err.getvalue())


if __name__ == '__main__':
    unittest.main()
