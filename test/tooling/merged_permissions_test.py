"""Offline tests for the merged-manifest permission check (no Gradle, no build)."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('merged_permissions', ROOT / 'tool/merged_permissions.py')
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)

MERGED = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.eatova.app">
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission-sdk-23 android:name="android.permission.WAKE_LOCK" />
    <application android:label="Eatova" />
</manifest>
"""


def run(manifest, allowlist):
    with tempfile.TemporaryDirectory() as base:
        directory = Path(base) / 'merged_manifests/release/processReleaseManifest'
        directory.mkdir(parents=True)
        (directory / 'AndroidManifest.xml').write_text(manifest, encoding='utf-8')
        listed = Path(base) / 'allowlist.txt'
        listed.write_text(allowlist, encoding='utf-8')
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tool.main(['--manifest-dir', str(Path(base) / 'merged_manifests/release'),
                              '--allowlist', str(listed)])
        return code, out.getvalue(), err.getvalue()


class MergedPermissionsTest(unittest.TestCase):
    ALLOWED = ('# reviewed\nandroid.permission.CAMERA  # camera\n\nandroid.permission.INTERNET\n'
               'android.permission.WAKE_LOCK # androidx.work\n')

    def test_an_exact_match_passes_including_sdk_23_entries(self):
        code, out, err = run(MERGED, self.ALLOWED)
        self.assertEqual((code, err), (0, ''))
        self.assertIn('exactly the 3 listed permissions', out)

    def test_a_permission_a_plugin_adds_fails_with_its_name(self):
        merged = MERGED.replace('<application', '<uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <application')
        code, _, err = run(merged, self.ALLOWED)
        self.assertEqual(code, 1)
        self.assertIn('::error::android.permission.RECORD_AUDIO is requested by the merged release manifest', err)
        self.assertIn('Data Safety', err)

    def test_a_listed_permission_no_longer_requested_also_fails(self):
        code, _, err = run(MERGED, self.ALLOWED + 'android.permission.VIBRATE\n')
        self.assertEqual(code, 1)
        self.assertIn('android.permission.VIBRATE is listed', err)

    def test_unreadable_inputs_are_errors_not_passes(self):
        self.assertEqual(run('<manifest', self.ALLOWED)[0], 2)
        self.assertEqual(run(MERGED, '# nothing listed\n')[0], 2)
        self.assertEqual(run(MERGED, 'not a permission!\n')[0], 2)
        self.assertEqual(run(MERGED, self.ALLOWED + 'android.permission.CAMERA\n')[0], 2)
        with tempfile.TemporaryDirectory() as base, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tool.main(['--manifest-dir', base]), 2, 'no manifest is no pass')

    def test_removed_entries_of_a_source_manifest_do_not_count(self):
        source = MERGED.replace('xmlns:android', 'xmlns:tools="http://schemas.android.com/tools" xmlns:android').replace(
            '<application', '<uses-permission android:name="android.permission.RECORD_AUDIO" tools:node="remove" />\n    <application')
        self.assertNotIn('android.permission.RECORD_AUDIO', tool.manifest_permissions(source))
        self.assertEqual(tool.removed_permissions(source), {'android.permission.RECORD_AUDIO'})

    def test_the_repository_list_agrees_with_the_source_manifest(self):
        # Offline half of the CI check: what the app manifest requests must be
        # listed, and what it strips from the merge must never be.
        allowed = tool.read_allowlist(tool.ALLOWLIST.read_text(encoding='utf-8'))
        source = (ROOT / 'android/app/src/main/AndroidManifest.xml').read_text(encoding='utf-8')
        self.assertEqual(tool.manifest_permissions(source) - allowed, set())
        removed = tool.removed_permissions(source)
        self.assertIn('android.permission.RECORD_AUDIO', removed)
        self.assertEqual(removed & allowed, set())


if __name__ == '__main__':
    unittest.main()
