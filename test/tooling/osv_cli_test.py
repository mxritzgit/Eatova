"""Exercise the installed scanner against ignored files and public package fixtures."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNER = None


class ScannerTests(unittest.TestCase):
    def setUp(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="osv-regression-", dir=build)
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        self.directory = self.project / "build"
        self.directory.mkdir()
        (self.project / ".gitignore").write_text("build/\n", encoding="utf-8")
        subprocess.run(["git", "init", "--quiet", str(self.project)], check=True, timeout=30)
        subprocess.run(["git", "add", ".gitignore"], cwd=self.project, check=True, timeout=30)
        subprocess.run(["git", "-c", "user.name=Scanner fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "--quiet", "-m", "Public scanner fixture"],
                       cwd=self.project, check=True, timeout=30)
        ignored = subprocess.run(["git", "check-ignore", "--quiet", str(self.directory)],
                                 cwd=self.project, capture_output=True, timeout=30)
        self.assertEqual(ignored.returncode, 0, "Regression fixture must be ignored in a real Git checkout")

    def custom(self, version):
        path = self.directory / "osv-scanner-custom.json"
        path.write_text(json.dumps({"results": [{"packages": [{"package": {
            "ecosystem": "Maven", "name": "com.google.code.gson:gson", "version": version,
        }}]}]}), encoding="utf-8")
        return "osv-scanner:" + path.relative_to(self.project).as_posix()

    def cdx(self, version="2.13.2"):
        path = self.directory / "android.cdx.json"
        path.write_text(json.dumps({"bomFormat": "CycloneDX", "specVersion": "1.5",
                                   "version": 1, "components": [{
            "type": "library", "group": "com.google.code.gson", "name": "gson",
            "version": version, "purl": f"pkg:maven/com.google.code.gson/gson@{version}",
        }]}), encoding="utf-8")
        return path.relative_to(self.project).as_posix()

    def scan(self, locks, output_format="json"):
        report = self.directory / "report.json"
        result = subprocess.run([
            str(SCANNER), "scan", "source", "--no-ignore", "--recursive",
            *[f"--lockfile={path}" for path in locks],
            f"--format={output_format}", f"--output-file={report}", "./",
        ], cwd=self.project, capture_output=True, text=True, timeout=120)
        return result, json.loads(report.read_text(encoding="utf-8")) if report.exists() else None

    def test_ignored_custom_and_android_inventories_generate_clean_sarif(self):
        for lock in [self.custom("2.13.2"), self.cdx()]:
            with self.subTest(lock=lock):
                result, report = self.scan([lock], "sarif")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(report["version"], "2.1.0")
                self.assertTrue(report["runs"])
                self.assertTrue(all(not run.get("results") for run in report["runs"]))

    def test_known_public_vulnerability_fails(self):
        for lock in [self.custom("2.8.8"), self.cdx("2.8.8")]:
            with self.subTest(lock=lock):
                result, report = self.scan([lock])
                self.assertEqual(result.returncode, 1, result.stderr)
                ids = {vuln["id"] for group in report["results"] for package in group["packages"]
                       for vuln in package.get("vulnerabilities", [])}
                self.assertIn("GHSA-4jrv-ppp4-jm57", ids)

    def test_empty_scan_does_not_succeed(self):
        result = subprocess.run([
            str(SCANNER), "scan", "source", "--no-ignore", str(self.directory),
        ], cwd=self.project, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 128, result.stderr)

    def test_missing_or_malformed_inventory_is_an_error(self):
        malformed = self.directory / "bad.cdx.json"
        malformed.write_text("{not-json", encoding="utf-8")
        for path in [str(malformed), str(self.directory / "missing.cdx.json")]:
            with self.subTest(path=path):
                result, _ = self.scan([path])
                self.assertNotIn(result.returncode, (0, 1), result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--scanner", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    SCANNER = args.scanner.resolve()
    unittest.main(argv=[__file__, *remaining])
