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


def run_main(argv, platform='darwin', status='', call_result=0):
    calls = []
    err, out = io.StringIO(), io.StringIO()
    with mock.patch.object(Path, 'is_file', return_value=True), \
            mock.patch.dict('os.environ', {'FLUTTER': 'flutter'}), \
            contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
        code = device_build.main(
            argv, runner=fake_git('800', status), platform=platform,
            call=lambda cmd, **k: calls.append(cmd) or call_result)
    return code, calls, err.getvalue(), out.getvalue()


class DeviceBuildTest(unittest.TestCase):
    def test_build_number_is_the_commit_count(self):
        self.assertEqual(device_build.build_number(fake_git('742')), 742)

    def test_an_empty_history_is_refused(self):
        with self.assertRaises(ValueError):
            device_build.build_number(fake_git('0'))

    def test_iphone_builds_then_installs_on_the_named_device(self):
        build, install = device_build.commands(
            'iphone', 742, ['-d', 'iPhone'], 'flutter')
        self.assertEqual(build, [
            'flutter', 'build', 'ios', '--release',
            '--dart-define-from-file=dart_defines.json', '--build-number=742'])
        self.assertEqual(install, ['flutter', 'install', '--release', '-d',
                                   'iPhone'])

    def test_android_builds_an_apk_then_installs(self):
        build, install = device_build.commands(
            'android', 9, ['--device-id=emulator-5554'])
        self.assertEqual(build[:3], ['flutter', 'build', 'apk'])
        self.assertEqual(install[-2:], ['-d', 'emulator-5554'])

    def test_flutter_run_never_gets_a_build_number(self):
        # `flutter run` has no --build-number option (2026-10-04: the first
        # version of this script ran into "Could not find an option").
        for target in device_build.TARGETS:
            for step in device_build.commands(target, 9, []):
                self.assertNotEqual(step[1], 'run', target)
                if '--build-number=9' in step:
                    self.assertEqual(step[1], 'build', target)

    def test_store_targets_only_build(self):
        steps = device_build.commands('ipa', 9, ['--obfuscate'])
        self.assertEqual(len(steps), 1)
        self.assertEqual(steps[0][:3], ['flutter', 'build', 'ipa'])
        self.assertEqual(steps[0][-1], '--obfuscate')

    def test_a_device_flag_without_id_is_refused(self):
        with self.assertRaises(ValueError):
            device_build.commands('android', 9, ['-d'])

    def test_unknown_target_prints_usage(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(device_build.main(['run'], call=lambda *a, **k: 0), 64)
        self.assertIn('device_build.py iphone', err.getvalue())

    def test_missing_defines_stop_before_flutter(self):
        calls = []
        err = io.StringIO()
        with mock.patch.object(device_build, 'ROOT', Path('/does/not/exist')), \
                contextlib.redirect_stderr(err):
            code = device_build.main(['android'], runner=fake_git(),
                                     call=lambda *a, **k: calls.append(a) or 0)
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])

    def test_iphone_outside_macos_says_so_before_building(self):
        code, calls, err, _ = run_main(['iphone'], platform='win32')
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])
        self.assertIn('macOS', err)

    def test_main_builds_and_installs_with_the_commit_count(self):
        code, calls, err, _ = run_main(['android', '-d', 'phone'],
                                       platform='win32', status=' M lib/a.dart')
        self.assertEqual(code, 0)
        self.assertEqual(calls[0][-1], '--build-number=800')
        self.assertEqual(calls[1], ['flutter', 'install', '--release', '-d',
                                    'phone'])
        self.assertIn('uncommitted changes', err)

    def test_a_failed_build_installs_nothing(self):
        code, calls, _, _ = run_main(['android'], call_result=1)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)

    def test_dry_run_prints_and_runs_nothing(self):
        code, calls, _, out = run_main(['iphone', '--dry-run'], platform='win32')
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])
        self.assertIn('flutter build ios --release', out)
        self.assertIn('flutter install --release', out)


if __name__ == '__main__':
    unittest.main()
