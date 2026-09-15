"""Keep unsupported lockfiles from silently escaping the dependency gate."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("inventory", ROOT / "tool/security_inventory.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="eatova-inventory-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock = {"version": 2, "pins": [{
            "kind": "remoteSourceControl",
            "location": "https://github.com/google/promises.git",
            "state": {"revision": "a" * 40, "version": "1.0.0"},
        }]}
        self.write_locks(self.lock)
        self.wrapper = self.root / "android/gradle/wrapper/gradle-wrapper.properties"
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_text(
            "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14.4-all.zip\n")

    def write_locks(self, lock):
        for path in MODULE.SWIFT_LOCKS:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(lock))

    def test_deduplicates_locks_and_keeps_exact_public_revision_and_tool_version(self):
        packages = MODULE.inventory(self.root)["results"][0]["packages"]
        self.assertEqual(packages, [
            {"package": {"name": "github.com/google/promises.git", "commit": "a" * 40}},
            {"package": {"name": "org.gradle:gradle-core", "version": "8.14.4", "ecosystem": "Maven"}},
        ])

    def test_rejects_missing_and_disagreeing_locks(self):
        other = self.root / MODULE.SWIFT_LOCKS[1]
        changed = copy.deepcopy(self.lock)
        changed["pins"][0]["state"]["revision"] = "b" * 40
        other.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "disagree"):
            MODULE.inventory(self.root)
        other.unlink()
        with self.assertRaises(FileNotFoundError):
            MODULE.inventory(self.root)

    def test_rejects_empty_unsupported_duplicate_and_unpinned_locks(self):
        cases = [
            {"version": 2, "pins": []}, {**self.lock, "version": 3},
            {**self.lock, "pins": self.lock["pins"] * 2},
            {**self.lock, "pins": [{**self.lock["pins"][0], "state": {"revision": "main"}}]},
        ]
        for lock in cases:
            with self.subTest(lock=lock):
                self.write_locks(lock)
                with self.assertRaises(ValueError):
                    MODULE.inventory(self.root)

    def test_does_not_export_unreviewed_origins_or_credentials(self):
        for origin in ["https://github.com/company/private.git",
                       "https://synthetic-password@github.com/google/promises.git",
                       "file:///private/dependency"]:
            with self.subTest(origin=origin):
                lock = copy.deepcopy(self.lock)
                lock["pins"][0]["location"] = origin
                self.write_locks(lock)
                with self.assertRaisesRegex(ValueError, "public-source review") as error:
                    MODULE.inventory(self.root)
                self.assertNotIn(origin, str(error.exception))

    def test_rejects_unknown_or_ambiguous_gradle_distribution(self):
        for value in ["", "distributionUrl=https://private.invalid/gradle-8.14.4.zip\n",
                      self.wrapper.read_text() * 2]:
            self.wrapper.write_text(value)
            with self.assertRaisesRegex(ValueError, "official stable Gradle"):
                MODULE.inventory(self.root)


if __name__ == "__main__":
    unittest.main()
