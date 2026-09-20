"""Real Git-history regressions for the forward-only client release gate."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from check_storage_release import (
    CUTOVER_COMMIT, IncompatibleRelease, SUPPORTED_CONTRACT, check_candidate, git,
)


class StorageReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="eatova_release_")
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name)
        git(self.repository, "init", "--initial-branch=main")
        git(self.repository, "config", "user.name", "Release test")
        git(self.repository, "config", "user.email", "release-test@example.invalid")
        self.legacy = self.commit("old storage", SUPPORTED_CONTRACT)
        self.cutover = self.commit("SQLite", None)
        self.current = self.commit("guarded SQLite", SUPPORTED_CONTRACT)

    def commit(self, description, contract):
        (self.repository / "version.txt").write_text(description, encoding="utf-8")
        path = self.repository / "release" / "storage_contract.json"
        path.parent.mkdir(exist_ok=True)
        if contract is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(json.dumps(contract), encoding="utf-8")
        git(self.repository, "add", ".")
        git(self.repository, "commit", "-m", description)
        return git(self.repository, "rev-parse", "HEAD")

    def check(self, candidate, trusted=None):
        return check_candidate(
            self.repository, candidate, trusted or self.current,
            cutover=self.cutover,
        )

    def test_current_exact_merged_commit_and_tree_are_attested(self):
        result = self.check(self.current)
        self.assertTrue(result["eligible"])
        self.assertEqual(result["candidate_commit"], self.current)
        self.assertEqual(result["candidate_tree"], git(self.repository, "rev-parse", "HEAD^{tree}"))

    def test_old_storage_cannot_be_a_rollback_even_with_forged_manifest(self):
        with self.assertRaisesRegex(IncompatibleRelease, "predates"):
            self.check(self.legacy)

    def test_first_sqlite_build_without_guard_contract_is_rejected(self):
        with self.assertRaisesRegex(IncompatibleRelease, "valid storage contract"):
            self.check(self.cutover)

    def test_candidate_cannot_select_its_own_policy(self):
        unsupported = self.commit("older protocol", {**SUPPORTED_CONTRACT, "storage_protocol": 1})
        with self.assertRaisesRegex(IncompatibleRelease, "unsupported"):
            self.check(unsupported, trusted=unsupported)

    def test_unmerged_and_symbolic_candidates_are_rejected(self):
        future = self.commit("not yet merged", SUPPORTED_CONTRACT)
        with self.assertRaisesRegex(IncompatibleRelease, "not merged"):
            self.check(future)
        for ref in ["main", "HEAD", self.current[:12], "--help"]:
            with self.subTest(ref=ref), self.assertRaises(IncompatibleRelease):
                self.check(ref)

    def test_real_pre_sqlite_production_revision_is_rejected(self):
        repository = Path(__file__).resolve().parents[1]
        old_build = git(repository, "rev-parse", f"{CUTOVER_COMMIT}^")
        with self.assertRaisesRegex(IncompatibleRelease, "predates"):
            check_candidate(repository, old_build, git(repository, "rev-parse", "HEAD"))

    def test_failed_cli_never_produces_an_eligibility_artifact(self):
        output = self.repository / "eligibility.json"
        script = Path(__file__).with_name("check_storage_release.py")
        import sys
        result = subprocess.run(
            [sys.executable, str(script), "--candidate", "HEAD", "--output", str(output)],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
